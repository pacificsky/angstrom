import XCTest
@testable import Angstrom
import AngstromTestSupport

/// Unit tests for the adapter's queue-confined in-flight operation table (SPEC §5.4, §6.10,
/// PLAN §3.1). The table is CB-free and synchronous, so every ordering of reply, timeout,
/// cancellation and disconnect fan-out is driven directly, one call at a time.
final class BluetoothOpTableTests: XCTestCase {

    /// Angstrom-only: §5.4 — `finish` removes the entry before completing: a re-entrant `finish`
    /// or `finishOldest` from inside the completion finds nothing, so the completion runs once.
    func testFinishRemovesBeforeComplete() {
        let table = BluetoothOpTable<OpKey>()
        let recorder = Recorder()
        var reentered = false
        var awaitingInsideCompletion: Bool?
        var reentrantFinish: Bool?
        var reentrantFinishAbandoning: Bool?
        var reentrantFinishOldest: Bool?

        table.register(1, key: .read(1, "a"), isGATTRequest: true) { result in
            recorder.record(1, result)
            // Guard the re-entry so a table that completes before removing records a second
            // completion instead of recursing forever.
            guard !reentered else { return }
            reentered = true
            awaitingInsideCompletion = table.isAwaiting(.read(1, "a"))
            reentrantFinish = table.finish(1, .success(99), abandoning: false)
            reentrantFinishAbandoning = table.finish(1, .failure(TestError.timedOut), abandoning: true)
            reentrantFinishOldest = table.finishOldest(.read(1, "a"), .success(98))
        }

        XCTAssertTrue(table.finish(1, .success(42), abandoning: false))

        XCTAssertEqual(recorder.events, [Event(token: 1, outcome: .value(42))])
        XCTAssertEqual(awaitingInsideCompletion, false)
        XCTAssertEqual(reentrantFinish, false)
        XCTAssertEqual(reentrantFinishAbandoning, false)
        XCTAssertEqual(reentrantFinishOldest, false)
        // The re-entrant abandoning finish found no entry, so it recorded no owed reply.
        XCTAssertFalse(table.isAwaiting(.read(1, "a")))

        // A later finish of the same token is a no-op too.
        XCTAssertFalse(table.finish(1, .success(7), abandoning: false))
        XCTAssertEqual(recorder.events, [Event(token: 1, outcome: .value(42))])
    }

    /// Angstrom-only: §5.4 — `finish` of a never-registered or already-finished token returns false,
    /// completes nothing, and (even when abandoning a GATT request) records no owed reply.
    func testFinishUnknownTokenReturnsFalse() {
        let table = BluetoothOpTable<OpKey>()
        let recorder = Recorder()

        // Empty table.
        XCTAssertFalse(table.finish(7, .success(1), abandoning: false))
        XCTAssertFalse(table.finish(7, .failure(TestError.timedOut), abandoning: true))

        table.register(1, key: .read(1, "a"), isGATTRequest: true, complete: recorder.completion(1))

        // A token that was never registered leaves the registered op pending.
        XCTAssertFalse(table.finish(2, .success(5), abandoning: false))
        XCTAssertFalse(table.finish(2, .failure(TestError.cancelled), abandoning: true))
        XCTAssertEqual(recorder.events, [])
        XCTAssertTrue(table.isAwaiting(.read(1, "a")))

        // Reply first (delegate path), then the timeout fires: the timeout finds nothing.
        XCTAssertTrue(table.finishOldest(.read(1, "a"), .success(10)))
        XCTAssertFalse(table.finish(1, .failure(TestError.timedOut), abandoning: true))
        XCTAssertFalse(table.finish(1, .failure(TestError.cancelled), abandoning: true))
        XCTAssertEqual(recorder.events, [Event(token: 1, outcome: .value(10))])

        // The late timeout/cancel recorded no debt: the next op with the key is resolved by the
        // very next reply instead of having that reply swallowed.
        XCTAssertFalse(table.isAwaiting(.read(1, "a")))
        table.register(2, key: .read(1, "a"), isGATTRequest: true, complete: recorder.completion(2))
        XCTAssertTrue(table.finishOldest(.read(1, "a"), .success(11)))
        XCTAssertEqual(recorder.events, [
            Event(token: 1, outcome: .value(10)),
            Event(token: 2, outcome: .value(11)),
        ])
    }

