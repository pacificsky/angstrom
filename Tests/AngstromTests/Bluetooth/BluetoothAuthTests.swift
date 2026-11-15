import XCTest
@testable import Angstrom
import AngstromTestSupport

/// T1 parity suite, authentication (SPEC §3.4, §4.2 steps 6–7, §4.3, §4.8): the upstream auth tests of
/// `tests/test_bluetooth_client.py` and the Angstrom-only G-AUTH gap tests, run against the real
/// `LaMarzoccoBluetoothClient` over the AngstromTestSupport fakes.
final class BluetoothAuthTests: XCTestCase {

    // MARK: - Upstream parity

    /// Upstream: test_auth_read_back_failure (tests/test_bluetooth_client.py:617) [C18]
    func testWrongTokenReadsTenTimesThenFails() async throws {
        let rig = makeRig()
        rig.central.makeLink = { .laMarzocco(token: "other") }  // `bleak_client.token = "other"`

        do {
            _ = try await rig.client.setPower(on: true)
            XCTFail("expected .bluetoothAuthenticationFailed")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .bluetoothAuthenticationFailed)
            // `match="authentication failed"`; the §6.4 text.
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "Bluetooth authentication failed. The Bluetooth token is likely wrong.")
        }
        await rig.client.drainBackgroundWorkForTesting()

        let link = try XCTUnwrap(rig.central.links.first)
        XCTAssertEqual(rig.central.links.count, 1)
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .write(authChar, Data("token".utf8))]
            + Array(repeating: FakeOp.read(authChar), count: 10) + [.disconnect],
                       "10 auth reads, then the link is disconnected exactly once")
        XCTAssertEqual(rig.sleeper.requested(.authPoll), Array(repeating: .milliseconds(50), count: 9))
        XCTAssertEqual(rig.central.connectCount, 1, "an auth failure is not retried as a connect attempt")
        let state = await rig.client.authTestState { ($0.isConnected, $0.link == nil, $0.authenticationFailed) }
        XCTAssertFalse(state.0)
        XCTAssertTrue(state.1)
        XCTAssertTrue(state.2)
    }

    /// Upstream: test_auth_read_back_retries_until_confirmed (tests/test_bluetooth_client.py:636) [C19]
    func testAuthRetriesUntilConfirmed() async throws {
        let rig = makeRig()
        rig.central.makeLink = { .laMarzocco(token: "token", confirmOnRead: 3) }

        let status = try await rig.client.setPower(on: true)

        XCTAssertTrue(status.isSuccess)
        let link = try XCTUnwrap(rig.central.links.first)
        // 3 authentication reads and the command status.
        XCTAssertEqual(link.recordedOps.filter { if case .read = $0 { true } else { false } }.count, 4)
        XCTAssertEqual(link.recordedOps, [
            .discover(refresh: false), .write(authChar, Data("token".utf8)),
            .read(authChar), .read(authChar), .read(authChar),
            .write(writeChar, powerOn), .read(writeChar),
        ])
        XCTAssertEqual(rig.sleeper.requested(.authPoll), [.milliseconds(50), .milliseconds(50)])
        let state = await rig.client.authTestState { ($0.isConnected, $0.authenticationFailed) }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        await rig.client.disconnect()
    }

    /// Upstream: test_cancelled_connect_does_not_keep_unauthenticated_link (tests/test_bluetooth_client.py:1197) [C41]
    func testCancellationDuringAuthDropsLink() async throws {
        let rig = makeRig()
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        let held = Latch()
        let authStarted = expectation(description: "auth read started")
        link.beforeOp = { op in
            if op == .read(authChar) {
                authStarted.fulfill()
                await held.wait()  // the unanswered read
            }
        }
        rig.central.enqueueConnect(.success(link))
        let events = await rig.client.connectionEvents()

        let task = Task { try await rig.client.machineMode() }
        await fulfillment(of: [authStarted], timeout: 5)
        task.cancel()
        held.open()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        await rig.client.drainBackgroundWorkForTesting()

        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .write(authChar, Data("token".utf8)),
                                          .read(authChar), .disconnect],
                       "the half-open link is disconnected exactly once")
        let state = await rig.client.authTestState {
            ($0.isConnected, $0.link == nil, $0.reportedConnected, $0.idleTask == nil, $0.gateBusy)
        }
        XCTAssertFalse(state.0)
        XCTAssertTrue(state.1)
        XCTAssertFalse(state.2)
        XCTAssertTrue(state.3, "no idle timer for an unauthenticated link")
        XCTAssertEqual(state.4, [])
        let seen = await drain(events)
        XCTAssertEqual(seen, [], "the connection callback is never called")
        await rig.client.disconnect()
    }

    /// Upstream: test_authentication_failed_flag (tests/test_bluetooth_client.py:1305) [C49]
    func testAuthenticationFailedFlagSetAndCleared() async throws {
        let rig = makeRig()
        let initially = await rig.client.authenticationFailed
        XCTAssertFalse(initially)
        rig.central.enqueueConnect(.success(.laMarzocco(token: "other")))

        await assertThrows(.bluetoothAuthenticationFailed) { try await rig.client.setPower(on: true) }
        let failed = await rig.client.authenticationFailed
        XCTAssertTrue(failed)
        await rig.client.drainBackgroundWorkForTesting()

        // The machine was paired with the client's token (the next link accepts it).
        let status = try await rig.client.setPower(on: true)
        XCTAssertTrue(status.isSuccess)
        let cleared = await rig.client.authenticationFailed
        XCTAssertFalse(cleared)
        XCTAssertEqual(rig.central.connectCount, 2)
        await rig.client.disconnect()
    }

    /// Upstream: test_connection_callback_not_called_on_failed_authentication (tests/test_bluetooth_client.py:1405) [C54]
    func testUnauthenticatedLinkNeverReportedConnected() async throws {
        let rig = makeRig()
        rig.central.makeLink = { .laMarzocco(token: "other") }
        let events = await rig.client.connectionEvents()
        let raw = await rig.client.rawFrames()

        await assertThrows(.bluetoothAuthenticationFailed) { try await rig.client.setPower(on: true) }
        await rig.client.drainBackgroundWorkForTesting()

        let seen = await drain(events)
        XCTAssertEqual(seen, [], "no .connected, and no .disconnected either")
        let state = await rig.client.authTestState { ($0.isConnected, $0.reportedConnected, $0.hasBackgroundWorkForTesting) }
        XCTAssertFalse(state.0)
        XCTAssertFalse(state.1)
        XCTAssertFalse(state.2)
        let markers = await drain(raw).filter { $0.kind == .event }.map { String(decoding: $0.data, as: UTF8.self) }
        XCTAssertTrue(markers.contains("[connected]"), "the transport link did come up: \(markers)")
        XCTAssertFalse(markers.contains("[authenticated]"))
    }

    // MARK: - Angstrom-only

    /// Angstrom-only: G-AUTH-1 — a transport error during the auth write or read is `.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: …")`, not the auth case
    func testTransportErrorDuringAuthIsConnectionFailed() async throws {
        struct Case {
            let label: String
            let failWrite: Bool
            /// The auth read that throws (1-based); earlier reads return [0x00].
            let failingRead: Int
            let error: BluetoothTransportError
            let expected: LaMarzoccoError
            let authPolls: Int
            let flagAfter: Bool
        }
        let prefix = "Failed to connect to machine with Bluetooth: "
        let cases = [
            Case(label: "auth write GATT error", failWrite: true, failingRead: 0,
                 error: .gatt(domain: "CBATTErrorDomain", code: 5),
                 expected: .bluetoothConnectionFailed(prefix + "GATT error CBATTErrorDomain 5"), authPolls: 0, flagAfter: false),
            Case(label: "first auth read disconnected", failWrite: false, failingRead: 1,
                 error: .disconnected(code: 7),
                 expected: .bluetoothConnectionFailed(prefix + "disconnected (code 7)"), authPolls: 0, flagAfter: false),
            Case(label: "first auth read not connected", failWrite: false, failingRead: 1,
                 error: .notConnected,
                 expected: .bluetoothConnectionFailed(prefix + "not connected"), authPolls: 0, flagAfter: false),
            // Two unconfirmed reads set the flag; the transport error does not reset it (§3.4 step 6).
            Case(label: "third auth read GATT error", failWrite: false, failingRead: 3,
                 error: .gatt(domain: "CBATTErrorDomain", code: 2),
                 expected: .bluetoothConnectionFailed(prefix + "GATT error CBATTErrorDomain 2"), authPolls: 2, flagAfter: true),
            // D10: unavailable maps to `.bluetoothUnavailable` in every phase.
            Case(label: "auth write unavailable", failWrite: true, failingRead: 0,
                 error: .unavailable(.poweredOff),
                 expected: .bluetoothUnavailable(.poweredOff), authPolls: 0, flagAfter: false),
        ]

        for testCase in cases {
            let rig = makeRig()
            let link = FakeBluetoothLink()
            let reads = Locked(0)
            let error = testCase.error
            let failWrite = testCase.failWrite
            let failingRead = testCase.failingRead
            link.onWrite = { _, _ in if failWrite { throw error } }
            link.onRead = { _ in
                let count = reads.withLock { value -> Int in
                    value += 1
                    return value
                }
                if count == failingRead { throw error }
                return Data([0x00])
            }
            rig.central.enqueueConnect(.success(link))
            let events = await rig.client.connectionEvents()

            await assertThrows(testCase.expected, testCase.label) { try await rig.client.setPower(on: true) }
            await rig.client.drainBackgroundWorkForTesting()

            let expectedReads = failWrite ? 0 : failingRead
            XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .write(authChar, Data("token".utf8))]
                + Array(repeating: FakeOp.read(authChar), count: expectedReads) + [.disconnect], testCase.label)
            XCTAssertEqual(rig.sleeper.requested(.authPoll), Array(repeating: .milliseconds(50), count: testCase.authPolls),
                           testCase.label)
            XCTAssertEqual(rig.central.connectCount, 1, testCase.label)
            let state = await rig.client.authTestState { ($0.isConnected, $0.authenticationFailed) }
            XCTAssertFalse(state.0, testCase.label)
            XCTAssertEqual(state.1, testCase.flagAfter, testCase.label)
            let seen = await drain(events)
            XCTAssertEqual(seen, [], testCase.label)
        }
    }

    /// Angstrom-only: G-AUTH-2 — the auth poll sleeps 50 ms (`.authPoll`) before every read except the first: 9 sleeps for 10 reads
    func testAuthPollIntervalIs50ms() async throws {
        // `.authPoll` is manual: each sleep waits until fired, so the read/sleep interleaving is observable.
        let rig = makeRig(manual: [.idleDisconnect, .authPoll])
        let link = FakeBluetoothLink.laMarzocco(token: "other")
        rig.central.enqueueConnect(.success(link))
        let command = Task { try await rig.client.setPower(on: true) }

        for poll in 1...9 {
            await waitForPending(rig.sleeper, .authPoll)
            XCTAssertEqual(authReads(link), poll, "read \(poll) happens before sleep \(poll)")
            XCTAssertEqual(rig.sleeper.pendingCount(.authPoll), 1)
            XCTAssertEqual(rig.sleeper.requested(.authPoll), Array(repeating: .milliseconds(50), count: poll))
            rig.sleeper.fire(.authPoll)
        }
        switch await command.result {
        case .success:
            XCTFail("the wrong token never confirms")
        case .failure(let error):
            XCTAssertEqual(error as? LaMarzoccoError, .bluetoothAuthenticationFailed)
        }
        XCTAssertEqual(authReads(link), 10)
        XCTAssertEqual(rig.sleeper.requested(.authPoll), Array(repeating: .milliseconds(50), count: 9),
                       "no sleep after the last read")
        XCTAssertEqual(rig.sleeper.pendingCount(.authPoll), 0)

        // A first read of [0x01] needs no sleep at all.
        let quick = makeRig()
        _ = try await quick.client.setPower(on: true)
        XCTAssertEqual(quick.sleeper.requested(.authPoll), [])
        await quick.client.disconnect()
        await rig.client.drainBackgroundWorkForTesting()
    }

    /// Angstrom-only: G-AUTH-3 — `authenticationFailed` reflects the last auth read and is unchanged by failures before auth
    func testAuthenticationFailedUnchangedByPreAuthFailure() async throws {
        let rig = makeRig()
        let connectFailure = LaMarzoccoError.bluetoothConnectionFailed(
            "Failed to connect to 00000000-0000-0000-0000-000000000001 after 3 attempts: disconnected (code 7)")
        let missingAuth = LaMarzoccoError.bluetoothConnectionFailed(
            "Could not find characteristic 0d0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")

        // Pre-auth failures leave the flag set by the last auth read: first `true`, later `false`.
        for (phase, expectedFlag) in [("after a rejected token", true), ("after a confirmed token", false)] {
            if expectedFlag {
                rig.central.enqueueConnect(.success(.laMarzocco(token: "other")))
                await assertThrows(.bluetoothAuthenticationFailed, phase) { try await rig.client.setPower(on: true) }
            } else {
                _ = try await rig.client.setPower(on: true)
                await rig.client.disconnect()
            }
            await rig.client.drainBackgroundWorkForTesting()
            var flag = await rig.client.authenticationFailed
            XCTAssertEqual(flag, expectedFlag, phase)

            // Connect attempts exhausted.
            for _ in 0..<3 { rig.central.enqueueConnect(.failure(.disconnected(code: 7))) }
            await assertThrows(connectFailure, phase) { try await rig.client.setPower(on: true) }
            await rig.client.drainBackgroundWorkForTesting()
            flag = await rig.client.authenticationFailed
            XCTAssertEqual(flag, expectedFlag, "\(phase): connect failure")

            // Bluetooth off.
            rig.central.setAvailability(.poweredOff)
            await assertThrows(.bluetoothUnavailable(.poweredOff), phase) { try await rig.client.setPower(on: true) }
            await rig.client.drainBackgroundWorkForTesting()
            rig.central.setAvailability(.poweredOn)
            flag = await rig.client.authenticationFailed
            XCTAssertEqual(flag, expectedFlag, "\(phase): unavailable")

            // Discovery without the auth characteristic: no auth read happens.
            let noAuth = FakeBluetoothLink.laMarzocco(token: "token")
            noAuth.present = [readChar, writeChar, BluetoothConstants.shotCounterCharacteristic]
            rig.central.enqueueConnect(.success(noAuth))
            await assertThrows(missingAuth, phase) { try await rig.client.setPower(on: true) }
            await rig.client.drainBackgroundWorkForTesting()
            XCTAssertEqual(noAuth.recordedOps, [.discover(refresh: false), .disconnect], phase)
            flag = await rig.client.authenticationFailed
            XCTAssertEqual(flag, expectedFlag, "\(phase): missing auth characteristic")

            // An auth that fails before any read completes: the flag is not reset at the start of auth
            // nor on the transport error (§3.4 step 6).
            for failWrite in [true, false] {
                let broken = FakeBluetoothLink()
                broken.onWrite = { _, _ in if failWrite { throw BluetoothTransportError.disconnected(code: 7) } }
                broken.onRead = { _ in throw BluetoothTransportError.disconnected(code: 7) }
                rig.central.enqueueConnect(.success(broken))
                await assertThrows(.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: disconnected (code 7)"),
                                   phase) { try await rig.client.setPower(on: true) }
                await rig.client.drainBackgroundWorkForTesting()
                XCTAssertEqual(broken.recordedOps.filter { $0 == .read(authChar) }.count, failWrite ? 0 : 1, phase)
                flag = await rig.client.authenticationFailed
                XCTAssertEqual(flag, expectedFlag, "\(phase): transport error during auth (failWrite: \(failWrite))")
            }
        }

        // The last read decides: [0x00] then [0x01] clears it within one auth.
        rig.central.enqueueConnect(.success(.laMarzocco(token: "other")))
        await assertThrows(.bluetoothAuthenticationFailed) { try await rig.client.setPower(on: true) }
        await rig.client.drainBackgroundWorkForTesting()
        rig.central.enqueueConnect(.success(.laMarzocco(token: "token", confirmOnRead: 2)))
        _ = try await rig.client.setPower(on: true)
        let final = await rig.client.authenticationFailed
        XCTAssertFalse(final)
        await rig.client.disconnect()
    }

    // MARK: - Helpers

    private struct Rig {
        let central: FakeBluetoothCentral
        let sleeper: ManualBluetoothSleeper
        let client: LaMarzoccoBluetoothClient
    }

    private func makeRig(manual: Set<SleepPurpose> = [.idleDisconnect]) -> Rig {
        let central = FakeBluetoothCentral()
        let sleeper = ManualBluetoothSleeper(manual: manual)
        let client = LaMarzoccoBluetoothClient(transport: .fake(central, sleeper: sleeper), peripheral: .fake,
                                               token: BluetoothAuthToken("token"))
        return Rig(central: central, sleeper: sleeper, client: client)
    }

    private func authReads(_ link: FakeBluetoothLink) -> Int {
        link.recordedOps.filter { $0 == .read(authChar) }.count
    }

    /// Suspends until `count` sleeps of `purpose` are pending (hang guard: 5 s).
    private func waitForPending(_ sleeper: ManualBluetoothSleeper, _ purpose: SleepPurpose, count: Int = 1) async {
        let done = XCTestExpectation(description: "\(count) pending \(purpose) sleep(s)")
        let waiter = Task {
            await sleeper.waitForPending(purpose, count: count)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        waiter.cancel()
    }

    /// Everything the stream has buffered right now, in order (the draining task is cancelled up front).
    private func drain<Element: Sendable>(_ stream: AsyncStream<Element>) async -> [Element] {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var elements: [Element] = []
            for await element in stream {
                elements.append(element)
            }
            return elements
        }.value
    }

    private func assertThrows<T>(_ expected: LaMarzoccoError, _ message: String = "",
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ operation: () async throws -> T) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected) \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, expected, "\(message) got \(error)", file: file, line: line)
        }
    }
}

// MARK: - Wire values (verbatim from SPEC §3.1/§3.7)

private let readChar = BluetoothConstants.readCharacteristic
private let writeChar = BluetoothConstants.writeCharacteristic
private let authChar = BluetoothConstants.authCharacteristic
private let powerOn = Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]

// MARK: - Private test doubles

/// A lock-protected value shared with `@Sendable` closures.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

/// One-shot gate: `wait()` suspends until `open()`; afterwards it returns at once.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

extension LaMarzoccoBluetoothClient {
    /// Runs `body` on the actor: read internal state from a test.
    fileprivate func authTestState<T: Sendable>(_ body: @Sendable (isolated LaMarzoccoBluetoothClient) -> T) -> T {
        body(self)
    }
}
