#if canImport(CoreBluetooth)
import Angstrom
import CoreBluetooth
import Foundation
import os

// The CoreBluetooth adapter (SPEC §5.4). Design: ONE private serial DispatchQueue
// (label "angstrom.bluetooth") is both the CBCentralManager delegate queue and the
// confinement domain for every CB object and every piece of mutable adapter state.
// Async callers hop onto the queue; delegate callbacks (already on the queue) resolve
// in-flight operations through a queue-confined `BluetoothOpTable`. There is no actor
// executor, no `Task` hop inside a delegate callback, and no CB object ever leaves the
// queue: only `Data`, `String`, UUIDs and enums cross into async callers.

// MARK: - Operation bridge (shared by the central and its links)

/// What an in-flight operation waits for. Delegate callbacks identify their operation only
/// by key, so same-key operations resolve FIFO (CoreBluetooth answers ATT requests in order).
protocol CoreBluetoothOperationKey: Hashable, Sendable, CustomStringConvertible {
    /// An ATT request always gets exactly one delegate reply (or the link drops), so an
    /// operation abandoned by timeout or cancellation still owes one callback, which the
    /// op table swallows instead of letting it resolve a newer operation with the same key.
    var isGATTRequest: Bool { get }
}

/// The async/await bridge over one queue-confined `BluetoothOpTable`.
///
/// `@unchecked Sendable` is sound because the only mutable state (`table`, `nextToken`) is
/// touched exclusively on `queue` — every access path either runs inside a `queue.async`
/// block or is a delegate-callback helper that asserts `dispatchPrecondition(.onQueue)`.
/// The `OSAllocatedUnfairLock` per operation is the only state shared with the
/// cancellation handler, which may run on any thread.
final class CoreBluetoothOperations<Key: CoreBluetoothOperationKey>: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Queue-confined.
    private let table = BluetoothOpTable<Key>()
    /// Queue-confined.
    private var nextToken: UInt64 = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Bridges one delegate round-trip to async/await.
    ///
    /// `precheck` runs on the queue first: what it throws wins over cancellation (a dead link is
    /// reported as dead, cancelled or not). `start` runs on the queue after the operation is
    /// registered; it issues the CB request, or throws (a `BluetoothTransportError`) without
    /// issuing anything. When the operation is abandoned — by its timeout or, if `cancellable`,
    /// by cancellation of the calling task — it fails with `.timedOut(key.description)` /
    /// `CancellationError`, an ATT request records its owed reply, and `onAbandon` runs on the queue.
    func perform<T: Sendable>(
        _ key: Key,
        timeout: Duration,
        cancellable: Bool = true,
        precheck: (@Sendable () throws -> Void)? = nil,
        onAbandon: (@Sendable () -> Void)? = nil,
        start: @escaping @Sendable () throws -> Void
    ) async throws -> T {
        guard cancellable else {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async {
                    self.begin(key, timeout: timeout, cancelState: nil, continuation: continuation,
                               precheck: precheck, onAbandon: onAbandon, start: start)
                }
            }
        }
        let cancelState = OSAllocatedUnfairLock(initialState: CancelState())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async {
                    self.begin(key, timeout: timeout, cancelState: cancelState, continuation: continuation,
                               precheck: precheck, onAbandon: onAbandon, start: start)
                }
            }
        } onCancel: {
            // May run on any thread, before or after `begin` registered the operation.
            let token = cancelState.withLock { state -> UInt64? in
                state.cancelled = true
                return state.token
            }
            guard let token else { return } // `begin` will see `cancelled` and never start the op
            self.queue.async {
                if self.table.finish(token, .failure(CancellationError()), abandoning: true) {
                    onAbandon?()
                }
            }
        }
    }

    /// Runs `body` on the queue (not cancellable: queue state must stay consistent).
    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Runs `body` on the queue, propagating what it throws.
    func runThrowing<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// Delegate-callback path (queue only): swallow one owed reply, else resolve the oldest op.
    @discardableResult
    func finishOldest(_ key: Key, _ result: Result<any Sendable, any Error>) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return table.finishOldest(key, result)
    }

    /// Queue only: an operation, or a reply owed by an abandoned one, is outstanding for `key`.
    func isAwaiting(_ key: Key) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return table.isAwaiting(key)
    }

    /// Queue only: a request was sent that nobody awaits; swallow its reply.
    func owe(_ key: Key) {
        dispatchPrecondition(condition: .onQueue(queue))
        table.owe(key)
    }

    /// Queue only: fail every matching operation and drop matching owed replies.
    func failAll(where match: (Key) -> Bool, _ error: any Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        table.failAll(where: match, error)
    }

    // MARK: Private

    private struct CancelState: Sendable {
        var cancelled = false
        var token: UInt64?
    }

    private func begin<T: Sendable>(
        _ key: Key,
        timeout: Duration,
        cancelState: OSAllocatedUnfairLock<CancelState>?,
        continuation: CheckedContinuation<T, any Error>,
        precheck: (@Sendable () throws -> Void)?,
        onAbandon: (@Sendable () -> Void)?,
        start: @Sendable () throws -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            try precheck?()
        } catch {
            continuation.resume(throwing: error)
            return
        }
        nextToken &+= 1
        let token = nextToken
        if let cancelState {
            let proceed = cancelState.withLock { state -> Bool in
                if state.cancelled { return false }
                state.token = token
                return true
            }
            guard proceed else {
                // Cancelled before registration: nothing was sent, nothing is owed.
                continuation.resume(throwing: CancellationError())
                return
            }
        }
        table.register(token, key: key, isGATTRequest: key.isGATTRequest) { result in
            switch result {
            case .success(let value):
                if let value = value as? T {
                    continuation.resume(returning: value)
                } else {
                    assertionFailure("CoreBluetooth adapter: \(key) resolved with \(type(of: value)), expected \(T.self)")
                    continuation.resume(throwing: BluetoothTransportError.notConnected)
                }
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
        do {
            try start()
        } catch {
            // `start` throws only before it issues a request, so nothing is owed.
            table.finish(token, .failure(error), abandoning: false)
            return
        }
        queue.asyncAfter(deadline: .now() + coreBluetoothSeconds(timeout)) {
            if self.table.finish(token, .failure(BluetoothTransportError.timedOut(key.description)), abandoning: true) {
                onAbandon?()
            }
        }
    }
}