    /// Angstrom-only: §5.4 — a GATT request abandoned by timeout or cancellation owes exactly one
    /// delegate reply for its key; `finishOldest` swallows that reply so it cannot resolve a newer op.
    func testAbandonedGATTRequestOwesOneReply() {
        let table = BluetoothOpTable<OpKey>()
        let recorder = Recorder()
        let key = OpKey.read(1, "a")

        // Timeout abandons op 1, then a cancellation races in for the same token.
        table.register(1, key: key, isGATTRequest: true, complete: recorder.completion(1))
        XCTAssertTrue(table.finish(1, .failure(TestError.timedOut), abandoning: true))
        XCTAssertFalse(table.finish(1, .failure(TestError.cancelled), abandoning: true))
        XCTAssertEqual(recorder.events, [Event(token: 1, outcome: .error(.timedOut))])
        XCTAssertTrue(table.isAwaiting(key))

        // A newer op with the same key: the late reply for op 1 is swallowed, not delivered.
        table.register(2, key: key, isGATTRequest: true, complete: recorder.completion(2))
        XCTAssertTrue(table.finishOldest(key, .success(100)))
        XCTAssertEqual(recorder.events, [Event(token: 1, outcome: .error(.timedOut))])
        XCTAssertTrue(table.isAwaiting(key))

        // Exactly one reply was owed (the racing cancel added none): the next reply resolves op 2.
        XCTAssertTrue(table.finishOldest(key, .success(200)))
        XCTAssertEqual(recorder.events, [
            Event(token: 1, outcome: .error(.timedOut)),
            Event(token: 2, outcome: .value(200)),
        ])
        XCTAssertFalse(table.isAwaiting(key))
        XCTAssertFalse(table.finishOldest(key, .success(300)))

        // Cancellation path with no newer op: one reply swallowed (true), then nothing (false).
        table.register(3, key: key, isGATTRequest: true, complete: recorder.completion(3))
        XCTAssertTrue(table.finish(3, .failure(TestError.cancelled), abandoning: true))
        XCTAssertTrue(table.finishOldest(key, .success(400)))
        XCTAssertFalse(table.isAwaiting(key))
        XCTAssertFalse(table.finishOldest(key, .success(500)))

        // Two abandoned ops owe two replies.
        table.register(4, key: key, isGATTRequest: true, complete: recorder.completion(4))
        table.register(5, key: key, isGATTRequest: true, complete: recorder.completion(5))
        XCTAssertTrue(table.finish(4, .failure(TestError.timedOut), abandoning: true))
        XCTAssertTrue(table.finish(5, .failure(TestError.cancelled), abandoning: true))
        XCTAssertTrue(table.finishOldest(key, .success(600)))
        XCTAssertTrue(table.isAwaiting(key))
        XCTAssertTrue(table.finishOldest(key, .success(700)))
        XCTAssertFalse(table.isAwaiting(key))
        XCTAssertFalse(table.finishOldest(key, .success(800)))

        // The debt is per key: an abandoned op on one characteristic does not swallow another's reply.
        table.register(6, key: key, isGATTRequest: true, complete: recorder.completion(6))
        table.register(7, key: .read(1, "b"), isGATTRequest: true, complete: recorder.completion(7))
        XCTAssertTrue(table.finish(6, .failure(TestError.timedOut), abandoning: true))
        XCTAssertFalse(table.isAwaiting(.write(1, "a")))
        XCTAssertTrue(table.finishOldest(.read(1, "b"), .success(900)))

        XCTAssertEqual(recorder.events, [
            Event(token: 1, outcome: .error(.timedOut)),
            Event(token: 2, outcome: .value(200)),
            Event(token: 3, outcome: .error(.cancelled)),
            Event(token: 4, outcome: .error(.timedOut)),
            Event(token: 5, outcome: .error(.cancelled)),
            Event(token: 6, outcome: .error(.timedOut)),
            Event(token: 7, outcome: .value(900)),
        ])
        XCTAssertTrue(table.isAwaiting(key))
    }

