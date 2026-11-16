#if canImport(CoreBluetooth)
import Angstrom
import CoreBluetooth
import Foundation

/// `BluetoothLink` over one connection to one `CBPeripheral` (SPEC §5.4, §6.2). A new
/// instance is created for every connection, so the client can compare links by identity.
///
/// `@unchecked Sendable` is sound because every stored `var` and every CB object it holds
/// (`peripheral`, `manager`, `characteristics`, `notifying`, …) is touched only on the
/// central's private serial queue — the `CBCentralManager` delegate queue, on which
/// CoreBluetooth also delivers every `CBPeripheralDelegate` callback. Async seam methods hop
/// onto it through `CoreBluetoothOperations`; queue-only helpers and every delegate callback
/// assert it with `dispatchPrecondition(condition: .onQueue(queue))`. The remaining stored
/// properties are immutable and `Sendable` (`peripheralID`, `events`, `sink`, `now`).
final class CoreBluetoothLink: NSObject, BluetoothLink, CBPeripheralDelegate, @unchecked Sendable {
    /// `DISCONNECT_TIMEOUT = 5` (`bleak_retry_connector/const.py:8`).
    private static let disconnectTimeout: Duration = .seconds(5)

    let peripheralID: BluetoothPeripheralID
    let events: AsyncStream<LinkEvent>

    private let sink: AsyncStream<LinkEvent>.Continuation
    private let queue: DispatchQueue
    private let ops: CoreBluetoothOperations<LinkOperation>
    private let now: @Sendable () -> Date
    // Queue-confined.
    private let peripheral: CBPeripheral
    private let manager: CBCentralManager
    /// Called once, on the queue, when this link terminates (so the central forgets it).
    private let onTerminate: (CoreBluetoothLink) -> Void
    /// Characteristic table by UUID, across every service (no service UUID is assumed, SPEC §3.1).
    private var characteristics: [GATTUUID: CBCharacteristic] = [:]
    /// A full discovery completed since the connection or the last invalidation.
    private var hasDiscovered = false
    /// Bumped on every invalidation or refresh, so a discovery overtaken by one is not marked complete.
    private var discoveryGeneration: UInt64 = 0
    /// Characteristics whose values are routed to `events` as notifications.
    private var notifying: Set<GATTUUID> = []
    /// Every `CBService` whose `ObjectIdentifier` has keyed a `.discoverCharacteristics` op on
    /// this link, retained until termination. An owed reply outlives its op, so the identifier
    /// must never be reused by a later service object at the same address: that would let the
    /// stale owed reply swallow the new service's real reply.
    private var keyedServices: [ObjectIdentifier: CBService] = [:]
    private var isTerminated = false

    /// Queue only (created by the central in `didConnect`).
    init(peripheral: CBPeripheral, manager: CBCentralManager, queue: DispatchQueue,
         now: @escaping @Sendable () -> Date, onTerminate: @escaping (CoreBluetoothLink) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.peripheral = peripheral
        self.manager = manager
        self.queue = queue
        self.now = now
        self.onTerminate = onTerminate
        self.ops = CoreBluetoothOperations(queue: queue)
        self.peripheralID = BluetoothPeripheralID(rawValue: peripheral.identifier.uuidString)
        (events, sink) = AsyncStream.makeStream(of: LinkEvent.self, bufferingPolicy: .unbounded)
        super.init()
    }

    /// Queue only. Fails everything in flight, reports `.disconnected(error)` once and finishes
    /// `events`. Idempotent: a link terminates at most once.
    func handleDisconnect(_ error: BluetoothTransportError?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isTerminated else { return }
        isTerminated = true
        while ops.isAwaiting(.disconnect) {
            ops.finishOldest(.disconnect, .success(()))
        }
        ops.failAll(where: { _ in true }, error ?? BluetoothTransportError.disconnected(code: nil))
        characteristics.removeAll()
        notifying.removeAll()
        keyedServices.removeAll() // failAll above dropped every owed reply
        hasDiscovered = false
        if peripheral.delegate === self {
            peripheral.delegate = nil
        }
        sink.yield(.disconnected(error))
        sink.finish()
        onTerminate(self)
    }

