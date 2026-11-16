import Foundation
import Angstrom

package extension BluetoothPeripheralID {
    /// The peripheral every fake link reports by default.
    static let fake = BluetoothPeripheralID(rawValue: "00000000-0000-0000-0000-000000000001")
}

/// A settable clock: the Swift equivalent of upstream's `FakeClock` patched over `_utcnow`
/// (`tests/test_bluetooth_client.py:86-105`). `now` is handed to `BluetoothTransport.now` and to the
/// fake central, which copies it into every link so replay notifications carry the same time.
package final class BluetoothTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    package init(_ start: Date) {
        current = start
    }

    /// Reads the clock at call time, so later `set`/`advance` calls are observed.
    package var now: @Sendable () -> Date {
        { [self] in self.read() }
    }

    package func set(_ date: Date) {
        locked { current = date }
    }

    package func advance(by seconds: TimeInterval) {
        locked { current = current.addingTimeInterval(seconds) }
    }

    private func read() -> Date {
        locked { current }
    }

    private func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

package extension BluetoothTransport {
    /// A transport over `central` whose sleeps go through `sleeper` and whose notifications are
    /// stamped by `clock`: it sets `central.now = clock.now` (the central copies it into each link it
    /// returns) and passes the same `clock.now` as the transport's `now`.
    static func fake(_ central: FakeBluetoothCentral, sleeper: ManualBluetoothSleeper = .init(),
                     clock: BluetoothTestClock = .init(Date(timeIntervalSince1970: 0))) -> BluetoothTransport {
        central.now = clock.now
        return BluetoothTransport(central: central, sleeper: sleeper, now: clock.now)
    }
}
