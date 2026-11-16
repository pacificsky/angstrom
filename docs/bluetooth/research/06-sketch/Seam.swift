import Foundation

// MARK: - The seam: everything above this line is CoreBluetooth-free and unit-testable.

/// Opaque, persistable identity of a peripheral. On Apple platforms this is the
/// `CBPeer.identifier` UUID string (NOT a MAC address).
public struct BluetoothPeripheralID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// A 128-bit GATT UUID, kept as a lowercase string so the seam never imports CoreBluetooth.
public struct GATTUUID: Hashable, Sendable, CustomStringConvertible {
    public let string: String
    public init(_ string: String) { self.string = string.lowercased() }
    public var description: String { string }
}

public enum BluetoothAuthorization: Sendable, Hashable { case notDetermined, restricted, denied, allowedAlways }

/// Mirror of `CBManagerState`, plus the authorization when unauthorized.
public enum BluetoothAvailability: Sendable, Hashable {
    case unknown, resetting, unsupported, unauthorized(BluetoothAuthorization), poweredOff, poweredOn
}

public struct DiscoveredPeripheral: Sendable, Hashable {
    public let id: BluetoothPeripheralID
    /// Advertised local name if present, else the GAP name CoreBluetooth reports.
    public let name: String?
    public let rssi: Int?
}

/// A characteristic value notification, timestamped where it entered the process
/// (the delegate callback), so actor hops cannot skew brewing-start maths.
public struct GATTNotification: Sendable, Hashable {
    public let value: Data
    public let receivedAt: Date
}

public enum BluetoothTransportError: Error, Sendable, Equatable {
    case unavailable(BluetoothAvailability)
    case unknownPeripheral(BluetoothPeripheralID)
    case timedOut(String)
    case notConnected
    case characteristicNotFound(GATTUUID)
    case valueTooLong(Int, max: Int)
    /// Link dropped; `code` is the CBError code when CoreBluetooth gave one.
    case disconnected(code: Int?)
    /// A GATT/ATT/CB error from a callback (`CBErrorDomain` / `CBATTErrorDomain`).
    case gatt(domain: String, code: Int)
    case cancelled
}

public enum LinkEvent: Sendable, Equatable {
    case disconnected(BluetoothTransportError?)
    /// `peripheral(_:didModifyServices:)` — cached characteristic handles are stale.
    case servicesInvalidated
}

/// Central-role entry point (CBCentralManager analogue).
public protocol BluetoothCentral: Sendable {
    func availability() async -> BluetoothAvailability
    /// Foreground scan for `duration`, returning every peripheral seen (de-duplicated).
    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral]
    /// Connect (with our own timeout — CoreBluetooth connects never time out).
    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink
}

/// One live connection (BleakClient analogue). A new object per connection, so
/// stale callbacks from an old link can be ignored by identity (upstream:
/// `if client is not self._client: return`).
public protocol BluetoothLink: AnyObject, Sendable {
    var peripheralID: BluetoothPeripheralID { get }
    /// Lifecycle events; finishes after `.disconnected`.
    var events: AsyncStream<LinkEvent> { get }
    /// Discover services/characteristics; returns which of `wanted` exist.
    /// `refresh: true` re-runs discovery even if a table is cached (bleak `clear_cache` analogue).
    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID>
    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data
    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws
    /// Enable notifications; the stream finishes on unsubscribe or disconnect.
    func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws -> AsyncStream<GATTNotification>
    func unsubscribe(_ characteristic: GATTUUID) async
    func disconnect() async
}

/// Tagged sleeps, so tests can fire one timer (e.g. the idle timer) on demand —
/// the Swift analogue of upstream's `IdleTimer` fixture.
public enum SleepPurpose: Sendable, Hashable { case authPoll, idleDisconnect, reconnectBackoff }
public protocol BluetoothSleeper: Sendable {
    func sleep(for duration: Duration, purpose: SleepPurpose) async throws
}
public struct RealSleeper: BluetoothSleeper {
    public init() {}
    public func sleep(for duration: Duration, purpose: SleepPurpose) async throws {
        try await Task.sleep(for: duration)
    }
}
