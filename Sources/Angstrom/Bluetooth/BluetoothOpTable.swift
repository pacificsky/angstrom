import Foundation

/// Queue-confined table of in-flight operations (NOT thread-safe: adapter queue only).
/// Exactly-once: every completion path goes through `finish`, which removes the entry
/// BEFORE calling `complete`.
package final class BluetoothOpTable<Key: Hashable & Sendable> {
    package typealias Completion = (Result<any Sendable, any Error>) -> Void

    /// In-flight ops by token.
    private var ops: [UInt64: (key: Key, isGATTRequest: Bool, complete: Completion)] = [:]
    /// Tokens in registration order, so `finishOldest` can find the oldest op for a key.
    private var order: [UInt64] = []
    /// Delegate replies still owed by abandoned GATT requests, per key.
    private var owed: [Key: Int] = [:]

    package init() {}

    /// Register an in-flight op. `isGATTRequest`: an abandoned op still owes one delegate callback.
    package func register(_ token: UInt64, key: Key, isGATTRequest: Bool, complete: @escaping Completion) {
        fatalError("unimplemented: BT-W1-07")
    }

    /// Remove + complete. `abandoning: true` (timeout/cancel) records an owed reply for GATT requests.
    @discardableResult
    package func finish(_ token: UInt64, _ result: Result<any Sendable, any Error>, abandoning: Bool) -> Bool {
        fatalError("unimplemented: BT-W1-07")
    }

    /// Delegate-callback path: swallow one owed reply for `key` if any, else finish the OLDEST op with `key`.
    @discardableResult
    package func finishOldest(_ key: Key, _ result: Result<any Sendable, any Error>) -> Bool {
        fatalError("unimplemented: BT-W1-07")
    }

    /// A request was sent without anyone awaiting it (e.g. best-effort unsubscribe).
    package func owe(_ key: Key) {
        fatalError("unimplemented: BT-W1-07")
    }

    /// An op or an owed reply is outstanding for `key`.
    package func isAwaiting(_ key: Key) -> Bool {
        fatalError("unimplemented: BT-W1-07")
    }

    /// Fail every op whose key matches, and drop owed replies for matching keys.
    package func failAll(where match: (Key) -> Bool, _ error: any Error) {
        fatalError("unimplemented: BT-W1-07")
    }
}
