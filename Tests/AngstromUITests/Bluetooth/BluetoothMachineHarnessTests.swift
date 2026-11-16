import XCTest
@testable import Angstrom
@testable import AngstromUI
import AngstromTestSupport

/// Self-tests of `BluetoothMachineHarness` (PLAN §3.3): its seeds, its construction with and without
/// each client, and the wiring of its fakes and failure modes. The Bluetooth client is still a stub in
/// Wave 0, so the Bluetooth side is driven through the harness's fakes directly.
@MainActor
final class BluetoothMachineHarnessTests: XCTestCase {
    private let read = BluetoothConstants.readCharacteristic
    private let write = BluetoothConstants.writeCharacteristic
    private let auth = BluetoothConstants.authCharacteristic
    private let opTimeout: Duration = .seconds(20)
    /// Hang guard only (PLAN §3.5).
    private let hangGuard: TimeInterval = 5

    // MARK: - Seeds

    /// Angstrom-only: §9.3.6 — the `.standard` seed is BT-DASH-SEED-001 (upstream fixture
    /// `mock_machine_with_dashboard`, tests/test_bluetooth_dashboard.py:68-105) for a Linea Micra, seeded
    /// through a MachineSnapshot into both the base and the rendered dashboard.
    func testStandardSeedMatchesSeed001() throws {
        let harness = BluetoothMachineHarness()
        let machine = harness.machine

        XCTAssertEqual(BluetoothMachineHarness.serial, "MR123456")
        XCTAssertEqual(machine.serialNumber, "MR123456")
        let dashboard = try XCTUnwrap(machine.dashboard)
        XCTAssertEqual(machine.baseDashboard, dashboard)
        XCTAssertEqual(dashboard, BluetoothMachineHarness.seedDashboard(model: .lineaMicra))
        XCTAssertEqual(machine.model, .lineaMicra)
        XCTAssertNil(machine.settings)
        XCTAssertNil(machine.schedule)

        XCTAssertEqual(dashboard.machine.serialNumber, "MR123456")
        XCTAssertEqual(dashboard.machine.model, .lineaMicra)
        XCTAssertFalse(dashboard.machine.isConnected)
        XCTAssertNil(dashboard.machine.connectionDate)

        XCTAssertEqual(dashboard.widgets.map(\.code),
                       ["CMMachineStatus", "CMCoffeeBoiler", "CMSteamBoilerLevel", "CMSteamBoilerTemperature"])
        XCTAssertEqual(dashboard.widgets.map(\.index), [1, 1, 1, 1])

        let status = try XCTUnwrap(dashboard.machineStatus)
        XCTAssertEqual(status.status, .standby)
        XCTAssertEqual(status.availableModes, [.brewing, .standby])
        XCTAssertEqual(status.mode, .standby)
        XCTAssertNil(status.nextStatus)
        XCTAssertNil(status.brewingStartTime)

        let coffee = try XCTUnwrap(dashboard.coffeeBoiler)
        XCTAssertEqual(coffee.status, .standby)
        XCTAssertTrue(coffee.enabled)
        XCTAssertFalse(coffee.enabledSupported)
        XCTAssertEqual(coffee.targetTemperature, 93.0)
        XCTAssertEqual(coffee.targetTemperatureMin, 80)
        XCTAssertEqual(coffee.targetTemperatureMax, 100)
        XCTAssertEqual(coffee.targetTemperatureStep, 0.1)
        XCTAssertNil(coffee.readyStartTime)

        let level = try XCTUnwrap(dashboard.steamBoilerLevel)
        XCTAssertEqual(level.status, .standby)
        XCTAssertTrue(level.enabled)
        XCTAssertTrue(level.enabledSupported)
        XCTAssertEqual(level.targetLevel, .level1)
        XCTAssertTrue(level.targetLevelSupported)
        XCTAssertNil(level.readyStartTime)

        let steam = try XCTUnwrap(dashboard.steamBoilerTemperature)
        XCTAssertEqual(steam.status, .standby)
        XCTAssertTrue(steam.enabled)
        XCTAssertFalse(steam.enabledSupported)
        XCTAssertEqual(steam.targetTemperature, 126.0)
        XCTAssertEqual(steam.targetTemperatureMin, 126)
        XCTAssertEqual(steam.targetTemperatureMax, 131)
        XCTAssertEqual(steam.targetTemperatureStep, 1.0)
        XCTAssertTrue(steam.targetTemperatureSupported)
        XCTAssertNil(steam.readyStartTime)

        // The seed takes the requested model and changes nothing else.
        let miniR = BluetoothMachineHarness.seedDashboard(model: .lineaMiniR)
        XCTAssertEqual(miniR.machine, Machine(serialNumber: "MR123456", model: .lineaMiniR))
        XCTAssertEqual(miniR.widgets, dashboard.widgets)
        XCTAssertEqual(BluetoothMachineHarness(model: .lineaMiniR).machine.dashboard, miniR)
    }

