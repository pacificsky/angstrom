import Foundation
import os

extension LaMarzoccoBluetoothClient {
    // MARK: Shot counter

    /// True when subscribed (also when already subscribed); false when unsupported. Throws connect/auth errors.
    ///
    /// Keeps the link open (no idle disconnect) and reconnects with backoff after a connection loss
    /// until ``stopShotCounter()`` or ``disconnect()`` (upstream `start_shot_counter`, `BT:327-362`).
    /// A start failure throws; it is not converted to `false`.
    public func startShotCounter() async throws -> Bool {
        // This also suppresses idle timers from here on.
        shotCounterEnabled = true
        let supported: Bool
        do {
            supported = try await subscribeShotCounter()
        } catch {
            abandonFailedStart()
            throw error
        }
        if !supported {
            abandonFailedStart()
        }
        return supported
    }

    /// Unsubscribe and resume idle disconnects; the link stays up.
    ///
    /// With no counter running, this only re-arms the idle timer (upstream `stop_shot_counter`, `BT:364-371`).
    public func stopShotCounter() async {
        let wasSubscribed = disableShotCounter()
        await acquire(.connection)
        await stopNotifyInternal()
        if link != nil {
            resetIdleTimer()
        }
        release(.connection)
        if wasSubscribed {
            emitShotCounter(.unsubscribed)
        }
    }

