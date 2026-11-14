import Foundation
import Angstrom

/// Tagged sleeper. Purposes in `manual` suspend until `fire` or cancellation; others return immediately.
/// With the default `manual`, a `.poweredOnWait` sleep returns at once, so an availability wait times
/// out immediately; a test that flips availability during the wait passes `[.idleDisconnect, .poweredOnWait]`
/// and fires `.poweredOnWait` to time it out.
///
/// The Swift equivalent of upstream's `IdleTimer` (`tests/test_bluetooth_client.py:108-154`, the idle
/// sleep blocks until fired) combined with the zero-patched `AUTH_READ_INTERVAL`/`RECONNECT_INITIAL_DELAY`
/// (every other sleep ends at once). Unlike upstream, every requested duration is recorded.
package final class ManualBluetoothSleeper: BluetoothSleeper, @unchecked Sendable {
    private struct PendingSleep {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let id: UInt64
        let purpose: SleepPurpose
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let manual: Set<SleepPurpose>
    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var requestedDurations: [SleepPurpose: [Duration]] = [:]
    private var pending: [SleepPurpose: [PendingSleep]] = [:]
    private var waiters: [Waiter] = []

    package init(manual: Set<SleepPurpose> = [.idleDisconnect]) {
        self.manual = manual
    }

    /// Every duration requested for `purpose`, in order (manual or not, fired, cancelled or pending).
    package func requested(_ purpose: SleepPurpose) -> [Duration] {
        locked { requestedDurations[purpose] ?? [] }
    }

    /// How many sleeps of `purpose` were started (every `sleep` call for it, like upstream's
    /// `IdleTimer.started`), whatever became of them.
    package func startedCount(_ purpose: SleepPurpose) -> Int {
        locked { requestedDurations[purpose]?.count ?? 0 }
    }

    /// Manual sleeps of `purpose` still suspended. Fired and cancelled sleeps are not pending.
    package func pendingCount(_ purpose: SleepPurpose) -> Int {
        locked { pending[purpose]?.count ?? 0 }
    }

    /// Resumes the oldest pending sleep of `purpose` (it returns normally). No-op when none is pending.
    package func fire(_ purpose: SleepPurpose) {
        let fired: PendingSleep? = locked {
            guard var queue = pending[purpose], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            pending[purpose] = queue
            return first
        }
        fired?.continuation.resume()
    }

    /// Suspends (without polling) until at least `count` sleeps of `purpose` are pending. Returns early
    /// if the waiting task is cancelled.
    package func waitForPending(_ purpose: SleepPurpose, count: Int) async {
        let id: UInt64 = locked { allocateID() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready: Bool = locked {
                    if (pending[purpose]?.count ?? 0) >= count || Task.isCancelled { return true }
                    waiters.append(Waiter(id: id, purpose: purpose, count: count, continuation: continuation))
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let waiter: Waiter? = locked {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index)
            }
            waiter?.continuation.resume()
        }
    }

    package func sleep(for duration: Duration, purpose: SleepPurpose) async throws {
        let id: UInt64 = locked {
            requestedDurations[purpose, default: []].append(duration)
            return allocateID()
        }
        guard manual.contains(purpose) else {
            // Returns at once, but honours the protocol's cancellation contract like `Task.sleep`.
            try Task.checkCancellation()
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (cancelled, satisfied): (Bool, [Waiter]) = locked {
                    // Checked under the lock: either this sees the cancellation, or `onCancel` (which
                    // takes the same lock) finds the entry appended here.
                    if Task.isCancelled { return (true, []) }
                    pending[purpose, default: []].append(PendingSleep(id: id, continuation: continuation))
                    return (false, takeSatisfiedWaiters())
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                for waiter in satisfied { waiter.continuation.resume() }
            }
        } onCancel: {
            let cancelled: PendingSleep? = locked {
                guard var queue = pending[purpose],
                      let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
                let entry = queue.remove(at: index)
                pending[purpose] = queue
                return entry
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Caller holds the lock.
    private func allocateID() -> UInt64 {
        nextID += 1
        return nextID
    }

    /// Caller holds the lock. Removes and returns the waiters whose condition now holds.
    private func takeSatisfiedWaiters() -> [Waiter] {
        var satisfied: [Waiter] = []
        waiters.removeAll { waiter in
            guard (pending[waiter.purpose]?.count ?? 0) >= waiter.count else { return false }
            satisfied.append(waiter)
            return true
        }
        return satisfied
    }

    private func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
