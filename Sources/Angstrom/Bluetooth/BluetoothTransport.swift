import Foundation

/// Persistable identity of a peripheral: the CoreBluetooth `CBPeer.identifier` UUID string.
/// Per Apple device and app; NOT a MAC address; never sync it across devices.
public struct BluetoothPeripheralID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Mirror of `CBManagerAuthorization`.
public enum BluetoothAuthorization: Sendable, Hashable {
    case notDetermined, restricted, denied, allowedAlways
}

/// Mirror of `CBManagerState`, carrying the authorization when unauthorized.
public enum BluetoothAvailability: Sendable, Hashable {
    case unknown, resetting, unsupported, unauthorized(BluetoothAuthorization), poweredOff, poweredOn
}

/// A peripheral seen during a scan.
public struct DiscoveredPeripheral: Sendable, Hashable {
    public let id: BluetoothPeripheralID
    /// `CBPeripheral.name`, else the advertised local name.
    public let name: String?
    /// RSSI in dBm, nil when unavailable.
    public let rssi: Int?
    /// Public so consumers outside the package (angcli, its tests) can build values.
    public init(id: BluetoothPeripheralID, name: String?, rssi: Int?) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

/// Diagnostic GATT table entry (from `LaMarzoccoBluetoothClient.gattTable`).
public struct BluetoothGATTService: Sendable, Hashable {
    /// The service UUID, lowercase.
    public let uuid: String
    public let characteristics: [BluetoothGATTCharacteristic]
    public init(uuid: String, characteristics: [BluetoothGATTCharacteristic]) {
        self.uuid = uuid
        self.characteristics = characteristics
    }
}

/// One characteristic of a ``BluetoothGATTService``.
public struct BluetoothGATTCharacteristic: Sendable, Hashable {
    /// The characteristic UUID, lowercase.
    public let uuid: String
    /// Property names: "broadcast", "read", "writeWithoutResponse", "write", "notify", "indicate",
    /// "authenticatedSignedWrites", "extendedProperties", "notifyEncryptionRequired", "indicateEncryptionRequired".
    public let properties: [String]
    public init(uuid: String, properties: [String]) {
        self.uuid = uuid
        self.properties = properties
    }
}

/// Opaque handle to a Bluetooth stack. Build with `BluetoothTransport.coreBluetooth()` (AngstromBluetooth).
public struct BluetoothTransport: Sendable {
    package let central: any BluetoothCentral
    package let sleeper: any BluetoothSleeper
    package let now: @Sendable () -> Date
    package init(central: any BluetoothCentral,
                 sleeper: any BluetoothSleeper = RealSleeper(),
                 now: @escaping @Sendable () -> Date = { Date() }) {
        self.central = central
        self.sleeper = sleeper
        self.now = now
    }
}

/// A 128-bit GATT UUID normalised to lowercase.
package struct GATTUUID: Hashable, Sendable, CustomStringConvertible {
    package let string: String
    /// Stores `string.lowercased()`, so UUIDs compare case-insensitively.
    package init(_ string: String) { self.string = string.lowercased() }
    package var description: String { string }
}

/// A notification value stamped with the transport clock when it entered the process.
package struct GATTNotification: Sendable, Hashable {
    package let value: Data
    package let receivedAt: Date
    package init(value: Data, receivedAt: Date) {
        self.value = value
        self.receivedAt = receivedAt
    }
}

/// The only errors (besides `CancellationError`) a seam method throws.
package enum BluetoothTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(BluetoothAvailability)
    case unknownPeripheral(BluetoothPeripheralID)
    case timedOut(String)
    case notConnected
    case characteristicNotFound(GATTUUID)
    case valueTooLong(Int, max: Int)
    /// Link dropped; `code` is the `CBError` code when CoreBluetooth gave one.
    case disconnected(code: Int?)
    /// A `CBErrorDomain` / `CBATTErrorDomain` error from a delegate callback.
    case gatt(domain: String, code: Int)

    package var description: String {
        switch self {
        case .unavailable(let availability):
            return "Bluetooth unavailable (\(Self.describe(availability)))"
        case .unknownPeripheral(let id):
            return "unknown peripheral \(id)"
        case .timedOut(let operation):
            return "timed out (\(operation))"
        case .notConnected:
            return "not connected"
        case .characteristicNotFound(let uuid):
            return "characteristic \(uuid) not found"
        case .valueTooLong(let length, let max):
            return "value too long (\(length) bytes, max \(max))"
        case .disconnected(let code):
            return code.map { "disconnected (code \($0))" } ?? "disconnected"
        case .gatt(let domain, let code):
            return "GATT error \(domain) \(code)"
        }
    }

    private static func describe(_ availability: BluetoothAvailability) -> String {
        switch availability {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized(let authorization):
            switch authorization {
            case .notDetermined: return "unauthorized: notDetermined"
            case .restricted: return "unauthorized: restricted"
            case .denied: return "unauthorized: denied"
            case .allowedAlways: return "unauthorized: allowedAlways"
            }
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        }
    }
}

/// Everything one link reports, in order. `.disconnected` is terminal.
package enum LinkEvent: Sendable, Equatable {
    case notification(GATTUUID, GATTNotification)
    case servicesInvalidated
    case disconnected(BluetoothTransportError?)
}

/// A Bluetooth central (adapter). Seam methods throw only ``BluetoothTransportError`` or `CancellationError`.
package protocol BluetoothCentral: Sendable {
    /// Current state (allocates the manager lazily on first call).
    func availability() async -> BluetoothAvailability
    /// Every state change after the call (multicast; finishes never).
    func availabilityUpdates() -> AsyncStream<BluetoothAvailability>
    /// Foreground scan, no service filter; de-duplicated, first-seen order.
    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral]
    /// ONE connection attempt with our own timeout. Returns a NEW link object per connection.
    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink
}

/// One connection to one peripheral. Compared by identity (`===`) to ignore stale events.
package protocol BluetoothLink: AnyObject, Sendable {
    var peripheralID: BluetoothPeripheralID { get }
    /// Single-consumer, ordered, `.unbounded`; finishes after `.disconnected`.
    var events: AsyncStream<LinkEvent> { get }
    /// Which of `wanted` exist. `refresh: true` re-runs service + characteristic discovery.
    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID>
    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data
    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws
    /// Enable notifications; route values to `events` BEFORE the CCCD write is acknowledged.
    func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws
    /// Best effort; never throws.
    func unsubscribe(_ characteristic: GATTUUID) async
    /// Bounded (5 s); never throws; idempotent.
    func disconnect() async
    /// `maximumWriteValueLength(.withoutResponse) + 3`, nil if unknown. Diagnostic only.
    func attMTU() async -> Int?
    /// Full discovery of every service/characteristic with properties. Diagnostic only.
    func gattTable(timeout: Duration) async throws -> [BluetoothGATTService]
}

/// Why the client is sleeping, so tests can fire one timer by hand and count the rest.
package enum SleepPurpose: Sendable, Hashable { case authPoll, connectBackoff, idleDisconnect, reconnectBackoff, poweredOnWait }

/// Every wait of the protocol logic goes through this, never `Task.sleep` directly.
package protocol BluetoothSleeper: Sendable {
    /// Throws `CancellationError` when the calling task is cancelled.
    func sleep(for duration: Duration, purpose: SleepPurpose) async throws
}

/// The production sleeper: `Task.sleep(for:)`.
package struct RealSleeper: BluetoothSleeper {
    package init() {}
    package func sleep(for duration: Duration, purpose: SleepPurpose) async throws {
        try await Task.sleep(for: duration)
    }
}
