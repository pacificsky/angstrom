#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import os

// MARK: - Helpers

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// What an in-flight operation is waiting for. Delegate callbacks identify their
/// operation only by (peripheral, characteristic), so ops with the same key are FIFO.
enum OpKey: Hashable, Sendable {
    case poweredOn
    case connect(UUID)
    case disconnect(UUID)
    case discoverServices(UUID)
    case discoverCharacteristics(UUID, service: String)
    case read(UUID, String)
    case write(UUID, String)
    case notify(UUID, String)

    var peripheral: UUID? {
        switch self {
        case .poweredOn: nil
        case .connect(let p), .disconnect(let p), .discoverServices(let p),
             .discoverCharacteristics(let p, _), .read(let p, _), .write(let p, _), .notify(let p, _): p
        }
    }

    /// ATT requests always get exactly one response or the link drops, so an op
    /// abandoned by timeout/cancel still "owes" one callback that must be swallowed.
    var isGATTRequest: Bool {
        switch self {
        case .read, .write, .notify, .discoverServices, .discoverCharacteristics: true
        default: false
        }
    }
}

/// Queue-confined table of in-flight operations (NOT thread-safe: touch only on the
/// adapter queue). Exactly-once resume: every completion path — delegate callback,
/// timeout, cancellation, disconnect — goes through `finish*`, which *removes* the
/// entry before calling it. On a serial queue only one path can win.
final class OpTable {
    typealias Completion = (Result<any Sendable, any Error>) -> Void
    private var entries: [UInt64: (key: OpKey, complete: Completion)] = [:]
    private var order: [UInt64] = []
    private var orphans: [OpKey: Int] = [:]

    func register(_ token: UInt64, key: OpKey, complete: @escaping Completion) {
        entries[token] = (key, complete)
        order.append(token)
    }

    /// Resolve by token. Returns false if the op already finished.
    @discardableResult
    func finish(_ token: UInt64, _ result: Result<any Sendable, any Error>, abandoning: Bool) -> Bool {
        guard let entry = entries.removeValue(forKey: token) else { return false }
        order.removeAll { $0 == token }
        if abandoning && entry.key.isGATTRequest { orphans[entry.key, default: 0] += 1 }
        entry.complete(result)
        return true
    }

    func isAwaiting(_ key: OpKey) -> Bool {
        (orphans[key] ?? 0) > 0 || order.contains { entries[$0]?.key == key }
    }

    /// Resolve the oldest op waiting on `key` (delegate-callback path). A late
    /// reply for an abandoned op is swallowed so it can't satisfy a newer request.
    @discardableResult
    func finishOldest(_ key: OpKey, _ result: Result<any Sendable, any Error>) -> Bool {
        if let owed = orphans[key], owed > 0 {
            orphans[key] = owed == 1 ? nil : owed - 1
            return true
        }
        guard let token = order.first(where: { entries[$0]?.key == key }) else { return false }
        return finish(token, result, abandoning: false)
    }

    func failAll(where match: (OpKey) -> Bool, _ error: any Error) {
        orphans = orphans.filter { !match($0.key) }
        for token in order where entries[token].map({ match($0.key) }) == true {
            finish(token, .failure(error), abandoning: false)
        }
    }
}

private struct CancelBox: Sendable {
    var cancelled = false
    var token: UInt64?
}

private func mapError(_ error: (any Error)?) -> BluetoothTransportError? {
    guard let error else { return nil }
    let ns = error as NSError
    if ns.domain == CBErrorDomain,
       ns.code == CBError.Code.peripheralDisconnected.rawValue || ns.code == CBError.Code.notConnected.rawValue {
        return .disconnected(code: ns.code)
    }
    return .gatt(domain: ns.domain, code: ns.code)
}

// MARK: - Central adapter

