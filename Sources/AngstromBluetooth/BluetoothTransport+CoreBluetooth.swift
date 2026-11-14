import Angstrom

extension BluetoothTransport {
    /// A CoreBluetooth-backed transport. Allocates its CBCentralManager lazily on first use.
    /// Create once per process and share. `showPowerAlert` maps to CBCentralManagerOptionShowPowerAlertKey.
    public static func coreBluetooth(showPowerAlert: Bool = false) -> BluetoothTransport {
        fatalError("unimplemented: BT-W1-08")
    }
}

extension BluetoothAuthorization {
    /// `CBManager.authorization` (class property; allocates no manager, so it never prompts).
    public static var current: BluetoothAuthorization {
        fatalError("unimplemented: BT-W1-08")
    }
}
