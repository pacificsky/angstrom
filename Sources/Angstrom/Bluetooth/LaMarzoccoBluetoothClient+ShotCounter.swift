import Foundation

extension LaMarzoccoBluetoothClient {
    // MARK: Shot counter

    /// True when subscribed (also when already subscribed); false when unsupported. Throws connect/auth errors.
    public func startShotCounter() async throws -> Bool {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-02")
    }

    /// Unsubscribe and resume idle disconnects; the link stays up.
    public func stopShotCounter() async {
        fatalError("unimplemented: BT-W2-02")
    }

    /// Multiplexed shot-counter events; register before `startShotCounter()`.
    public func shotCounterEvents() -> AsyncStream<ShotCounterEvent> {
        fatalError("unimplemented: BT-W2-02")
    }

    // MARK: Internal helpers [+ShotCounter]

    /// §4.9.
    func subscribeShotCounter() async throws -> Bool {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-02")
    }

    /// Inert until its owner lands: a disabled counter has nothing to disable (PLAN §3.0).
    func disableShotCounter() -> Bool {
        guard shotCounterEnabled else { return false }
        fatalError("unimplemented: BT-W2-02")
    }

    /// Inert until its owner lands: with no live subscription there is nothing to unsubscribe (PLAN §3.0).
    func stopNotifyInternal() async {
        if shotCounterSubscribed && link != nil {
            fatalError("unimplemented: BT-W2-02")
        }
        shotCounterSubscribed = false
    }

    /// §4.10. Inert until its owner lands: a notification while disabled is dropped (PLAN §3.0).
    func handleShotCounterNotification(_ notification: GATTNotification) {
        guard shotCounterEnabled else { return }
        fatalError("unimplemented: BT-W2-02")
    }

    /// §4.13.
    func reconnectLoop() async {
        fatalError("unimplemented: BT-W2-02")
    }
}