    /// Angstrom-only: §9.3.6 — `.empty` seeds `Dashboard(machine: Machine(serialNumber:model:), widgets: [])`,
    /// `.none` seeds nothing, `.custom` seeds the given dashboard.
    func testEmptyNoneAndCustomSeeds() throws {
        let empty = BluetoothMachineHarness(model: .lineaMiniR, seed: .empty)
        let expectedEmpty = Dashboard(machine: Machine(serialNumber: "MR123456", model: .lineaMiniR), widgets: [])
        XCTAssertEqual(empty.machine.dashboard, expectedEmpty)
        XCTAssertEqual(empty.machine.baseDashboard, expectedEmpty)
        XCTAssertEqual(empty.machine.model, .lineaMiniR)

        let none = BluetoothMachineHarness(seed: .none)
        XCTAssertNil(none.machine.dashboard)
        XCTAssertNil(none.machine.baseDashboard)
        XCTAssertNil(none.machine.model)

        let custom = Dashboard(machine: Machine(serialNumber: "MR123456", model: .gs3AV), widgets: [
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: true))),
        ])
        let seeded = BluetoothMachineHarness(seed: .custom(custom))
        XCTAssertEqual(seeded.machine.dashboard, custom)
        XCTAssertEqual(seeded.machine.baseDashboard, custom)
        XCTAssertEqual(seeded.machine.model, .gs3AV)
    }

    // MARK: - Construction

    /// Angstrom-only: §6.16 — with neither client the machine has no cloud and no Bluetooth client:
    /// cloud-only operations throw `.cloudOnlyFunctionality` (recorded in `lastError`) and the harness
    /// helpers report no traffic.
    func testHarnessWithoutCloudOrBluetooth() async throws {
        let harness = BluetoothMachineHarness(cloud: false, bluetooth: false)
        let machine = harness.machine

        XCTAssertNil(harness.backend)
        XCTAssertNil(harness.bluetooth)
        XCTAssertNil(machine.bluetooth)
        XCTAssertNil(machine.cloudClient)
        XCTAssertFalse(machine.hasCloudClient)
        XCTAssertFalse(machine.hasBluetoothClient)
        XCTAssertFalse(machine.isBluetoothConnected)
        XCTAssertEqual(machine.dashboard, BluetoothMachineHarness.seedDashboard(model: .lineaMicra))

        do {
            _ = try await machine.refreshDashboard()
            XCTFail("refreshDashboard must throw without a cloud client")
        } catch let error as LaMarzoccoError {
            XCTAssertEqual(error, .cloudOnlyFunctionality)
        }
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, .cloudOnlyFunctionality)

        do {
            _ = try await machine.setPower(on: true)
            XCTFail("setPower must throw with neither client")
        } catch let error as LaMarzoccoError {
            XCTAssertEqual(error, .cloudOnlyFunctionality)
        }
        // A failed command applies no optimistic update.
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .standby)

        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineChangeMode"), 0)
        XCTAssertNil(try harness.cloudCommandBody("CoffeeMachineChangeMode"))
        XCTAssertTrue(harness.links.isEmpty)
        XCTAssertEqual(harness.central.connectCount, 0)
        XCTAssertEqual(harness.bluetoothWrites(to: write), [])
    }

    /// Angstrom-only: §6.16 — the default harness holds both clients: the real Bluetooth client is the
    /// machine's, talks to `.fake` with the token "token", and runs on the harness's central, sleeper and
    /// clock; constructing the machine performs no Bluetooth or cloud traffic.
    func testHarnessWithCloudAndBluetooth() async throws {
        let harness = BluetoothMachineHarness()
        let machine = harness.machine
        let bluetooth = try XCTUnwrap(harness.bluetooth)

        XCTAssertNotNil(harness.backend)
        XCTAssertTrue(machine.hasCloudClient)
        XCTAssertTrue(machine.hasBluetoothClient)
        XCTAssertTrue(machine.bluetooth === bluetooth)
        XCTAssertEqual(bluetooth.peripheral, .fake)
        XCTAssertEqual(bluetooth.peripheral.rawValue, "00000000-0000-0000-0000-000000000001")
        let token = await bluetooth.token
        XCTAssertEqual(token, BluetoothAuthToken("token"))
        let central = await bluetooth.central
        XCTAssertTrue((central as? FakeBluetoothCentral) === harness.central)
        let sleeper = await bluetooth.sleeper
        XCTAssertTrue((sleeper as? ManualBluetoothSleeper) === harness.sleeper)

        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let clientNow = await bluetooth.now
        XCTAssertEqual(harness.clock.now(), start)
        XCTAssertEqual(clientNow(), start)
        XCTAssertEqual(harness.central.now(), start)
        harness.clock.advance(by: 5)
        XCTAssertEqual(clientNow(), start.addingTimeInterval(5))
        XCTAssertEqual(harness.central.now(), start.addingTimeInterval(5))

        XCTAssertEqual(harness.central.connectCount, 0)
        XCTAssertTrue(harness.links.isEmpty)
        XCTAssertEqual(harness.backend?.recordedPaths, [])
    }

    /// Angstrom-only: §6.16 — a cloud-only harness answers every read from the UI fixtures and acks
    /// commands with `[{"id":"cmd1","status":"Pending"}]`; `cloudCommandCount`/`cloudCommandBody` see them.
    func testHarnessWithCloudOnly() async throws {
        let harness = BluetoothMachineHarness(seed: .none, bluetooth: false)
        let machine = harness.machine
        let backend = try XCTUnwrap(harness.backend)

        XCTAssertNil(harness.bluetooth)
        XCTAssertNil(machine.bluetooth)
        XCTAssertTrue(machine.hasCloudClient)
        XCTAssertFalse(machine.hasBluetoothClient)

        try await machine.refreshAll()
        XCTAssertEqual(machine.dashboard?.machine.serialNumber, "MR123456")
        XCTAssertEqual(machine.dashboard?.machine.model, .lineaMicra)
        XCTAssertEqual(machine.settings?.machine.serialNumber, "MR123456")
        XCTAssertNotNil(machine.schedule)
        _ = try await machine.refreshStatistics()
        XCTAssertNotNil(machine.statistics)
        XCTAssertEqual(backend.count(pathSuffix: "/dashboard"), 1)
        XCTAssertEqual(backend.count(pathSuffix: "/settings"), 1)
        XCTAssertEqual(backend.count(pathSuffix: "/scheduling"), 1)
        XCTAssertEqual(backend.count(pathSuffix: "/stats"), 1)

        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineChangeMode"), 0)
        let response = try await machine.setPower(on: true)
        XCTAssertEqual(response.id, "cmd1")
        XCTAssertEqual(response.status, .pending)
        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineChangeMode"), 1)
        let body = try XCTUnwrap(try harness.cloudCommandBody("CoffeeMachineChangeMode"))
        XCTAssertEqual(body as NSDictionary, ["mode": "BrewingMode"] as NSDictionary)
        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineChangeSetting"), 0)
        XCTAssertNil(try harness.cloudCommandBody("CoffeeMachineChangeSetting"))
        XCTAssertTrue(harness.links.isEmpty)
    }

    /// Angstrom-only: §6.16 — a Bluetooth-only harness holds the client and no cloud backend; cloud-only
    /// operations throw `.cloudOnlyFunctionality`.
    func testHarnessWithBluetoothOnly() async throws {
        let harness = BluetoothMachineHarness(cloud: false)
        let machine = harness.machine

        XCTAssertNil(harness.backend)
        XCTAssertNil(machine.cloudClient)
        XCTAssertNotNil(harness.bluetooth)
        XCTAssertTrue(machine.bluetooth === harness.bluetooth)
        XCTAssertFalse(machine.hasCloudClient)
        XCTAssertTrue(machine.hasBluetoothClient)

        do {
            _ = try await machine.refreshSettings()
            XCTFail("refreshSettings must throw without a cloud client")
        } catch let error as LaMarzoccoError {
            XCTAssertEqual(error, .cloudOnlyFunctionality)
        }
        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineChangeMode"), 0)
        XCTAssertTrue(harness.links.isEmpty)
    }

    // MARK: - Fakes and failure modes

    /// Angstrom-only: §6.17 — every link the central makes is the scripted machine built from the
    /// harness's `token` (the token it accepts), `settingResponses` and `commandResponse`;
    /// `bluetoothWrites(to:)` collects writes across links in order.
    func testScriptedLinksUseHarnessArguments() async throws {
        let modeResponse = Data(#"{"mode":"BrewingMode"}"#.utf8)
        let commandResponse = Data(#"{"id":"x","message":"Error","status":"error"}"#.utf8)
        let harness = BluetoothMachineHarness(token: "other", settingResponses: [.machineMode: modeResponse],
                                              commandResponse: commandResponse)

        let first = try await harness.central.connect(to: .fake, timeout: opTimeout)
        try await first.write(Data("token".utf8), to: auth, withResponse: true, timeout: opTimeout)
        let rejected = try await first.read(auth, timeout: opTimeout)
        XCTAssertEqual(rejected, Data([0x00]))
        try await first.write(Data("other".utf8), to: auth, withResponse: true, timeout: opTimeout)
        let accepted = try await first.read(auth, timeout: opTimeout)
        XCTAssertEqual(accepted, Data([0x01]))
        try await first.write(Data("machineMode\0".utf8), to: read, withResponse: true, timeout: opTimeout)
        let mode = try await first.read(read, timeout: opTimeout)
        XCTAssertEqual(mode, modeResponse)
        try await first.write(Data("boilers\0".utf8), to: read, withResponse: true, timeout: opTimeout)
        let unscripted = try await first.read(read, timeout: opTimeout)
        XCTAssertEqual(unscripted, Data("[]".utf8))
        try await first.write(Data("cmd1".utf8), to: write, withResponse: true, timeout: opTimeout)
        let status = try await first.read(write, timeout: opTimeout)
        XCTAssertEqual(status, commandResponse)

        let second = try await harness.central.connect(to: .fake, timeout: opTimeout)
        XCTAssertFalse(second === first)
        try await second.write(Data("cmd2".utf8), to: write, withResponse: true, timeout: opTimeout)

        XCTAssertEqual(harness.links.count, 2)
        XCTAssertTrue(harness.links[0] === first as? FakeBluetoothLink)
        XCTAssertTrue(harness.links[1] === second as? FakeBluetoothLink)
        XCTAssertEqual(harness.bluetoothWrites(to: write), [Data("cmd1".utf8), Data("cmd2".utf8)])
        XCTAssertEqual(harness.bluetoothWrites(to: auth), [Data("token".utf8), Data("other".utf8)])
        XCTAssertEqual(harness.bluetoothWrites(to: read), [Data("machineMode\0".utf8), Data("boilers\0".utf8)])

        // Defaults: the machine accepts "token" and answers commands with BluetoothTestVectors.commandSuccess.
        let defaults = BluetoothMachineHarness()
        let link = try await defaults.central.connect(to: .fake, timeout: opTimeout)
        try await link.write(Data("token".utf8), to: auth, withResponse: true, timeout: opTimeout)
        let confirmed = try await link.read(auth, timeout: opTimeout)
        XCTAssertEqual(confirmed, Data([0x01]))
        let success = try await link.read(write, timeout: opTimeout)
        XCTAssertEqual(success, Data(#"{"id":"test-id","message":"Success","status":"success"}"#.utf8))
        XCTAssertEqual(link.peripheralID, .fake)
    }

    /// Angstrom-only: §6.17 — `.connect`: every connect attempt fails `.disconnected(code: 7)` and adds no link.
    func testConnectFailureFailsEveryAttempt() async {
        let harness = BluetoothMachineHarness(failure: .connect)
        XCTAssertEqual(harness.central.connectFailure, .disconnected(code: 7))
        for _ in 0..<3 {
            do {
                _ = try await harness.central.connect(to: .fake, timeout: opTimeout)
                XCTFail("connect must fail")
            } catch {
                XCTAssertEqual(error as? BluetoothTransportError, .disconnected(code: 7))
            }
        }
        XCTAssertEqual(harness.central.connectCount, 3)
        XCTAssertTrue(harness.links.isEmpty)
        XCTAssertNil(BluetoothMachineHarness().central.connectFailure)
    }

    /// Angstrom-only: §6.17 — `.commandWrite` / `.commandTimeout` fail only writes to 0b0b…; auth and
    /// read-setting writes still reach the scripted machine.
    func testCommandWriteFailuresHitOnlyTheCommandCharacteristic() async throws {
        let cases: [(BluetoothMachineHarness.BluetoothFailure, BluetoothTransportError)] = [
            (.commandWrite, .gatt(domain: "CBATTErrorDomain", code: 14)),
            (.commandTimeout, .timedOut("write")),
        ]
        for (failure, expected) in cases {
            let harness = BluetoothMachineHarness(settingResponses: [.tankStatus: Data("true".utf8)], failure: failure)
            let link = try await harness.central.connect(to: .fake, timeout: opTimeout)
            try await link.write(Data("token".utf8), to: auth, withResponse: true, timeout: opTimeout)
            let confirmed = try await link.read(auth, timeout: opTimeout)
            XCTAssertEqual(confirmed, Data([0x01]), "\(failure)")
            try await link.write(Data("tankStatus\0".utf8), to: read, withResponse: true, timeout: opTimeout)
            let tank = try await link.read(read, timeout: opTimeout)
            XCTAssertEqual(tank, Data("true".utf8), "\(failure)")
            do {
                try await link.write(Data("cmd".utf8), to: write, withResponse: true, timeout: opTimeout)
                XCTFail("the command write must fail for \(failure)")
            } catch {
                XCTAssertEqual(error as? BluetoothTransportError, expected, "\(failure)")
            }
            // Every link the central makes carries the failure.
            let next = try await harness.central.connect(to: .fake, timeout: opTimeout)
            do {
                try await next.write(Data("cmd".utf8), to: write, withResponse: true, timeout: opTimeout)
                XCTFail("the command write must fail on every link for \(failure)")
            } catch {
                XCTAssertEqual(error as? BluetoothTransportError, expected, "\(failure)")
            }
        }

        let healthy = BluetoothMachineHarness()
        let link = try await healthy.central.connect(to: .fake, timeout: opTimeout)
        try await link.write(Data("cmd".utf8), to: write, withResponse: true, timeout: opTimeout)
        XCTAssertEqual(healthy.bluetoothWrites(to: write), [Data("cmd".utf8)])
    }

    /// Angstrom-only: §6.17 — `.unavailable(x)` makes the central report `x`; otherwise it is `.poweredOn`.
    func testUnavailableFailureSetsCentralAvailability() async {
        let availabilities: [BluetoothAvailability] = [.poweredOff, .unsupported, .unauthorized(.denied), .unknown]
        for availability in availabilities {
            let harness = BluetoothMachineHarness(failure: .unavailable(availability))
            let reported = await harness.central.availability()
            XCTAssertEqual(reported, availability)
            XCTAssertNil(harness.central.connectFailure)
        }
        let reported = await BluetoothMachineHarness().central.availability()
        XCTAssertEqual(reported, .poweredOn)
    }

    /// Angstrom-only: §6.17 — the sleeper is manual for `.idleDisconnect` only: an idle sleep waits for
    /// `fire`, any other purpose returns at once and records its duration.
    func testSleeperIsManualForIdleDisconnectOnly() async throws {
        let harness = BluetoothMachineHarness()
        let sleeper = harness.sleeper

        try await sleeper.sleep(for: .milliseconds(50), purpose: .authPoll)
        try await sleeper.sleep(for: .seconds(1), purpose: .reconnectBackoff)
        XCTAssertEqual(sleeper.requested(.authPoll), [.milliseconds(50)])
        XCTAssertEqual(sleeper.requested(.reconnectBackoff), [.seconds(1)])
        XCTAssertEqual(sleeper.pendingCount(.authPoll), 0)

        let idle = Task { try await sleeper.sleep(for: .seconds(30), purpose: .idleDisconnect) }
        let pending = expectation(description: "idle sleep pending")
        let waiter = Task {
            await sleeper.waitForPending(.idleDisconnect, count: 1)
            pending.fulfill()
        }
        await fulfillment(of: [pending], timeout: hangGuard)
        await waiter.value
        XCTAssertEqual(sleeper.pendingCount(.idleDisconnect), 1)
        XCTAssertEqual(sleeper.requested(.idleDisconnect), [.seconds(30)])
        sleeper.fire(.idleDisconnect)
        try await idle.value
        XCTAssertEqual(sleeper.pendingCount(.idleDisconnect), 0)
    }
}