/// The ONLY CoreBluetooth-touching central type. All mutable state is confined to
/// `queue`, which is also the queue CoreBluetooth delivers delegate callbacks on —
/// hence `@unchecked Sendable` is sound: nothing is read or written off-queue.
final class CoreBluetoothCentral: NSObject, BluetoothCentral, CBCentralManagerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "angstrom.bluetooth")
    let now: @Sendable () -> Date

    // queue-confined
    private var manager: CBCentralManager?
    let ops = OpTable()
    private var nextToken: UInt64 = 0
    private var known: [UUID: CBPeripheral] = [:]       // discovered peripherals must be retained
    private var scanResults: [UUID: DiscoveredPeripheral] = [:]
    private var links: [UUID: CoreBluetoothLink] = [:]

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        super.init()
    }

    /// Lazily create the manager: instantiating CBCentralManager is what triggers
    /// the TCC prompt, so a consumer that never touches Bluetooth never prompts.
    private func ensureManager() -> CBCentralManager {
        dispatchPrecondition(condition: .onQueue(queue))
        if let manager { return manager }
        let m = CBCentralManager(delegate: self, queue: queue,
                                 options: [CBCentralManagerOptionShowPowerAlertKey: false])
        manager = m
        return m
    }

    func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: body()) } }
    }

    /// Bridge one delegate round-trip to async/await with timeout + cancellation.
    func perform<T: Sendable>(
        _ key: OpKey,
        timeout: Duration?,
        onTimeout: (@Sendable () -> Void)? = nil,
        start: @escaping @Sendable () throws -> Void
    ) async throws -> T {
        let box = OSAllocatedUnfairLock(initialState: CancelBox())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
                queue.async {
                    self.nextToken += 1
                    let token = self.nextToken
                    // Cancellation may have run before this block (task already cancelled).
                    let proceed = box.withLock { state -> Bool in
                        if state.cancelled { return false }
                        state.token = token
                        return true
                    }
                    guard proceed else { cont.resume(throwing: CancellationError()); return }
                    self.ops.register(token, key: key) { result in
                        switch result {
                        case .success(let value as T): cont.resume(returning: value)
                        case .success: cont.resume(throwing: BluetoothTransportError.gatt(domain: "angstrom", code: -1))
                        case .failure(let error): cont.resume(throwing: error)
                        }
                    }
                    do { try start() } catch {
                        self.ops.finish(token, .failure(error), abandoning: false)
                        return
                    }
                    if let timeout {
                        self.queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                            if self.ops.finish(token, .failure(BluetoothTransportError.timedOut("\(key)")), abandoning: true) {
                                onTimeout?()
                            }
                        }
                    }
                }
            }
        } onCancel: {
            let token = box.withLock { state -> UInt64? in
                state.cancelled = true
                return state.token
            }
            if let token {
                self.queue.async { self.ops.finish(token, .failure(CancellationError()), abandoning: true) }
            }
        }
    }

    // MARK: BluetoothCentral

    func availability() async -> BluetoothAvailability {
        await onQueue { Self.map(self.ensureManager().state) }
    }

    static func map(_ state: CBManagerState) -> BluetoothAvailability {
        switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized:
            switch CBManager.authorization {
            case .notDetermined: .unauthorized(.notDetermined)
            case .restricted: .unauthorized(.restricted)
            case .denied: .unauthorized(.denied)
            case .allowedAlways: .unauthorized(.allowedAlways)
            @unknown default: .unauthorized(.denied)
            }
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    /// Wait for `.poweredOn`, failing fast on terminal states. `timeout` must be
    /// generous on first use: state stays `.unknown` while the TCC prompt is up (UNVERIFIED).
    func requirePoweredOn(timeout: Duration = .seconds(30)) async throws {
        let _: Void = try await perform(.poweredOn, timeout: timeout) {
            let state = self.ensureManager().state
            switch state {
            case .poweredOn:
                self.queue.async { self.ops.finishOldest(.poweredOn, .success(())) }
            case .unknown, .resetting:
                break // wait for centralManagerDidUpdateState
            default:
                throw BluetoothTransportError.unavailable(Self.map(state))
            }
        }
    }

    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] {
        try await requirePoweredOn()
        await onQueue {
            self.scanResults = [:]
            // nil services: the La Marzocco service UUID is not in upstream (UNVERIFIED);
            // upstream filters by name prefix only.
            self.ensureManager().scanForPeripherals(withServices: nil, options: nil)
        }
        try? await Task.sleep(for: duration) // cancellation just ends the scan early
        return await onQueue {
            self.manager?.stopScan()
            return Array(self.scanResults.values)
        }
    }

    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        try await requirePoweredOn()
        guard let uuid = UUID(uuidString: id.rawValue) else { throw BluetoothTransportError.unknownPeripheral(id) }
        let link: CoreBluetoothLink = try await perform(
            .connect(uuid), timeout: timeout,
            onTimeout: { [weak self] in self?.cancelConnection(uuid) }   // CB connects never time out
        ) {
            let manager = self.ensureManager()
            guard let p = self.known[uuid] ?? manager.retrievePeripherals(withIdentifiers: [uuid]).first else {
                throw BluetoothTransportError.unknownPeripheral(id)
            }
            self.known[uuid] = p
            manager.connect(p, options: nil)
        }
        return link
    }

    /// queue-only
    func cancelConnection(_ uuid: UUID) {
        if let p = known[uuid] { manager?.cancelPeripheralConnection(p) }
    }

    // MARK: CBCentralManagerDelegate (always on `queue`)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        switch state {
        case .poweredOn:
            while ops.finishOldest(.poweredOn, .success(())) {}
        case .unknown, .resetting:
            break
        default:
            ops.failAll(where: { $0 == .poweredOn }, BluetoothTransportError.unavailable(Self.map(state)))
        }
        if state != .poweredOn {
            // "A state below PoweredOn implies ... connected peripherals have been disconnected" (CBCentralManager.h:264-268)
            for link in links.values { link.handleDisconnect(BluetoothTransportError.unavailable(Self.map(state))) }
            links.removeAll()
            if state != .poweredOff { known.removeAll() } // below PoweredOff: CBPeripheral objects invalid
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        known[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue // 127 = unavailable (CBCentralManager.h:300-301)
        scanResults[peripheral.identifier] = DiscoveredPeripheral(
            id: BluetoothPeripheralID(rawValue: peripheral.identifier.uuidString), name: name, rssi: rssi)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let link = CoreBluetoothLink(peripheral: peripheral, central: self)
        peripheral.delegate = link
        if ops.finishOldest(.connect(peripheral.identifier), .success(link)) {
            links[peripheral.identifier] = link
        } else {
            central.cancelPeripheralConnection(peripheral) // nobody wants it any more (timed out / cancelled)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        ops.finishOldest(.connect(peripheral.identifier),
                         .failure(mapError(error) ?? BluetoothTransportError.disconnected(code: nil)))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        ops.failAll(where: { $0 == .connect(peripheral.identifier) },
                    mapError(error) ?? BluetoothTransportError.disconnected(code: nil))
        links.removeValue(forKey: peripheral.identifier)?.handleDisconnect(mapError(error))
    }
}

