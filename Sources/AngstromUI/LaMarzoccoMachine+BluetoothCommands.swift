import Angstrom
import os

extension LaMarzoccoMachine {
    /// BLE-first command with cloud fallback (SPEC §4.16, upstream `MACH:983-1049`).
    ///
    /// Runs inside the calling method's `capturing { … }`, after gating.
    ///
    /// - With a Bluetooth client, the Bluetooth operation is **always** tried first (no
    ///   `isBluetoothConnected` check: the client connects lazily, `MACH:1013`). A success status
    ///   (`status.lowercased() == "success"`) returns a synthesized
    ///   `CommandResponse(id: status.id, status: .success, errorCode: nil)` (D18).
    /// - A non-success status throws nothing on the Bluetooth side and falls through to the cloud
    ///   (G-DEV-1); without a cloud client it throws `.commandFailed(status:errorCode:)` with the
    ///   status and message (D18; upstream returns `False`).
    /// - Only a Bluetooth connection failure (`isBluetoothConnectionFailure`: connection failed,
    ///   authentication failed, Bluetooth unavailable — upstream's `except (BleakError,
    ///   BluetoothConnectionFailed)`) falls back to the cloud; without a cloud client it is rethrown
    ///   (D18). Every other error (`.bluetoothTimedOut`, `.decoding`, `CancellationError`, …)
    ///   propagates with no cloud call (parity, `MACH:1025`; D19).
    /// - Without a Bluetooth client it goes straight to the cloud, and throws
    ///   `.cloudOnlyFunctionality` when there is no cloud client either. Cloud errors propagate.
    func bluetoothFirst(
        bluetooth bluetoothOperation: (LaMarzoccoBluetoothClient) async throws -> BluetoothCommandStatus,
        cloud cloudOperation: (LaMarzoccoCloudClient) async throws -> CommandResponse
    ) async throws -> CommandResponse {
        if let bluetooth {
            do {
                let status = try await bluetoothOperation(bluetooth)
                if status.isSuccess {
                    return CommandResponse(id: status.id, status: .success, errorCode: nil)
                }
                // A non-success status is not an error on the Bluetooth side: fall through to the cloud.
                guard cloudClient != nil else {
                    throw LaMarzoccoError.commandFailed(status: status.status, errorCode: status.message)
                }
                bluetoothCommandLog.debug("Bluetooth command returned non-success status; trying the cloud")
            } catch let error as LaMarzoccoError where error.isBluetoothConnectionFailure {
                let message = "Could not send command to bluetooth device, even though initalized."
                guard cloudClient != nil else {
                    bluetoothCommandLog.error(
                        "\(message, privacy: .public) Cloud client not initialized, cannot fallback. Full error \(String(describing: error))")
                    throw error
                }
                bluetoothCommandLog.warning("\(message, privacy: .public) Falling back to cloud")
                bluetoothCommandLog.debug("Full error: \(String(describing: error))")
            }
        }
        guard let cloud = cloudClient else { throw LaMarzoccoError.cloudOnlyFunctionality }
        return try await cloudOperation(cloud)
    }
}

/// Informative log lines only (SPEC §2.1: not contract, never the token — no Bluetooth error
/// carries it). Error details use the default (private) privacy level.
private let bluetoothCommandLog = Logger(subsystem: "Angstrom", category: "LaMarzoccoMachine.Bluetooth")
