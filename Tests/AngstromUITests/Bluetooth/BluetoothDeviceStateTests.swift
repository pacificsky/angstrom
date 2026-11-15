import XCTest
import Observation
@testable import Angstrom
@testable import AngstromUI
import AngstromTestSupport

/// The device layer's connection properties (`hasCloudClient`, `hasBluetoothClient`,
/// `isBluetoothConnected`) and `bluetoothConnectionEvents()` (SPEC §2.5, §4.15, §6.16, D4, D11).
///
/// Connections are made with client reads (`harness.bluetooth!.machineMode()`), never with UI commands.
/// The idle timer is manual (`[.idleDisconnect]`), so a link stays up until the test drops it.
@MainActor
final class BluetoothDeviceStateTests: XCTestCase {
    /// Hang guard only (PLAN §3.5).
    private let hangGuard: TimeInterval = 5
    /// `"BrewingMode"` (upstream `MachineMode.BREWING_MODE`, TBC:1227), so `machineMode()` succeeds.
    private let modeResponses: [BluetoothReadSetting: Data] = [.machineMode: Data(#""BrewingMode""#.utf8)]

    // MARK: - T01 / T02

    /// Upstream: test_connection_properties_without_clients (tests/test_thing.py:36) [T01]
    func testPropertiesWithoutClients() async throws {
        let harness = BluetoothMachineHarness(cloud: false, bluetooth: false)
        let machine = harness.machine

        XCTAssertFalse(machine.hasCloudClient)          // cloud_client_available
        XCTAssertFalse(machine.hasBluetoothClient)      // bluetooth_client_available
        XCTAssertFalse(machine.isBluetoothConnected)    // bluetooth_connected
        XCTAssertFalse(machine.isConnected)             // websocket.connected
        XCTAssertNil(machine.bluetooth)
        XCTAssertNil(machine.bluetoothConnectionTask, "no observation without a Bluetooth client")

        // `register_bluetooth_connection_callback` returns a no-op unregister: here, a finished stream.
        let events = await collectUntilFinished(await machine.bluetoothConnectionEvents())
        XCTAssertEqual(events, [])
    }

    /// Upstream: test_connection_properties_with_clients (tests/test_thing.py:48) [T02]
    func testPropertiesWithClients() async throws {
        let harness = BluetoothMachineHarness(cloud: true, bluetooth: true, settingResponses: modeResponses)
        let machine = harness.machine
        let bluetooth = try XCTUnwrap(harness.bluetooth)

        XCTAssertTrue(machine.hasCloudClient)
        XCTAssertTrue(machine.hasBluetoothClient)
        XCTAssertTrue(machine.bluetooth === bluetooth)
        XCTAssertNotNil(machine.bluetoothConnectionTask, "init starts observing the Bluetooth client")
        // Upstream's websocket is the cloud client's `WebSocketDetails()` (not connected); ours is
        // `isConnected`, false until `start()`.
        XCTAssertFalse(machine.isConnected)

        // Upstream sets `bluetooth_client.is_connected = True`; the real client is connected by a read.
        XCTAssertFalse(machine.isBluetoothConnected)
        let mode = try await bluetooth.machineMode()
        XCTAssertEqual(mode, .brewing)
        let clientConnected = await bluetooth.isConnected
        XCTAssertTrue(clientConnected)
        await waitForBluetoothConnected(machine, true)
        XCTAssertTrue(machine.isBluetoothConnected)
        XCTAssertEqual(harness.central.connectCount, 1)
    }

    // MARK: - M15

    /// Upstream: test_register_bluetooth_connection_callback (tests/test_machine.py:765) [M15]
    ///
    /// Restated (D4): with a client, each call is its own registration on the client's
    /// `connectionEvents()` and forwards its transitions; without one, the stream is already finished.
    func testBluetoothConnectionEventsForwardOrFinish() async throws {
        let harness = BluetoothMachineHarness(cloud: true, bluetooth: true, settingResponses: modeResponses)
        let machine = harness.machine
        let bluetooth = try XCTUnwrap(harness.bluetooth)

        let first = await machine.bluetoothConnectionEvents()
        let second = await machine.bluetoothConnectionEvents()

        _ = try await bluetooth.machineMode()
        await bluetooth.disconnect()

        let firstEvents = await prefixEvents(first, count: 2)
        let secondEvents = await prefixEvents(second, count: 2)
        XCTAssertEqual(firstEvents, [.connected, .disconnected])
        XCTAssertEqual(secondEvents, [.connected, .disconnected])
        XCTAssertEqual(harness.central.connectCount, 1)

        // Without a Bluetooth client, registering is a no-op: the stream is finished and empty.
        let cloudOnly = BluetoothMachineHarness(cloud: true, bluetooth: false)
        XCTAssertFalse(cloudOnly.machine.hasBluetoothClient)
        let none = await collectUntilFinished(await cloudOnly.machine.bluetoothConnectionEvents())
        XCTAssertEqual(none, [])
    }

    // MARK: - G-DEV-9

    /// Angstrom-only: G-DEV-9 — `isBluetoothConnected` follows the real client's connection events
    /// (idle drop, link loss, `disconnect()`, reconnects), means an authenticated link (D11), and starts
    /// from the client's state for a machine created while the client is already connected.
    func testIsBluetoothConnectedFollowsRealClient() async throws {
        // The scripted machine accepts "other", so links from `makeLink` fail auth; good links are
        // queued explicitly for the connects that must succeed.
        let harness = BluetoothMachineHarness(cloud: false, bluetooth: true, token: "other",
                                              settingResponses: modeResponses)
        let machine = harness.machine
        let bluetooth = try XCTUnwrap(harness.bluetooth)
        XCTAssertFalse(machine.isBluetoothConnected)

        // Connect → true.
        enqueueAcceptingLink(harness)
        _ = try await bluetooth.machineMode()
        await waitForBluetoothConnected(machine, true)

        // Idle auto-disconnect → false.
        await harness.sleeper.waitForPending(.idleDisconnect, count: 1)
        harness.sleeper.fire(.idleDisconnect)
        await waitForBluetoothConnected(machine, false)
        let afterIdle = await bluetooth.isConnected
        XCTAssertFalse(afterIdle)

        // Reconnect → true. From here on every transition can only come from an event.
        enqueueAcceptingLink(harness)
        _ = try await bluetooth.machineMode()
        await waitForBluetoothConnected(machine, true)
        XCTAssertEqual(harness.central.connectCount, 2)

        // Link loss → false.
        try XCTUnwrap(harness.links.last).drop(.disconnected(code: 7))
        await waitForBluetoothConnected(machine, false)

        // D11: a link that fails authentication is never reported.
        do {
            _ = try await bluetooth.machineMode()
            XCTFail("expected authentication to fail")
        } catch let error as LaMarzoccoError {
            guard case .bluetoothAuthenticationFailed = error else {
                return XCTFail("expected .bluetoothAuthenticationFailed, got \(error)")
            }
        }
        XCTAssertEqual(harness.central.connectCount, 3)
        let afterAuthFailure = await bluetooth.isConnected
        XCTAssertFalse(afterAuthFailure)
        XCTAssertFalse(machine.isBluetoothConnected)

        // Reconnect → true; `disconnect()` → false.
        enqueueAcceptingLink(harness)
        _ = try await bluetooth.machineMode()
        await waitForBluetoothConnected(machine, true)
        XCTAssertEqual(harness.central.connectCount, 4)
        await bluetooth.disconnect()
        await waitForBluetoothConnected(machine, false)

        // A machine created while the client is already connected starts from the client's state
        // (no event will come for a link that is already up), then follows it like the first.
        enqueueAcceptingLink(harness)
        _ = try await bluetooth.machineMode()
        await waitForBluetoothConnected(machine, true)
        let late = LaMarzoccoMachine(serialNumber: BluetoothMachineHarness.serial, client: nil, bluetooth: bluetooth)
        XCTAssertFalse(late.isBluetoothConnected)
        await waitForBluetoothConnected(late, true)
        await bluetooth.disconnect()
        await waitForBluetoothConnected(late, false)
        await waitForBluetoothConnected(machine, false)
        XCTAssertEqual(harness.central.connectCount, 5)
    }

    /// Angstrom-only: G-DEV-9 — a machine created on a *disconnected* client is seeded `false` from the
    /// client's `isConnected` and stays `false` until a connection event (the counterpart of the
    /// already-connected `late` machine above).
    ///
    /// The default is already `false`, so the test first sets the property to `true` synchronously,
    /// before the observation task can run: with no client activity, only the seed can bring it back
    /// to `false`, which makes the seed's value observable (a seed that ignored the client, or was
    /// skipped, leaves it `true`).
    func testIsBluetoothConnectedSeedsFalseFromDisconnectedClient() async throws {
        let harness = BluetoothMachineHarness(cloud: false, bluetooth: true, settingResponses: modeResponses)
        let bluetooth = try XCTUnwrap(harness.bluetooth)

        let machine = LaMarzoccoMachine(serialNumber: BluetoothMachineHarness.serial, client: nil,
                                        bluetooth: bluetooth)
        XCTAssertNotNil(machine.bluetoothConnectionTask)
        XCTAssertFalse(machine.isBluetoothConnected)
        machine.isBluetoothConnected = true   // no suspension since `init`: the task has not run yet

        // The seed reads the disconnected client and writes `false`.
        await waitForBluetoothConnected(machine, false)
        let clientConnected = await bluetooth.isConnected
        XCTAssertFalse(clientConnected)
        XCTAssertEqual(harness.central.connectCount, 0, "nothing connected the client")

        // It stays `false` with no event (a client round trip later), then follows the client's events.
        _ = await bluetooth.isConnected
        XCTAssertFalse(machine.isBluetoothConnected)
        _ = try await bluetooth.machineMode()
        await waitForBluetoothConnected(machine, true)
        await bluetooth.disconnect()
        await waitForBluetoothConnected(machine, false)
        XCTAssertEqual(harness.central.connectCount, 1)
    }

    // MARK: - Lifetime

    /// Angstrom-only: §6.16 — the observation holds the machine weakly: a dropped machine deallocates,
    /// and its observation task ends at the client's next connection event while other observers go on.
    func testObservationStopsWhenMachineDeallocates() async throws {
        let harness = BluetoothMachineHarness(cloud: false, bluetooth: true, settingResponses: modeResponses)
        let bluetooth = try XCTUnwrap(harness.bluetooth)

        var machine: LaMarzoccoMachine? = LaMarzoccoMachine(serialNumber: BluetoothMachineHarness.serial,
                                                            client: nil, bluetooth: bluetooth)
        let task = try XCTUnwrap(machine?.bluetoothConnectionTask)

        // The observation is registered and live once it reports the connection.
        _ = try await bluetooth.machineMode()
        await waitForBluetoothConnected(try XCTUnwrap(machine), true)
        await waitForBluetoothConnected(harness.machine, true)

        weak var weakMachine: LaMarzoccoMachine?
        weakMachine = machine
        machine = nil
        XCTAssertNil(weakMachine, "the observation task must not keep the machine alive")
        XCTAssertFalse(task.isCancelled)

        // The next event ends the orphaned task; the harness machine still follows it.
        await bluetooth.disconnect()
        let ended = expectation(description: "observation task ended")
        Task {
            await task.value
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: hangGuard)
        await waitForBluetoothConnected(harness.machine, false)
    }

    /// Angstrom-only: §5.5 (Lifetime) — the long-lived observation holds only the stream, never the
    /// client: releasing a machine and its never-connected client releases both, whether the observation
    /// has already registered and seeded (parked on the stream) or has not run yet.
    ///
    /// Does not rely on the client finishing its listener streams in `deinit`: the parked task may stay
    /// suspended on its orphaned stream, which must not keep either object alive.
    func testReleasingMachineAndClientReleasesBoth() async throws {
        // Observation registered and seeded, parked in `for await` on a client with no link.
        do {
            let (weakMachine, weakClient, central) = try await makeReleasedMachineAndClient(parked: true)
            await waitUntilReleased { weakMachine.value == nil && weakClient.value == nil }
            XCTAssertNil(weakMachine.value, "the machine must deallocate")
            XCTAssertNil(weakClient.value, "the observation task must not keep the client alive")
            XCTAssertEqual(central.connectCount, 0, "the client was never connected")
        }
        // Released before the observation task first runs.
        do {
            let (weakMachine, weakClient, central) = try await makeReleasedMachineAndClient(parked: false)
            await waitUntilReleased { weakMachine.value == nil && weakClient.value == nil }
            XCTAssertNil(weakMachine.value, "the machine must deallocate")
            XCTAssertNil(weakClient.value, "the observation task must not keep the client alive")
            XCTAssertEqual(central.connectCount, 0, "the client was never connected")
        }
    }

    // MARK: - Helpers

    /// A weak reference box, so references can be handed out of a scope.
    private final class Weak<Object: AnyObject> {
        weak var value: Object?
        init(_ value: Object) { self.value = value }
    }

    /// Build a fake-central-backed client and a machine on it, optionally wait until the observation has
    /// registered and seeded, then drop every strong reference and return weak ones (plus the central).
    private func makeReleasedMachineAndClient(parked: Bool) async throws
        -> (Weak<LaMarzoccoMachine>, Weak<LaMarzoccoBluetoothClient>, FakeBluetoothCentral) {
        let central = FakeBluetoothCentral()   // nothing connects: no link is ever made
        var client: LaMarzoccoBluetoothClient? = LaMarzoccoBluetoothClient(
            transport: .fake(central, sleeper: ManualBluetoothSleeper(manual: [.idleDisconnect])),
            peripheral: .fake, token: BluetoothAuthToken("token"))
        var machine: LaMarzoccoMachine? = LaMarzoccoMachine(serialNumber: BluetoothMachineHarness.serial,
                                                            client: nil, bluetooth: client)
        let weakMachine = Weak(try XCTUnwrap(machine))
        let weakClient = Weak(try XCTUnwrap(client))
        XCTAssertNotNil(machine?.bluetoothConnectionTask)

        if parked {
            // Only the seed can bring the property back to `false` (no client activity): once it has,
            // the observation is registered, seeded and parked on the stream.
            let observed = try XCTUnwrap(machine)
            observed.isBluetoothConnected = true
            await waitForBluetoothConnected(observed, false)
        }

        machine = nil
        client = nil
        return (weakMachine, weakClient, central)
    }

    /// Bounded wait without wall-clock sleeps: yield (letting pending tasks and actor jobs run) until
    /// `released()` holds or the yield budget is spent; the caller asserts afterwards.
    private func waitUntilReleased(_ released: () -> Bool) async {
        for _ in 0..<1_000 where !released() {
            await Task.yield()
        }
    }

    /// Queue one link whose scripted machine accepts the client's token `"token"`.
    private func enqueueAcceptingLink(_ harness: BluetoothMachineHarness) {
        harness.central.enqueueConnect(.success(.laMarzocco(token: "token", settingResponses: modeResponses)))
    }

    /// Wait (observation-driven) until `machine.isBluetoothConnected == expected`.
    private func waitForBluetoothConnected(_ machine: LaMarzoccoMachine, _ expected: Bool,
                                           file: StaticString = #filePath, line: UInt = #line) async {
        guard machine.isBluetoothConnected != expected else { return }
        let reached = expectation(description: "isBluetoothConnected == \(expected)")
        Self.observeBluetoothConnected(machine, expected, reached)
        await fulfillment(of: [reached], timeout: hangGuard)
        XCTAssertEqual(machine.isBluetoothConnected, expected, file: file, line: line)
    }

    /// `onChange` fires in `willSet`; the check runs in a later MainActor job, after the write.
    private static func observeBluetoothConnected(_ machine: LaMarzoccoMachine, _ expected: Bool,
                                           _ reached: XCTestExpectation) {
        withObservationTracking {
            _ = machine.isBluetoothConnected
        } onChange: { [weak machine] in
            Task { @MainActor [weak machine] in
                guard let machine else { return }
                if machine.isBluetoothConnected == expected {
                    reached.fulfill()
                } else {
                    observeBluetoothConnected(machine, expected, reached)
                }
            }
        }
    }

    /// Every element of `stream` until it finishes (an unfinished stream fails after the hang guard).
    private func collectUntilFinished(_ stream: AsyncStream<ConnectionEvent>) async -> [ConnectionEvent] {
        let finished = expectation(description: "stream finished")
        let task = Task { () -> [ConnectionEvent] in
            var events: [ConnectionEvent] = []
            for await event in stream {
                events.append(event)
            }
            finished.fulfill()
            return events
        }
        await fulfillment(of: [finished], timeout: hangGuard)
        task.cancel()
        return await task.value
    }

    /// The first `count` elements of `stream` (fewer, and a failure, if they do not arrive in time).
    private func prefixEvents(_ stream: AsyncStream<ConnectionEvent>, count: Int) async -> [ConnectionEvent] {
        let received = expectation(description: "\(count) connection events")
        let task = Task { () -> [ConnectionEvent] in
            var events: [ConnectionEvent] = []
            for await event in stream {
                events.append(event)
                if events.count == count {
                    received.fulfill()
                    break
                }
            }
            return events
        }
        await fulfillment(of: [received], timeout: hangGuard)
        task.cancel()
        return await task.value
    }
}