/// `Duration` as seconds for `DispatchTime` arithmetic (negative durations clamp to 0).
private func coreBluetoothSeconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return max(0, Double(seconds) + Double(attoseconds) / 1e18)
}

// MARK: - Central

/// `BluetoothCentral` over `CBCentralManager`.
///
/// `@unchecked Sendable` is sound because every stored `var` and every CB object it holds
/// (`manager`, `known`, `links`, `scanSessions`, `scanLeases`) is touched only on `queue`,
/// which is also the manager's delegate queue; queue-only helpers and every delegate
/// callback assert it with `dispatchPrecondition(condition: .onQueue(queue))`. The one
/// exception, `availabilitySubscribers`, is protected by its own `OSAllocatedUnfairLock`
/// because `availabilityUpdates()` is synchronous and must register before it returns.
final class CoreBluetoothCentral: NSObject, BluetoothCentral, CBCentralManagerDelegate, @unchecked Sendable {
    /// bleak `find_device_by_address` analogue (`B-CL:101-110`): scan this long for an
    /// identifier that neither the retention table nor `retrievePeripherals` knows.
    private static let findTimeout: Duration = .seconds(10)

    private let queue = DispatchQueue(label: "angstrom.bluetooth")
    private let showPowerAlert: Bool
    /// The transport's clock; links stamp `GATTNotification.receivedAt` with it.
    private let now: @Sendable () -> Date
    private let ops: CoreBluetoothOperations<CentralOperation>
    private let availabilitySubscribers =
        OSAllocatedUnfairLock(initialState: [UInt64: AsyncStream<BluetoothAvailability>.Continuation]())
    private let nextSubscriberID = OSAllocatedUnfairLock(initialState: UInt64(0))

    // Queue-confined.
    private var manager: CBCentralManager?
    /// Retention table: CB cleans up a peripheral nobody retains (`CBCentralManager.h:303-305`).
    private var known: [UUID: CBPeripheral] = [:]
    /// Live links (connected and not yet terminated), at most one per peripheral.
    private var links: [UUID: CoreBluetoothLink] = [:]
    /// Active `scan(for:)` calls, each with its own de-duplicated, first-seen-ordered results.
    private var scanSessions: [UUID: ScanSession] = [:]
    /// Everything that currently needs the radio scanning (scan sessions and identifier finds).
    private var scanLeases: Set<UUID> = []

    init(showPowerAlert: Bool, now: @escaping @Sendable () -> Date) {
        self.showPowerAlert = showPowerAlert
        self.now = now
        self.ops = CoreBluetoothOperations(queue: queue)
        super.init()
    }

    // MARK: BluetoothCentral

    func availability() async -> BluetoothAvailability {
        await ops.run { [self] in Self.availability(of: ensureManager().state) }
    }