    /// Angstrom-only: §5.4 — abandoning a non-GATT op (e.g. connect), or finishing a GATT request
    /// without abandoning it, owes nothing: the next reply for the key resolves the next op.
    func testAbandonedNonGATTOwesNothing() {
        let table = BluetoothOpTable<OpKey>()
        let recorder = Recorder()

        // Non-GATT op abandoned by timeout, then by a racing cancellation.
        table.register(1, key: .connect(1), isGATTRequest: false, complete: recorder.completion(1))
        XCTAssertTrue(table.finish(1, .failure(TestError.timedOut), abandoning: true))
        XCTAssertFalse(table.finish(1, .failure(TestError.cancelled), abandoning: true))
        XCTAssertFalse(table.isAwaiting(.connect(1)))
        XCTAssertFalse(table.finishOldest(.connect(1), .success(1)))

        table.register(2, key: .connect(1), isGATTRequest: false, complete: recorder.completion(2))
        XCTAssertTrue(table.finishOldest(.connect(1), .success(2)))

        // GATT request finished with `abandoning: false` (e.g. its start threw): no debt either.
        table.register(3, key: .write(1, "a"), isGATTRequest: true, complete: recorder.completion(3))
        XCTAssertTrue(table.finish(3, .failure(TestError.gatt), abandoning: false))
        XCTAssertFalse(table.isAwaiting(.write(1, "a")))
        table.register(4, key: .write(1, "a"), isGATTRequest: true, complete: recorder.completion(4))
        XCTAssertTrue(table.finishOldest(.write(1, "a"), .success(4)))

        XCTAssertEqual(recorder.events, [
            Event(token: 1, outcome: .error(.timedOut)),
            Event(token: 2, outcome: .value(2)),
            Event(token: 3, outcome: .error(.gatt)),
            Event(token: 4, outcome: .value(4)),
        ])
        XCTAssertFalse(table.isAwaiting(.connect(1)))
        XCTAssertFalse(table.isAwaiting(.write(1, "a")))
    }

    /// Angstrom-only: §5.4 — `owe` records one debt per call (best-effort unsubscribe); each debt
    /// swallows exactly one reply for its key before any registered op sees one.
    func testOweSwallowsNextReply() {
        let table = BluetoothOpTable<OpKey>()
        let recorder = Recorder()
        let key = OpKey.notify(1, "sc")

        // A debt with no op: swallowed (true), then nothing outstanding (false).
        table.owe(key)
        XCTAssertTrue(table.isAwaiting(key))
        XCTAssertTrue(table.finishOldest(key, .success(1)))
        XCTAssertFalse(table.isAwaiting(key))
        XCTAssertFalse(table.finishOldest(key, .success(2)))

        // Two debts, then an op registered after them: the first two replies are swallowed.
        table.owe(key)
        table.owe(key)
        table.register(1, key: key, isGATTRequest: true, complete: recorder.completion(1))
        XCTAssertTrue(table.finishOldest(key, .success(10)))
        XCTAssertEqual(recorder.events, [])
        XCTAssertTrue(table.finishOldest(key, .success(20)))
        XCTAssertEqual(recorder.events, [])
        XCTAssertTrue(table.isAwaiting(key))
        XCTAssertTrue(table.finishOldest(key, .failure(TestError.gatt)))
        XCTAssertEqual(recorder.events, [Event(token: 1, outcome: .error(.gatt))])
        XCTAssertFalse(table.isAwaiting(key))
        XCTAssertFalse(table.finishOldest(key, .success(40)))

        // A debt swallows the next reply even when the op was registered first.
        table.register(2, key: key, isGATTRequest: true, complete: recorder.completion(2))
        table.owe(key)
        XCTAssertTrue(table.finishOldest(key, .success(50)))
        XCTAssertEqual(recorder.events, [Event(token: 1, outcome: .error(.gatt))])
        XCTAssertTrue(table.finishOldest(key, .success(60)))
        XCTAssertEqual(recorder.events, [
            Event(token: 1, outcome: .error(.gatt)),
            Event(token: 2, outcome: .value(60)),
        ])

        // A debt on another key does not swallow this key's reply.
        table.owe(.notify(2, "sc"))
        table.register(3, key: key, isGATTRequest: true, complete: recorder.completion(3))
        XCTAssertTrue(table.finishOldest(key, .success(70)))
        XCTAssertEqual(recorder.events.last, Event(token: 3, outcome: .value(70)))
        XCTAssertTrue(table.isAwaiting(.notify(2, "sc")))
    }

