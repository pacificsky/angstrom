import Foundation
import Angstrom

extension LaMarzoccoMachine {
    /// Start the Bluetooth shot counter (upstream `connect_bluetooth_shot_counter`).
    ///
    /// Keeps a persistent Bluetooth connection and overlays the brewing state the machine reports on
    /// the `CMMachineStatus` widget of ``dashboard``; live values land in ``bluetoothTelemetry`` and a
    /// reported machine mode is applied to the dashboard. Events are delivered on
    /// ``bluetoothEvents()`` after the state was updated.
    ///
    /// Not gated on the dashboard's `shotCounterSupported` flag or on the model.
    ///
    /// - Returns: `false` without a Bluetooth client, or when the machine has no shot counter.
    /// - Throws: the Bluetooth client's connect/authentication errors.
    @discardableResult
    public func startShotCounter() async throws -> Bool {
        guard let bluetooth else { return false }
        let listener: Task<Void, Never>
        if let running = shotCounterTask {
            listener = running
        } else {
            // Subscribe BEFORE starting, so the `.subscribed` of this start is not missed.
            let events = await bluetooth.shotCounterEvents()
            if let running = shotCounterTask {
                // An overlapping start installed its listener while this one was suspended (MainActor
                // reentrancy): reuse it. Dropping `events` terminates it, which unregisters it from
                // the client, so every event is handled once and a stop silences the only listener.
                listener = running
            } else {
                listener = Task { [weak self] in
                    for await event in events {
                        // A cancelled listener drops the events still buffered in its stream: the
                        // `.unsubscribed` of `stopShotCounter()` (upstream `_stopping_shot_counter`).
                        guard !Task.isCancelled, let self else { return }
                        self.handleShotCounterEvent(event)
                    }
                }
                shotCounterTask = listener
            }
        }

        let started: Bool
        do {
            started = try await bluetooth.startShotCounter()
        } catch {
            abandonShotCounterListener(listener)
            throw error
        }
        guard started else {
            abandonShotCounterListener(listener)
            return false
        }
        // The client's live state (upstream's property reads it): a stop that raced this start leaves
        // it false.
        isShotCounterActive = await bluetooth.shotCounterActive
        return true
    }

    /// Stop the Bluetooth shot counter (upstream `disconnect_bluetooth_shot_counter`).
    ///
    /// Restores the cloud machine status and resets ``bluetoothTelemetry``. ``bluetoothEvents()``
    /// listeners are **not** notified (upstream: "The update callbacks are not called, refresh after
    /// awaiting this."). ``lastShotTime`` is kept. The Bluetooth link stays up until its idle timer
    /// fires.
    public func stopShotCounter() async {
        // First, so the client's `.unsubscribed` for this stop is never handled.
        shotCounterTask?.cancel()
        shotCounterTask = nil
        await bluetooth?.stopShotCounter()
        bluetoothTelemetry = BluetoothMachineTelemetry()
        clearBluetoothBrewingState(notify: false)
        isShotCounterActive = false
    }

    /// Brewing and telemetry events, delivered after the machine's state was updated.
    ///
    /// Multiplexed: every call returns an independent stream that reports the events from
    /// registration on. Cancelling its iteration unregisters it.
    public func bluetoothEvents() -> AsyncStream<MachineBluetoothEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MachineBluetoothEvent>.makeStream()
        bluetoothEventListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.bluetoothEventListeners[id] = nil
            }
        }
        return stream
    }

    /// Apply one event of the Bluetooth client's shot-counter stream (SPEC §4.19).
    ///
    /// State is mutated first, then ``bluetoothEvents()`` listeners are notified.
    func handleShotCounterEvent(_ event: ShotCounterEvent) {
        switch event {
        case .brewing(let update):
            // upstream `_on_shot_counter_update` (MACH:209-221)
            bluetoothBrewingUpdate = update
            if let finalShotTime = update.finalShotTime {
                lastShotTime = finalShotTime
            }
            renderDashboard()
            // Every brewing update, whatever its state, extends the overlay's lifetime.
            armBluetoothBrewingExpiry()
            emitBluetoothEvent(.brewing(update))
        case .telemetry(let telemetry):
            // upstream `_on_bluetooth_telemetry` (MACH:230-241); never re-arms the expiry.
            bluetoothTelemetry = bluetoothTelemetry.merging(telemetry)
            if let mode = telemetry.machineMode {
                updateBaseDashboard { $0.settingMachineMode(mode).settingMachineState(MachineState(bluetoothMode: mode)) }
            }
            emitBluetoothEvent(.telemetry(telemetry))
        case .subscribed:
            isShotCounterActive = true
        case .unsubscribed:
            // upstream `_on_shot_counter_connection(False)` (MACH:223-228)
            isShotCounterActive = false
            bluetoothTelemetry = BluetoothMachineTelemetry()
            clearBluetoothBrewingState(notify: true)
        case .gaveUp(let error):
            // Angstrom-only (D15): the client stopped reconnecting for good.
            isShotCounterActive = false
            lastError = error
            shotCounterTask?.cancel()
            shotCounterTask = nil
            emitBluetoothEvent(.shotCounterStopped(error))
        }
    }

    /// Drop the BLE brewing overlay; emit `.brewingCleared` when `notify` is true.
    func clearBluetoothBrewingState(notify: Bool) {
        bluetoothBrewingUpdate = nil
        brewingExpiryTask?.cancel()
        brewingExpiryTask = nil
        renderDashboard()
        if notify {
            emitBluetoothEvent(.brewingCleared)
        }
    }

    /// (Re-)arm the brewing-state expiry (upstream `BLE_BREWING_STATE_TIMEOUT`).
    ///
    /// Cancels the running expiry and starts a new one that, unless cancelled, drops the overlay
    /// after ``bluetoothBrewingStateTimeout`` and notifies `.brewingCleared`.
    func armBluetoothBrewingExpiry() {
        brewingExpiryTask?.cancel()
        let timeout = bluetoothBrewingStateTimeout
        let sleep = brewingExpirySleep
        brewingExpiryTask = Task { [weak self] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            // A sleep that ignores cancellation returns normally: re-check before acting.
            guard !Task.isCancelled, let self else { return }
            self.clearBluetoothBrewingState(notify: true)
        }
    }

    /// Test seam: replace the brewing-state timeout and the sleep the expiry waits on.
    func setBluetoothBrewingExpiryForTesting(timeout: Duration,
                                             sleep: @escaping @Sendable (Duration) async throws -> Void) {
        bluetoothBrewingStateTimeout = timeout
        brewingExpirySleep = sleep
    }

    // MARK: - Private

    /// A start that threw or returned false leaves no listener behind.
    private func abandonShotCounterListener(_ listener: Task<Void, Never>) {
        listener.cancel()
        if shotCounterTask == listener {
            shotCounterTask = nil
        }
    }

    private func emitBluetoothEvent(_ event: MachineBluetoothEvent) {
        for listener in bluetoothEventListeners.values {
            listener.yield(event)
        }
    }
}