    // MARK: BluetoothLink

    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        try await ensureDiscovered(refresh: refresh, deadline: ContinuousClock.now + timeout)
        let found = try await ops.runThrowing { [self] in
            try requireConnected()
            return wanted.filter { characteristics[$0] != nil }
        }
        try Task.checkCancellation() // also on the cached path, which sends nothing
        return found
    }

    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data {
        try await ops.perform(.read(characteristic), timeout: timeout, precheck: requireConnectedCheck) { [self] in
            // Values longer than MTU-1 are fetched by the system with Read Blob.
            peripheral.readValue(for: try resolve(characteristic))
        }
    }

    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        guard withResponse else {
            // Upstream never writes without response (SPEC §3.1); kept for seam completeness.
            // A dead link is reported as dead, cancelled or not.
            try await ops.runThrowing { [self] in try requireConnected() }
            try Task.checkCancellation()
            try await ops.runThrowing { [self] in
                let resolved = try resolve(characteristic)
                let max = peripheral.maximumWriteValueLength(for: .withoutResponse)
                guard data.count <= max else { throw BluetoothTransportError.valueTooLong(data.count, max: max) }
                peripheral.writeValue(data, for: resolved, type: .withoutResponse)
            }
            return
        }
        let _: Void = try await ops.perform(.write(characteristic), timeout: timeout, precheck: requireConnectedCheck) { [self] in
            let resolved = try resolve(characteristic)
            // Never truncate: the system carries values above MTU-3 as a long write, up to this limit.
            let max = peripheral.maximumWriteValueLength(for: .withResponse)
            guard data.count <= max else { throw BluetoothTransportError.valueTooLong(data.count, max: max) }
            peripheral.writeValue(data, for: resolved, type: .withResponse)
        }
    }

    func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws {
        do {
            let _: Void = try await ops.perform(.notify(characteristic), timeout: timeout, precheck: requireConnectedCheck) { [self] in
                let resolved = try resolve(characteristic)
                // Route BEFORE enabling: the machine replays its last notification on subscribe
                // (`_bluetooth.py:429-431`), possibly before the CCCD write is acknowledged.
                notifying.insert(characteristic)
                peripheral.setNotifyValue(true, for: resolved)
            }
        } catch {
            await ops.run { [self] in _ = notifying.remove(characteristic) }
            throw error
        }
    }

    func unsubscribe(_ characteristic: GATTUUID) async {
        await ops.run { [self] in
            notifying.remove(characteristic)
            // Best effort, like upstream's `suppress(Exception)` (`_bluetooth.py:399-400`). The
            // acknowledgement is not awaited, so record it as owed: it must never resolve a
            // later subscribe. Only sent while the CCCD is enabled, so a reply is really owed.
            guard !isTerminated, let resolved = characteristics[characteristic], resolved.isNotifying else { return }
            ops.owe(.notify(characteristic))
            peripheral.setNotifyValue(false, for: resolved)
        }
    }

    func disconnect() async {
        // Not cancellable: teardown runs on cancellation paths too, and must still reach CoreBluetooth.
        let _: Void? = try? await ops.performOrSatisfy(
            .disconnect, timeout: Self.disconnectTimeout, cancellable: false,
            // No didDisconnectPeripheral within 5 s: treat the link as gone.
            onAbandon: { [self] in handleDisconnect(nil) }
        ) { [self] in
            // Already gone: finish this op by its own token (not via finishOldest).
            if isTerminated { return .satisfied(()) }
            manager.cancelPeripheralConnection(peripheral)
            return .issued
        }
    }

    func attMTU() async -> Int? {
        await ops.run { [self] in
            // bleak's MTU: maximumWriteValueLength(.withoutResponse) + 3 (`B-CL:176-187`).
            isTerminated ? nil : peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
        }
    }

    func gattTable(timeout: Duration) async throws -> [BluetoothGATTService] {
        try await ensureDiscovered(refresh: false, deadline: ContinuousClock.now + timeout)
        let table = try await ops.runThrowing { [self] in
            try requireConnected()
            return (peripheral.services ?? []).map { service in
                BluetoothGATTService(
                    uuid: service.uuid.gattUUID.string,
                    characteristics: (service.characteristics ?? []).map { characteristic in
                        BluetoothGATTCharacteristic(uuid: characteristic.uuid.gattUUID.string,
                                                    properties: Self.propertyNames(characteristic.properties))
                    })
            }
        }
        try Task.checkCancellation()
        return table
    }

    // MARK: CBPeripheralDelegate (always on the queue)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        ops.finishOldest(.discoverServices, Self.result(error))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Only a service that is still current feeds the table (not one invalidated meanwhile).
        if error == nil, !isTerminated, peripheral.services?.contains(where: { $0 === service }) == true {
            for characteristic in service.characteristics ?? [] {
                characteristics[characteristic.uuid.gattUUID] = characteristic
            }
        }
        ops.finishOldest(.discoverCharacteristics(ObjectIdentifier(service), service: service.uuid.gattUUID),
                         Self.result(error))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isTerminated else { return }
        characteristics.removeAll()
        hasDiscovered = false
        discoveryGeneration &+= 1
        sink.yield(.servicesInvalidated)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Stamp first, inside the callback: actor hops must not skew brewing-start maths.
        let receivedAt = now()
        let uuid = characteristic.uuid.gattUUID
        let value = characteristic.value ?? Data()
        // One callback serves reads AND notifications. A pending (or owed) read wins; the
        // client never reads a characteristic it is subscribed to.
        if ops.isAwaiting(.read(uuid)) {
            ops.finishOldest(.read(uuid), error.map { .failure(Self.gattError($0)) } ?? .success(value))
        } else if error == nil, notifying.contains(uuid) {
            sink.yield(.notification(uuid, GATTNotification(value: value, receivedAt: receivedAt)))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        ops.finishOldest(.write(characteristic.uuid.gattUUID), Self.result(error))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        ops.finishOldest(.notify(characteristic.uuid.gattUUID), Self.result(error))
    }

    // MARK: Private

    private enum LinkOperation: CoreBluetoothOperationKey {
        case discoverServices
        case discoverCharacteristics(ObjectIdentifier, service: GATTUUID)
        case read(GATTUUID)
        case write(GATTUUID)
        case notify(GATTUUID)
        case disconnect

        var isGATTRequest: Bool {
            switch self {
            case .discoverServices, .discoverCharacteristics, .read, .write, .notify: true
            case .disconnect: false
            }
        }

        var description: String {
            switch self {
            case .discoverServices: "discover services"
            case .discoverCharacteristics(_, let service): "discover characteristics \(service)"
            case .read(let uuid): "read \(uuid)"
            case .write(let uuid): "write \(uuid)"
            case .notify(let uuid): "subscribe \(uuid)"
            case .disconnect: "disconnect"
            }
        }
    }

    /// A discovered service, identified without letting the `CBService` leave the queue.
    private struct ServiceHandle: Sendable {
        let id: ObjectIdentifier
        let uuid: GATTUUID
    }

    private func requireConnected() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if isTerminated { throw BluetoothTransportError.notConnected }
    }

    /// `requireConnected` as a `perform` precheck.
    private var requireConnectedCheck: @Sendable () throws -> Void {
        { [self] in try requireConnected() }
    }

    private func resolve(_ uuid: GATTUUID) throws -> CBCharacteristic {
        try requireConnected()
        guard let characteristic = characteristics[uuid] else {
            throw BluetoothTransportError.characteristicNotFound(uuid)
        }
        return characteristic
    }

    /// Runs service + characteristic discovery unless a complete table is cached and `refresh`
    /// is false: `discoverServices(nil)`, then `discoverCharacteristics(nil, for:)` on EVERY
    /// service. Characteristics are matched by UUID across services; the legacy service
    /// `d30a…` is never assumed (SPEC §3.1). Each step gets what is left of one overall deadline.
    private func ensureDiscovered(refresh: Bool, deadline: ContinuousClock.Instant) async throws {
        let needed = try await ops.runThrowing { [self] in
            try requireConnected()
            return refresh || !hasDiscovered
        }
        guard needed else { return }
        let servicesStep = LinkOperation.discoverServices
        let _: Void = try await ops.perform(servicesStep,
                                            timeout: try remaining(until: deadline, servicesStep.description),
                                            precheck: requireConnectedCheck) { [self] in
            try requireConnected()
            characteristics.removeAll()
            hasDiscovered = false
            discoveryGeneration &+= 1
            peripheral.discoverServices(nil)
        }
        let (started, services): (UInt64, [ServiceHandle]) = try await ops.runThrowing { [self] in
            try requireConnected()
            let current = peripheral.services ?? []
            for service in current {
                keyedServices[ObjectIdentifier(service)] = service
            }
            let handles = current.map {
                ServiceHandle(id: ObjectIdentifier($0), uuid: $0.uuid.gattUUID)
            }
            return (discoveryGeneration, handles)
        }
        for service in services {
            let key = LinkOperation.discoverCharacteristics(service.id, service: service.uuid)
            let _: Void = try await ops.performOrSatisfy(key, timeout: try remaining(until: deadline, key.description),
                                                         precheck: requireConnectedCheck) { [self] in
                try requireConnected()
                guard let current = peripheral.services?.first(where: { ObjectIdentifier($0) == service.id }) else {
                    // Invalidated since the service discovery: nothing to ask for. Finished by this
                    // op's own token — finishOldest would first swallow a reply still owed by an
                    // earlier, timed-out discovery of this service and leave this op hanging.
                    return .satisfied(())
                }
                peripheral.discoverCharacteristics(nil, for: current)
                return .issued
            }
        }
        try await ops.runThrowing { [self] in
            try requireConnected()
            if discoveryGeneration == started {
                hasDiscovered = true
            }
        }
    }

    private func remaining(until deadline: ContinuousClock.Instant, _ operation: String) throws -> Duration {
        let left = deadline - .now
        guard left > .zero else { throw BluetoothTransportError.timedOut(operation) }
        return left
    }

    private static func result(_ error: (any Error)?) -> Result<any Sendable, any Error> {
        error.map { .failure(gattError($0)) } ?? .success(())
    }

    /// A delegate-callback error: a dropped link as `.disconnected(code:)`, anything else from
    /// `CBErrorDomain` / `CBATTErrorDomain` as `.gatt(domain:code:)`.
    private static func gattError(_ error: any Error) -> BluetoothTransportError {
        let nsError = error as NSError
        if nsError.domain == CBErrorDomain,
           nsError.code == CBError.Code.peripheralDisconnected.rawValue
            || nsError.code == CBError.Code.notConnected.rawValue {
            return .disconnected(code: nsError.code)
        }
        return .gatt(domain: nsError.domain, code: nsError.code)
    }

    /// The SPEC §6.2 property names, in its order.
    private static func propertyNames(_ properties: CBCharacteristicProperties) -> [String] {
        let names: [(CBCharacteristicProperties, String)] = [
            (.broadcast, "broadcast"),
            (.read, "read"),
            (.writeWithoutResponse, "writeWithoutResponse"),
            (.write, "write"),
            (.notify, "notify"),
            (.indicate, "indicate"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"),
            (.extendedProperties, "extendedProperties"),
            (.notifyEncryptionRequired, "notifyEncryptionRequired"),
            (.indicateEncryptionRequired, "indicateEncryptionRequired"),
        ]
        return names.filter { properties.contains($0.0) }.map(\.1)
    }
}

