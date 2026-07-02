import Foundation
@testable import Angstrom

/// A tiny thread-safe box for cross-task assertions in tests.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
}

/// A scriptable ``WebSocketChannel`` for tests: records sent frames and lets the
/// test `push` incoming frames that a pending `receive()` resolves with.
final class MockWebSocketChannel: WebSocketChannel, @unchecked Sendable {
    /// How ``sendPing()`` behaves — lets tests simulate a healthy socket, a
    /// broken one (ping errors), or a zombie half-open one (pong never arrives).
    enum PingBehavior {
        case succeed
        case fail(Error)
        case hang
    }

    private let lock = NSLock()
    private var sent: [String] = []
    private var incoming: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private var pings = 0
    private var _pingBehavior: PingBehavior = .succeed
    private var pingWaiters: [CheckedContinuation<Void, Error>] = []

    var pingBehavior: PingBehavior {
        get { lock.withLock { _pingBehavior } }
        set { lock.withLock { _pingBehavior = newValue } }
    }

    /// Deliver an incoming frame to the (current or next) `receive()`.
    func push(_ frame: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: frame)
        } else {
            incoming.append(frame)
            lock.unlock()
        }
    }

    func send(_ text: String) async throws { lock.withLock { sent.append(text) } }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if closed {
                lock.unlock()
                cont.resume(throwing: URLError(.networkConnectionLost))
            } else if !incoming.isEmpty {
                let frame = incoming.removeFirst()
                lock.unlock()
                cont.resume(returning: frame)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }

    func sendPing() async throws {
        let behavior = lock.withLock { pings += 1; return _pingBehavior }
        switch behavior {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .hang:
            // Zombie socket: the pong handler never fires. Parked waiters are
            // resolved (with an error) only when the channel is closed.
            try await withCheckedThrowingContinuation { cont in
                lock.withLock { pingWaiters.append(cont) }
            }
        }
    }
    var pingCount: Int { lock.withLock { pings } }

    func close() {
        lock.lock()
        closed = true
        let waiter = self.waiter
        self.waiter = nil
        let pending = pingWaiters
        pingWaiters = []
        lock.unlock()
        waiter?.resume(throwing: URLError(.cancelled))
        for ping in pending { ping.resume(throwing: URLError(.cancelled)) }
    }

    var sentFrames: [String] { lock.withLock { sent } }
    func sentFrame(command: String) -> Stomp.Frame? {
        sentFrames.compactMap(Stomp.decode).first { $0.command == command }
    }
}