    /// Angstrom-only: §5.4 — ops sharing a key resolve FIFO by registration order (not token order);
    /// ops finished directly by token drop out of that order; other keys are untouched.
    func testFinishOldestIsFIFO() {
        let table = BluetoothOpTable<OpKey>()
        let recorder = Recorder()
        let a = OpKey.read(1, "a")
        let b = OpKey.read(1, "b")

        table.register(5, key: a, isGATTRequest: true, complete: recorder.completion(5))
        table.register(3, key: b, isGATTRequest: true, complete: recorder.completion(3))
        table.register(9, key: a, isGATTRequest: true, complete: recorder.completion(9))
        table.register(1, key: a, isGATTRequest: true, complete: recorder.completion(1))
        table.register(2, key: b, isGATTRequest: true, complete: recorder.completion(2))

        XCTAssertTrue(table.finishOldest(a, .success(100)))
        XCTAssertEqual(recorder.events, [Event(token: 5, outcome: .value(100))])

        // The next-oldest `a` op (token 9) fails on its own (start threw): it leaves the order.
        XCTAssertTrue(table.finish(9, .failure(TestError.gatt), abandoning: false))

        XCTAssertTrue(table.finishOldest(a, .success(200)))
        XCTAssertTrue(table.finishOldest(b, .success(300)))
        XCTAssertTrue(table.finishOldest(b, .success(400)))
        XCTAssertFalse(table.finishOldest(a, .success(500)))
        XCTAssertFalse(table.finishOldest(b, .success(600)))

        XCTAssertEqual(recorder.events, [
            Event(token: 5, outcome: .value(100)),
            Event(token: 9, outcome: .error(.gatt)),
            Event(token: 1, outcome: .value(200)),
            Event(token: 3, outcome: .value(300)),
            Event(token: 2, outcome: .value(400)),
        ])

        // A token reused after its op finished joins the back of the order.
        table.register(7, key: a, isGATTRequest: true, complete: recorder.completion(7))
        table.register(5, key: a, isGATTRequest: true, complete: recorder.completion(5))
        XCTAssertTrue(table.finishOldest(a, .success(700)))
        XCTAssertEqual(recorder.events.last, Event(token: 7, outcome: .value(700)))
        XCTAssertTrue(table.finishOldest(a, .success(800)))
        XCTAssertEqual(recorder.events.last, Event(token: 5, outcome: .value(800)))
        XCTAssertEqual(recorder.events.count, 7)
    }

    /// Angstrom-only: §5.4 — disconnect fan-out: `failAll` fails every matching op exactly once, in
    /// registration order, with the given error, drops matching owed replies, and keeps the rest.
    func testFailAllMatchingClearsOrphans() {
        let table = BluetoothOpTable<OpKey>()
        let recorder = Recorder()
        let onPeripheral1: (OpKey) -> Bool = { $0.peripheral == 1 }

        // Debts on peripheral 1 (an abandoned read and an unawaited unsubscribe) and peripheral 2.
        table.register(10, key: .read(1, "x"), isGATTRequest: true, complete: recorder.completion(10))
        XCTAssertTrue(table.finish(10, .failure(TestError.timedOut), abandoning: true))
        table.owe(.notify(1, "sc"))
        table.owe(.write(2, "q"))

        table.register(4, key: .read(1, "z"), isGATTRequest: true, complete: recorder.completion(4))
        table.register(2, key: .write(2, "y"), isGATTRequest: true, complete: recorder.completion(2))
        table.register(3, key: .connect(1), isGATTRequest: false, complete: recorder.completion(3))
        table.register(1, key: .read(1, "x"), isGATTRequest: true, complete: recorder.completion(1))

        table.failAll(where: onPeripheral1, TestError.disconnected)

        XCTAssertEqual(recorder.events, [
            Event(token: 10, outcome: .error(.timedOut)),
            Event(token: 4, outcome: .error(.disconnected)),
            Event(token: 3, outcome: .error(.disconnected)),
            Event(token: 1, outcome: .error(.disconnected)),
        ])
        XCTAssertFalse(table.isAwaiting(.read(1, "x")))
        XCTAssertFalse(table.isAwaiting(.read(1, "z")))
        XCTAssertFalse(table.isAwaiting(.connect(1)))
        XCTAssertFalse(table.isAwaiting(.notify(1, "sc")))
        XCTAssertTrue(table.isAwaiting(.write(2, "y")))
        XCTAssertTrue(table.isAwaiting(.write(2, "q")))

        // Failed ops are gone: finishing them again is a no-op.
        XCTAssertFalse(table.finish(4, .success(0), abandoning: true))
        XCTAssertFalse(table.finish(1, .success(0), abandoning: false))

        // The dropped debts no longer swallow replies on the reconnected peripheral.
        table.register(5, key: .read(1, "x"), isGATTRequest: true, complete: recorder.completion(5))
        XCTAssertTrue(table.finishOldest(.read(1, "x"), .success(50)))
        XCTAssertEqual(recorder.events.last, Event(token: 5, outcome: .value(50)))
        XCTAssertFalse(table.finishOldest(.notify(1, "sc"), .success(0)))

        // A second fan-out with nothing matching completes nothing.
        let countBefore = recorder.events.count
        table.failAll(where: onPeripheral1, TestError.disconnected)
        XCTAssertEqual(recorder.events.count, countBefore)

        // Peripheral 2's debt survived and still swallows one reply; its op is still pending.
        XCTAssertTrue(table.finishOldest(.write(2, "q"), .success(0)))
        XCTAssertFalse(table.isAwaiting(.write(2, "q")))

        table.failAll(where: { _ in true }, TestError.gatt)
        XCTAssertEqual(recorder.events.count, countBefore + 1)
        XCTAssertEqual(recorder.events.last, Event(token: 2, outcome: .error(.gatt)))
        XCTAssertFalse(table.isAwaiting(.write(2, "y")))
    }

