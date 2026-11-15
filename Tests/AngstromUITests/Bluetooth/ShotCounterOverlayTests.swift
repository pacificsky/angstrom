import XCTest
import Observation
import os
@testable import Angstrom
@testable import AngstromUI
import AngstromTestSupport

/// The AngstromUI shot counter: start/stop, the BLE brewing overlay on `CMMachineStatus` (base +
/// render, D12), the telemetry merge, the 60 s brewing-state expiry and `bluetoothEvents()`
/// (SPEC §4.19, vectors BT-OVL-001 and D7–D13 of §9.3.8).
///
/// The Bluetooth client is the real `LaMarzoccoBluetoothClient` over the harness fakes. Where upstream
/// calls the client's callbacks directly (`on_update(_brewing_update(…))`), these tests emit the same
/// `ShotCounterEvent` through the client's own shot-counter stream (`emitShotCounter`), so every event
/// reaches the machine through the listener `startShotCounter()` installed. The expiry runs on a
/// gate-controlled sleep (`setBluetoothBrewingExpiryForTesting`), the stand-in for upstream's
/// `FakeTimer`; cloud pushes go through the existing `MockWebSocketChannel`.
@MainActor
final class ShotCounterOverlayTests: XCTestCase {
    private let shotCounter = BluetoothConstants.shotCounterCharacteristic
    /// Hang guard only (PLAN §3.5).
    private let hangGuard: TimeInterval = 5
    /// `BLE_BREWING_STATE_TIMEOUT = 60` (`src/pylamarzocco/devices/_machine.py:88`).
    private let brewingStateTimeout: Duration = .seconds(60)
    /// `received_at` of upstream's `_brewing_update`: 2026-01-01T12:00:00Z.
    private let receivedAt = Date(timeIntervalSince1970: 1_767_268_800)
    /// `cloud_start`: 2026-01-01T11:00:00Z.
    private let cloudStart = Date(timeIntervalSince1970: 1_767_265_200)

    // MARK: - Parity

    /// Upstream: test_connect_bluetooth_shot_counter (tests/test_machine.py:745) [M14]
    func testStartIgnoresCloudSupportFlag() async throws {
        let harness = BluetoothMachineHarness()
        let machine = harness.machine
        let client = try XCTUnwrap(harness.bluetooth)
        XCTAssertEqual(machine.dashboard?.machine.shotCounterSupported, false)

        // The machine's listener must already be registered when the client subscribes (and emits
        // `.subscribed`): count the client's shot-counter listeners at the subscribe.
        let listenersAtSubscribe = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let makeLink = harness.central.makeLink
        harness.central.makeLink = { [shotCounter] in
            let link = makeLink()
            link.beforeOp = { op in
                guard op == .subscribe(shotCounter) else { return }
                let count = await client.shotCounterListeners.count
                listenersAtSubscribe.withLock { $0.append(count) }
            }
            return link
        }

        let started = try await machine.startShotCounter()
        XCTAssertTrue(started)
        XCTAssertEqual(listenersAtSubscribe.withLock { $0 }, [1])
        XCTAssertEqual(harness.links.count, 1)
        XCTAssertEqual(harness.links[0].recordedOps.filter { $0 == .subscribe(shotCounter) }.count, 1)
        XCTAssertTrue(machine.isShotCounterActive)
        let clientActive = await client.shotCounterActive
        XCTAssertTrue(clientActive)
        XCTAssertNotNil(machine.shotCounterTask)

        // The machine has no shot counter (the characteristic is missing, also after rediscovery):
        // false, and no listener is left behind.
        let unsupported = BluetoothMachineHarness()
        let missing = unsupported.central.makeLink
        unsupported.central.makeLink = { [shotCounter] in
            let link = missing()
            link.present.remove(shotCounter)
            link.presentAfterRefresh = link.present
            return link
        }
        let unsupportedStarted = try await unsupported.machine.startShotCounter()
        XCTAssertFalse(unsupportedStarted)
        XCTAssertFalse(unsupported.machine.isShotCounterActive)
        XCTAssertNil(unsupported.machine.shotCounterTask)
        XCTAssertTrue(unsupported.links.allSatisfy { !$0.recordedOps.contains(.subscribe(shotCounter)) })

        // A start that fails to connect rethrows and leaves no listener behind.
        let failing = BluetoothMachineHarness(failure: .connect)
        do {
            try await failing.machine.startShotCounter()
            XCTFail("expected the connect failure to be rethrown")
        } catch let error as LaMarzoccoError {
            guard case .bluetoothConnectionFailed = error else {
                return XCTFail("expected .bluetoothConnectionFailed, got \(error)")
            }
        }
        XCTAssertFalse(failing.machine.isShotCounterActive)
        XCTAssertNil(failing.machine.shotCounterTask)

        // Without a Bluetooth client: false.
        let cloudOnly = BluetoothMachineHarness(bluetooth: false)
        let cloudOnlyStarted = try await cloudOnly.machine.startShotCounter()
        XCTAssertFalse(cloudOnlyStarted)
        XCTAssertNil(cloudOnly.machine.shotCounterTask)
        XCTAssertFalse(cloudOnly.machine.isShotCounterActive)

        await machine.stopShotCounter()
    }

