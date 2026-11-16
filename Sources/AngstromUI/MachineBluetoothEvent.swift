import Angstrom

/// Bluetooth events of a `LaMarzoccoMachine` (upstream `update_callback`/`telemetry_callback`).
///
/// Delivered by ``LaMarzoccoMachine/bluetoothEvents()`` after the machine's
/// observable state has been updated.
public enum MachineBluetoothEvent: Sendable, Equatable {
    /// A brewing update was applied to `dashboard` (upstream `update_callback(update)`).
    case brewing(BluetoothShotCounterUpdate)
    /// The BLE brewing state is no longer applied — link lost or 60 s without an update
    /// (upstream `update_callback(None)`). NOT sent on `stopShotCounter()`.
    case brewingCleared
    /// One notification's telemetry, after any machine mode was applied to `dashboard`.
    case telemetry(BluetoothMachineTelemetry)
    /// Angstrom-only: the shot counter stopped for good (reconnect gave up).
    case shotCounterStopped(LaMarzoccoError)
}