    /// Angstrom-only: §5.4 — `isAwaiting` is true exactly while a registered op or an owed reply is
    /// outstanding for the key, and is scoped to that key.
    func testIsAwaiting() {
        let table = BluetoothOpTable<OpKey>()
        let recorder = Recorder()
        let key = OpKey.read(1, "a")

        XCTAssertFalse(table.isAwaiting(key))

        // Registered ops.
        table.register(1, key: key, isGATTRequest: true, complete: recorder.completion(1))
        XCTAssertTrue(table.isAwaiting(key))
        XCTAssertFalse(table.isAwaiting(.read(1, "b")))
        XCTAssertFalse(table.isAwaiting(.read(2, "a")))
        XCTAssertFalse(table.isAwaiting(.write(1, "a")))
        table.register(2, key: key, isGATTRequest: false, complete: recorder.completion(2))
        XCTAssertTrue(table.finish(1, .success(1), abandoning: false))
        XCTAssertTrue(table.isAwaiting(key))
        XCTAssertTrue(table.finishOldest(key, .success(2)))
        XCTAssertFalse(table.isAwaiting(key))

        // Owed replies from `owe`, counted.
        table.owe(key)
        table.owe(key)
        XCTAssertTrue(table.isAwaiting(key))
        XCTAssertFalse(table.isAwaiting(.read(1, "b")))
        XCTAssertTrue(table.finishOldest(key, .success(3)))
        XCTAssertTrue(table.isAwaiting(key))
        XCTAssertTrue(table.finishOldest(key, .success(4)))
        XCTAssertFalse(table.isAwaiting(key))

        // Owed reply from an abandoned GATT request outlives the op itself.
        table.register(3, key: key, isGATTRequest: true, complete: recorder.completion(3))
        XCTAssertTrue(table.finish(3, .failure(TestError.cancelled), abandoning: true))
        XCTAssertTrue(table.isAwaiting(key))
        XCTAssertTrue(table.finishOldest(key, .success(5)))
        XCTAssertFalse(table.isAwaiting(key))

        // Fan-out clears both kinds.
        table.owe(key)
        table.register(4, key: key, isGATTRequest: true, complete: recorder.completion(4))
        table.failAll(where: { $0 == key }, TestError.disconnected)
        XCTAssertFalse(table.isAwaiting(key))

        XCTAssertEqual(recorder.events, [
            Event(token: 1, outcome: .value(1)),
            Event(token: 2, outcome: .value(2)),
            Event(token: 3, outcome: .error(.cancelled)),
            Event(token: 4, outcome: .error(.disconnected)),
        ])
    }

