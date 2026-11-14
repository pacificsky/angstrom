import Foundation

extension LaMarzoccoBluetoothClient {
    // MARK: Discovery & pairing (static; no instance state)

    /// Every peripheral seen, unfiltered (diagnostic; §4.14). `discoverMachines` = this, filtered.
    public static func scanAll(transport: BluetoothTransport,
                               duration: Duration = .seconds(5)) async throws -> [DiscoveredPeripheral] {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-10")
    }

    /// Peripherals whose name starts with one of ``machineNamePrefixes`` (§4.14).
    public static func discoverMachines(transport: BluetoothTransport,
                                        duration: Duration = .seconds(5)) async throws -> [DiscoveredPeripheral] {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-10")
    }

    /// Reads the token from a machine in pairing mode (§4.14).
    public static func readToken(transport: BluetoothTransport,
                                 peripheral: BluetoothPeripheralID) async throws -> BluetoothAuthToken {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-10")
    }

    /// Full GATT table of a peripheral (diagnostic; §4.14).
    public static func gattTable(transport: BluetoothTransport,
                                 peripheral: BluetoothPeripheralID) async throws -> [BluetoothGATTService] {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-10")
    }
}
