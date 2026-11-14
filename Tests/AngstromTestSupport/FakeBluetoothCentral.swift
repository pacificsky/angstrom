import Foundation
import Angstrom

/// A fake Bluetooth stack: the central half of upstream's `FakeBleakClient`
/// (`tests/test_bluetooth_client.py:157-292`) — `connect_errors` becomes `enqueueConnect(.failure(…))`.
///
/// `connect` performs one attempt: it counts the call, records its timeout and peripheral id, pops the
/// oldest queued outcome (else throws `connectFailure` if set, else calls `makeLink()`), copies `now`
/// into the link and appends it to `links`. A queued failure or `connectFailure` is thrown and adds no
/// link. A cancelled `connect` is counted and recorded, then throws `CancellationError` without popping
/// an outcome or adding a link. Availability defaults to `.poweredOn`.
package final class FakeBluetoothCentral: BluetoothCentral, @unchecked Sendable {
    private let lock = NSLock()
    private var state: BluetoothAvailability = .poweredOn
    private var updateContinuations: [UInt64: AsyncStream<BluetoothAvailability>.Continuation] = [:]
    private var nextUpdateID: UInt64 = 0
    private var scanResults: [DiscoveredPeripheral] = []
    private var queuedOutcomes: [Result<FakeBluetoothLink, BluetoothTransportError>] = []
    private var makeLinkStorage: @Sendable () -> FakeBluetoothLink = { .laMarzocco(token: "token") }
    private var nowStorage: @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
    private var connectCountStorage = 0
    private var connectTimeoutsStorage: [Duration] = []
    private var connectPeripheralIDsStorage: [BluetoothPeripheralID] = []
    private var connectFailureStorage: BluetoothTransportError?
    private var linksStorage: [FakeBluetoothLink] = []

    package init() {}

    /// Sets the state AND yields it on every `availabilityUpdates()` stream.
    package func setAvailability(_ availability: BluetoothAvailability) {
        locked {
            state = availability
            for continuation in updateContinuations.values { continuation.yield(availability) }
        }
    }

    /// What `scan(for:)` returns.
    package func setScanResults(_ results: [DiscoveredPeripheral]) {
        locked { scanResults = results }
    }

    /// Popped per `connect`; when empty, `makeLink()` is used.
    package func enqueueConnect(_ outcome: Result<FakeBluetoothLink, BluetoothTransportError>) {
        locked { queuedOutcomes.append(outcome) }
    }

    /// Builds the link of a `connect` with nothing queued. Default: `.laMarzocco(token: "token")`.
    package var makeLink: @Sendable () -> FakeBluetoothLink {
        get { locked { makeLinkStorage } }
        set { locked { makeLinkStorage = newValue } }
    }

    /// Notification clock. `BluetoothTransport.fake(_:sleeper:clock:)` sets it to `clock.now`; `connect`
    /// copies it into every link it returns (queued or made) before returning it.
    package var now: @Sendable () -> Date {
        get { locked { nowStorage } }
        set { locked { nowStorage = newValue } }
    }

    /// Every `connect` call, successful or not.
    package var connectCount: Int { locked { connectCountStorage } }

    /// The `timeout` of every `connect` call, in order.
    package var connectTimeouts: [Duration] { locked { connectTimeoutsStorage } }

    /// The peripheral id passed to every `connect(to:timeout:)` attempt, in order (C51) — including
    /// failed and cancelled attempts, exactly the attempts `connectCount` counts.
    package var connectPeripheralIDs: [BluetoothPeripheralID] { locked { connectPeripheralIDsStorage } }

    /// When non-nil, every connect attempt with nothing queued throws it instead of using `makeLink()`
    /// (the attempt is still counted and recorded). Default nil. A queued outcome takes precedence.
    package var connectFailure: BluetoothTransportError? {
        get { locked { connectFailureStorage } }
        set { locked { connectFailureStorage = newValue } }
    }

    /// Live `availabilityUpdates()` streams (created and not yet terminated). A stream only sees changes
    /// made after it was created, so a test waits for this to be non-zero before `setAvailability`.
    package var availabilitySubscriberCount: Int { locked { updateContinuations.count } }

    /// Every link `connect` returned, in order.
    package var links: [FakeBluetoothLink] { locked { linksStorage } }

    // MARK: - BluetoothCentral

    package func availability() async -> BluetoothAvailability {
        locked { state }
    }

    package func availabilityUpdates() -> AsyncStream<BluetoothAvailability> {
        let (stream, continuation) = AsyncStream.makeStream(of: BluetoothAvailability.self,
                                                            bufferingPolicy: .unbounded)
        // Registered (and counted by `availabilitySubscriberCount`) before the stream is returned; the
        // termination handler — run when the stream finishes, is deallocated, or its consumer is
        // cancelled — unregisters it.
        let id: UInt64 = locked {
            nextUpdateID += 1
            updateContinuations[nextUpdateID] = continuation
            return nextUpdateID
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.locked { _ = self.updateContinuations.removeValue(forKey: id) }
        }
        return stream
    }

    package func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] {
        locked { scanResults }
    }

    package func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        locked {
            connectCountStorage += 1
            connectTimeoutsStorage.append(timeout)
            connectPeripheralIDsStorage.append(id)
        }
        // Like the real seam (§5.3), a cancelled attempt throws `CancellationError`. It is still counted,
        // but pops nothing: the queued outcome stays for the next attempt and no link is added.
        try Task.checkCancellation()
        let (queued, failure, makeLink, now): (Result<FakeBluetoothLink, BluetoothTransportError>?, BluetoothTransportError?, @Sendable () -> FakeBluetoothLink, @Sendable () -> Date) = locked {
            let queued = queuedOutcomes.isEmpty ? nil : queuedOutcomes.removeFirst()
            return (queued, connectFailureStorage, makeLinkStorage, nowStorage)
        }
        let link: FakeBluetoothLink
        switch queued {
        case .failure(let error)?:
            throw error
        case .success(let queuedLink)?:
            link = queuedLink
        case nil:
            if let failure { throw failure }
            link = makeLink()
        }
        link.now = now
        locked { linksStorage.append(link) }
        return link
    }

    // MARK: - Private

    private func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
