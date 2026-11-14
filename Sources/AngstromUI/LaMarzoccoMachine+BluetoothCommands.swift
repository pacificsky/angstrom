import Angstrom

extension LaMarzoccoMachine {
    /// BLE-first command with cloud fallback (SPEC §4.16, upstream `MACH:983-1049`).
    ///
    /// Runs inside the calling method's `capturing { … }`, after gating. Without a
    /// Bluetooth client it goes straight to the cloud, and throws
    /// `.cloudOnlyFunctionality` when there is no cloud client either.
    func bluetoothFirst(
        bluetooth bluetoothOperation: (LaMarzoccoBluetoothClient) async throws -> BluetoothCommandStatus,
        cloud cloudOperation: (LaMarzoccoCloudClient) async throws -> CommandResponse
    ) async throws -> CommandResponse {
        guard bluetooth == nil else {
            fatalError("unimplemented: BT-W3-07")
        }
        guard let cloud = cloudClient else { throw LaMarzoccoError.cloudOnlyFunctionality }
        return try await cloudOperation(cloud)
    }
}