    /// Upstream: test_shot_counter_overrides_machine_status (tests/test_machine.py:784) [M16, BT-OVL-001]
    func testOverrideLifecycle() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn, cloudStart))
        let machine = rig.machine
        let channel = MockWebSocketChannel()
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in channel }
        channel.push(Stomp.encode(.connected, headers: [("version", "1.2")]))
        try await machine.start()

        // Step 1: `.brewing(timer 12.5)` → brewing, start 11:59:47.5Z.
        let brewing = update(.brewing, timer: 12.5)
        try await rig.deliver(.brewing(brewing))
        XCTAssertEqual(rig.log.events, [.brewing(brewing)])
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)
        XCTAssertEqual(machine.dashboard?.machineStatus?.brewingStartTime,
                       Date(timeIntervalSince1970: 1_767_268_787.5))
        // The read rule: the base keeps the cloud values.
        XCTAssertEqual(machine.baseDashboard?.machineStatus, machineStatus(.poweredOn, cloudStart))

        // Step 2: `.brewingStopped(final 27.4)` → poweredOn with the cloud start time.
        try await rig.deliver(.brewing(update(.brewingStopped, final: 27.4)))
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .poweredOn)
        XCTAssertEqual(machine.dashboard?.machineStatus?.brewingStartTime, cloudStart)
        XCTAssertEqual(machine.lastShotTime, 27.4)

        // Step 3: a late cloud "Brewing" after the BLE stop is overridden.
        channel.push(pushFrame(status: "Brewing", brewingStartTime: cloudStart))
        try await awaitState("late Brewing push merged") { machine.baseDashboard?.machineStatus?.status == .brewing }
        XCTAssertEqual(machine.baseDashboard?.machineStatus, machineStatus(.brewing, cloudStart))
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .poweredOn)
        XCTAssertEqual(machine.dashboard?.machineStatus?.brewingStartTime, cloudStart)

        // Step 4: flushes keep non-brewing cloud states.
        channel.push(pushFrame(status: "StandBy", brewingStartTime: nil))
        try await awaitState("StandBy push merged") { machine.baseDashboard?.machineStatus?.status == .standby }
        try await rig.deliver(.brewing(update(.flushed)))
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .standby)
        XCTAssertEqual(machine.lastShotTime, 27.4)

        // Step 5: brewing again.
        let again = update(.brewing, timer: 1)
        try await rig.deliver(.brewing(again))
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)

        // Step 6: losing the connection restores the cloud state and notifies `.brewingCleared`.
        try await rig.deliver(.unsubscribed)
        XCTAssertEqual(rig.log.events.last, .brewingCleared)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .standby)
        XCTAssertNil(machine.dashboard?.machineStatus?.brewingStartTime)
        XCTAssertNil(machine.bluetoothBrewingUpdate)
        XCTAssertEqual(rig.log.events, [
            .brewing(brewing),
            .brewing(update(.brewingStopped, final: 27.4)),
            .brewing(update(.flushed)),
            .brewing(again),
            .brewingCleared,
        ])

        await machine.stop()
        await rig.finish()
    }

    /// Upstream: test_shot_counter_falls_back_to_websocket_callback (tests/test_machine.py:835) [M17]
    ///
    /// Restated (D13): there is no websocket update callback; a brewing update re-renders the
    /// observable `dashboard`, with no `bluetoothEvents()` listener at all.
    func testBrewingUpdateRendersObservableDashboard() async throws {
        let harness = BluetoothMachineHarness(seed: .custom(dashboard(status: machineStatus(.poweredOn))))
        let machine = harness.machine
        let started = try await machine.startShotCounter()
        XCTAssertTrue(started)
        XCTAssertTrue(machine.bluetoothEventListeners.isEmpty)

        // A real notification through the link (the subscribe replay was already dropped).
        let link = try XCTUnwrap(harness.links.last)
        link.notify(shotCounter, BluetoothTestVectors.tick("3"), at: receivedAt)
        try await awaitState("the observable dashboard shows the shot") {
            machine.dashboard?.machineStatus?.status == .brewing
        }
        XCTAssertEqual(machine.bluetoothBrewingUpdate?.state, .brewing)
        XCTAssertEqual(machine.bluetoothBrewingUpdate?.timerValue, 3)
        XCTAssertEqual(machine.dashboard?.machineStatus?.brewingStartTime, receivedAt.addingTimeInterval(-3))
        XCTAssertEqual(machine.baseDashboard?.machineStatus, machineStatus(.poweredOn))

        await machine.stopShotCounter()
    }

    /// Upstream: test_disconnect_bluetooth_shot_counter (tests/test_machine.py:853) [M18, §9.3.8 D7]
    func testStopRestoresSilently() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn))
        let machine = rig.machine
        let client = try XCTUnwrap(rig.harness.bluetooth)
        let link = try XCTUnwrap(rig.harness.links.last)

        try await rig.deliver(.brewing(update(.brewing, timer: 3)))
        try await rig.deliver(.telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 93)))
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)
        try await rig.waitForExpirySleeps(1)
        let listener = try XCTUnwrap(machine.shotCounterTask)

        await machine.stopShotCounter()
        // The listener ended: whatever it handled has been emitted.
        let ended = XCTestExpectation(description: "the shot-counter listener ended")
        Task {
            await listener.value
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: hangGuard)

        // Like the client, the stop unsubscribed once; nothing reached `bluetoothEvents()`.
        XCTAssertEqual(link.recordedOps.filter { $0 == .unsubscribe(shotCounter) }.count, 1)
        let clientActive = await client.shotCounterActive
        XCTAssertFalse(clientActive)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .poweredOn)
        XCTAssertEqual(machine.dashboard, machine.baseDashboard)
        XCTAssertNil(machine.bluetoothBrewingUpdate)
        XCTAssertEqual(machine.bluetoothTelemetry, BluetoothMachineTelemetry())
        XCTAssertFalse(machine.isShotCounterActive)
        XCTAssertNil(machine.brewingExpiryTask)
        XCTAssertNil(machine.shotCounterTask)
        XCTAssertEqual(rig.gate.cancelled, [true])

        // A sentinel proves no `.brewingCleared` was emitted by the stop (events are ordered).
        let sentinel = BluetoothMachineTelemetry(sleep: "sentinel")
        machine.handleShotCounterEvent(.telemetry(sentinel))
        try await rig.waitForEvents(3)
        XCTAssertEqual(rig.log.events, [
            .brewing(update(.brewing, timer: 3)),
            .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 93)),
            .telemetry(sentinel),
        ])
        rig.log.cancel()
    }

    /// Upstream: test_shot_counter_state_expires (tests/test_machine.py:882) [M19, §9.3.8 D8]
    func testStaleStateExpiresAfter60s() async throws {
        // The default timeout is BLE_BREWING_STATE_TIMEOUT.
        XCTAssertEqual(BluetoothMachineHarness().machine.bluetoothBrewingStateTimeout, .seconds(60))

        let rig = try await makeRig(status: machineStatus(.poweredOn))
        let machine = rig.machine

        try await rig.deliver(.brewing(update(.brewing, timer: 3)))
        try await rig.waitForExpirySleeps(1)
        XCTAssertEqual(rig.gate.cancelled, [false])

        // A new notification extends the lifetime.
        try await rig.deliver(.brewing(update(.brewing, timer: 4)))
        try await rig.waitForExpirySleeps(2)
        XCTAssertEqual(rig.gate.cancelled, [true, false])
        XCTAssertEqual(rig.gate.durations, [brewingStateTimeout, brewingStateTimeout])
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)

        rig.gate.fire(1)
        try await rig.waitForEvents(3)
        XCTAssertEqual(rig.log.events, [
            .brewing(update(.brewing, timer: 3)),
            .brewing(update(.brewing, timer: 4)),
            .brewingCleared,
        ])
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .poweredOn)
        XCTAssertEqual(machine.dashboard, machine.baseDashboard)
        XCTAssertNil(machine.bluetoothBrewingUpdate)
        XCTAssertNil(machine.brewingExpiryTask)

        // The shot counter keeps running; the next brewing update re-applies the overlay.
        XCTAssertTrue(machine.isShotCounterActive)
        try await rig.deliver(.brewing(update(.brewing, timer: 5)))
        try await rig.waitForExpirySleeps(3)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)
        XCTAssertEqual(rig.gate.cancelled, [true, false, false])

        await rig.finish()
    }

    /// Upstream: test_bluetooth_refresh_after_shot_replaces_cloud_status (tests/test_machine.py:917) [M20, §9.3.8 D9]
    func testBluetoothRefreshBecomesBaseline() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn))
        let machine = rig.machine
        try await rig.deliver(.brewing(update(.brewing, timer: 3)))
        try await rig.deliver(.brewing(update(.brewingStopped, final: 27.4)))
        try await rig.waitForExpirySleeps(2)

        // The machine is put in standby and the dashboard is refreshed over Bluetooth (§4.17 step 6).
        let state = BluetoothDashboardState(machineMode: .standby, isPlumbedIn: false, tankStatus: true, boilers: [])
        machine.updateBaseDashboard { $0.applyingBluetoothState(state, model: .lineaMicra) }
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .standby)

        rig.gate.fire(1)
        try await rig.waitForEvents(3)
        XCTAssertEqual(rig.log.events.last, .brewingCleared)
        XCTAssertNil(machine.bluetoothBrewingUpdate)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .standby)
        XCTAssertEqual(machine.baseDashboard?.machineStatus?.status, .standby)

        await rig.finish()
    }

    /// Upstream: test_bluetooth_refresh_while_brewing_keeps_cloud_start_time (tests/test_machine.py:940) [M21, §9.3.8 D10]
    func testBluetoothRefreshKeepsCloudStartTime() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn, cloudStart))
        let machine = rig.machine
        try await rig.deliver(.brewing(update(.brewing, timer: 3)))

        let state = BluetoothDashboardState(machineMode: .brewing, isPlumbedIn: false, tankStatus: true, boilers: [])
        machine.updateBaseDashboard { $0.applyingBluetoothState(state, model: .lineaMicra) }
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)
        XCTAssertEqual(machine.dashboard?.machineStatus?.brewingStartTime, receivedAt.addingTimeInterval(-3))

        try await rig.deliver(.brewing(update(.brewingStopped, final: 27.4)))
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .poweredOn)
        XCTAssertEqual(machine.dashboard?.machineStatus?.brewingStartTime, cloudStart)

        await machine.stopShotCounter()
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .poweredOn)
        XCTAssertEqual(machine.dashboard?.machineStatus?.brewingStartTime, cloudStart)
        rig.log.cancel()
    }

    /// Upstream: test_bluetooth_telemetry (tests/test_machine.py:961) [M22, §9.3.8 D12]
    func testTelemetryMergeAndModeApply() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn))
        let machine = rig.machine

        let steam = BluetoothMachineTelemetry(steamBoilerTemperature: 130)
        try await rig.deliver(.telemetry(steam))
        XCTAssertEqual(rig.log.events, [.telemetry(steam)])
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .brewing)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .poweredOn)

        let standby = BluetoothMachineTelemetry(machineMode: .standby, sleep: "command")
        try await rig.deliver(.telemetry(standby))
        // Only telemetry events: no brewing update was reported.
        XCTAssertEqual(rig.log.events, [.telemetry(steam), .telemetry(standby)])
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .standby)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .standby)
        XCTAssertEqual(machine.baseDashboard?.machineStatus?.mode, .standby)
        XCTAssertEqual(machine.baseDashboard?.machineStatus?.status, .standby)
        XCTAssertEqual(machine.bluetoothTelemetry,
                       BluetoothMachineTelemetry(steamBoilerTemperature: 130, machineMode: .standby, sleep: "command"))
        // Telemetry never arms the expiry.
        XCTAssertNil(machine.brewingExpiryTask)
        XCTAssertEqual(rig.gate.durations, [])

        // The live values are dropped with the connection.
        try await rig.deliver(.unsubscribed)
        XCTAssertEqual(machine.bluetoothTelemetry, BluetoothMachineTelemetry())
        XCTAssertEqual(rig.log.events, [.telemetry(steam), .telemetry(standby), .brewingCleared])
        XCTAssertFalse(machine.isShotCounterActive)

        await rig.finish()
    }

    /// Upstream: test_bluetooth_machine_mode_during_shot (tests/test_machine.py:995) [M23, §9.3.8 D13]
    func testModeDuringShotAppliedAfterShot() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn))
        let machine = rig.machine

        try await rig.deliver(.brewing(update(.brewing, timer: 3)))
        try await rig.deliver(.telemetry(BluetoothMachineTelemetry(machineMode: .eco)))
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)
        XCTAssertEqual(machine.baseDashboard?.machineStatus?.status, .eco)

        try await rig.deliver(.brewing(update(.flushed)))
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .eco)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .eco)

        await rig.finish()
    }

    /// Upstream: test_bluetooth_machine_mode_falls_back_to_websocket_callback (tests/test_machine.py:1014) [M24]
    ///
    /// Restated (D13): no dashboard callback; a temperature-only notification leaves the observable
    /// dashboard untouched, a machine mode changes it.
    func testTemperatureTelemetryDoesNotChangeDashboard() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn))
        let machine = rig.machine
        let before = machine.dashboard

        let quiet = Self.trackDashboardWrites(machine)
        try await rig.deliver(.telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 93)))
        XCTAssertFalse(quiet.withLock { $0 }, "a temperature-only notification must not write the dashboard")
        XCTAssertEqual(machine.dashboard, before)
        XCTAssertEqual(machine.bluetoothTelemetry, BluetoothMachineTelemetry(coffeeBoilerTemperature: 93))

        let written = Self.trackDashboardWrites(machine)
        try await rig.deliver(.telemetry(BluetoothMachineTelemetry(machineMode: .standby)))
        XCTAssertTrue(written.withLock { $0 })
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .standby)

        await rig.finish()
    }

    /// Upstream: test_bluetooth_shot_counter_active (tests/test_machine.py:1036) [M25]
    func testShotCounterActiveMirrorsClient() async throws {
        let harness = BluetoothMachineHarness()
        let machine = harness.machine
        let client = try XCTUnwrap(harness.bluetooth)
        let log = EventLog(machine.bluetoothEvents())
        XCTAssertFalse(machine.isShotCounterActive)

        let started = try await machine.startShotCounter()
        XCTAssertTrue(started)
        var clientActive = await client.shotCounterActive
        XCTAssertTrue(clientActive)
        XCTAssertTrue(machine.isShotCounterActive)

        // The link drops: the client reports `.unsubscribed`, the machine follows. The reconnect's
        // subscribe is held until the loss was observed.
        let resubscribe = Latch()
        let makeLink = harness.central.makeLink
        harness.central.makeLink = { [shotCounter] in
            let link = makeLink()
            link.beforeOp = { op in
                if op == .subscribe(shotCounter) { await resubscribe.wait() }
            }
            return link
        }
        try XCTUnwrap(harness.links.first).drop(nil)
        await fulfillment(of: [log.expectation(count: 1)], timeout: hangGuard)
        XCTAssertEqual(log.events, [.brewingCleared])
        XCTAssertFalse(machine.isShotCounterActive)

        // The reconnect loop subscribes again: `.subscribed`, the machine follows.
        resubscribe.release()
        try await awaitState("resubscribed") { machine.isShotCounterActive }
        clientActive = await client.shotCounterActive
        XCTAssertTrue(clientActive)
        XCTAssertEqual(harness.links.count, 2)

        await machine.stopShotCounter()
        clientActive = await client.shotCounterActive
        XCTAssertFalse(clientActive)
        XCTAssertFalse(machine.isShotCounterActive)

        // Without a Bluetooth client, never active.
        XCTAssertFalse(BluetoothMachineHarness(bluetooth: false).machine.isShotCounterActive)
        log.cancel()
    }

    /// Upstream: test_machine_stop_from_update_callback (tests/test_bluetooth_client.py:1156) [C39]
    ///
    /// Restated (D4): a `bluetoothEvents()` consumer that stops the shot counter on every event stops
    /// it once, without recursion or deadlock.
    func testStopFromEventConsumerDoesNotRecurse() async throws {
        let harness = BluetoothMachineHarness(seed: .none, cloud: false)
        let machine = harness.machine
        let client = try XCTUnwrap(harness.bluetooth)
        let consumer = StoppingConsumer()
        let stream = machine.bluetoothEvents()
        let stopped = XCTestExpectation(description: "the consumer's stop returned")
        let task = Task { @MainActor in
            for await event in stream {
                consumer.received.append(event)
                if case .telemetry = event { return }
                consumer.stops += 1
                await machine.stopShotCounter()
                stopped.fulfill()
            }
        }

        let started = try await machine.startShotCounter()
        XCTAssertTrue(started)
        let link = try XCTUnwrap(harness.links.last)
        link.notify(shotCounter, BluetoothTestVectors.started, at: receivedAt)
        await fulfillment(of: [stopped], timeout: hangGuard)

        XCTAssertEqual(consumer.stops, 1)
        let clientActive = await client.shotCounterActive
        XCTAssertFalse(clientActive)
        XCTAssertFalse(machine.isShotCounterActive)
        XCTAssertEqual(link.recordedOps.filter { $0 == .unsubscribe(shotCounter) }.count, 1)

        // Ends the consumer; anything the stop emitted would be ordered before it.
        let sentinel = BluetoothMachineTelemetry(sleep: "sentinel")
        machine.handleShotCounterEvent(.telemetry(sentinel))
        await task.value
        XCTAssertEqual(consumer.received.count, 2)
        guard case .brewing(let first) = consumer.received.first else {
            return XCTFail("expected the brewing update first, got \(consumer.received)")
        }
        XCTAssertEqual(first.state, .brewing)
        XCTAssertEqual(first.startedDoseIndex, "DoseA")
        XCTAssertEqual(consumer.received.last, .telemetry(sentinel))
        XCTAssertEqual(consumer.stops, 1)
    }

    // MARK: - Angstrom-only

    /// Angstrom-only: G-DEV-5 — a REST `refreshDashboard()` during an active overlay re-applies the overlay to the fresh widget
    func testRestRefreshReappliesOverlay() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn, cloudStart))
        let machine = rig.machine
        let brewing = update(.brewing, timer: 3)
        try await rig.deliver(.brewing(brewing))

        let returned = try await machine.refreshDashboard()
        // The base is the REST fixture (dashboard_micra: StandBy, no start time)…
        let fixtureStatus = MachineStatus(status: .standby, availableModes: [.brewing, .standby], mode: .standby,
                                          nextStatus: nil, brewingStartTime: nil)
        XCTAssertEqual(machine.baseDashboard?.machineStatus, fixtureStatus)
        // …and the overlay is applied over it.
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)
        XCTAssertEqual(machine.dashboard?.machineStatus?.brewingStartTime, receivedAt.addingTimeInterval(-3))
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .standby)
        XCTAssertEqual(returned, machine.dashboard)
        XCTAssertEqual(machine.bluetoothBrewingUpdate, brewing)

        try await rig.waitForExpirySleeps(1)
        rig.gate.fire(0)
        try await rig.waitForEvents(2)
        XCTAssertEqual(machine.dashboard, machine.baseDashboard)
        XCTAssertEqual(machine.dashboard?.machineStatus, fixtureStatus)

        await rig.finish()
    }

    /// Angstrom-only: G-DEV-6 — `.subscribed` (after a reconnect) does not clear the overlay; only the expiry or a loss does
    func testResubscribeKeepsOverlayUntilExpiry() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn))
        let machine = rig.machine
        let brewing = update(.brewing, timer: 3)
        try await rig.deliver(.brewing(brewing))
        try await rig.waitForExpirySleeps(1)

        // As after a loss, then a resubscribe.
        machine.isShotCounterActive = false
        try await rig.deliver(.subscribed, emits: 0)
        // A telemetry sentinel orders after `.subscribed` and touches neither the overlay nor the expiry.
        let sentinel = BluetoothMachineTelemetry(coffeeBoilerTemperature: 94)
        try await rig.deliver(.telemetry(sentinel))
        XCTAssertTrue(machine.isShotCounterActive)
        XCTAssertEqual(machine.bluetoothBrewingUpdate, brewing)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)
        XCTAssertNotNil(machine.brewingExpiryTask)
        XCTAssertEqual(rig.gate.cancelled, [false])
        XCTAssertEqual(rig.log.events, [.brewing(brewing), .telemetry(sentinel)])

        // The expiry clears it.
        rig.gate.fire(0)
        try await rig.waitForEvents(3)
        XCTAssertEqual(rig.log.events.last, .brewingCleared)
        XCTAssertNil(machine.bluetoothBrewingUpdate)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .poweredOn)
        XCTAssertTrue(machine.isShotCounterActive)

        // And a loss clears a new one.
        try await rig.deliver(.brewing(brewing))
        try await rig.deliver(.unsubscribed)
        XCTAssertEqual(rig.log.events.last, .brewingCleared)
        XCTAssertNil(machine.bluetoothBrewingUpdate)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .poweredOn)

        await rig.finish()
    }

    /// Angstrom-only: G-DEV-7 — a telemetry machine mode also updates `CMMachineGroupStatus.mode`
    func testTelemetryModeUpdatesGroupWidget() async throws {
        let group = Widget(code: "CMMachineGroupStatus", index: 1, kind: .machineGroupStatus(machineStatus(.poweredOn)))
        let base = dashboard(status: machineStatus(.poweredOn))
        let seeded = Dashboard(machine: base.machine, widgets: base.widgets + [group])
        let rig = try await makeRig(seed: seeded)
        let machine = rig.machine

        try await rig.deliver(.telemetry(BluetoothMachineTelemetry(machineMode: .standby)))
        XCTAssertEqual(machine.dashboard?.machineGroupStatus?.mode, .standby)
        // Only `CMMachineStatus` takes the BLE machine state.
        XCTAssertEqual(machine.dashboard?.machineGroupStatus?.status, .poweredOn)
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .standby)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .standby)
        XCTAssertEqual(machine.baseDashboard?.machineGroupStatus?.mode, .standby)

        try await rig.deliver(.telemetry(BluetoothMachineTelemetry(machineMode: .eco)))
        XCTAssertEqual(machine.dashboard?.machineGroupStatus?.mode, .eco)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .eco)

        await rig.finish()
    }

    /// Angstrom-only: G-DEV-12 — device state is mutated before the `bluetoothEvents()` event is emitted
    ///
    /// Each observed property yields a marker into the same stream continuation the machine emits
    /// into, synchronously from its `willSet`; the stream's order is therefore the order of the
    /// mutations and the emission.
    func testStateMutatedBeforeEventEmitted() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn))
        let machine = rig.machine
        let id = UUID()
        let (stream, continuation) = AsyncStream<MachineBluetoothEvent>.makeStream()
        machine.bluetoothEventListeners[id] = continuation
        let order = EventLog(stream)
        var taken = 0

        // `.brewing`: the update and the rendered dashboard first.
        Self.mark(continuation, "bluetoothBrewingUpdate") { _ = machine.bluetoothBrewingUpdate }
        Self.mark(continuation, "dashboard") { _ = machine.dashboard }
        machine.handleShotCounterEvent(.brewing(update(.brewing, timer: 3)))
        var events = await take(3, from: order, after: &taken)
        XCTAssertEqual(Set(events.prefix(2).map(Self.markerName)), ["bluetoothBrewingUpdate", "dashboard"])
        XCTAssertEqual(events.last, .brewing(update(.brewing, timer: 3)))

        // A final shot time: the last shot time too.
        let stopped = update(.brewingStopped, final: 27.4)
        Self.mark(continuation, "bluetoothBrewingUpdate") { _ = machine.bluetoothBrewingUpdate }
        Self.mark(continuation, "lastShotTime") { _ = machine.lastShotTime }
        Self.mark(continuation, "dashboard") { _ = machine.dashboard }
        machine.handleShotCounterEvent(.brewing(stopped))
        events = await take(4, from: order, after: &taken)
        XCTAssertEqual(Set(events.prefix(3).map(Self.markerName)), ["bluetoothBrewingUpdate", "lastShotTime", "dashboard"])
        XCTAssertEqual(events.last, .brewing(stopped))

        // `.telemetry`: the merge and the mode first.
        let mode = BluetoothMachineTelemetry(machineMode: .standby)
        Self.mark(continuation, "bluetoothTelemetry") { _ = machine.bluetoothTelemetry }
        Self.mark(continuation, "baseDashboard") { _ = machine.baseDashboard }
        Self.mark(continuation, "dashboard") { _ = machine.dashboard }
        machine.handleShotCounterEvent(.telemetry(mode))
        events = await take(4, from: order, after: &taken)
        XCTAssertEqual(Set(events.prefix(3).map(Self.markerName)), ["bluetoothTelemetry", "baseDashboard", "dashboard"])
        XCTAssertEqual(events.last, .telemetry(mode))

        // `.unsubscribed`: active flag, telemetry, overlay and dashboard first. A running shot first, so
        // that clearing the overlay changes the rendered dashboard.
        machine.handleShotCounterEvent(.brewing(update(.brewing, timer: 2)))
        _ = await take(1, from: order, after: &taken)
        Self.mark(continuation, "isShotCounterActive") { _ = machine.isShotCounterActive }
        Self.mark(continuation, "bluetoothTelemetry") { _ = machine.bluetoothTelemetry }
        Self.mark(continuation, "bluetoothBrewingUpdate") { _ = machine.bluetoothBrewingUpdate }
        Self.mark(continuation, "dashboard") { _ = machine.dashboard }
        machine.handleShotCounterEvent(.unsubscribed)
        events = await take(5, from: order, after: &taken)
        XCTAssertEqual(Set(events.prefix(4).map(Self.markerName)),
                       ["isShotCounterActive", "bluetoothTelemetry", "bluetoothBrewingUpdate", "dashboard"])
        XCTAssertEqual(events.last, .brewingCleared)

        // The expiry: overlay and dashboard first.
        machine.handleShotCounterEvent(.brewing(update(.brewing, timer: 1)))
        _ = await take(1, from: order, after: &taken)
        try await rig.waitForExpirySleeps(4)
        Self.mark(continuation, "bluetoothBrewingUpdate") { _ = machine.bluetoothBrewingUpdate }
        Self.mark(continuation, "dashboard") { _ = machine.dashboard }
        rig.gate.fire(3)
        events = await take(3, from: order, after: &taken)
        XCTAssertEqual(Set(events.prefix(2).map(Self.markerName)), ["bluetoothBrewingUpdate", "dashboard"])
        XCTAssertEqual(events.last, .brewingCleared)

        // `.gaveUp`: active flag and last error first.
        machine.isShotCounterActive = true
        Self.mark(continuation, "isShotCounterActive") { _ = machine.isShotCounterActive }
        Self.mark(continuation, "lastError") { _ = machine.lastError }
        machine.handleShotCounterEvent(.gaveUp(.bluetoothAuthenticationFailed))
        events = await take(3, from: order, after: &taken)
        XCTAssertEqual(Set(events.prefix(2).map(Self.markerName)), ["isShotCounterActive", "lastError"])
        XCTAssertEqual(events.last, .shotCounterStopped(.bluetoothAuthenticationFailed))

        // Nothing beyond what was taken.
        XCTAssertEqual(order.events.count, taken)
        machine.bluetoothEventListeners[id] = nil
        continuation.finish()
        await rig.finish()
    }

    /// Angstrom-only: D15 — a reconnect that gives up surfaces `.shotCounterStopped`, sets `lastError` and stops listening
    func testGaveUpSurfacesShotCounterStopped() async throws {
        let harness = BluetoothMachineHarness()
        let machine = harness.machine
        let log = EventLog(machine.bluetoothEvents())
        let started = try await machine.startShotCounter()
        XCTAssertTrue(started)

        // Every reconnect attempt fails authentication: three cumulative failures give up (D15).
        let goodLink = harness.central.makeLink
        harness.central.makeLink = { FakeBluetoothLink.laMarzocco(token: "other") }
        try XCTUnwrap(harness.links.first).drop(nil)

        await fulfillment(of: [log.expectation(count: 2)], timeout: hangGuard)
        XCTAssertEqual(log.events, [.brewingCleared, .shotCounterStopped(.bluetoothAuthenticationFailed)])
        XCTAssertFalse(machine.isShotCounterActive)
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, .bluetoothAuthenticationFailed)
        XCTAssertNil(machine.shotCounterTask)
        XCTAssertEqual(harness.central.connectCount, 4)

        // No listener is left: a later start installs a new one and works.
        harness.central.makeLink = goodLink
        let restarted = try await machine.startShotCounter()
        XCTAssertTrue(restarted)
        XCTAssertTrue(machine.isShotCounterActive)
        XCTAssertNotNil(machine.shotCounterTask)

        await machine.stopShotCounter()
        log.cancel()
    }

    /// Angstrom-only: D12 — snapshots persist the base dashboard, never the overlay's `Brewing` or BLE start time
    func testSnapshotNeverPersistsOverlay() async throws {
        let base = machineStatus(.poweredOn, cloudStart)
        let rig = try await makeRig(status: base)
        let machine = rig.machine
        let seeded = machine.baseDashboard

        try await rig.deliver(.brewing(update(.brewing, timer: 12.5)))
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)
        XCTAssertEqual(machine.snapshot.dashboard, seeded)
        XCTAssertEqual(machine.snapshot.dashboard?.machineStatus, base)

        // Through persistence and back.
        let restored = try MachineSnapshot(data: machine.snapshot.encoded())
        XCTAssertEqual(restored.dashboard?.machineStatus?.status, .poweredOn)
        XCTAssertEqual(restored.dashboard?.machineStatus?.brewingStartTime, cloudStart)

        try await rig.deliver(.brewing(update(.brewingStopped, final: 27.4)))
        XCTAssertEqual(machine.snapshot.dashboard, seeded)

        await rig.finish()
    }

    /// Angstrom-only: §4.19 — a widget-less push during an active `.brewing` overlay keeps the base status; after the expiry the rendered and snapshot status equal the pre-shot base status
    func testWidgetlessPushDuringOverlayDoesNotLeakIntoBase() async throws {
        let preShot = machineStatus(.poweredOn, cloudStart)
        let rig = try await makeRig(status: preShot)
        let machine = rig.machine
        XCTAssertEqual(machine.baseDashboard?.machine.isConnected, false)
        let channel = MockWebSocketChannel()
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in channel }
        channel.push(Stomp.encode(.connected, headers: [("version", "1.2")]))
        try await machine.start()

        try await rig.deliver(.brewing(update(.brewing, timer: 12.5)))
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)

        channel.push(messageFrame(#"{ "connected": true, "removedWidgets": [], "commands": [], "widgets": [] }"#))
        try await awaitState("widget-less push merged") { machine.baseDashboard?.machine.isConnected == true }
        XCTAssertEqual(machine.baseDashboard?.machineStatus, preShot)
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing)
        XCTAssertEqual(machine.dashboard?.machine.isConnected, true)

        try await rig.waitForExpirySleeps(1)
        rig.gate.fire(0)
        try await rig.waitForEvents(2)
        XCTAssertEqual(rig.log.events.last, .brewingCleared)
        XCTAssertEqual(machine.dashboard?.machineStatus, preShot)
        XCTAssertEqual(machine.snapshot.dashboard?.machineStatus, preShot)
        XCTAssertEqual(machine.dashboard, machine.baseDashboard)

        await machine.stop()
        await rig.finish()
    }

    /// Angstrom-only: §4.19 — `lastShotTime` is set only by a final shot time and never reset (by updates, loss, expiry or stop)
    func testLastShotTimeNeverReset() async throws {
        let rig = try await makeRig(status: machineStatus(.poweredOn))
        let machine = rig.machine
        XCTAssertNil(machine.lastShotTime)

        try await rig.deliver(.brewing(update(.brewingStopped, final: 27.4)))
        XCTAssertEqual(machine.lastShotTime, 27.4)
        try await rig.deliver(.brewing(update(.brewing, timer: 1)))
        XCTAssertEqual(machine.lastShotTime, 27.4)
        try await rig.deliver(.brewing(update(.flushed)))
        XCTAssertEqual(machine.lastShotTime, 27.4)
        try await rig.deliver(.telemetry(BluetoothMachineTelemetry(machineMode: .standby)))
        XCTAssertEqual(machine.lastShotTime, 27.4)

        // Expiry.
        try await rig.waitForExpirySleeps(3)
        rig.gate.fire(2)
        try await rig.waitForEvents(5)
        XCTAssertEqual(rig.log.events.last, .brewingCleared)
        XCTAssertEqual(machine.lastShotTime, 27.4)

        // Loss.
        try await rig.deliver(.unsubscribed)
        XCTAssertEqual(machine.lastShotTime, 27.4)

        // Stop.
        await machine.stopShotCounter()
        XCTAssertEqual(machine.lastShotTime, 27.4)

        // A new final shot time replaces it.
        let restarted = try await machine.startShotCounter()
        XCTAssertTrue(restarted)
        try await rig.deliver(.brewing(update(.brewingStopped, final: 30.1)))
        XCTAssertEqual(machine.lastShotTime, 30.1)

        await rig.finish()
    }

    // MARK: - Helpers

    /// A started shot counter on a harness machine, with a gate-controlled expiry and an event log.
    @MainActor
    private final class Rig {
        let harness: BluetoothMachineHarness
        let gate: ExpiryGate
        let log: EventLog
        private let test: ShotCounterOverlayTests
        var machine: LaMarzoccoMachine { harness.machine }

        init(harness: BluetoothMachineHarness, gate: ExpiryGate, log: EventLog, test: ShotCounterOverlayTests) {
            self.harness = harness
            self.gate = gate
            self.log = log
            self.test = test
        }

        /// Emit `event` through the client's shot-counter stream and wait until the machine emitted
        /// `emits` more `bluetoothEvents()` events.
        func deliver(_ event: ShotCounterEvent, emits: Int = 1) async throws {
            let client = try XCTUnwrap(harness.bluetooth)
            let target = log.events.count + emits
            await client.emitShotCounter(event)
            try await waitForEvents(target)
        }

        func waitForEvents(_ count: Int) async throws {
            await test.fulfillment(of: [log.expectation(count: count)], timeout: test.hangGuard)
            XCTAssertEqual(log.events.count, count)
        }

        func waitForExpirySleeps(_ count: Int) async throws {
            let reached = XCTestExpectation(description: "\(count) expiry sleeps")
            let gate = self.gate
            Task {
                await gate.waitForSleeps(count)
                reached.fulfill()
            }
            await test.fulfillment(of: [reached], timeout: test.hangGuard)
        }

        func finish() async {
            await machine.stopShotCounter()
            log.cancel()
        }
    }

    private func makeRig(status: MachineStatus) async throws -> Rig {
        try await makeRig(seed: dashboard(status: status))
    }

    private func makeRig(seed: Dashboard) async throws -> Rig {
        let harness = BluetoothMachineHarness(seed: .custom(seed))
        let gate = ExpiryGate()
        harness.machine.setBluetoothBrewingExpiryForTesting(timeout: brewingStateTimeout) { try await gate.sleep($0) }
        let log = EventLog(harness.machine.bluetoothEvents())
        let started = try await harness.machine.startShotCounter()
        XCTAssertTrue(started)
        XCTAssertTrue(harness.machine.isShotCounterActive)
        return Rig(harness: harness, gate: gate, log: log, test: self)
    }

    /// upstream `machine_status(status, brewing_start_time)` (tests/conftest.py:60-72).
    private func machineStatus(_ status: MachineState, _ brewingStartTime: Date? = nil,
                               mode: MachineMode = .brewing) -> MachineStatus {
        MachineStatus(status: status, availableModes: [.brewing, .standby], mode: mode, nextStatus: nil,
                      brewingStartTime: brewingStartTime)
    }

    /// The BT-DASH-SEED-001 dashboard with its `CMMachineStatus` replaced by `status` (upstream sets
    /// `dashboard.config[CM_MACHINE_STATUS]`).
    private func dashboard(status: MachineStatus) -> Dashboard {
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)
        return seed.replacing(Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(status)))
    }

    /// upstream `_brewing_update(state, timer_value, final_shot_time)` (tests/test_machine.py:710-721).
    private func update(_ state: BluetoothBrewingState, timer: Double? = nil, final: Double? = nil) -> BluetoothShotCounterUpdate {
        BluetoothShotCounterUpdate(state: state, timerValue: timer, finalShotTime: final, receivedAt: receivedAt,
                                   raw: BluetoothBrewingData())
    }

    private func messageFrame(_ json: String) -> String {
        Stomp.encode(.message, headers: [("destination", "/ws/sn/\(BluetoothMachineHarness.serial)/dashboard")], body: json)
    }

    /// upstream `websocket_config(machine_status(status, start))` (tests/conftest.py:75-89).
    private func pushFrame(status: String, brewingStartTime: Date?) -> String {
        let start = brewingStartTime.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "null"
        return messageFrame("""
        { "connected": true, "removedWidgets": [], "commands": [],
          "widgets": [ { "code": "CMMachineStatus", "index": 1,
            "output": { "status": "\(status)", "availableModes": ["BrewingMode","StandBy"],
                        "mode": "BrewingMode", "nextStatus": null, "brewingStartTime": \(start) } } ] }
        """)
    }

    /// The next `count` events of `log` after the first `taken` (advances `taken`).
    private func take(_ count: Int, from log: EventLog, after taken: inout Int) async -> [MachineBluetoothEvent] {
        let target = taken + count
        await fulfillment(of: [log.expectation(count: target)], timeout: hangGuard)
        let events = Array(log.events[min(taken, log.events.count)..<min(target, log.events.count)])
        taken = target
        return events
    }

    /// Wait (by observation, no polling) until `predicate` holds.
    private func awaitState(_ description: String, _ predicate: @escaping @MainActor @Sendable () -> Bool) async throws {
        let reached = XCTestExpectation(description: description)
        Self.observe(reached, predicate)
        await fulfillment(of: [reached], timeout: hangGuard)
    }

    private static func observe(_ reached: XCTestExpectation, _ predicate: @escaping @MainActor @Sendable () -> Bool) {
        if predicate() {
            reached.fulfill()
            return
        }
        withObservationTracking {
            _ = predicate()
        } onChange: {
            Task { @MainActor in observe(reached, predicate) }
        }
    }

    /// A flag set (synchronously) on the next write to `dashboard` or `baseDashboard`.
    private static func trackDashboardWrites(_ machine: LaMarzoccoMachine) -> OSAllocatedUnfairLock<Bool> {
        let flag = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = machine.dashboard
            _ = machine.baseDashboard
        } onChange: {
            flag.withLock { $0 = true }
        }
        return flag
    }

    /// The marker yielded for a mutation of `property` (G-DEV-12).
    nonisolated private static func marker(_ property: String) -> MachineBluetoothEvent {
        .shotCounterStopped(.decoding("marker: \(property)"))
    }

    nonisolated private static func markerName(_ event: MachineBluetoothEvent) -> String? {
        guard case .shotCounterStopped(.decoding(let text)) = event, text.hasPrefix("marker: ") else { return nil }
        return String(text.dropFirst("marker: ".count))
    }

    /// Yield `marker(property)` into `continuation` synchronously on the next write to what `access` reads.
    private static func mark(_ continuation: AsyncStream<MachineBluetoothEvent>.Continuation, _ property: String,
                             _ access: () -> Void) {
        withObservationTracking(access) {
            continuation.yield(marker(property))
        }
    }
}