    func availabilityUpdates() -> AsyncStream<BluetoothAvailability> {
        let (stream, continuation) = AsyncStream.makeStream(of: BluetoothAvailability.self,
                                                            bufferingPolicy: .unbounded)
        let id = nextSubscriberID.withLock { next -> UInt64 in
            next &+= 1
            return next
        }
        // Registered before the stream is returned, so no later state change is missed.
        availabilitySubscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.availabilitySubscribers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] {
        try Task.checkCancellation()
        let session = UUID()
        try await ops.runThrowing { [self] in
            try requirePoweredOn()
            scanSessions[session] = ScanSession()
            beginScanning(lease: session)
        }
        do {
            try await Task.sleep(for: duration)
        } catch {
            await ops.run { [self] in _ = endScanSession(session) }
            throw CancellationError()
        }
        return await ops.run { [self] in endScanSession(session) }
    }

    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        guard let uuid = UUID(uuidString: id.rawValue) else {
            throw BluetoothTransportError.unknownPeripheral(id)
        }
        try Task.checkCancellation()
        let resolved = try await ops.runThrowing { [self] in
            try requirePoweredOn()
            return resolvePeripheral(uuid) != nil
        }
        if !resolved {
            try await findByScanning(id, uuid)
        }
        let link: CoreBluetoothLink = try await ops.perform(
            .connect(uuid), timeout: timeout,
            // CoreBluetooth connects never time out (`CBCentralManager.h:201`): cancel ours.
            onAbandon: { [self] in cancelAbandonedConnect(uuid) }
        ) { [self] in
            try requirePoweredOn()
            guard let peripheral = resolvePeripheral(uuid) else {
                throw BluetoothTransportError.unknownPeripheral(id)
            }
            // No options: never CBConnectPeripheralOptionEnableAutoReconnect (SPEC §5.4).
            ensureManager().connect(peripheral, options: nil)
        }
        return link
    }

    // MARK: CBCentralManagerDelegate (always on `queue`)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(queue))
        let state = central.state
        let availability = Self.availability(of: state)
        if state == .poweredOn {
            // A state drop stopped the radio; resume for scans that are still running.
            if !scanLeases.isEmpty {
                central.scanForPeripherals(withServices: nil, options: nil)
            }
        } else {
            // "A state below PoweredOn implies that scanning has stopped and any connected
            // peripherals have been disconnected" (`CBCentralManager.h:264-268`). Whether
            // didDisconnectPeripheral still arrives is UNVERIFIED (H4), so synthesise it; a
            // link terminates at most once.
            let error = BluetoothTransportError.unavailable(availability)
            let live = Array(links.values)
            links.removeAll()
            for link in live {
                link.handleDisconnect(error)
            }
            ops.failAll(where: { _ in true }, error) // pending connects and identifier finds
            switch state {
            case .unknown, .resetting, .unsupported, .unauthorized:
                // Below PoweredOff every CBPeripheral is invalid (`CBCentralManager.h:266-268`).
                known.removeAll()
            default:
                break
            }
        }
        let subscribers = availabilitySubscribers.withLock { Array($0.values) }
        for subscriber in subscribers {
            subscriber.yield(availability)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(queue))
        let uuid = peripheral.identifier
        known[uuid] = peripheral
        // bleak's BLEDevice.name on macOS is CBPeripheral.name; fall back to the advertised local name (D3).
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        // 127 is reserved: RSSI not available (`CBCentralManager.h:300`).
        let rssi: Int? = RSSI.intValue == 127 ? nil : RSSI.intValue
        for session in Array(scanSessions.keys) {
            scanSessions[session]?.record(uuid, name: name, rssi: rssi)
        }
        while ops.isAwaiting(.find(uuid)) {
            ops.finishOldest(.find(uuid), .success(()))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(queue))
        let uuid = peripheral.identifier
        guard ops.isAwaiting(.connect(uuid)) else {
            // Nobody waits any more (timed out or cancelled): drop the late connection — unless
            // it is the connection a live link already uses.
            if links[uuid] == nil {
                central.cancelPeripheralConnection(peripheral)
            }
            return
        }
        // A new link per connection. A previous live link for this peripheral loses its
        // delegate here, so it can never complete another op: terminate it.
        links.removeValue(forKey: uuid)?.handleDisconnect(.disconnected(code: nil))
        let link = CoreBluetoothLink(
            peripheral: peripheral, manager: central, queue: queue, now: now,
            onTerminate: { [weak self] link in
                guard let self, self.links[uuid] === link else { return }
                self.links.removeValue(forKey: uuid)
            })
        peripheral.delegate = link
        links[uuid] = link
        ops.finishOldest(.connect(uuid), .success(link))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        ops.finishOldest(.connect(peripheral.identifier), .failure(Self.linkError(error)))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Pending connects are NOT failed here: they resolve through didConnect, didFailToConnect
        // or their timeout. A disconnect arriving while one is pending belongs to an earlier,
        // abandoned connection (its cancelPeripheralConnection) and must not fail the new attempt.
        links.removeValue(forKey: peripheral.identifier)?.handleDisconnect(error.map { Self.linkError($0) })
    }

    // MARK: Private

    private enum CentralOperation: CoreBluetoothOperationKey {
        case connect(UUID)
        /// Scan until this identifier is discovered.
        case find(UUID)

        var isGATTRequest: Bool { false }

        var description: String {
            switch self {
            case .connect(let uuid): "connect \(uuid.uuidString)"
            case .find(let uuid): "scan for \(uuid.uuidString)"
            }
        }
    }

    private struct ScanSession {
        private var order: [UUID] = []
        private var entries: [UUID: DiscoveredPeripheral] = [:]

        /// De-duplicates by identifier and keeps the first-seen position; a later
        /// advertisement only fills in what is still missing or fresher.
        mutating func record(_ uuid: UUID, name: String?, rssi: Int?) {
            if let existing = entries[uuid] {
                entries[uuid] = DiscoveredPeripheral(id: existing.id, name: name ?? existing.name,
                                                     rssi: rssi ?? existing.rssi)
            } else {
                order.append(uuid)
                entries[uuid] = DiscoveredPeripheral(id: BluetoothPeripheralID(rawValue: uuid.uuidString),
                                                     name: name, rssi: rssi)
            }
        }

        var results: [DiscoveredPeripheral] { order.compactMap { entries[$0] } }
    }

    /// Lazy: allocating the manager is what can surface the TCC prompt, so a process that
    /// never uses Bluetooth never prompts.
    private func ensureManager() -> CBCentralManager {
        dispatchPrecondition(condition: .onQueue(queue))
        if let manager { return manager }
        let created = CBCentralManager(delegate: self, queue: queue,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: showPowerAlert])
        manager = created
        return created
    }

    private func requirePoweredOn() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let state = ensureManager().state
        guard state == .poweredOn else {
            throw BluetoothTransportError.unavailable(Self.availability(of: state))
        }
    }

    /// `known[uuid] ?? retrievePeripherals(withIdentifiers: [uuid]).first`, retained when found.
    private func resolvePeripheral(_ uuid: UUID) -> CBPeripheral? {
        dispatchPrecondition(condition: .onQueue(queue))
        if let peripheral = known[uuid] { return peripheral }
        guard let peripheral = ensureManager().retrievePeripherals(withIdentifiers: [uuid]).first else {
            return nil
        }
        known[uuid] = peripheral
        return peripheral
    }

    /// Scans (no service filter) for up to 10 s until `uuid` is discovered; `.unknownPeripheral` otherwise.
    private func findByScanning(_ id: BluetoothPeripheralID, _ uuid: UUID) async throws {
        let lease = UUID()
        do {
            let _: Void = try await ops.perform(.find(uuid), timeout: Self.findTimeout) { [self] in
                try requirePoweredOn()
                if known[uuid] != nil {
                    // Discovered by another scan since the lookup: satisfy every find for it.
                    while ops.isAwaiting(.find(uuid)) {
                        ops.finishOldest(.find(uuid), .success(()))
                    }
                    return
                }
                beginScanning(lease: lease)
            }
        } catch BluetoothTransportError.timedOut {
            await ops.run { [self] in endScanning(lease: lease) }
            throw BluetoothTransportError.unknownPeripheral(id)
        } catch {
            await ops.run { [self] in endScanning(lease: lease) }
            throw error
        }
        await ops.run { [self] in endScanning(lease: lease) }
    }

    private func beginScanning(lease: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        let wasIdle = scanLeases.isEmpty
        scanLeases.insert(lease)
        if wasIdle {
            // No service filter: upstream filters by name only and the service UUID is UNVERIFIED (U1).
            ensureManager().scanForPeripherals(withServices: nil, options: nil)
        }
    }

    /// Idempotent.
    private func endScanning(lease: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard scanLeases.remove(lease) != nil, scanLeases.isEmpty, let manager else { return }
        if manager.state == .poweredOn {
            manager.stopScan()
        }
    }

    private func endScanSession(_ session: UUID) -> [DiscoveredPeripheral] {
        dispatchPrecondition(condition: .onQueue(queue))
        endScanning(lease: session)
        return scanSessions.removeValue(forKey: session)?.results ?? []
    }

    /// After a connect timed out or was cancelled: cancel the pending CB connect, unless
    /// another attempt still waits on it or a live link uses the connection.
    private func cancelAbandonedConnect(_ uuid: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard links[uuid] == nil, !ops.isAwaiting(.connect(uuid)),
              let manager, let peripheral = known[uuid] else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    private static func availability(of state: CBManagerState) -> BluetoothAvailability {
        switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized: .unauthorized(.current)
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    /// A connect failure or link loss: `.disconnected(code:)` carrying the `CBError` code when
    /// CoreBluetooth gave one.
    private static func linkError(_ error: (any Error)?) -> BluetoothTransportError {
        guard let error else { return .disconnected(code: nil) }
        let nsError = error as NSError
        return .disconnected(code: nsError.domain == CBErrorDomain ? nsError.code : nil)
    }
}
#endif