// MARK: - UUID normalisation (SPEC §6.2)

extension CBUUID {
    /// This UUID as a `GATTUUID`: lowercase and always the full 128-bit form. Every place the
    /// adapter turns a `CBUUID` into a string or a `GATTUUID` goes through here, because
    /// `uuidString` is the short form for 16- and 32-bit SIG UUIDs ("180A", not
    /// "0000180A-0000-1000-8000-00805F9B34FB").
    fileprivate var gattUUID: GATTUUID {
        GATTUUID(fullGATTUUIDString(uuidString))
    }
}

/// Pure: expands a 4- or 8-hex-digit (16-/32-bit SIG) UUID string with the Bluetooth base UUID
/// (`0000xxxx-0000-1000-8000-00805f9b34fb` / `xxxxxxxx-0000-1000-8000-00805f9b34fb`) and
/// lowercases the result. Any other string (already 128-bit) is only lowercased.
private func fullGATTUUIDString(_ string: String) -> String {
    let lower = string.lowercased()
    // ASCII only (`Character.isHexDigit` also accepts fullwidth forms).
    guard lower.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
        return lower
    }
    switch lower.count {
    case 4: return "0000\(lower)-0000-1000-8000-00805f9b34fb"
    case 8: return "\(lower)-0000-1000-8000-00805f9b34fb"
    default: return lower
    }
}
#endif
