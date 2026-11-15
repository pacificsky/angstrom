import Angstrom

extension LaMarzoccoMachine {
    /// The Bluetooth client's connection events (upstream `register_bluetooth_connection_callback`,
    /// `devices/_thing.py:116-126`; a stream instead of a callback, D4).
    ///
    /// With a Bluetooth client this is a new, independent registration on
    /// ``LaMarzoccoBluetoothClient/connectionEvents()``: `.connected` once a link is authenticated (D11),
    /// `.disconnected` when it closes. Cancel its iteration to unregister. Without a Bluetooth client the
    /// stream is already finished (upstream returns a no-op unregister).
    public func bluetoothConnectionEvents() async -> AsyncStream<ConnectionEvent> {
        guard let bluetooth else {
            let (stream, continuation) = AsyncStream<ConnectionEvent>.makeStream()
            continuation.finish()
            return stream
        }
        return await bluetooth.connectionEvents()
    }

    /// Mirror the Bluetooth client's connection events into ``isBluetoothConnected``.
    /// Called from `init` when `bluetooth != nil`.
    ///
    /// Starts ``bluetoothConnectionTask``: a MainActor task holding the machine weakly. It registers on the
    /// client's `connectionEvents()`, then seeds ``isBluetoothConnected`` from the client's `isConnected`
    /// (read *after* registering, so a transition between the two is still delivered by the stream and
    /// none is lost), then sets it to `true` on `.connected` and `false` on `.disconnected`. Once the
    /// machine is deallocated the task ends at the next event, which also unregisters its stream.
    func startObservingBluetoothConnection() {
        guard let bluetooth, bluetoothConnectionTask == nil else { return }
        bluetoothConnectionTask = Task { @MainActor [weak self] in
            let events = await bluetooth.connectionEvents()
            let connected = await bluetooth.isConnected
            // Bind `self` only per step, so the suspended task never keeps the machine alive.
            if let self {
                self.setBluetoothConnected(connected)
            } else {
                return
            }
            for await event in events {
                guard let self else { return }
                switch event {
                case .connected: self.setBluetoothConnected(true)
                case .disconnected: self.setBluetoothConnected(false)
                }
            }
        }
    }

    /// Write ``isBluetoothConnected`` only on a change, so observers see transitions, not repeats.
    private func setBluetoothConnected(_ connected: Bool) {
        if isBluetoothConnected != connected {
            isBluetoothConnected = connected
        }
    }
}
