import Angstrom

extension LaMarzoccoMachine {
    /// Start the Bluetooth shot counter (upstream `connect_bluetooth_shot_counter`).
    @discardableResult
    public func startShotCounter() async throws -> Bool {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W3-09")
    }

    /// Stop the Bluetooth shot counter (upstream `disconnect_bluetooth_shot_counter`).
    public func stopShotCounter() async {
        fatalError("unimplemented: BT-W3-09")
    }

    /// Brewing and telemetry events, delivered after the machine's state was updated.
    public func bluetoothEvents() -> AsyncStream<MachineBluetoothEvent> {
        fatalError("unimplemented: BT-W3-09")
    }

    /// Apply one event of the Bluetooth client's shot-counter stream.
    func handleShotCounterEvent(_ event: ShotCounterEvent) {
        fatalError("unimplemented: BT-W3-09")
    }

    /// Drop the BLE brewing overlay; emit `.brewingCleared` when `notify` is true.
    func clearBluetoothBrewingState(notify: Bool) {
        fatalError("unimplemented: BT-W3-09")
    }

    /// (Re-)arm the brewing-state expiry (upstream `BLE_BREWING_STATE_TIMEOUT`).
    func armBluetoothBrewingExpiry() {
        fatalError("unimplemented: BT-W3-09")
    }

    /// Test seam: replace the brewing-state timeout and the sleep the expiry waits on.
    func setBluetoothBrewingExpiryForTesting(timeout: Duration,
                                             sleep: @escaping @Sendable (Duration) async throws -> Void) {
        bluetoothBrewingStateTimeout = timeout
        brewingExpirySleep = sleep
    }
}
