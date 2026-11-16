import Foundation

// MARK: - Protocol-logic actor (fully testable through the seam)

enum LMChar {
    static let read = GATTUUID("0a0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let write = GATTUUID("0b0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let token = GATTUUID("0c0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let auth = GATTUUID("0d0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let shotCounter = GATTUUID("0e0b7847-e12b-09a8-b04b-8e0922a9abab")
}

enum SessionError: Error, Sendable { case connectionFailed(String), authenticationFailed }

actor BluetoothMachineSession {
    private let central: any BluetoothCentral
    private let peripheral: BluetoothPeripheralID
    private let token: String
    private let sleeper: any BluetoothSleeper
    private var link: (any BluetoothLink)?
    private var linkWatcher: Task<Void, Never>?

    // Actor re-entrancy means upstream's asyncio.Lock pairs must be explicit:
    // `_lock` (connect/disconnect) and `_request_lock` (atomic write->read pairs).
    private enum GateID { case connection, request }
    private var gateBusy: Set<GateID> = []
    private var gateWaiters: [GateID: [CheckedContinuation<Void, Never>]] = [:]

    /// FIFO async mutex as actor-isolated state (a mutating struct can't be awaited
    /// on an actor property; a non-Sendable class can't be awaited across isolation).
    private func acquire(_ gate: GateID) async {
        if gateBusy.insert(gate).inserted { return }
        await withCheckedContinuation { gateWaiters[gate, default: []].append($0) }
    }
    private func release(_ gate: GateID) {
        if var queue = gateWaiters[gate], !queue.isEmpty {
            let next = queue.removeFirst()
            gateWaiters[gate] = queue
            next.resume() // ownership handed over; stays busy
        } else {
            gateBusy.remove(gate)
        }
    }

    init(central: any BluetoothCentral, peripheral: BluetoothPeripheralID, token: String,
         sleeper: any BluetoothSleeper = RealSleeper()) {
        self.central = central
        self.peripheral = peripheral
        self.token = token
        self.sleeper = sleeper
    }

    /// Upstream `_ensure_connected` + `_authenticate`.
    func ensureConnected() async throws -> any BluetoothLink {
        await acquire(.connection)
        defer { release(.connection) }
        if let link { return link }
        let newLink = try await central.connect(to: peripheral, timeout: .seconds(20)) // timeout UNVERIFIED (bleak-retry-connector)
        do {
            _ = try await newLink.discover([LMChar.auth, LMChar.read, LMChar.write, LMChar.shotCounter],
                                           refresh: false, timeout: .seconds(10))
            try await authenticate(newLink)
        } catch {
            await newLink.disconnect() // never keep an unauthenticated link (upstream :257-264)
            throw error
        }
        link = newLink
        let events = newLink.events
        linkWatcher = Task { [weak self] in
            for await event in events {
                if case .disconnected = event { await self?.linkLost(newLink) }
            }
        }
        return newLink
    }

    private func linkLost(_ lost: any BluetoothLink) {
        guard lost === link else { return } // stale link (upstream: `client is not self._client`)
        link = nil
    }

    private func authenticate(_ link: any BluetoothLink) async throws {
        try await link.write(Data(token.utf8), to: LMChar.auth, withResponse: true, timeout: .seconds(10))
        for attempt in 0..<10 {                                   // AUTH_READ_ATTEMPTS = 10
            if attempt > 0 { try await sleeper.sleep(for: .milliseconds(50), purpose: .authPoll) } // 0.05 s
            if try await link.read(LMChar.auth, timeout: .seconds(10)) == Data([0x01]) { return }  // AUTH_SUCCESS
        }
        throw SessionError.authenticationFailed
    }

    /// Upstream `__send_command`: write JSON + NUL to WRITE, read the status back from WRITE.
    func sendCommand(_ json: String) async throws -> String {
        await acquire(.request)
        defer { release(.request) }
        let link = try await ensureConnected()
        try await link.write(Data(json.utf8) + [0x00], to: LMChar.write, withResponse: true, timeout: .seconds(10))
        let raw = try await link.read(LMChar.write, timeout: .seconds(10))
        return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) // NUL-terminated (upstream :670-671)
    }
}

// MARK: - In-memory fake (test target)

final class FakeLink: BluetoothLink, @unchecked Sendable {
    let peripheralID = BluetoothPeripheralID(rawValue: "00000000-0000-0000-0000-000000000001")
    let events: AsyncStream<LinkEvent>
    private let eventSink: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()
    // scripted machine state
    var acceptedToken = "token"
    var authConfirmReads = 1
    var values: [GATTUUID: Data] = [:]
    var missing: Set<GATTUUID> = []
    var failNext: [BluetoothTransportError] = []
    private(set) var writes: [(GATTUUID, Data)] = []
    private var authenticated = false
    private var authReads = 0
    private var sinks: [GATTUUID: AsyncStream<GATTNotification>.Continuation] = [:]
    var replay: Data?

    init() { (events, eventSink) = AsyncStream.makeStream(of: LinkEvent.self) }

    private func takeFailure() throws {
        try lock.withLock { if !failNext.isEmpty { throw failNext.removeFirst() } }
    }

    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        try takeFailure()
        return lock.withLock { wanted.subtracting(missing) }
    }
    func read(_ c: GATTUUID, timeout: Duration) async throws -> Data {
        try takeFailure()
        return lock.withLock {
            guard c == LMChar.auth else { return values[c] ?? Data() }
            authReads += 1
            return Data([authenticated && authReads >= authConfirmReads ? 0x01 : 0x00])
        }
    }
    func write(_ data: Data, to c: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        try takeFailure()
        lock.withLock {
            writes.append((c, data))
            if c == LMChar.auth { authenticated = data == Data(acceptedToken.utf8); authReads = 0 }
        }
    }
    func subscribe(_ c: GATTUUID, timeout: Duration) async throws -> AsyncStream<GATTNotification> {
        try takeFailure()
        let (stream, sink) = AsyncStream.makeStream(of: GATTNotification.self)
        lock.withLock { sinks[c] = sink }
        if let replay { sink.yield(GATTNotification(value: replay, receivedAt: Date())) }
        return stream
    }
    func unsubscribe(_ c: GATTUUID) async { lock.withLock { sinks.removeValue(forKey: c)?.finish() } }
    func disconnect() async { drop(nil) }

    // test controls
    func notify(_ c: GATTUUID, _ payload: Data, at date: Date) {
        _ = lock.withLock { sinks[c]?.yield(GATTNotification(value: payload, receivedAt: date)) }
    }
    func drop(_ error: BluetoothTransportError?) {
        let sinks = lock.withLock { () -> [AsyncStream<GATTNotification>.Continuation] in
            defer { self.sinks.removeAll() }
            return Array(self.sinks.values)
        }
        sinks.forEach { $0.finish() }
        eventSink.yield(.disconnected(error))
        eventSink.finish()
    }
}
