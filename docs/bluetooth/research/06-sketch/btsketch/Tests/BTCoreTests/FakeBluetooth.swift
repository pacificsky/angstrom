import Foundation
@testable import BTCore

/// Every operation the protocol layer performs, in order — the assertion surface.
enum FakeOp: Equatable, Sendable {
    case connect(BluetoothPeripheralID)
    case discover(refresh: Bool)
    case read(GATTUUID)
    case write(GATTUUID, Data)
    case subscribe(GATTUUID)
    case unsubscribe(GATTUUID)
    case disconnect
}

/// Scriptable central: availability, scan results, and one outcome per connect attempt.
final class FakeCentral: BluetoothCentral, @unchecked Sendable {
    private let lock = NSLock()
    private var _availability: BluetoothAvailability = .poweredOn
    private var _scan: [DiscoveredPeripheral] = []
    /// Popped per connect(); when empty, `makeLink()` is used.
    private var connectOutcomes: [Result<FakeLink, BluetoothTransportError>] = []
    private(set) var connectCount = 0
    private(set) var links: [FakeLink] = []
    var makeLink: @Sendable () -> FakeLink = { FakeLink.laMarzocco(token: "token") }

    func setAvailability(_ a: BluetoothAvailability) { lock.withLock { _availability = a } }
    func setScanResults(_ r: [DiscoveredPeripheral]) { lock.withLock { _scan = r } }
    func enqueueConnect(_ outcome: Result<FakeLink, BluetoothTransportError>) { lock.withLock { connectOutcomes.append(outcome) } }

    func availability() async -> BluetoothAvailability { lock.withLock { _availability } }
    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] { lock.withLock { _scan } }
    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        let outcome: Result<FakeLink, BluetoothTransportError> = lock.withLock {
            connectCount += 1
            return connectOutcomes.isEmpty ? .success(makeLink()) : connectOutcomes.removeFirst()
        }
        let link = try outcome.get()
        lock.withLock { links.append(link) }
        return link
    }
}

/// A scriptable GATT server for one connection.
final class FakeLink: BluetoothLink, @unchecked Sendable {
    let peripheralID = BluetoothPeripheralID(rawValue: "00000000-0000-0000-0000-000000000001")
    let events: AsyncStream<LinkEvent>
    private let sink: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()

    // script
    var present: Set<GATTUUID> = [LMChar.auth, LMChar.read, LMChar.write, LMChar.shotCounter]
    /// Synchronous GATT-server behaviour. Throw a BluetoothTransportError to fail an op.
    var onRead: @Sendable (GATTUUID) throws -> Data = { _ in Data() }
    var onWrite: @Sendable (GATTUUID, Data) throws -> Void = { _, _ in }
    /// Async hook run before every op: await a gate here to hold an op in flight
    /// (serialization, cancellation and timeout tests).
    var beforeOp: (@Sendable (FakeOp) async -> Void)?
    /// Notifications to emit synchronously when a subscribe succeeds (the replay).
    var replayOnSubscribe: [Data] = []

    private(set) var ops: [FakeOp] = []
    private var dropped = false

    init() { (events, sink) = AsyncStream.makeStream(of: LinkEvent.self) }

    private func record(_ op: FakeOp) async throws {
        if let beforeOp { await beforeOp(op) }
        try lock.withLock {
            ops.append(op)
            if dropped && op != .disconnect { throw BluetoothTransportError.notConnected }
        }
    }

    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        try await record(.discover(refresh: refresh))
        return lock.withLock { wanted.intersection(present) }
    }
    func read(_ c: GATTUUID, timeout: Duration) async throws -> Data {
        try await record(.read(c))
        return try onRead(c)
    }
    func write(_ data: Data, to c: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        try await record(.write(c, data))
        try onWrite(c, data)
    }
    func subscribe(_ c: GATTUUID, timeout: Duration) async throws {
        try await record(.subscribe(c))
        for value in replayOnSubscribe { notify(c, value, at: Date(timeIntervalSince1970: 0)) }
    }
    func unsubscribe(_ c: GATTUUID) async { try? await record(.unsubscribe(c)) }
    func disconnect() async {
        try? await record(.disconnect)
        drop(nil)
    }

    // test controls
    func notify(_ c: GATTUUID, _ value: Data, at date: Date) {
        sink.yield(.notification(c, GATTNotification(value: value, receivedAt: date)))
    }
    func drop(_ error: BluetoothTransportError?) {
        let first = lock.withLock { () -> Bool in defer { dropped = true }; return !dropped }
        guard first else { return }
        sink.yield(.disconnected(error))
        sink.finish()
    }
    var recordedOps: [FakeOp] { lock.withLock { ops } }

    /// A machine that accepts `token` and confirms auth on the `confirmOnRead`-th auth read,
    /// and answers commands with upstream's COMMAND_SUCCESS (tests/test_bluetooth_client.py:47).
    static func laMarzocco(token: String, confirmOnRead: Int = 1) -> FakeLink {
        final class AuthState: @unchecked Sendable {
            let lock = NSLock(); var tokenOK = false; var reads = 0
        }
        let link = FakeLink()
        let state = AuthState()
        link.onWrite = { c, data in
            if c == LMChar.auth { state.lock.withLock { state.tokenOK = data == Data(token.utf8); state.reads = 0 } }
        }
        link.onRead = { c in
            switch c {
            case LMChar.auth:
                return state.lock.withLock {
                    state.reads += 1
                    return Data([state.tokenOK && state.reads >= confirmOnRead ? 0x01 : 0x00])
                }
            case LMChar.write:
                return Data(#"{"id":"test-id","message":"Success","status":"success"}"#.utf8) + [0x00, 0x41]
            default:
                return Data("[]".utf8) + [0x00]
            }
        }
        return link
    }
}

/// Records every sleep and returns immediately (upstream patches the intervals to 0).
final class RecordingSleeper: BluetoothSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(Duration, SleepPurpose)] = []
    func sleep(for duration: Duration, purpose: SleepPurpose) async throws {
        lock.withLock { log.append((duration, purpose)) }
        try Task.checkCancellation()
    }
    func count(_ purpose: SleepPurpose) -> Int { lock.withLock { log.filter { $0.1 == purpose }.count } }
}

/// A one-shot async gate for holding an op in flight.
actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
