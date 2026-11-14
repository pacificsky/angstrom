import Angstrom

extension LaMarzoccoMachine {
    /// Build the dashboard from Bluetooth reads (SPEC §4.17, upstream `get_dashboard_from_bluetooth`).
    @discardableResult
    public func refreshDashboardFromBluetooth() async throws -> Dashboard {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W3-08")
    }

    /// Resolve the model from the machine's Bluetooth capabilities (upstream `get_model_info_from_bluetooth`).
    @discardableResult
    public func refreshModelFromBluetooth() async throws -> BluetoothMachineCapabilities {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W3-08")
    }
}