    /// Multiplexed shot-counter events; register before `startShotCounter()`.
    ///
    /// Every call returns an independent stream that reports the events from registration on.
    /// Cancelling its iteration unregisters it.
    public func shotCounterEvents() -> AsyncStream<ShotCounterEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ShotCounterEvent>.makeStream()
        shotCounterListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeShotCounterListener(id) }
        }
        return stream
    }

    // MARK: Internal helpers [+ShotCounter]

    /// §4.9 (`BT:403-439`): connect, authenticate and subscribe, with the cached service table first
    /// and a rediscovery pass second.
    func subscribeShotCounter() async throws -> Bool {
        for refresh in [false, true] {
            _ = try await ensureConnected(refresh: refresh)
            await acquire(.connection)
            // The gate wait is not cancellable (upstream's lock would raise `CancelledError` here): a
            // cancelled caller (the reconnect loop after a stop) must not subscribe or disconnect.
            if Task.isCancelled {
                release(.connection)
                throw CancellationError()
            }
            let outcome: SubscribeOutcome
            do {
                outcome = try await subscribeHoldingGate(refresh: refresh)
            } catch {
                release(.connection)
                throw error
            }
            release(.connection)
            switch outcome {
            case .finished(let result):
                return result
            case .rediscover:
                continue
            case .subscribed:
                log?("Subscribed to shot counter on \(peripheral)")
                emitShotCounter(.subscribed)
                return true
            }
        }
        return false
    }

    /// §4.9 (`BT:373-394`). Clears the shot-counter state and stops reconnecting; returns whether
    /// notifications were subscribed. All state is mutated before the caller emits any event.
    func disableShotCounter() -> Bool {
        guard shotCounterEnabled else { return false }
        let wasSubscribed = shotCounterSubscribed
        shotCounterEnabled = false
        tracker = BrewingTracker()
        reconnectTask?.cancel()
        reconnectTask = nil
        return wasSubscribed
    }

    /// §4.9 (`BT:396-401`). Best-effort unsubscribe; the caller holds `.connection`.
    func stopNotifyInternal() async {
        if shotCounterSubscribed, let link {
            await link.unsubscribe(BluetoothConstants.shotCounterCharacteristic)
            emitRawEvent(RawBluetoothFrame.unsubscribedMarker)
        }
        shotCounterSubscribed = false
    }

    /// §4.10 (`BT:441-465`).
    func handleShotCounterNotification(_ notification: GATTNotification) {
        // 1. The raw tap sees every notification verbatim, the replay included.
        emitRaw(.notification, .inbound, characteristic: BluetoothConstants.shotCounterCharacteristic,
                data: notification.value, isSecret: false)
        // 2. On subscribe, the machine first replays its last notification, which can be hours old.
        if replayPending {
            replayPending = false
            log?("Ignoring the replayed shot counter notification")
            emitRawEvent(RawBluetoothFrame.replayDroppedMarker)
            return
        }
        // 3. Parse or drop (§3.8).
        guard let decoded = ShotCounterNotificationDecoder.decode(notification.value) else {
            log?("Failed to parse shot counter data")
            return
        }
        // 4. Brewing first. Most notifications are telemetry only and must not touch the brewing state.
        if !decoded.brewing.isEmpty {
            let update = tracker.process(decoded.brewing, receivedAt: notification.receivedAt)
            if let update, shotCounterEnabled {
                emitShotCounter(.brewing(update))
            }
        }
        // 5. Then the telemetry of this notification only (not merged).
        if !decoded.telemetry.isEmpty, shotCounterEnabled {
            emitShotCounter(.telemetry(decoded.telemetry))
        }
    }

    /// §4.13 (`BT:488-520`, D14, D15): reconnect with backoff until the shot counter is subscribed
    /// again, or give up for good.
    func reconnectLoop() async {
        var delay = timing.reconnectInitialDelay
        var authFailures = 0
        var lastError: LaMarzoccoError?
        // Created ONCE, before the first sleep: a stream only sees later changes (D14). One consumer
        // reads it for the whole run, so no change is lost between two sleeps.
        let poweredOn = PoweredOnSignal()
        let updates = central.availabilityUpdates()
        let monitor = Task {
            for await state in updates {
                poweredOn.observe(state)
            }
        }
        defer { monitor.cancel() }

        attempts: while shotCounterEnabled {
            // Sleep BEFORE every attempt, including the first (G-SC-7).
            do {
                if try await reconnectBackoff(delay, poweredOn: poweredOn) {
                    log?("Bluetooth is powered on again, reconnecting the shot counter now")
                    delay = timing.reconnectInitialDelay
                }
            } catch {
                return  // cancelled: the shot counter was stopped
            }

            let result: Result<Bool, any Error>
            do {
                result = .success(try await subscribeShotCounter())
            } catch {
                result = .failure(error)
            }
            // Only `disableShotCounter()` cancels this task, and it has already cleaned up. Upstream's
            // `CancelledError` would surface at the next await; the gate waits are not cancellable, so
            // the attempt checks after each of them and may have run to its end first.
            if Task.isCancelled {
                return
            }

            switch result {
            case .success(true):
                // `.subscribed` was already emitted.
                reconnectTask = nil
                return
            case .success(false):
                let shotCounter = BluetoothConstants.shotCounterCharacteristic
                lastError = .bluetoothConnectionFailed("Could not find characteristic \(shotCounter.string) on machine.")
                break attempts
            case .failure(let error as LaMarzoccoError) where error == .bluetoothAuthenticationFailed:
                // Cumulative per loop run, not "in a row" (D15); the delay is not doubled.
                authFailures += 1
                lastError = .bluetoothAuthenticationFailed
                log?("Shot counter authentication failed (\(authFailures)/\(timing.maxAuthFailures)): \(error)")
                if authFailures >= timing.maxAuthFailures {
                    log?("Giving up reconnecting the shot counter")
                    break attempts
                }
                continue attempts
            case .failure(is CancellationError):
                return
            case .failure(let error):
                // Connection-class (upstream: BleakError/TimeoutError/BluetoothConnectionFailed); any
                // other error takes this branch too (D15).
                log?("Shot counter reconnect failed: \(error)")
                lastError = error as? LaMarzoccoError
                await acquire(.connection)
                // The gate wait is not cancellable: a stop that landed while this task waited must not
                // be followed by a disconnect (the gate holder may have connected a new link meanwhile).
                // Upstream's `async with self._lock` raises `CancelledError` here instead.
                if Task.isCancelled {
                    release(.connection)
                    return
                }
                await disconnectInternal()
                release(.connection)
                delay = min(delay * 2, timing.reconnectMaxDelay)
                continue attempts
            }
        }

        // Give up for good, without cancelling this task.
        reconnectTask = nil
        let stillEnabled = shotCounterEnabled
        _ = disableShotCounter()  // no .unsubscribed here: it was sent at loss time
        if link != nil {
            resetIdleTimer()
        }
        if stillEnabled, let lastError {
            emitShotCounter(.gaveUp(lastError))  // Angstrom-only terminal event (D15)
        }
    }

    // MARK: Private

    /// What the gated part of one `subscribeShotCounter` pass decided.
    private enum SubscribeOutcome {
        /// Return this result without an event.
        case finished(Bool)
        /// The cached service table may be stale: run the pass again with `refresh: true`.
        case rediscover
        /// Subscribed: emit `.subscribed` after releasing the gate.
        case subscribed
    }

    /// The gated step 2 of §4.9. The caller holds `.connection`.
    private func subscribeHoldingGate(refresh: Bool) async throws -> SubscribeOutcome {
        guard let link else {
            throw LaMarzoccoError.bluetoothConnectionFailed("Client is not connected")
        }
        // Stopped meanwhile.
        guard shotCounterEnabled else { return .finished(false) }
        guard !shotCounterSubscribed else { return .finished(true) }
        let shotCounter = BluetoothConstants.shotCounterCharacteristic
        guard discovered.contains(shotCounter) else {
            log?("Shot counter characteristic not found on \(peripheral)")
            if refresh {
                return .finished(false)
            }
            await disconnectInternal()
            return .rediscover
        }
        tracker = BrewingTracker()
        // Armed BEFORE subscribing: the replay may arrive before the subscribe acknowledgement.
        replayPending = true
        do {
            try await link.subscribe(shotCounter, timeout: timing.operationTimeout)
        } catch {
            throw Self.mapTransportError(error, phase: .request)
        }
        shotCounterSubscribed = true
        emitRawEvent(RawBluetoothFrame.subscribedMarker)
        return .subscribed
    }

    /// §4.9 step 3: a start that threw or found no characteristic leaves nothing running.
    private func abandonFailedStart() {
        _ = disableShotCounter()
        if link != nil {
            resetIdleTimer()
        }
    }

    /// The `.reconnectBackoff` sleep, ended early by `poweredOn` (D14). Returns true when Bluetooth
    /// came back on before the delay elapsed. Throws `CancellationError` when the loop is cancelled.
    private func reconnectBackoff(_ delay: Duration, poweredOn: PoweredOnSignal) async throws -> Bool {
        let sleeper = self.sleeper
        let endedEarly = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await sleeper.sleep(for: delay, purpose: .reconnectBackoff)
                return false
            }
            group.addTask {
                try await poweredOn.wait()
                return true
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        try Task.checkCancellation()
        return endedEarly
    }

    private func removeShotCounterListener(_ id: UUID) {
        shotCounterListeners[id] = nil
    }
}

