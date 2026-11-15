import Angstrom

extension LaMarzoccoMachine {
    /// The Bluetooth client's connection events (upstream `register_bluetooth_connection_callback`,
    /// `devices/_thing.py:116-126`; a stream instead of a callback, D4).
    ///
    /// With a Bluetooth client this is a new, independent registration on
    /// `LaMarzoccoBluetoothClient.connectionEvents()`: `.connected` once a link is authenticated (D11),
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
    /// Starts ``bluetoothConnectionTask``: a MainActor task that captures neither the client nor the
    /// machine strongly (SPEC §5.5). Through ``beginBluetoothConnectionObservation()``, which reaches the
    /// client via the machine only for that one call, it registers on the client's `connectionEvents()`,
    /// then seeds ``isBluetoothConnected`` from the client's `isConnected` (read *after* registering, so
    /// a transition between the two is still delivered by the stream and none is lost). From then on it
    /// holds only the stream and a weak machine, setting the property to `true` on `.connected` and
    /// `false` on `.disconnected`.
    ///
    /// Releasing the machine and the client therefore releases both, even while the client has no link.
    /// Once the machine is gone the task ends at the next event (unregistering its stream) or when the
    /// client finishes the stream; a machine released before the task first runs makes it end at once.
    func startObservingBluetoothConnection() {
        guard bluetooth != nil, bluetoothConnectionTask == nil else { return }
        bluetoothConnectionTask = Task { @MainActor [weak self] in
            // The strong machine (and through it the client) lives only for this call.
            guard let events = await self?.beginBluetoothConnectionObservation() else { return }
            for await event in events {
                // Bind `self` only per event, so the suspended task never keeps the machine alive.
                guard let self else { return }
                switch event {
                case .connected: self.setBluetoothConnected(true)
                case .disconnected: self.setBluetoothConnected(false)
                }
            }
        }
    }

    /// Register on the client's connection events and seed ``isBluetoothConnected`` from its `isConnected`,
    /// in that order. Returns the stream, or `nil` without a Bluetooth client. The client is reached only
    /// through this call's locals, so the long-lived observation task never captures it.
    private func beginBluetoothConnectionObservation() async -> AsyncStream<ConnectionEvent>? {
        guard let bluetooth else { return nil }
        let events = await bluetooth.connectionEvents()
        setBluetoothConnected(await bluetooth.isConnected)
        return events
    }

    /// Write ``isBluetoothConnected`` only on a change, so observers see transitions, not repeats.
    private func setBluetoothConnected(_ connected: Bool) {
        if isBluetoothConnected != connected {
            isBluetoothConnected = connected
        }
    }
}
