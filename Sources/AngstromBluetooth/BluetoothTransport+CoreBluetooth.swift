#if canImport(CoreBluetooth)
import Angstrom
import CoreBluetooth
import Foundation

extension BluetoothTransport {
    /// A CoreBluetooth-backed transport. Allocates its CBCentralManager lazily on first use.
    /// Create once per process and share. `showPowerAlert` maps to CBCentralManagerOptionShowPowerAlertKey.
    ///
    /// Creating the transport touches no Bluetooth API: the `CBCentralManager` — and with it
    /// the system permission prompt — is created by the first Bluetooth operation, so a process
    /// that never uses Bluetooth never prompts. Each call creates an independent central with
    /// its own manager. The transport's clock (`Date()`) is the one the adapter stamps
    /// notifications with.
    public static func coreBluetooth(showPowerAlert: Bool = false) -> BluetoothTransport {
        let now: @Sendable () -> Date = { Date() }
        return BluetoothTransport(central: CoreBluetoothCentral(showPowerAlert: showPowerAlert, now: now),
                                  sleeper: RealSleeper(),
                                  now: now)
    }
}

extension BluetoothAuthorization {
    /// `CBManager.authorization` (class property; allocates no manager, so it never prompts).
    ///
    /// Use it to gate Bluetooth UI before the first Bluetooth operation. An authorization value
    /// unknown to this version of the library reads as ``denied``.
    public static var current: BluetoothAuthorization {
        switch CBManager.authorization {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .allowedAlways: .allowedAlways
        @unknown default: .denied
        }
    }
}
#endif
