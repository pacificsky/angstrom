import Foundation

// MARK: - Protocol-logic actor (fully testable through the seam). Illustrative subset
// of upstream LaMarzoccoBluetoothClient: connect+retry, auth polling, request/response
// framing, shot-counter subscribe with replay drop, disconnect-on-error, stale-link guard.

package enum LMChar {
    // Verbatim from upstream src/pylamarzocco/clients/_bluetooth.py:40-44
    static let read = GATTUUID("0a0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let write = GATTUUID("0b0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let token = GATTUUID("0c0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let auth = GATTUUID("0d0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let shotCounter = GATTUUID("0e0b7847-e12b-09a8-b04b-8e0922a9abab")
}

/// Sketch-local errors. The real port maps these into `LaMarzoccoError`.
public enum BluetoothSessionError: Error, Sendable, Equatable {
    /// upstream BluetoothConnectionFailed (exceptions.py:20)
    case connectionFailed(String)
    /// upstream BluetoothAuthenticationFailed(BluetoothConnectionFailed) (exceptions.py:46)
    case authenticationFailed
    case unavailable(BluetoothAvailability)
}

public actor BluetoothMachineSession {
    // Upstream constants (_bluetooth.py:49-51) and dependency defaults (see note §1.3).
    static let authSuccess = Data([0x01])                 // AUTH_SUCCESS = b"\x01"
    static let authReadAttempts = 10                      // AUTH_READ_ATTEMPTS = 10
    static let authReadInterval = Duration.milliseconds(50) // AUTH_READ_INTERVAL = 0.05
    static let maxConnectAttempts = 3                     // establish_connection(max_attempts=3), :252
    static let connectTimeout = Duration.seconds(20)      // BLEAK_TIMEOUT = 20.0 (bleak-retry-connector)
    static let opTimeout = Duration.seconds(20)           // bleak CB read timeout = 20; writes: none upstream

    private let central: any BluetoothCentral
    private let sleeper: any BluetoothSleeper
    private let peripheral: BluetoothPeripheralID
    private let token: String
    private var link: (any BluetoothLink)?
    private var watcher: Task<Void, Never>?
    private(set) var authenticationFailed = false

    // shot counter
    private var shotCounterEnabled = false
    private var shotCounterSubscribed = false
    private var replayPending = false
    private var notificationSink: AsyncStream<GATTNotification>.Continuation?

    // Actor re-entrancy means upstream's two asyncio.Locks must be explicit:
    // `_lock` (connect/disconnect) and `_request_lock` (atomic write->read pairs).
    private enum Gate { case connection, request }
    private var busy: Set<Gate> = []
    private var waiters: [Gate: [CheckedContinuation<Void, Never>]] = [:]

    private func acquire(_ gate: Gate) async {
        if busy.insert(gate).inserted { return }
        await withCheckedContinuation { waiters[gate, default: []].append($0) }
    }
    private func release(_ gate: Gate) {
        if var queue = waiters[gate], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[gate] = queue
            next.resume() // ownership handed over; gate stays busy (FIFO)
        } else {
            busy.remove(gate)
        }
    }

    public init(transport: BluetoothTransport, peripheral: BluetoothPeripheralID, token: String) {
        central = transport.central
        sleeper = transport.sleeper
        self.peripheral = peripheral
        self.token = token
    }

    public var isConnected: Bool { link != nil }

    // MARK: connection (upstream _ensure_connected, :233-269)

    func ensureConnected() async throws -> any BluetoothLink {
        await acquire(.connection)
        defer { release(.connection) }
        if let link { return link }
        let newLink = try await connectWithRetry()
        do {
            let found = try await newLink.discover([LMChar.auth, LMChar.read, LMChar.write, LMChar.shotCounter],
                                                   refresh: false, timeout: Self.opTimeout)
            guard found.contains(LMChar.auth) else {
                throw BluetoothSessionError.connectionFailed("Could not find characteristic \(LMChar.auth) on machine.")
            }
            try await authenticate(newLink)
        } catch {
            await newLink.disconnect() // never keep an unauthenticated link (:257-264), also on cancellation
            throw error
        }
        link = newLink
        let events = newLink.events
        watcher = Task { [weak self] in
            for await event in events { await self?.handle(event, from: newLink) }
        }
        return newLink
    }

    /// establish_connection(max_attempts=3) analogue; fail fast on non-transient states.
    private func connectWithRetry() async throws -> any BluetoothLink {
        var lastError: (any Error)?
        for attempt in 1...Self.maxConnectAttempts {
            switch await central.availability() {
            case .poweredOn: break
            case let state: throw BluetoothSessionError.unavailable(state)
            }
            do {
                return try await central.connect(to: peripheral, timeout: Self.connectTimeout)
            } catch let error as BluetoothTransportError {
                lastError = error
                if attempt == Self.maxConnectAttempts { break }
                // bleak-retry-connector: 0.25 s after a timeout, 0.1 s otherwise
                let backoff: Duration = if case .timedOut = error { .milliseconds(250) } else { .milliseconds(100) }
                try await sleeper.sleep(for: backoff, purpose: .connectBackoff)
            }
        }
        throw BluetoothSessionError.connectionFailed("Failed to connect: \(String(describing: lastError))")
    }

    /// upstream _authenticate (:628-653)
    private func authenticate(_ link: any BluetoothLink) async throws {
        do {
            try await link.write(Data(token.utf8), to: LMChar.auth, withResponse: true, timeout: Self.opTimeout)
            for attempt in 0..<Self.authReadAttempts {
                if attempt > 0 { try await sleeper.sleep(for: Self.authReadInterval, purpose: .authPoll) }
                let result = try await link.read(LMChar.auth, timeout: Self.opTimeout)
                authenticationFailed = result != Self.authSuccess
                if !authenticationFailed { return }
            }
        } catch let error as BluetoothTransportError {
            throw BluetoothSessionError.connectionFailed("Failed to connect to machine with Bluetooth: \(error)")
        }
        throw BluetoothSessionError.authenticationFailed
    }

    private func handle(_ event: LinkEvent, from source: any BluetoothLink) {
        guard source === link else { return } // stale link
        switch event {
        case .notification(let characteristic, let notification):
            guard characteristic == LMChar.shotCounter else { return }
            if replayPending { replayPending = false; return } // first notification is a replay (:446-449)
            notificationSink?.yield(notification)
        case .servicesInvalidated:
            break // real port: drop the characteristic table / force rediscovery
        case .disconnected:
            link = nil
            watcher = nil
            shotCounterSubscribed = false
            // real port: _set_connected(False), _handle_connection_lost() -> reconnect task
        }
    }

    // MARK: requests (upstream disconnect_on_exception + __send_command / __read_value_from_machine)

    /// Write `JSON + NUL` to WRITE, then read the status back from WRITE (:702-710).
    public func sendCommand(_ json: String) async throws -> String {
        try await request { link in
            try await link.write(Data(json.utf8) + [0x00], to: LMChar.write, withResponse: true, timeout: Self.opTimeout)
            return try await link.read(LMChar.write, timeout: Self.opTimeout)
        }
    }

    /// Write the setting name + NUL to READ, then read READ (:655-657).
    public func readSetting(_ setting: String) async throws -> String {
        try await request { link in
            try await link.write(Data(setting.utf8) + [0x00], to: LMChar.read, withResponse: true, timeout: Self.opTimeout)
            return try await link.read(LMChar.read, timeout: Self.opTimeout)
        }
    }

    private func request(_ body: (any BluetoothLink) async throws -> Data) async throws -> String {
        await acquire(.request)
        defer { release(.request) }
        do {
            let link = try await ensureConnected()
            let raw = try await body(link)
            // responses are NUL-terminated, ignore anything after it (:670-671)
            return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        } catch {
            // a single failed command must not kill a running shot counter (:130-133)
            if !(shotCounterEnabled && link != nil) { await dropConnection() }
            throw error
        }
    }

    // MARK: shot counter (upstream _subscribe_shot_counter, :403-439, minus the cache retry)

    package func shotCounterNotifications() -> AsyncStream<GATTNotification> {
        let (stream, sink) = AsyncStream.makeStream(of: GATTNotification.self)
        notificationSink = sink
        return stream
    }

    public func startShotCounter() async throws -> Bool {
        shotCounterEnabled = true
        let link = try await ensureConnected()
        if shotCounterSubscribed { return true }
        let found = try await link.discover([LMChar.shotCounter], refresh: false, timeout: Self.opTimeout)
        guard found.contains(LMChar.shotCounter) else { shotCounterEnabled = false; return false }
        replayPending = true // set BEFORE enabling: the replay can precede the CCCD ack
        try await link.subscribe(LMChar.shotCounter, timeout: Self.opTimeout)
        shotCounterSubscribed = true
        return true
    }

    public func disconnect() async {
        shotCounterEnabled = false
        if shotCounterSubscribed, let link { await link.unsubscribe(LMChar.shotCounter) }
        shotCounterSubscribed = false
        await dropConnection()
    }

    private func dropConnection() async {
        await acquire(.connection)
        defer { release(.connection) }
        let old = link
        link = nil // detach first so its .disconnected is ignored as stale (:303-304)
        watcher?.cancel()
        watcher = nil
        await old?.disconnect()
    }
}