/// The gate-controlled expiry sleep (upstream's `FakeTimer`): records every requested duration and
/// whether that sleep was cancelled, and suspends until `fire` or cancellation.
private final class ExpiryGate: @unchecked Sendable {
    private struct Entry {
        let duration: Duration
        var cancelled = false
        var fired = false
        var continuation: CheckedContinuation<Void, any Error>?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var durations: [Duration] { lock.withLock { entries.map(\.duration) } }
    var cancelled: [Bool] { lock.withLock { entries.map(\.cancelled) } }

    func sleep(_ duration: Duration) async throws {
        let (index, ready): (Int, [CheckedContinuation<Void, Never>]) = lock.withLock {
            entries.append(Entry(duration: duration))
            let count = entries.count
            let ready = countWaiters.filter { $0.count <= count }.map(\.continuation)
            countWaiters.removeAll { $0.count <= count }
            return (count - 1, ready)
        }
        ready.forEach { $0.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Decision { case cancelled, fired, suspended }
                let decision: Decision = lock.withLock {
                    if entries[index].cancelled { return .cancelled }
                    if entries[index].fired { return .fired }
                    entries[index].continuation = continuation
                    return .suspended
                }
                switch decision {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .fired: continuation.resume()
                case .suspended: break
                }
            }
        } onCancel: {
            let pending: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard !entries[index].fired else { return nil }
                entries[index].cancelled = true
                defer { entries[index].continuation = nil }
                return entries[index].continuation
            }
            pending?.resume(throwing: CancellationError())
        }
    }

    /// Let the `index`-th sleep return normally (the timer fires).
    func fire(_ index: Int) {
        let pending: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard index < entries.count, !entries[index].cancelled, !entries[index].fired else { return nil }
            entries[index].fired = true
            defer { entries[index].continuation = nil }
            return entries[index].continuation
        }
        pending?.resume()
    }

    /// Returns once at least `count` sleeps have started.
    func waitForSleeps(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready: Bool = lock.withLock {
                if entries.count >= count { return true }
                countWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// Holds every `wait()` until `release()`.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pass: Bool = lock.withLock {
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if pass { continuation.resume() }
        }
    }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// Records a `bluetoothEvents()` stream on the MainActor.
@MainActor
private final class EventLog {
    private(set) var events: [MachineBluetoothEvent] = []
    private var waiters: [(count: Int, expectation: XCTestExpectation)] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<MachineBluetoothEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                self?.append(event)
            }
        }
    }

    /// Fulfilled once at least `count` events were recorded.
    func expectation(count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) bluetoothEvents")
        if events.count >= count {
            expectation.fulfill()
        } else {
            waiters.append((count, expectation))
        }
        return expectation
    }

    func cancel() {
        task?.cancel()
    }

    private func append(_ event: MachineBluetoothEvent) {
        events.append(event)
        let ready = waiters.filter { $0.count <= events.count }
        waiters.removeAll { $0.count <= events.count }
        ready.forEach { $0.expectation.fulfill() }
    }
}

/// What the C39 consumer saw and did.
@MainActor
private final class StoppingConsumer {
    var received: [MachineBluetoothEvent] = []
    var stops = 0
}
