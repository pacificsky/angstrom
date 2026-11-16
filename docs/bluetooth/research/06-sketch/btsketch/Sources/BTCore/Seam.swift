import Foundation

// MARK: - The seam. Nothing in this file imports CoreBluetooth.
//
// Access levels: types a consumer must hold or persist are `public`; the transport
// protocols are `package`, so the CoreBluetooth adapter target (same package) can
// implement them and tests can fake them, but they are NOT public API — the same
// stance as the internal `WebSocketChannel` seam in Angstrom today.

/// Opaque, persistable identity of a peripheral. On Apple platforms this is the
/// `CBPeer.identifier` UUID (per Apple device + app install), NOT a MAC address.
public struct BluetoothPeripheralID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// A 128-bit GATT UUID, normalised to lowercase so the seam never needs `CBUUID`.
package struct GATTUUID: Hashable, Sendable, CustomStringConvertible {
    package let string: String
    package init(_ string: String) { self.string = string.lowercased() }
    package var description: String { string }
}

/// Mirror of `CBManagerAuthorization` (CBManager.h:62-67).
public enum BluetoothAuthorization: Sendable, Hashable {
    case notDetermined, restricted, denied, allowedAlways
}

/// Mirror of `CBManagerState` (CBManager.h:32-39), carrying the authorization when unauthorized.
public enum BluetoothAvailability: Sendable, Hashable {
    case unknown, resetting, unsupported, unauthorized(BluetoothAuthorization), poweredOff, poweredOn
}

public struct DiscoveredPeripheral: Sendable, Hashable {
    public let id: BluetoothPeripheralID
    /// `CBPeripheral.name` (what bleak's `BLEDevice.name` is on macOS), else the
    /// advertised local name.
    public let name: String?
    public let rssi: Int?
    package init(id: BluetoothPeripheralID, name: String?, rssi: Int?) {
        self.id = id; self.name = name; self.rssi = rssi
    }
}

/// A notification, timestamped where it entered the process (the delegate callback),
/// mirroring upstream's `received_at = _utcnow()` taken first (_bluetooth.py:445).
package struct GATTNotification: Sendable, Hashable {
    package let value: Data
    package let receivedAt: Date
    package init(value: Data, receivedAt: Date) { self.value = value; self.receivedAt = receivedAt }
}

package enum BluetoothTransportError: Error, Sendable, Equatable {
    case unavailable(BluetoothAvailability)
    case unknownPeripheral(BluetoothPeripheralID)
    case timedOut(String)
    case notConnected
    case characteristicNotFound(GATTUUID)
    case valueTooLong(Int, max: Int)
    /// Link dropped; `code` is the `CBError` code when CoreBluetooth gave one.
    case disconnected(code: Int?)
    /// A GATT/ATT/CB error from a callback (`CBErrorDomain` / `CBATTErrorDomain`).
    case gatt(domain: String, code: Int)
}

/// Everything a link reports, on ONE ordered stream, so a consumer can never see a
/// disconnect overtake the notifications that preceded it.
package enum LinkEvent: Sendable, Equatable {
    case notification(GATTUUID, GATTNotification)
    /// `peripheral(_:didModifyServices:)` — cached characteristic handles are stale.
    case servicesInvalidated
    /// Terminal. The stream finishes right after this event.
    case disconnected(BluetoothTransportError?)
}

/// Central-role entry point (`BleakScanner` + `establish_connection` analogue).
package protocol BluetoothCentral: Sendable {
    func availability() async -> BluetoothAvailability
    /// Foreground scan for `duration`, returning every peripheral seen (de-duplicated).
    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral]
    /// One connection attempt with our own timeout (CoreBluetooth connects never time
    /// out, CBCentralManager.h:201). Retries are protocol logic, above the seam.
    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink
}

/// One live connection (`BleakClient` analogue). A new object per connection, so
/// stale events from an old link can be ignored by identity (upstream:
/// `if client is not self._client: return`, _bluetooth.py:469).
package protocol BluetoothLink: AnyObject, Sendable {
    var peripheralID: BluetoothPeripheralID { get }
    /// Ordered lifecycle + notification events; finishes after `.disconnected`.
    var events: AsyncStream<LinkEvent> { get }
    /// Discover services/characteristics; returns which of `wanted` exist.
    /// `refresh: true` re-runs discovery (bleak `clear_cache` analogue).
    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID>
    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data
    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws
    /// Enable notifications; values then arrive as `.notification` on `events`.
    func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws
    /// Best effort, never throws (upstream wraps stop_notify in suppress(), :399-400).
    func unsubscribe(_ characteristic: GATTUUID) async
    func disconnect() async
}

/// Tagged sleeps, so tests can see and fire individual timers (upstream patches
/// AUTH_READ_INTERVAL / RECONNECT_INITIAL_DELAY to 0 and fakes the idle timer).
package enum SleepPurpose: Sendable, Hashable { case authPoll, connectBackoff, idleDisconnect, reconnectBackoff }
package protocol BluetoothSleeper: Sendable {
    func sleep(for duration: Duration, purpose: SleepPurpose) async throws
}
package struct RealSleeper: BluetoothSleeper {
    package init() {}
    package func sleep(for duration: Duration, purpose: SleepPurpose) async throws {
        try await Task.sleep(for: duration)
    }
}

/// The public, opaque handle a consumer passes in. Built by the CoreBluetooth
/// adapter module (`.coreBluetooth()`), or from a fake in tests.
public struct BluetoothTransport: Sendable {
    package let central: any BluetoothCentral
    package let sleeper: any BluetoothSleeper
    package let now: @Sendable () -> Date
    package init(central: any BluetoothCentral,
                 sleeper: any BluetoothSleeper = RealSleeper(),
                 now: @escaping @Sendable () -> Date = { Date() }) {
        self.central = central; self.sleeper = sleeper; self.now = now
    }
}
