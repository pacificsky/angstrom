import Foundation
import os

/// BLE client for one La Marzocco machine (port of pylamarzocco's LaMarzoccoBluetoothClient).
///
/// Build it with a ``BluetoothTransport`` (from `BluetoothTransport.coreBluetooth()` in
/// `AngstromBluetooth`), the machine's ``BluetoothPeripheralID`` and its ``BluetoothAuthToken``.
/// The client connects on demand, authenticates, serialises requests, and closes an idle link
/// after 30 s unless the shot counter is running.
public actor LaMarzoccoBluetoothClient {
    /// Name prefixes kept by discovery (`BT_MODEL_PREFIXES`).
    public static let machineNamePrefixes: [String] = BluetoothConstants.machineNamePrefixes
    /// The peripheral this client talks to (upstream `address`; a CoreBluetooth UUID, not a MAC).
    public nonisolated let peripheral: BluetoothPeripheralID

    // MARK: Internal state (frozen, SPEC §6.11)

    let central: any BluetoothCentral
    let sleeper: any BluetoothSleeper
    let now: @Sendable () -> Date
    let token: BluetoothAuthToken
    let log: (@Sendable (String) -> Void)?
    var timing: BluetoothTiming
    var link: (any BluetoothLink)?
    var linkWatcher: Task<Void, Never>?
    var discovered: Set<GATTUUID>
    var needsRediscovery: Bool
    var reportedConnected: Bool
    var idleTask: Task<Void, Never>?
    var gateBusy: Set<BluetoothGate>
    var gateWaiters: [BluetoothGate: [CheckedContinuation<Void, Never>]]
    var shotCounterEnabled: Bool
    var shotCounterSubscribed: Bool
    var replayPending: Bool
    var tracker: BrewingTracker
    var reconnectTask: Task<Void, Never>?
    var connectionListeners: [UUID: AsyncStream<ConnectionEvent>.Continuation]
    var shotCounterListeners: [UUID: AsyncStream<ShotCounterEvent>.Continuation]
    var rawFrameListeners: [UUID: AsyncStream<RawBluetoothFrame>.Continuation]
    var backgroundTasks: [UUID: Task<Void, Never>]

    /// The two FIFO gates: `.request` serialises whole requests, `.connection` serialises
    /// connect/auth/teardown/subscribe. Lock order is always request → connection.
    enum BluetoothGate: Hashable { case connection, request }
    /// Which step a transport error came from (selects the §4.4.1 mapping column).
    enum BluetoothErrorPhase { case connect, authenticate, request }

    // MARK: Public surface

    public init(transport: BluetoothTransport, peripheral: BluetoothPeripheralID,
                token: BluetoothAuthToken, logHandler: (@Sendable (String) -> Void)? = nil) {
        self.peripheral = peripheral
        self.central = transport.central
        self.sleeper = transport.sleeper
        self.now = transport.now
        self.token = token
        self.log = logHandler
        self.timing = BluetoothTiming()
        self.link = nil
        self.linkWatcher = nil
        self.discovered = []
        self.needsRediscovery = false
        self.reportedConnected = false
        self.idleTask = nil
        self.gateBusy = []
        self.gateWaiters = [:]
        self.shotCounterEnabled = false
        self.shotCounterSubscribed = false
        self.replayPending = false
        self.tracker = BrewingTracker()
        self.reconnectTask = nil
        self.connectionListeners = [:]
        self.shotCounterListeners = [:]
        self.rawFrameListeners = [:]
        self.backgroundTasks = [:]
        self.authenticationFailed = false
    }

    /// §5.5 Lifetime: a client released without `disconnect()` must not leak its link or park its
    /// consumers. The idle task and the link watcher hold the client weakly, so nothing else would
    /// close the link or end the listener streams. No event is emitted from here.
    ///
    /// A running reconnect loop (or any tracked background task) holds the client strongly, so the
    /// client lives until that work ends; cancelling `reconnectTask` here only covers a stale handle.
    deinit {
        idleTask?.cancel()
        linkWatcher?.cancel()
        reconnectTask?.cancel()
        if let live = link {
            Task { await live.disconnect() }
        }
        for listener in connectionListeners.values {
            listener.finish()
        }
        for listener in shotCounterListeners.values {
            listener.finish()
        }
        for listener in rawFrameListeners.values {
            listener.finish()
        }
    }

    /// An authenticated link is up.
    public var isConnected: Bool { link != nil }
    /// The last auth read was not 0x01 — usually a wrong token.
    public internal(set) var authenticationFailed: Bool
    /// Shot counter enabled ∧ subscribed ∧ connected.
    public var shotCounterActive: Bool { shotCounterEnabled && shotCounterSubscribed && link != nil }

    /// Edge-triggered `.connected` (after auth) / `.disconnected` (any close, incl. idle).
    ///
    /// Multiplexed: every call returns an independent stream that reports the transitions from
    /// registration on. Cancelling its iteration unregisters it.
    public func connectionEvents() -> AsyncStream<ConnectionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConnectionEvent>.makeStream()
        connectionListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeConnectionListener(id) }
        }
        return stream
    }

    /// Stop the shot counter (if any) and close the link. Never throws; idempotent.
    ///
    /// Takes the connection gate only (not the request gate, upstream `BT:319-325`), and never
    /// reconnects.
    public func disconnect() async {
        let wasSubscribed = disableShotCounter()
        await acquire(.connection)
        await stopNotifyInternal()
        await disconnectInternal()
        release(.connection)
        if wasSubscribed {
            emitShotCounter(.unsubscribed)
        }
    }

    /// Multiplexed raw BLE frames (writes, reads, notifications, lifecycle markers). Free without listeners.
    ///
    /// The tap is verbatim: frames carrying the token (the auth write) set `isSecret`, so display
    /// layers can redact them. Lifecycle markers are `.event` frames with direction `.inbound`.
    public func rawFrames() -> AsyncStream<RawBluetoothFrame> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RawBluetoothFrame>.makeStream()
        rawFrameListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRawFrameListener(id) }
        }
        return stream
    }

    // MARK: Internal helpers [main]

    /// FIFO acquire of `gate`. Not cancellable: a waiter keeps its place until the gate is handed to it.
    func acquire(_ gate: BluetoothGate) async {
        guard gateBusy.contains(gate) else {
            gateBusy.insert(gate)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gateWaiters[gate, default: []].append(continuation)
        }
        // `release` handed the gate over without clearing `gateBusy`.
    }

    /// Hands `gate` to the oldest waiter, or frees it when nobody waits.
    func release(_ gate: BluetoothGate) {
        if var waiters = gateWaiters[gate], !waiters.isEmpty {
            let next = waiters.removeFirst()
            gateWaiters[gate] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            gateBusy.remove(gate)
        }
    }

    /// §4.2. Runs under the connection gate.
    func ensureConnected(refresh: Bool = false) async throws -> any BluetoothLink {
        await acquire(.connection)
        defer { release(.connection) }

        // 1. Trust the stored link (I1, D7e).
        if let link {
            resetIdleTimer()
            return link
        }

        log?("Connecting to Bluetooth device \(peripheral)")
        // 2. A new connection never has active notifications.
        shotCounterSubscribed = false

        // 3. Availability (§8.1).
        do {
            try await awaitPoweredOn()
        } catch {
            log?("Bluetooth is not available for \(peripheral): \(Self.describe(error))")
            throw error
        }

        // 4.–6. Connect with retry, discover, authenticate.
        emitRawEvent(RawBluetoothFrame.connectingMarker)
        var newLink: (any BluetoothLink)?
        let connected: any BluetoothLink
        do {
            connected = try await connectWithRetry()
            newLink = connected
            emitRawEvent(RawBluetoothFrame.connectedMarker)

            let found: Set<GATTUUID>
            do {
                found = try await connected.discover(BluetoothConstants.sessionCharacteristics,
                                                     refresh: refresh, timeout: timing.operationTimeout)
            } catch {
                throw Self.mapTransportError(error, phase: .authenticate)
            }
            discovered = found
            let auth = BluetoothConstants.authCharacteristic
            guard found.contains(auth) else {
                throw LaMarzoccoError.bluetoothConnectionFailed("Could not find characteristic \(auth.string) on machine.")
            }
            if !rawFrameListeners.isEmpty, let mtu = await connected.attMTU() {
                emitRawEvent(RawBluetoothFrame.mtuMarker(mtu))
            }

            try await authenticate(connected)
        } catch {
            // 7. Never keep an unauthenticated link, also on cancellation. No connection event.
            if let newLink {
                await newLink.disconnect()
            }
            let mapped = Self.mapTransportError(error, phase: .authenticate)
            log?("Failed to connect to Bluetooth device \(peripheral): \(Self.describe(mapped))")
            throw mapped
        }

        // 8. Success.
        link = connected
        startLinkWatcher(connected)
        needsRediscovery = false
        resetIdleTimer()
        setConnected(true)
        emitRawEvent(RawBluetoothFrame.authenticatedMarker)
        log?("Successfully connected to Bluetooth device \(peripheral)")
        return connected
    }

    /// §3.4. Called only from `ensureConnected`, while the connection gate is held.
    func authenticate(_ link: any BluetoothLink) async throws {
        let auth = BluetoothConstants.authCharacteristic
        let frame = BluetoothCodec.authFrame(token)
        do {
            try await link.write(frame, to: auth, withResponse: true, timeout: timing.operationTimeout)
            emitRaw(.write, .outbound, characteristic: auth, data: frame, isSecret: true)
            // The machine confirms a successful authentication with 0x01.
            for attempt in 0..<timing.authReadAttempts {
                if attempt > 0 {
                    try await sleeper.sleep(for: timing.authReadInterval, purpose: .authPoll)
                }
                let result = try await link.read(auth, timeout: timing.operationTimeout)
                emitRaw(.read, .inbound, characteristic: auth, data: result, isSecret: false)
                authenticationFailed = result != BluetoothConstants.authSuccess
                if !authenticationFailed {
                    return
                }
            }
        } catch {
            throw Self.mapTransportError(error, phase: .authenticate)
        }
        log?("Bluetooth authentication with \(peripheral) failed")
        throw LaMarzoccoError.bluetoothAuthenticationFailed
    }

    /// §4.6. Cancels the idle task and, unless the shot counter runs, starts a new one.
    func resetIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
        // Keep the connection open while the shot counter is running.
        guard !shotCounterEnabled else { return }
        let sleeper = self.sleeper
        let timeout = timing.idleTimeout
        idleTask = Task { [weak self] in
            do {
                try await sleeper.sleep(for: timeout, purpose: .idleDisconnect)
            } catch {
                return  // reset or cancelled: this is normal
            }
            guard !Task.isCancelled else { return }
            await self?.dropConnection(fromIdleTimer: true)
        }
    }

    /// The caller holds `.connection`.
    func disconnectInternal(fromIdleTimer: Bool = false) async {
        // Cancel the idle timer, unless it is the one disconnecting (it never cancels itself).
        if !fromIdleTimer {
            idleTask?.cancel()
        }
        idleTask = nil

        // Detach first, so the link's own `.disconnected` is ignored.
        let old = link
        link = nil
        linkWatcher?.cancel()
        linkWatcher = nil
        if let old {
            log?("Disconnecting from Bluetooth device \(peripheral)")
            await old.disconnect()
            emitRawEvent(RawBluetoothFrame.disconnectedMarker)
        }
        setConnected(false)
    }

    /// Disconnects without stopping the shot counter (it will reconnect).
    ///
    /// An idle-timer drop whose task was cancelled while it waited for the gate (the timer was
    /// reset or replaced meanwhile) is abandoned, as upstream's `CancelledError` would abandon it.
    func dropConnection(fromIdleTimer: Bool = false) async {
        await acquire(.connection)
        if fromIdleTimer && Task.isCancelled {
            release(.connection)
            return
        }
        if fromIdleTimer {
            log?("Auto-disconnect timer expired, disconnecting from \(peripheral)")
        }
        await disconnectInternal(fromIdleTimer: fromIdleTimer)
        release(.connection)
        handleConnectionLost()
    }

    /// Runs `dropConnection()` in a tracked background `Task`.
    func dropConnectionInBackground() {
        let id = UUID()
        backgroundTasks[id] = Task {
            await self.dropConnection()
            self.backgroundTasks[id] = nil
        }
    }

    /// §4.13.
    func handleConnectionLost() {
        let wasSubscribed = shotCounterSubscribed
        shotCounterSubscribed = false
        // The running shot must be forgotten.
        tracker = BrewingTracker()
        guard shotCounterEnabled else { return }
        if wasSubscribed {
            log?("Shot counter connection lost, reinitializing brewing data")
            emitShotCounter(.unsubscribed)
        }
        if reconnectTask == nil {
            reconnectTask = Task { await reconnectLoop() }
        }
    }

    /// Edge-triggered connection-event emission.
    func setConnected(_ connected: Bool) {
        guard connected != reportedConnected else { return }
        reportedConnected = connected
        let event: ConnectionEvent = connected ? .connected : .disconnected
        for listener in connectionListeners.values {
            listener.yield(event)
        }
    }

    /// §4.7. Events from a link that is not the current `link` are ignored (I5).
    func handleLinkEvent(_ event: LinkEvent, from source: any BluetoothLink) {
        guard let current = link, current === source else { return }
        switch event {
        case .disconnected:
            log?("Bluetooth device \(peripheral) disconnected")
            link = nil
            idleTask?.cancel()  // D16
            idleTask = nil
            linkWatcher?.cancel()
            linkWatcher = nil
            emitRawEvent(RawBluetoothFrame.disconnectedMarker)
            setConnected(false)
            handleConnectionLost()
        case .notification(let characteristic, let notification):
            if characteristic == BluetoothConstants.shotCounterCharacteristic {
                handleShotCounterNotification(notification)
            }
        case .servicesInvalidated:
            needsRediscovery = true
            emitRawEvent(RawBluetoothFrame.servicesInvalidatedMarker)
        }
    }

    /// No-op without listeners.
    func emitRaw(_ kind: RawBluetoothFrame.Kind, _ direction: RawBluetoothFrame.Direction,
                 characteristic: GATTUUID?, data: Data, isSecret: Bool) {
        guard !rawFrameListeners.isEmpty else { return }
        let frame = RawBluetoothFrame(timestamp: now(), direction: direction, kind: kind,
                                      characteristic: characteristic?.string, data: data, isSecret: isSecret)
        for listener in rawFrameListeners.values {
            listener.yield(frame)
        }
    }

    /// A synthetic lifecycle marker (`.event`, `.inbound`, no characteristic, UTF-8 text).
    func emitRawEvent(_ marker: String) {
        guard !rawFrameListeners.isEmpty else { return }
        emitRaw(.event, .inbound, characteristic: nil, data: Data(marker.utf8), isSecret: false)
    }

    func emitShotCounter(_ event: ShotCounterEvent) {
        for listener in shotCounterListeners.values {
            listener.yield(event)
        }
    }

    /// §4.4.1. `CancellationError` and `LaMarzoccoError` pass through unchanged.
    ///
    /// In the `.connect` phase, the retryable errors map to `.bluetoothConnectionFailed(<e>)`; the
    /// connect loop of `ensureConnected` wraps the last one into its "after <n> attempts" message.
    nonisolated static func mapTransportError(_ error: any Error,
                                              phase: BluetoothErrorPhase) -> any Error {
        if error is CancellationError || error is LaMarzoccoError {
            return error
        }
        let authPrefix = "Failed to connect to machine with Bluetooth: "
        guard let transport = error as? BluetoothTransportError else {
            // Seam methods throw nothing else; keep the every-error-is-a-LaMarzoccoError rule anyway.
            let text = String(describing: error)
            switch phase {
            case .connect, .request: return LaMarzoccoError.bluetoothConnectionFailed(text)
            case .authenticate: return LaMarzoccoError.bluetoothConnectionFailed(authPrefix + text)
            }
        }
        switch transport {
        case .unavailable(let availability):
            return LaMarzoccoError.bluetoothUnavailable(availability)
        case .unknownPeripheral(let id):
            return LaMarzoccoError.bluetoothConnectionFailed("Unknown peripheral \(id); scan again")
        case .characteristicNotFound(let uuid):
            return LaMarzoccoError.bluetoothConnectionFailed("Could not find characteristic \(uuid.string) on machine.")
        case .timedOut(let operation):
            switch phase {
            case .connect: return LaMarzoccoError.bluetoothConnectionFailed(transport.description)
            case .authenticate: return LaMarzoccoError.bluetoothConnectionFailed(authPrefix + transport.description)
            case .request: return LaMarzoccoError.bluetoothTimedOut(operation)
            }
        case .notConnected, .disconnected, .gatt, .valueTooLong:
            switch phase {
            case .connect, .request: return LaMarzoccoError.bluetoothConnectionFailed(transport.description)
            case .authenticate: return LaMarzoccoError.bluetoothConnectionFailed(authPrefix + transport.description)
            }
        }
    }

    // MARK: Test seams

    package func setTimingForTesting(_ timing: BluetoothTiming) {
        self.timing = timing
    }

    /// Awaits every tracked background task (drops, reconnect loop, idle task excluded).
    package func drainBackgroundWorkForTesting() async {
        var awaited = Set<Task<Void, Never>>()
        while true {
            var pending = Array(backgroundTasks.values)
            if let reconnectTask {
                pending.append(reconnectTask)
            }
            pending.removeAll { awaited.contains($0) }
            if pending.isEmpty {
                return
            }
            for task in pending {
                await task.value
                awaited.insert(task)
            }
        }
    }

    /// Any tracked background work is pending, including the idle task and the reconnect loop.
    package var hasBackgroundWorkForTesting: Bool {
        !backgroundTasks.isEmpty || idleTask != nil || reconnectTask != nil
    }

    // MARK: Private

    private func removeConnectionListener(_ id: UUID) {
        connectionListeners[id] = nil
    }

    private func removeRawFrameListener(_ id: UUID) {
        rawFrameListeners[id] = nil
    }

    /// §4.2 step 3. The update stream is created BEFORE the state is read, so a transition
    /// between the two calls is not lost.
    private func awaitPoweredOn() async throws {
        let updates = central.availabilityUpdates()
        let state = await central.availability()
        switch state {
        case .poweredOn:
            return
        case .unknown, .resetting, .unauthorized(.notDetermined):
            try await waitForPoweredOn(updates, initial: state)
        case .poweredOff, .unsupported, .unauthorized(.denied), .unauthorized(.restricted),
             .unauthorized(.allowedAlways):
            throw LaMarzoccoError.bluetoothUnavailable(state)
        }
    }

    /// Races `updates` against the `.poweredOnWait` sleep; the first child to finish decides.
    private func waitForPoweredOn(_ updates: AsyncStream<BluetoothAvailability>,
                                  initial: BluetoothAvailability) async throws {
        let lastSeen = OSAllocatedUnfairLock(initialState: initial)
        let sleeper = self.sleeper
        let wait = timing.poweredOnWait
        // nil: the wait ended without a decisive state (timeout).
        let decided: BluetoothAvailability? = try await withThrowingTaskGroup(of: BluetoothAvailability?.self) { group in
            group.addTask {
                for await state in updates {
                    lastSeen.withLock { $0 = state }
                    switch state {
                    case .unknown, .resetting, .unauthorized(.notDetermined):
                        continue
                    case .poweredOn, .poweredOff, .unsupported, .unauthorized(.denied),
                         .unauthorized(.restricted), .unauthorized(.allowedAlways):
                        return state
                    }
                }
                try Task.checkCancellation()
                return nil
            }
            group.addTask {
                try await sleeper.sleep(for: wait, purpose: .poweredOnWait)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        try Task.checkCancellation()
        switch decided {
        case .poweredOn?:
            return
        case let terminal?:
            throw LaMarzoccoError.bluetoothUnavailable(terminal)
        case nil:
            throw LaMarzoccoError.bluetoothUnavailable(lastSeen.withLock { $0 })
        }
    }

    /// §4.2 step 4: up to `timing.connectAttempts` single attempts with backoff.
    private func connectWithRetry() async throws -> any BluetoothLink {
        let attempts = max(1, timing.connectAttempts)
        var lastError: BluetoothTransportError?
        for attempt in 1...attempts {
            do {
                return try await central.connect(to: peripheral, timeout: timing.connectTimeout)
            } catch let error as BluetoothTransportError {
                switch error {
                case .unavailable, .unknownPeripheral:
                    throw Self.mapTransportError(error, phase: .connect)  // terminal
                case .timedOut, .notConnected, .characteristicNotFound, .valueTooLong, .disconnected, .gatt:
                    break
                }
                lastError = error
                log?("Connection attempt \(attempt)/\(attempts) to \(peripheral) failed: \(error)")
                if attempt < attempts {
                    let backoff: Duration
                    if case .timedOut = error {
                        backoff = timing.connectBackoffAfterTimeout
                    } else {
                        backoff = timing.connectBackoff
                    }
                    try await sleeper.sleep(for: backoff, purpose: .connectBackoff)
                }
            } catch {
                throw Self.mapTransportError(error, phase: .connect)
            }
        }
        let last = lastError.map { String(describing: $0) } ?? "unknown error"
        throw LaMarzoccoError.bluetoothConnectionFailed("Failed to connect to \(peripheral) after \(attempts) attempts: \(last)")
    }

    /// One watcher per link; events are handled in the order the link emitted them (I5).
    private func startLinkWatcher(_ link: any BluetoothLink) {
        linkWatcher = Task { [weak self] in for await e in link.events { await self?.handleLinkEvent(e, from: link) } }
    }

    /// Error text for log lines (never contains the token).
    private nonisolated static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }
}
