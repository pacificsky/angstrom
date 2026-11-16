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
        ops[token] = (key, isGATTRequest, complete)
        order.append(token)
    }

    /// Remove + complete. `abandoning: true` (timeout/cancel) records an owed reply for GATT requests.
    @discardableResult
    package func finish(_ token: UInt64, _ result: Result<any Sendable, any Error>, abandoning: Bool) -> Bool {
        // Remove first: a re-entrant or later `finish` for the same token finds nothing.
        guard let entry = ops.removeValue(forKey: token) else { return false }
        order.removeAll { $0 == token }
        if abandoning && entry.isGATTRequest { owed[entry.key, default: 0] += 1 }
        entry.complete(result)
        return true
    }

    /// Delegate-callback path: swallow one owed reply for `key` if any, else finish the OLDEST op with `key`.
    @discardableResult
    package func finishOldest(_ key: Key, _ result: Result<any Sendable, any Error>) -> Bool {
        // A late reply for an abandoned (or unawaited) request is swallowed, so it can never
        // resolve a newer op with the same key.
        if let debt = owed[key], debt > 0 {
            owed[key] = debt == 1 ? nil : debt - 1
            return true
        }
        guard let token = order.first(where: { ops[$0]?.key == key }) else { return false }
        return finish(token, result, abandoning: false)
    }

    /// A request was sent without anyone awaiting it (e.g. best-effort unsubscribe).
    package func owe(_ key: Key) {
        owed[key, default: 0] += 1
    }

    /// An op or an owed reply is outstanding for `key`.
    package func isAwaiting(_ key: Key) -> Bool {
        (owed[key] ?? 0) > 0 || order.contains { ops[$0]?.key == key }
    }

    /// Fail every op whose key matches, and drop owed replies for matching keys.
    package func failAll(where match: (Key) -> Bool, _ error: any Error) {
        owed = owed.filter { !match($0.key) }
        // Iterate a snapshot of the registration order; re-check each token, because a
        // completion may re-enter the table and finish another op first.
        for token in order where ops[token].map({ match($0.key) }) == true {
            finish(token, .failure(error), abandoning: false)
        }
    }
}
