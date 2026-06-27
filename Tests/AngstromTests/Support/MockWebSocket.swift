import Foundation
@testable import Angstrom

/// A scriptable ``WebSocketChannel`` for tests: records sent frames and lets the
/// test `push` incoming frames that a pending `receive()` resolves with.
final class MockWebSocketChannel: WebSocketChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    private var incoming: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private var pings = 0

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

    func sendPing() async throws { lock.withLock { pings += 1 } }
    var pingCount: Int { lock.withLock { pings } }

    func close() {
        lock.lock()
        closed = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: URLError(.cancelled))
    }

    var sentFrames: [String] { lock.withLock { sent } }
    func sentFrame(command: String) -> Stomp.Frame? {
        sentFrames.compactMap(Stomp.decode).first { $0.command == command }
    }
}