    /// Angstrom-only: §5.4 — a completion may re-enter the table (register the next op, finish other
    /// ops, fan out) and every op still completes exactly once with its own result.
    func testCompletionMayReenterTable() {
        let table = BluetoothOpTable<OpKey>()
        let recorder = Recorder()
        let key = OpKey.read(1, "a")

        // 1. A reply's completion registers the next op on the same key: the same reply must not
        //    resolve it; the next reply does.
        table.register(1, key: key, isGATTRequest: true) { result in
            recorder.record(1, result)
            table.register(2, key: key, isGATTRequest: true, complete: recorder.completion(2))
        }
        XCTAssertTrue(table.finishOldest(key, .success(10)))
        XCTAssertEqual(recorder.events, [Event(token: 1, outcome: .value(10))])
        XCTAssertTrue(table.isAwaiting(key))
        XCTAssertTrue(table.finishOldest(key, .success(20)))
        XCTAssertEqual(recorder.events, [
            Event(token: 1, outcome: .value(10)),
            Event(token: 2, outcome: .value(20)),
        ])
        XCTAssertFalse(table.isAwaiting(key))

        // 2. During fan-out, the first failed op's completion finishes a later matching op by
        //    token with a success: fan-out must not complete that op a second time.
        var innerFinish: Bool?
        table.register(3, key: .read(1, "b"), isGATTRequest: true) { result in
            recorder.record(3, result)
            innerFinish = table.finish(4, .success(40), abandoning: false)
        }
        table.register(4, key: .write(1, "b"), isGATTRequest: true, complete: recorder.completion(4))
        table.register(5, key: .connect(1), isGATTRequest: false, complete: recorder.completion(5))
        table.register(6, key: .connect(2), isGATTRequest: false, complete: recorder.completion(6))
        table.failAll(where: { $0.peripheral == 1 }, TestError.disconnected)
        XCTAssertEqual(innerFinish, true)
        XCTAssertEqual(Array(recorder.events.dropFirst(2)), [
            Event(token: 3, outcome: .error(.disconnected)),
            Event(token: 4, outcome: .value(40)),
            Event(token: 5, outcome: .error(.disconnected)),
        ])
        XCTAssertTrue(table.isAwaiting(.connect(2)))

        // 3. An abandoned op's completion owes and resolves on other keys and fans out the rest.
        var innerOldest: Bool?
        table.register(7, key: key, isGATTRequest: true) { result in
            recorder.record(7, result)
            innerOldest = table.finishOldest(.connect(2), .success(60))
            table.failAll(where: { _ in true }, TestError.gatt)
        }
        table.register(8, key: .write(3, "c"), isGATTRequest: true, complete: recorder.completion(8))
        XCTAssertTrue(table.finish(7, .failure(TestError.timedOut), abandoning: true))
        XCTAssertEqual(innerOldest, true)
        XCTAssertEqual(Array(recorder.events.dropFirst(5)), [
            Event(token: 7, outcome: .error(.timedOut)),
            Event(token: 6, outcome: .value(60)),
            Event(token: 8, outcome: .error(.gatt)),
        ])
        // The owed reply for op 7 was recorded before its completion ran, so the re-entrant
        // match-all fan-out dropped it.
        XCTAssertFalse(table.isAwaiting(key))
        XCTAssertFalse(table.finishOldest(key, .success(0)))
        XCTAssertEqual(recorder.events.count, 8)
    }
}

// MARK: - Helpers

private enum OpKey: Hashable, Sendable {
    case connect(Int)
    case read(Int, String)
    case write(Int, String)
    case notify(Int, String)

    var peripheral: Int {
        switch self {
        case .connect(let p), .read(let p, _), .write(let p, _), .notify(let p, _): return p
        }
    }
}

private enum TestError: Error, Equatable {
    case timedOut, cancelled, disconnected, gatt
}

private enum Outcome: Equatable {
    case value(Int)
    case error(TestError)
    case unexpected(String)
}

private struct Event: Equatable {
    let token: UInt64
    let outcome: Outcome
}

/// Records every completion call in order, so double completions and misrouted results show up.
private final class Recorder {
    private(set) var events: [Event] = []

    func record(_ token: UInt64, _ result: Result<any Sendable, any Error>) {
        let outcome: Outcome
        switch result {
        case .success(let value):
            outcome = (value as? Int).map(Outcome.value) ?? .unexpected("\(value)")
        case .failure(let error):
            outcome = (error as? TestError).map(Outcome.error) ?? .unexpected("\(error)")
        }
        events.append(Event(token: token, outcome: outcome))
    }

    func completion(_ token: UInt64) -> BluetoothOpTable<OpKey>.Completion {
        { [self] result in record(token, result) }
    }
}