// MARK: - Link adapter

final class CoreBluetoothLink: NSObject, BluetoothLink, CBPeripheralDelegate, @unchecked Sendable {
    let peripheralID: BluetoothPeripheralID
    let events: AsyncStream<LinkEvent>
    private let eventSink: AsyncStream<LinkEvent>.Continuation
    private let uuid: UUID
    private let central: CoreBluetoothCentral

    // queue-confined
    private let peripheral: CBPeripheral
    private var characteristics: [String: CBCharacteristic] = [:]
    private var subscribers: [String: AsyncStream<GATTNotification>.Continuation] = [:]
    private var isDisconnected = false

    init(peripheral: CBPeripheral, central: CoreBluetoothCentral) {
        self.peripheral = peripheral
        self.central = central
        uuid = peripheral.identifier
        peripheralID = BluetoothPeripheralID(rawValue: peripheral.identifier.uuidString)
        (events, eventSink) = AsyncStream.makeStream(of: LinkEvent.self, bufferingPolicy: .unbounded)
        super.init()
    }

    private func characteristic(_ id: GATTUUID) throws -> CBCharacteristic {
        if isDisconnected { throw BluetoothTransportError.notConnected }
        guard let ch = characteristics[id.string] else { throw BluetoothTransportError.characteristicNotFound(id) }
        return ch
    }

    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        let cached = await central.onQueue { wanted.filter { self.characteristics[$0.string] != nil } }
        if !refresh && cached == wanted { return cached }
        let _: Void = try await central.perform(.discoverServices(uuid), timeout: timeout) {
            if self.isDisconnected { throw BluetoothTransportError.notConnected }
            self.characteristics.removeAll()
            self.peripheral.discoverServices(nil) // service UUID unknown upstream (UNVERIFIED)
        }
        let services = await central.onQueue { self.peripheral.services?.map { $0.uuid.uuidString.lowercased() } ?? [] }
        for service in services {
            let _: Void = try await central.perform(.discoverCharacteristics(uuid, service: service), timeout: timeout) {
                guard let svc = self.peripheral.services?.first(where: { $0.uuid.uuidString.lowercased() == service }) else {
                    throw BluetoothTransportError.notConnected
                }
                self.peripheral.discoverCharacteristics(wanted.map { CBUUID(string: $0.string) }, for: svc)
            }
        }
        return await central.onQueue { wanted.filter { self.characteristics[$0.string] != nil } }
    }

    func read(_ id: GATTUUID, timeout: Duration) async throws -> Data {
        try await central.perform(.read(uuid, id.string), timeout: timeout) {
            self.peripheral.readValue(for: try self.characteristic(id))
        }
    }

    func write(_ data: Data, to id: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        guard withResponse else {
            // upstream never writes without response; kept for completeness
            try await central.onQueue { () -> Result<Void, BluetoothTransportError> in
                do {
                    self.peripheral.writeValue(data, for: try self.characteristic(id), type: .withoutResponse)
                    return .success(())
                } catch { return .failure(error as? BluetoothTransportError ?? .notConnected) }
            }.get()
            return
        }
        let _: Void = try await central.perform(.write(uuid, id.string), timeout: timeout) {
            let ch = try self.characteristic(id)
            let max = self.peripheral.maximumWriteValueLength(for: .withResponse)
            guard data.count <= max else { throw BluetoothTransportError.valueTooLong(data.count, max: max) }
            self.peripheral.writeValue(data, for: ch, type: .withResponse)
        }
    }

    func subscribe(_ id: GATTUUID, timeout: Duration) async throws -> AsyncStream<GATTNotification> {
        let (stream, sink) = AsyncStream.makeStream(of: GATTNotification.self, bufferingPolicy: .unbounded)
        do {
            let _: Void = try await central.perform(.notify(uuid, id.string), timeout: timeout) {
                let ch = try self.characteristic(id)
                self.subscribers.removeValue(forKey: id.string)?.finish()
                // Install BEFORE enabling: the machine replays its last notification on
                // subscribe (upstream _bluetooth.py:429-431), possibly before the CCCD ack.
                self.subscribers[id.string] = sink
                self.peripheral.setNotifyValue(true, for: ch)
            }
        } catch {
            await central.onQueue { self.subscribers.removeValue(forKey: id.string)?.finish() }
            throw error
        }
        return stream
    }

    func unsubscribe(_ id: GATTUUID) async {
        await central.onQueue {
            self.subscribers.removeValue(forKey: id.string)?.finish()
            if !self.isDisconnected, let ch = self.characteristics[id.string] {
                self.peripheral.setNotifyValue(false, for: ch) // best effort, like upstream's suppress()
            }
        }
    }

    func disconnect() async {
        let _: Void? = try? await central.perform(.disconnect(uuid), timeout: .seconds(5)) {
            if self.isDisconnected {
                self.central.queue.async { self.central.ops.finishOldest(.disconnect(self.uuid), .success(())) }
            } else {
                self.central.cancelConnection(self.uuid)
            }
        }
    }

    /// queue-only. Fails everything in flight, ends streams, reports once.
    func handleDisconnect(_ error: BluetoothTransportError?) {
        guard !isDisconnected else { return }
        isDisconnected = true
        while central.ops.finishOldest(.disconnect(uuid), .success(())) {}
        central.ops.failAll(where: { $0.peripheral == self.uuid }, error ?? BluetoothTransportError.disconnected(code: nil))
        for sink in subscribers.values { sink.finish() }
        subscribers.removeAll()
        eventSink.yield(.disconnected(error))
        eventSink.finish()
    }

    // MARK: CBPeripheralDelegate (always on the central's queue)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        central.ops.finishOldest(.discoverServices(uuid), error.map { .failure(mapError($0)!) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        for ch in service.characteristics ?? [] { characteristics[ch.uuid.uuidString.lowercased()] = ch }
        central.ops.finishOldest(.discoverCharacteristics(uuid, service: service.uuid.uuidString.lowercased()),
                                 error.map { .failure(mapError($0)!) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        characteristics.removeAll()
        eventSink.yield(.servicesInvalidated)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let key = characteristic.uuid.uuidString.lowercased()
        let value = characteristic.value ?? Data()
        // Same callback serves reads AND notifications. A pending (or owed) read wins;
        // upstream never reads a characteristic it is subscribed to, so this is unambiguous.
        if central.ops.isAwaiting(.read(uuid, key)) {
            central.ops.finishOldest(.read(uuid, key), error.map { .failure(mapError($0)!) } ?? .success(value))
        } else if error == nil, let sink = subscribers[key] {
            sink.yield(GATTNotification(value: value, receivedAt: central.now()))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        central.ops.finishOldest(.write(uuid, characteristic.uuid.uuidString.lowercased()),
                                 error.map { .failure(mapError($0)!) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        central.ops.finishOldest(.notify(uuid, characteristic.uuid.uuidString.lowercased()),
                                 error.map { .failure(mapError($0)!) } ?? .success(()))
    }
}
#endif