/// D14: latches "Bluetooth is `.poweredOn` again after a non-`.poweredOn` state seen during this
/// reconnect loop" and hands it to the backoff sleep that is waiting, or to the next one.
private final class PoweredOnSignal: Sendable {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var sawNotPoweredOn = false
        var latched = false
        var waiter: Waiter?
        var nextID: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Fed every value of the loop's availability stream, in order.
    func observe(_ availability: BluetoothAvailability) {
        let resumed: CheckedContinuation<Void, any Error>? = state.withLock { state in
            guard availability == .poweredOn else {
                state.sawNotPoweredOn = true
                return nil
            }
            guard state.sawNotPoweredOn else { return nil }
            state.sawNotPoweredOn = false
            guard let waiter = state.waiter else {
                state.latched = true
                return nil
            }
            state.waiter = nil
            return waiter.continuation
        }
        resumed?.resume()
    }

    /// Returns once the signal fires (consuming it); throws `CancellationError` when cancelled first.
    func wait() async throws {
        let id: UInt64 = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Decision { case cancelled, fired, suspended }
                let decision: Decision = state.withLock { state in
                    // Checked under the lock: either this sees the cancellation, or `onCancel` (which
                    // takes the same lock) finds the waiter stored here.
                    if Task.isCancelled { return .cancelled }
                    if state.latched {
                        state.latched = false
                        return .fired
                    }
                    state.waiter = Waiter(id: id, continuation: continuation)
                    return .suspended
                }
                switch decision {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .fired: continuation.resume()
                case .suspended: break
                }
            }
        } onCancel: {
            let cancelled: CheckedContinuation<Void, any Error>? = state.withLock { state in
                guard let waiter = state.waiter, waiter.id == id else { return nil }
                state.waiter = nil
                return waiter.continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }
}
