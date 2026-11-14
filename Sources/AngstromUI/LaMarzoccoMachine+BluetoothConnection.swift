import Angstrom

extension LaMarzoccoMachine {
    /// The Bluetooth client's connection events (upstream `register_bluetooth_connection_callback`).
    public func bluetoothConnectionEvents() async -> AsyncStream<ConnectionEvent> {
        fatalError("unimplemented: BT-W3-06")
    }

    /// Mirror the Bluetooth client's connection events into ``isBluetoothConnected``.
    /// Called from `init` when `bluetooth != nil`.
    ///
    /// Inert until its owner lands (PLAN §3.0: no-op) — unimplemented: BT-W3-06
    func startObservingBluetoothConnection() {}
}
