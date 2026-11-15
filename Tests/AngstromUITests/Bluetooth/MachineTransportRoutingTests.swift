import XCTest
import Observation
@testable import Angstrom
@testable import AngstromUI
import AngstromTestSupport

/// BT-W1-11: the main-file changes of `LaMarzoccoMachine` (SPEC §6.16) — the base-dashboard funnel
/// (§4.19), the cloud-only accessor (§4.15), the BLE-first routing of the six commands when there is
/// no Bluetooth client (§4.16), and model gating on the core sets.
///
/// Every machine here has **no** Bluetooth client (`BluetoothMachineHarness(bluetooth: false)`):
/// `bluetoothFirst`'s BLE branch belongs to BT-W3-07. The BLE overlay transform
/// (`overlayingBluetoothBrewing`) belongs to BT-W1-05, so where a test needs a rendered dashboard that
/// differs from the base, it writes `dashboard` directly with `overlayStandIn(_:)`.
@MainActor
final class MachineTransportRoutingTests: XCTestCase {

    // MARK: - Cloud-only operations

    /// Upstream: test_cloud_only_without_cloud_client (tests/test_thing.py:29) [T00]
    ///
    /// Upstream asserts `get_dashboard()` raises `CloudOnlyFunctionality` on a thing built without a
    /// cloud client. Swift: `refreshDashboard()` — and every other cloud operation, including the six
    /// BLE-first commands when there is no Bluetooth client either — throws `.cloudOnlyFunctionality`,
    /// records it in `lastError`, and leaves the dashboard untouched (no optimistic update).
    func testCloudOnlyWithoutCloudClientThrows() async throws {
        // The upstream case, verbatim: a machine with neither client.
        let bare = LaMarzoccoMachine(serialNumber: BluetoothMachineHarness.serial, client: nil, bluetooth: nil)
        XCTAssertFalse(bare.hasCloudClient)
        XCTAssertFalse(bare.hasBluetoothClient)
        await assertCloudOnly(bare, "refreshDashboard") { try await bare.refreshDashboard() }
        XCTAssertNil(bare.dashboard)
        XCTAssertNil(bare.baseDashboard)

        // Coffee-machine operations on a seeded Linea Micra (gates pass, so the client is what fails).
        let micra = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, cloud: false, bluetooth: false).machine
        XCTAssertFalse(micra.hasCloudClient)
        XCTAssertFalse(micra.hasBluetoothClient)
        await assertCloudOnly(micra, "refreshDashboard") { try await micra.refreshDashboard() }
        await assertCloudOnly(micra, "refreshSettings") { try await micra.refreshSettings() }
        await assertCloudOnly(micra, "refreshSchedule") { try await micra.refreshSchedule() }
        await assertCloudOnly(micra, "refreshStatistics") { try await micra.refreshStatistics() }
        await assertCloudOnly(micra, "refreshAll") { try await micra.refreshAll() }
        XCTAssertNil(micra.settings)
        XCTAssertNil(micra.schedule)
        XCTAssertNil(micra.statistics)
        XCTAssertNil(micra.lastUpdateAt)
        // The six BLE-first commands: no Bluetooth client and no cloud client.
        await assertCloudOnly(micra, "setPower") { try await micra.setPower(on: true) }
        await assertCloudOnly(micra, "setSteam") { try await micra.setSteam(on: false) }
        await assertCloudOnly(micra, "setSteamTargetLevel") { try await micra.setSteamTargetLevel(.level3) }
        await assertCloudOnly(micra, "setCoffeeTargetTemperature") { try await micra.setCoffeeTargetTemperature(celsius: 94) }
        await assertCloudOnly(micra, "setSmartStandby") {
            try await micra.setSmartStandby(enabled: true, minutes: 10, after: .powerOn)
        }
        // Every other cloud command.
        await assertCloudOnly(micra, "startBackflush") { try await micra.startBackflush() }
        await assertCloudOnly(micra, "setCupWarmer") { try await micra.setCupWarmer(on: true) }
        await assertCloudOnly(micra, "setPlumbIn") { try await micra.setPlumbIn(on: true) }
        await assertCloudOnly(micra, "setPreExtractionMode") { try await micra.setPreExtractionMode(.preInfusion) }
        await assertCloudOnly(micra, "setPreExtractionTimes") {
            try await micra.setPreExtractionTimes(secondsIn: 2, secondsOut: 3)
        }
        await assertCloudOnly(micra, "setAutoStandby") { try await micra.setAutoStandby(mode: "01:00") }
        await assertCloudOnly(micra, "setWakeUpSchedule") {
            try await micra.setWakeUpSchedule(WakeUpSchedule(enabled: true, onTimeMinutes: 420, offTimeMinutes: 540,
                                                             steamBoiler: true, days: []))
        }
        await assertCloudOnly(micra, "deleteWakeUpSchedule") { try await micra.deleteWakeUpSchedule(id: "w1") }
        await assertCloudOnly(micra, "firmwareUpdateStatus") { try await micra.firmwareUpdateStatus() }
        await assertCloudOnly(micra, "installFirmwareUpdate") { try await micra.installFirmwareUpdate() }

        let mini = BluetoothMachineHarness(model: .lineaMini, seed: .standard, cloud: false, bluetooth: false).machine
        await assertCloudOnly(mini, "setBrewByWeightMode") { try await mini.setBrewByWeightMode(.dose1) }
        await assertCloudOnly(mini, "setBrewByWeightDoses") { try await mini.setBrewByWeightDoses(dose1: 30, dose2: 40) }

        // Strada X: an empty seed, so the group-dose guards (which read the base widgets) pass.
        let strada = BluetoothMachineHarness(model: .stradaX, seed: .empty, cloud: false, bluetooth: false).machine
        await assertCloudOnly(strada, "setSteamTargetTemperature") { try await strada.setSteamTargetTemperature(celsius: 128) }
        await assertCloudOnly(strada, "setMode") { try await strada.setMode(.eco) }
        await assertCloudOnly(strada, "setAutoFlush") { try await strada.setAutoFlush(on: true) }
        await assertCloudOnly(strada, "setSteamFlush") { try await strada.setSteamFlush(on: true) }
        await assertCloudOnly(strada, "setRinseFlush") { try await strada.setRinseFlush(on: true) }
        await assertCloudOnly(strada, "setRinseFlushTime") { try await strada.setRinseFlushTime(seconds: 3) }
        await assertCloudOnly(strada, "setHotWaterDoseEnabled") { try await strada.setHotWaterDoseEnabled(on: true) }
        await assertCloudOnly(strada, "setHotWaterDose") { try await strada.setHotWaterDose(dose: 8, doseIndex: .doseA) }
        await assertCloudOnly(strada, "setGroupMode") { try await strada.setGroupMode(.brewing) }
        await assertCloudOnly(strada, "setCoffeeBoilerEnabled") { try await strada.setCoffeeBoilerEnabled(on: false) }
        await assertCloudOnly(strada, "setGroupDoseMode") { try await strada.setGroupDoseMode(.mass) }
        await assertCloudOnly(strada, "setGroupDose") {
            try await strada.setGroupDose(mode: .mass, doseIndex: .doseA, dose: 20)
        }
        await assertCloudOnly(strada, "setBrewingPressure") { try await strada.setBrewingPressure(pressure: 9) }
        await assertCloudOnly(strada, "setContinuousDoseEnabled") { try await strada.setContinuousDoseEnabled(on: true) }
        await assertCloudOnly(strada, "setContinuousDose") { try await strada.setContinuousDose(seconds: 25) }
        await assertCloudOnly(strada, "setMirrorGroup1") { try await strada.setMirrorGroup1(on: true, groupIndex: 2) }

        let swan = BluetoothMachineHarness(model: .swan, seed: .empty, cloud: false, bluetooth: false).machine
        await assertCloudOnly(swan, "setGrinderBaristaLight") { try await swan.setGrinderBaristaLight(on: true) }
        await assertCloudOnly(swan, "setGrinderPower") { try await swan.setGrinderPower(on: true) }
        await assertCloudOnly(swan, "setGrinderGrindWith") { try await swan.setGrinderGrindWith(.portafilter) }
        await assertCloudOnly(swan, "setGrinderDose") { try await swan.setGrinderDose(doseIndex: .doseA, dose: 12) }
        await assertCloudOnly(swan, "setGrinderMoreDose") { try await swan.setGrinderMoreDose(revolutions: 2) }
        await assertCloudOnly(swan, "setGrinderSingleDoseMode") { try await swan.setGrinderSingleDoseMode(on: true) }
        await assertCloudOnly(swan, "setGrinderMirrorDoses") { try await swan.setGrinderMirrorDoses(on: true) }
        await assertCloudOnly(swan, "setGrinderSpeed") { try await swan.setGrinderSpeed(doseIndex: .doseA, level: .high) }
        await assertCloudOnly(swan, "setGrinderAutoSpeed") {
            try await swan.setGrinderAutoSpeed(doseIndex: .doseA, enabled: true)
        }
        await assertCloudOnly(swan, "setGrinderAutoSpeedReference") {
            try await swan.setGrinderAutoSpeedReference(doseMode: .mass, extractionSeconds: 28, doseMass: 36)
        }
        await assertCloudOnly(swan, "setGrinderAutoStandby") { try await swan.setGrinderAutoStandby(minutes: 15) }
    }

    /// Upstream parity: `@cloud_only` is the outermost decorator on every gated cloud command
    /// (`MACH:511-512,922-923`, `_grinder.py:59-60`), so it fires before `@models_supported` and the
    /// argument checks. SPEC §4.15 (amended): cloud resolution precedes gating. A cloud-less machine
    /// therefore gets `.cloudOnlyFunctionality` (recorded in `lastError`, nothing written) from every
    /// cloud-only gated method, whatever its model and arguments:
    ///
    /// - model gate: a non-matching model (Linea Micra, in none of the sets) and an unknown (nil) model;
    /// - argument guard alone: a matching model whose argument (`setMirrorGroup1` group 1) or cached
    ///   widget (Strada X `CMGroupDoses`: `ManualType` only, no pressure) would reject the call;
    /// - both: a non-matching or nil model together with a rejecting argument.
    ///
    /// The BLE-first gated commands are untouched (§4.16: gating runs first), so on the same cloud-less,
    /// Bluetooth-less machines they still throw `.unsupportedModel`.
    func testGatedCloudOnlyResolvesCloudBeforeGating() async throws {
        let micra = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, cloud: false, bluetooth: false).machine
        let unknown = BluetoothMachineHarness(seed: .none, cloud: false, bluetooth: false).machine
        XCTAssertEqual(micra.model, .lineaMicra)
        XCTAssertNil(unknown.model)

        // Model gate (and model gate + argument guard): every cloud-only gated method.
        for (machine, label) in [(micra, "Linea Micra"), (unknown, "nil model")] {
            func check<T>(_ name: String, _ operation: () async throws -> T) async {
                await assertCloudOnly(machine, "\(name) [\(label)]", operation)
            }
            await check("setBrewByWeightMode") { try await machine.setBrewByWeightMode(.dose1) }
            await check("setBrewByWeightDoses") { try await machine.setBrewByWeightDoses(dose1: 30, dose2: 40) }
            await check("setMode") { try await machine.setMode(.eco) }
            await check("setAutoFlush") { try await machine.setAutoFlush(on: true) }
            await check("setSteamFlush") { try await machine.setSteamFlush(on: true) }
            await check("setRinseFlush") { try await machine.setRinseFlush(on: true) }
            await check("setRinseFlushTime") { try await machine.setRinseFlushTime(seconds: 3) }
            await check("setHotWaterDoseEnabled") { try await machine.setHotWaterDoseEnabled(on: true) }
            await check("setHotWaterDose") { try await machine.setHotWaterDose(dose: 8, doseIndex: .doseA) }
            await check("setGroupMode") { try await machine.setGroupMode(.brewing) }
            await check("setCoffeeBoilerEnabled") { try await machine.setCoffeeBoilerEnabled(on: false) }
            await check("setGroupDoseMode") { try await machine.setGroupDoseMode(.mass) }
            await check("setGroupDose") { try await machine.setGroupDose(mode: .mass, doseIndex: .doseA, dose: 20) }
            await check("setBrewingPressure") { try await machine.setBrewingPressure(pressure: 9) }
            await check("setContinuousDoseEnabled") { try await machine.setContinuousDoseEnabled(on: true) }
            await check("setContinuousDose") { try await machine.setContinuousDose(seconds: 25) }
            await check("setMirrorGroup1") { try await machine.setMirrorGroup1(on: true, groupIndex: 2) }
            // Model gate + a rejecting argument.
            await check("setMirrorGroup1 (group 1)") { try await machine.setMirrorGroup1(on: true, groupIndex: 1) }
            await check("setGrinderGrindWith") { try await machine.setGrinderGrindWith(.portafilter) }
            await check("setGrinderMoreDose") { try await machine.setGrinderMoreDose(revolutions: 2) }
            await check("setGrinderSpeed") { try await machine.setGrinderSpeed(doseIndex: .doseA, level: .high) }
            await check("setGrinderAutoSpeed") { try await machine.setGrinderAutoSpeed(doseIndex: .doseA, enabled: true) }
            await check("setGrinderAutoSpeedReference") {
                try await machine.setGrinderAutoSpeedReference(doseMode: .mass, extractionSeconds: 28, doseMass: 36)
            }
            // `set_dose` is `@cloud_only` too; its speed leg goes through the gated `setGrinderSpeed`.
            await check("setGrinderDose (speed level)") {
                try await machine.setGrinderDose(doseIndex: .doseA, dose: 12, speedLevel: .high)
            }

            // BLE-first gated commands: gating still runs first (§4.16), even with no transport at all.
            await assertUnsupported(machine, "steam temperature is only supported on GS3, GS3 AV, GS3 MP, Strada X",
                                    label) {
                try await machine.setSteamTargetTemperature(celsius: 128)
            }
        }
        await assertUnsupported(unknown, "steam level is only supported on Linea Micra, Linea Mini R", "nil model") {
            try await unknown.setSteamTargetLevel(.level2)
        }
        // The Micra passes the steam-level gate; with no transport at all it then fails on the transport.
        await assertCloudOnly(micra, "setSteamTargetLevel [Linea Micra]") { try await micra.setSteamTargetLevel(.level2) }

        // Argument guards alone, on a matching model. With a cloud client each of these is rejected with
        // `.operationNotAvailable` (pinned by testSnapshotPersistsBaseDashboard / LaMarzoccoMachineTests);
        // without one, `.cloudOnlyFunctionality` comes first.
        let stradaXBase = try decodeDashboard("dashboard_stradax")
        let stradaX = BluetoothMachineHarness(seed: .custom(stradaXBase), cloud: false, bluetooth: false).machine
        XCTAssertEqual(stradaX.model, .stradaX)
        XCTAssertEqual(stradaX.baseDashboard?.groupDoses?.availableModes, [.manual])
        XCTAssertEqual(stradaX.baseDashboard?.groupDoses?.brewingPressureSupported, false)
        await assertCloudOnly(stradaX, "setMirrorGroup1 (group 1) [Strada X]") {
            try await stradaX.setMirrorGroup1(on: true, groupIndex: 1)
        }
        await assertCloudOnly(stradaX, "setGroupDoseMode (unavailable mode) [Strada X]") {
            try await stradaX.setGroupDoseMode(.mass)
        }
        await assertCloudOnly(stradaX, "setGroupDose (no doses for mode) [Strada X]") {
            try await stradaX.setGroupDose(mode: .manual, doseIndex: .doseA, dose: 20)
        }
        await assertCloudOnly(stradaX, "setBrewingPressure (unsupported) [Strada X]") {
            try await stradaX.setBrewingPressure(pressure: 9)
        }
        XCTAssertEqual(stradaX.baseDashboard, stradaXBase)

        // With a cloud client, the same calls still fail on the gate / guard, not on the client.
        let gatedHarness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, bluetooth: false)
        await assertUnsupported(gatedHarness.machine, "machine mode is only supported on Strada X", "cloud") {
            try await gatedHarness.machine.setMode(.eco)
        }
        let guardedHarness = BluetoothMachineHarness(model: .stradaX, seed: .standard, bluetooth: false)
        do {
            _ = try await guardedHarness.machine.setMirrorGroup1(on: true, groupIndex: 1)
            XCTFail("setMirrorGroup1(group 1) with a cloud client must be rejected by the argument guard")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .operationNotAvailable("groupIndex must be 2 or 3"))
        }
        XCTAssertEqual(guardedHarness.machine.lastError as? LaMarzoccoError,
                       .operationNotAvailable("groupIndex must be 2 or 3"))
        XCTAssertEqual(gatedHarness.backend?.recordedPaths.filter { $0.contains("/command/") }.count, 0)
        XCTAssertEqual(guardedHarness.backend?.recordedPaths.filter { $0.contains("/command/") }.count, 0)
    }

    /// Angstrom-only: §4.15 — `start()` without a cloud client throws `.cloudOnlyFunctionality` and records
    /// it; `stop()` without one is a no-op.
    func testStartWithoutCloudThrowsAndStopIsNoOp() async throws {
        let machine = BluetoothMachineHarness(seed: .standard, cloud: false, bluetooth: false).machine
        let seeded = machine.dashboard

        do {
            try await machine.start()
            XCTFail("start() without a cloud client must throw")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .cloudOnlyFunctionality)
        }
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, .cloudOnlyFunctionality)
        XCTAssertFalse(machine.isLive)
        XCTAssertFalse(machine.isConnected)

        // stop() neither traps nor touches state (lastError keeps the start failure).
        await machine.stop()
        XCTAssertFalse(machine.isLive)
        XCTAssertFalse(machine.isConnected)
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, .cloudOnlyFunctionality)
        XCTAssertEqual(machine.dashboard, seeded)
        XCTAssertEqual(machine.baseDashboard, seeded)
        XCTAssertNil(machine.lastUpdateAt)

        // Nothing was left half-started: a second start() fails the same way (not a silent return).
        machine.lastError = nil
        do {
            try await machine.start()
            XCTFail("a second start() without a cloud client must throw too")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .cloudOnlyFunctionality)
        }
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, .cloudOnlyFunctionality)
        XCTAssertFalse(machine.isLive)
    }

    // MARK: - Base dashboard

    /// Angstrom-only: §13 — with no Bluetooth brewing update held, the rendered `dashboard` equals
    /// `baseDashboard` after every base write: the snapshot seed, `refreshDashboard`, an optimistic update,
    /// `refreshAll`, and a re-render over a stale rendered value.
    func testDashboardEqualsBaseWithoutOverlay() async throws {
        let unseeded = BluetoothMachineHarness(seed: .none, bluetooth: false).machine
        XCTAssertNil(unseeded.baseDashboard)
        XCTAssertNil(unseeded.dashboard)

        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, bluetooth: false)
        let machine = harness.machine
        XCTAssertNil(machine.bluetoothBrewingUpdate)

        // Snapshot seed → base, rendered = base.
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)
        XCTAssertEqual(machine.baseDashboard, seed)
        XCTAssertEqual(machine.dashboard, seed)

        // refreshDashboard: wholesale → the REST fixture.
        let fixture = try decodeDashboard("dashboard_micra")
        XCTAssertNotEqual(fixture, seed)
        let refreshed = try await machine.refreshDashboard()
        XCTAssertEqual(refreshed, fixture)
        XCTAssertEqual(machine.baseDashboard, fixture)
        XCTAssertEqual(machine.dashboard, fixture)

        // Optimistic update after a cloud command.
        try await machine.setPower(on: true)
        let powered = fixture.settingMachineMode(.brewing)
        XCTAssertNotEqual(powered, fixture)
        XCTAssertEqual(machine.baseDashboard, powered)
        XCTAssertEqual(machine.dashboard, powered)

        // refreshAll: wholesale again, back to the fixture.
        try await machine.refreshAll()
        XCTAssertEqual(machine.baseDashboard, fixture)
        XCTAssertEqual(machine.dashboard, fixture)
        XCTAssertNotNil(machine.settings)
        XCTAssertNotNil(machine.schedule)

        // A stale rendered value is replaced by the base on the next render.
        machine.dashboard = Dashboard(machine: fixture.machine, widgets: [])
        machine.renderDashboard()
        XCTAssertEqual(machine.dashboard, fixture)
        XCTAssertNil(machine.bluetoothBrewingUpdate)
    }

    /// Angstrom-only: §4.19 (amended) — `refreshDashboard()` returns the **rendered** dashboard (base + the
    /// BLE brewing overlay), as `refreshDashboardFromBluetooth()` does, while the base (and the snapshot)
    /// hold the plain REST value. The overlay is put in place by setting `bluetoothBrewingUpdate` directly
    /// (the shot-counter entry points belong to BT-W3-09).
    func testRefreshDashboardReturnsRenderedDashboard() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, bluetooth: false)
        let machine = harness.machine
        let fixture = try decodeDashboard("dashboard_micra")
        XCTAssertEqual(fixture.machineStatus?.status, .standby)
        XCTAssertNil(fixture.machineStatus?.brewingStartTime)

        let receivedAt = Date(timeIntervalSince1970: 1_767_268_830)
        let update = BluetoothShotCounterUpdate(state: .brewing, timerValue: 30, receivedAt: receivedAt,
                                                raw: BluetoothBrewingData(ev: true, brewingTime: 30))
        let startTime = Date(timeIntervalSince1970: 1_767_268_800)
        XCTAssertEqual(update.brewingStartTime, startTime)
        machine.bluetoothBrewingUpdate = update

        let returned = try await machine.refreshDashboard()
        let rendered = fixture.overlayingBluetoothBrewing(update)
        XCTAssertNotEqual(rendered, fixture, "the overlay must make the rendered value differ from the REST value")
        XCTAssertEqual(returned, rendered, "refreshDashboard() returns base + overlay")
        XCTAssertEqual(returned, machine.dashboard)
        XCTAssertEqual(returned.machineStatus?.status, .brewing)
        XCTAssertEqual(returned.machineStatus?.brewingStartTime, startTime)
        XCTAssertEqual(machine.baseDashboard, fixture, "the base keeps the REST value")
        XCTAssertEqual(machine.snapshot.dashboard, fixture)
        XCTAssertNotNil(machine.lastUpdateAt)
        XCTAssertNil(machine.lastError)

        // No overlay held: the rendered value is the REST value.
        machine.bluetoothBrewingUpdate = nil
        let plain = try await machine.refreshDashboard()
        XCTAssertEqual(plain, fixture)
        XCTAssertEqual(machine.dashboard, fixture)
    }

    /// Angstrom-only: §4.19 — a websocket push is merged into the base, not set wholesale: a push with no
    /// widgets keeps the base widgets (applying only connectivity), a push with widgets replaces them.
    func testWidgetlessPushKeepsBaseWidgets() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, bluetooth: false)
        let machine = harness.machine
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)
        XCTAssertEqual(seed.widgets.count, 4)
        XCTAssertFalse(seed.machine.isConnected, "the seed machine starts not connected")
        XCTAssertNil(seed.machine.connectionDate)
        XCTAssertNil(machine.lastUpdateAt)

        let channel = MockWebSocketChannel()
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in channel }
        channel.push(Stomp.encode(.connected, headers: [("version", "1.2")]))
        try await machine.start()
        XCTAssertTrue(machine.isLive)

        // 1. Widget-less push: widgets kept, connectivity applied.
        await awaitLastUpdateAt(of: machine) {
            channel.push(messageFrame("""
            { "connected": true, "connectionDate": 1783565955166, "removedWidgets": [], "commands": [], "widgets": [] }
            """))
        }
        var onlineMachine = seed.machine
        onlineMachine.isConnected = true
        onlineMachine.connectionDate = Date(timeIntervalSince1970: 1_783_565_955.166)
        var expected = Dashboard(machine: onlineMachine, widgets: seed.widgets)
        XCTAssertEqual(machine.baseDashboard?.widgets, seed.widgets, "a widget-less push keeps the base widgets")
        XCTAssertEqual(machine.baseDashboard, expected)
        XCTAssertEqual(machine.dashboard, expected)
        XCTAssertEqual(machine.isMachineConnected, true)
        XCTAssertNotNil(machine.lastUpdateAt)

        // 2. A push with widgets replaces the base widget set wholesale.
        await awaitLastUpdateAt(of: machine) {
            channel.push(messageFrame("""
            { "connected": false, "removedWidgets": [], "commands": [],
              "widgets": [ { "code": "CMMachineStatus", "index": 1,
                "output": { "status": "PoweredOn", "availableModes": ["BrewingMode","StandBy"],
                            "mode": "BrewingMode", "nextStatus": null, "brewingStartTime": null } } ] }
            """))
        }
        let pushedStatus = Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(MachineStatus(
            status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
            nextStatus: nil, brewingStartTime: nil)))
        var offlineMachine = onlineMachine
        offlineMachine.isConnected = false
        expected = Dashboard(machine: offlineMachine, widgets: [pushedStatus])
        XCTAssertEqual(machine.baseDashboard, expected)
        XCTAssertEqual(machine.dashboard, expected)

        // 3. Another widget-less push keeps the pushed widget set.
        await awaitLastUpdateAt(of: machine) {
            channel.push(messageFrame("""
            { "connected": true, "removedWidgets": [], "commands": [], "widgets": [] }
            """))
        }
        expected = Dashboard(machine: onlineMachine, widgets: [pushedStatus])
        XCTAssertEqual(machine.baseDashboard?.widgets, [pushedStatus])
        XCTAssertEqual(machine.baseDashboard, expected)
        XCTAssertEqual(machine.dashboard, expected)

        await machine.stop()
    }

    /// Angstrom-only: §4.19 — `snapshot` persists `baseDashboard`, never the rendered `dashboard`; and every
    /// base write (all optimistic sites and the group-dose / grinder-dose guard reads) reads the base, so a
    /// rendered value that differs from the base never reaches the base or the snapshot.
    ///
    /// The rendered dashboard is set directly with `overlayStandIn(_:)` (a `CMMachineStatus` with
    /// `status = .brewing` and a start time, every other widget dropped), standing in for the BLE overlay.
    func testSnapshotPersistsBaseDashboard() async throws {
        // Snapshot vs rendered.
        let micraHarness = try harness(fixture: "dashboard_micra")
        let micra = micraHarness.machine
        let micraBase = try decodeDashboard("dashboard_micra")
        XCTAssertEqual(micra.baseDashboard, micraBase)
        micra.dashboard = overlayStandIn(micraBase)
        XCTAssertEqual(micra.dashboard?.machineStatus?.status, .brewing)
        XCTAssertEqual(micra.snapshot.dashboard, micraBase)
        XCTAssertEqual(micra.snapshot.dashboard?.machineStatus?.status, .standby)
        XCTAssertNil(micra.snapshot.dashboard?.machineStatus?.brewingStartTime)
        XCTAssertEqual(micra.snapshot.serialNumber, BluetoothMachineHarness.serial)
        // It round-trips into a new machine as the base.
        let restored = try MachineSnapshot(data: micra.snapshot.encoded())
        let relaunched = LaMarzoccoMachine(serialNumber: BluetoothMachineHarness.serial, client: nil, bluetooth: nil,
                                           snapshot: restored)
        XCTAssertEqual(relaunched.baseDashboard, micraBase)
        XCTAssertEqual(relaunched.dashboard, micraBase)

        // Linea Micra: the BLE-first commands' optimistic sites.
        try await assertBaseWrite(micra, { $0.settingMachineMode(.brewing) }) { try await micra.setPower(on: true) }
        try await assertBaseWrite(micra, { $0.settingSteamEnabled(false) }) { try await micra.setSteam(on: false) }
        try await assertBaseWrite(micra, { $0.settingSteamTargetLevel(.level3) }) {
            try await micra.setSteamTargetLevel(.level3)
        }
        try await assertBaseWrite(micra, { $0.settingCoffeeTargetTemperature(94.5) }) {
            try await micra.setCoffeeTargetTemperature(celsius: 94.5)
        }

        // Linea Mini: brew by weight.
        let mini = try harness(fixture: "dashboard_mini").machine
        try await assertBaseWrite(mini, { $0.settingBrewByWeightMode(.dose2) }) { try await mini.setBrewByWeightMode(.dose2) }
        try await assertBaseWrite(mini, { $0.settingBrewByWeightDoses(dose1: 31, dose2: 41) }) {
            try await mini.setBrewByWeightDoses(dose1: 31, dose2: 41)
        }

        // Strada X: mode, flushes, hot water, group mode, coffee boiler, steam temperature.
        let stradaXHarness = try harness(fixture: "dashboard_stradax")
        let stradaX = stradaXHarness.machine
        try await assertBaseWrite(stradaX, { $0.settingSteamTargetTemperature(129) }) {
            try await stradaX.setSteamTargetTemperature(celsius: 129)
        }
        try await assertBaseWrite(stradaX, { $0.settingMachineMode(.eco) }) { try await stradaX.setMode(.eco) }
        try await assertBaseWrite(stradaX, { $0.settingAutoFlush(false) }) { try await stradaX.setAutoFlush(on: false) }
        try await assertBaseWrite(stradaX, { $0.settingSteamFlush(false) }) { try await stradaX.setSteamFlush(on: false) }
        try await assertBaseWrite(stradaX, { $0.settingRinseFlushEnabled(false) }) { try await stradaX.setRinseFlush(on: false) }
        try await assertBaseWrite(stradaX, { $0.settingRinseFlushTime(2.5) }) { try await stradaX.setRinseFlushTime(seconds: 2.5) }
        try await assertBaseWrite(stradaX, { $0.settingHotWaterDoseEnabled(false) }) {
            try await stradaX.setHotWaterDoseEnabled(on: false)
        }
        try await assertBaseWrite(stradaX, { $0.settingHotWaterDose(9.9, doseIndex: .doseA) }) {
            try await stradaX.setHotWaterDose(dose: 9.9, doseIndex: .doseA)
        }
        try await assertBaseWrite(stradaX, { $0.settingGroupMode(.brewing, groupIndex: 1) }) {
            try await stradaX.setGroupMode(.brewing)
        }
        try await assertBaseWrite(stradaX, { $0.settingCoffeeBoilerEnabled(false) }) {
            try await stradaX.setCoffeeBoilerEnabled(on: false)
        }
        // Guard reads come from the base: its CMGroupDoses (availableModes [ManualType], an empty ManualType
        // list, brewing pressure unsupported) rejects these; the stand-in has no CMGroupDoses and would not.
        try await assertGuardReadsBase(stradaX, stradaXHarness, "CoffeeMachineGroupDoseChangeMode") {
            try await stradaX.setGroupDoseMode(.mass)
        }
        try await assertGuardReadsBase(stradaX, stradaXHarness, "CoffeeMachineGroupDoseSettingDose") {
            try await stradaX.setGroupDose(mode: .manual, doseIndex: .doseA, dose: 20)
        }
        try await assertGuardReadsBase(stradaX, stradaXHarness, "CoffeeMachineGroupDoseSettingGroupBrewingPressure") {
            try await stradaX.setBrewingPressure(pressure: 9)
        }

        // Strada (Mass dosing): valid group-dose calls, and an unknown dose index rejected by the base.
        let stradaHarness = try harness(fixture: "dashboard_strada")
        let strada = stradaHarness.machine
        try await assertGuardReadsBase(strada, stradaHarness, "CoffeeMachineGroupDoseSettingDose") {
            try await strada.setGroupDose(mode: .mass, doseIndex: .continuous, dose: 20)
        }
        try await assertBaseWrite(strada, { $0.settingGroupDose(mode: .mass, doseIndex: .doseA, dose: 20, groupIndex: 1) }) {
            try await strada.setGroupDose(mode: .mass, doseIndex: .doseA, dose: 20)
        }
        try await assertBaseWrite(strada, { $0.settingGroupDoseMode(.brewRatio, groupIndex: 1) }) {
            try await strada.setGroupDoseMode(.brewRatio)
        }

        // Pico: barista light, power, dose (mode resolved from the base's GDoses: TimeType), single dose, mirror.
        let picoHarness = try harness(fixture: "dashboard_pico")
        let pico = picoHarness.machine
        try await assertBaseWrite(pico, { $0.settingGrinderBaristaLight(false) }) { try await pico.setGrinderBaristaLight(on: false) }
        try await assertBaseWrite(pico, { $0.settingGrinderMode(.grinding) }) { try await pico.setGrinderPower(on: true) }
        XCTAssertEqual(pico.baseDashboard?.grinderDoses?.mode, .time)
        try await assertBaseWrite(pico, { $0.settingGrinderDose(doseIndex: .doseB, dose: 5.5, mode: .time) }) {
            try await pico.setGrinderDose(doseIndex: .doseB, dose: 5.5)
        }
        XCTAssertEqual(try picoHarness.cloudCommandBody("GrinderSettingDose")?["mode"] as? String, "TimeType",
                       "the default dose mode is read from the base, not the rendered dashboard")
        try await assertBaseWrite(pico, { $0.settingGrinderSingleDose(false) }) { try await pico.setGrinderSingleDoseMode(on: false) }
        try await assertBaseWrite(pico, { $0.settingGrinderMirrorDoses(true) }) { try await pico.setGrinderMirrorDoses(on: true) }

        // Swan: grind-with, more dose, speed, auto speed, auto-speed reference.
        let swan = try harness(fixture: "dashboard_swan").machine
        try await assertBaseWrite(swan, { $0.settingGrinderGrindWith(.portafilter) }) { try await swan.setGrinderGrindWith(.portafilter) }
        try await assertBaseWrite(swan, { $0.settingGrinderMoreDose(2) }) { try await swan.setGrinderMoreDose(revolutions: 2) }
        try await assertBaseWrite(swan, { $0.settingGrinderSpeed(doseIndex: .doseA, level: .high) }) {
            try await swan.setGrinderSpeed(doseIndex: .doseA, level: .high)
        }
        try await assertBaseWrite(swan, { $0.settingGrinderAutoSpeed(doseIndex: .doseA, enabled: true, groupIndex: 2) }) {
            try await swan.setGrinderAutoSpeed(doseIndex: .doseA, enabled: true, groupIndex: 2)
        }
        try await assertBaseWrite(swan, {
            $0.settingGrinderAutoSpeedReference(doseMode: .mass, extractionSeconds: 28, doseMass: 36,
                                                dosePulses: nil, rateLock: false)
        }) {
            try await swan.setGrinderAutoSpeedReference(doseMode: .mass, extractionSeconds: 28, doseMass: 36)
        }
    }

    // MARK: - Routing without Bluetooth

    /// Angstrom-only: §4.16 — without a Bluetooth client the six BLE-first commands send exactly their
    /// cloud command (one request, exact body), return the cloud response, and apply their optimistic
    /// update (none for `setSmartStandby`).
    func testSixCommandsWithoutBluetoothUseCloud() async throws {
        let pending = CommandResponse(id: "cmd1", status: .pending, errorCode: nil)
        let micraHarness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, bluetooth: false)
        let micra = micraHarness.machine
        XCTAssertTrue(micra.hasCloudClient)
        XCTAssertFalse(micra.hasBluetoothClient)
        var expected = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)

        // setPower(on:) → CoffeeMachineChangeMode.
        let power = try await micra.setPower(on: true)
        XCTAssertEqual(power, pending)
        XCTAssertEqual(micraHarness.cloudCommandCount("CoffeeMachineChangeMode"), 1)
        try assertBody(micraHarness, "CoffeeMachineChangeMode", ["mode": "BrewingMode"])
        expected = expected.settingMachineMode(.brewing)
        XCTAssertEqual(micra.baseDashboard?.machineStatus?.mode, .brewing)
        XCTAssertEqual(micra.baseDashboard, expected)
        XCTAssertEqual(micra.dashboard, expected)

        try await micra.setPower(on: false)
        XCTAssertEqual(micraHarness.cloudCommandCount("CoffeeMachineChangeMode"), 2)
        try assertBody(micraHarness, "CoffeeMachineChangeMode", ["mode": "StandBy"])
        expected = expected.settingMachineMode(.standby)
        XCTAssertEqual(micra.baseDashboard, expected)

        // setSteam(on:) → CoffeeMachineSettingSteamBoilerEnabled.
        let steam = try await micra.setSteam(on: false)
        XCTAssertEqual(steam, pending)
        XCTAssertEqual(micraHarness.cloudCommandCount("CoffeeMachineSettingSteamBoilerEnabled"), 1)
        try assertBody(micraHarness, "CoffeeMachineSettingSteamBoilerEnabled", ["boilerIndex": 1, "enabled": false])
        expected = expected.settingSteamEnabled(false)
        XCTAssertEqual(micra.baseDashboard?.steamBoilerLevel?.enabled, false)
        XCTAssertEqual(micra.baseDashboard?.steamBoilerTemperature?.enabled, false)
        XCTAssertEqual(micra.baseDashboard, expected)
        XCTAssertEqual(micra.dashboard, expected)

        // setSteamTargetLevel(_:) → CoffeeMachineSettingSteamBoilerTargetLevel.
        let level = try await micra.setSteamTargetLevel(.level3)
        XCTAssertEqual(level, pending)
        XCTAssertEqual(micraHarness.cloudCommandCount("CoffeeMachineSettingSteamBoilerTargetLevel"), 1)
        try assertBody(micraHarness, "CoffeeMachineSettingSteamBoilerTargetLevel", ["boilerIndex": 1, "targetLevel": "Level3"])
        expected = expected.settingSteamTargetLevel(.level3)
        XCTAssertEqual(micra.baseDashboard?.steamBoilerLevel?.targetLevel, .level3)
        XCTAssertEqual(micra.baseDashboard, expected)
        XCTAssertEqual(micra.dashboard, expected)

        // setCoffeeTargetTemperature(celsius:) → the cloud rounds to 0.1, the optimistic value does not.
        let coffee = try await micra.setCoffeeTargetTemperature(celsius: 93.46)
        XCTAssertEqual(coffee, pending)
        XCTAssertEqual(micraHarness.cloudCommandCount("CoffeeMachineSettingCoffeeBoilerTargetTemperature"), 1)
        try assertBody(micraHarness, "CoffeeMachineSettingCoffeeBoilerTargetTemperature",
                       ["boilerIndex": 1, "targetTemperature": 93.5])
        expected = expected.settingCoffeeTargetTemperature(93.46)
        XCTAssertEqual(micra.baseDashboard?.coffeeBoiler?.targetTemperature, 93.46)
        XCTAssertEqual(micra.baseDashboard, expected)
        XCTAssertEqual(micra.dashboard, expected)

        // setSmartStandby (no schedule loaded, so not the auto-standby path) → CoffeeMachineSettingSmartStandBy.
        XCTAssertNil(micra.schedule)
        let standby = try await micra.setSmartStandby(enabled: true, minutes: 42, after: .lastBrewing)
        XCTAssertEqual(standby, pending)
        XCTAssertEqual(micraHarness.cloudCommandCount("CoffeeMachineSettingSmartStandBy"), 1)
        XCTAssertEqual(micraHarness.cloudCommandCount("CoffeeMachineSettingAutoStandBy"), 0)
        try assertBody(micraHarness, "CoffeeMachineSettingSmartStandBy",
                       ["enabled": true, "minutes": 42, "after": "LastBrewing"])
        XCTAssertEqual(micra.baseDashboard, expected, "setSmartStandby has no optimistic update")
        XCTAssertEqual(micra.dashboard, expected)

        // setSteamTargetTemperature(celsius:) on a GS3 AV → CoffeeMachineSettingSteamBoilerTargetTemperature.
        let gs3Harness = BluetoothMachineHarness(model: .gs3AV, seed: .standard, bluetooth: false)
        let gs3 = gs3Harness.machine
        let steamTemperature = try await gs3.setSteamTargetTemperature(celsius: 128)
        XCTAssertEqual(steamTemperature, pending)
        XCTAssertEqual(gs3Harness.cloudCommandCount("CoffeeMachineSettingSteamBoilerTargetTemperature"), 1)
        try assertBody(gs3Harness, "CoffeeMachineSettingSteamBoilerTargetTemperature",
                       ["boilerIndex": 1, "targetTemperature": 128])
        let gs3Expected = BluetoothMachineHarness.seedDashboard(model: .gs3AV).settingSteamTargetTemperature(128)
        XCTAssertEqual(gs3.baseDashboard?.steamBoilerTemperature?.targetTemperature, 128)
        XCTAssertEqual(gs3.baseDashboard, gs3Expected)
        XCTAssertEqual(gs3.dashboard, gs3Expected)

        // One request per call, nothing else sent.
        let commandPaths = (micraHarness.backend?.recordedPaths ?? []).filter { $0.contains("/command/") }
        XCTAssertEqual(commandPaths.count, 6)
        XCTAssertNil(micra.lastError)
        XCTAssertNil(gs3.lastError)
    }

    /// Angstrom-only: D22 — `setSmartStandby` on a machine whose schedule reports
    /// `autoStandBySupported == true` sends only `CoffeeMachineSettingAutoStandBy` with `"HH:MM"` or
    /// `"Off"` (no smart-standby command, no BLE leg), and throws `.cloudOnlyFunctionality` without a
    /// cloud client.
    func testSmartStandbyAutoStandbyStaysCloudOnly() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, bluetooth: false)
        let machine = harness.machine
        try await machine.refreshSchedule()
        XCTAssertEqual(machine.schedule?.autoStandBySupported, true)
        let seeded = machine.baseDashboard

        let response = try await machine.setSmartStandby(enabled: true, minutes: 90, after: .powerOn)
        XCTAssertEqual(response, CommandResponse(id: "cmd1", status: .pending, errorCode: nil))
        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingAutoStandBy"), 1)
        try assertBody(harness, "CoffeeMachineSettingAutoStandBy", ["mode": "01:30"])

        try await machine.setSmartStandby(enabled: true, minutes: 5, after: .lastBrewing)
        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingAutoStandBy"), 2)
        try assertBody(harness, "CoffeeMachineSettingAutoStandBy", ["mode": "00:05"])

        try await machine.setSmartStandby(enabled: false, minutes: 90, after: .powerOn)
        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingAutoStandBy"), 3)
        try assertBody(harness, "CoffeeMachineSettingAutoStandBy", ["mode": "Off"])

        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingSmartStandBy"), 0)
        XCTAssertEqual(machine.baseDashboard, seeded, "no optimistic update")
        XCTAssertNil(machine.lastError)

        // Without a cloud client (the schedule seeded from a snapshot): .cloudOnlyFunctionality, recorded.
        let schedule = try XCTUnwrap(machine.schedule)
        let offline = LaMarzoccoMachine(
            serialNumber: BluetoothMachineHarness.serial, client: nil, bluetooth: nil,
            snapshot: MachineSnapshot(serialNumber: BluetoothMachineHarness.serial,
                                      dashboard: BluetoothMachineHarness.seedDashboard(model: .lineaMicra),
                                      schedule: schedule))
        XCTAssertEqual(offline.schedule?.autoStandBySupported, true)
        await assertCloudOnly(offline, "setSmartStandby (auto-standby)") {
            try await offline.setSmartStandby(enabled: true, minutes: 90, after: .powerOn)
        }
    }

    // MARK: - Gating

    /// Angstrom-only: §6.16 — `setSteamTargetLevel` gates on `Model.steamLevelModels` and
    /// `setSteamTargetTemperature` on `Model.steamTemperatureModels`, before any transport: every other
    /// model (and an unknown one) throws `.unsupportedModel` with the exact message and sends nothing.
    func testGatingUsesCoreModelSets() async throws {
        XCTAssertEqual(Model.steamLevelModels, [.lineaMicra, .lineaMiniR])
        XCTAssertEqual(Model.steamTemperatureModels, [.gs3, .gs3AV, .gs3MP, .stradaX])

        let models: [Model] = [.lineaMini, .lineaMicra, .lineaMiniR, .gs3, .gs3AV, .gs3MP, .stradaX, .pico, .swan,
                               .unknown("FUTUREMODEL")]
        for model in models {
            let harness = BluetoothMachineHarness(model: model, seed: .standard, bluetooth: false)
            let machine = harness.machine
            XCTAssertEqual(machine.model, model)

            // Steam level.
            if Model.steamLevelModels.contains(model) {
                let response = try await machine.setSteamTargetLevel(.level2)
                XCTAssertEqual(response.id, "cmd1", "\(model)")
                XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingSteamBoilerTargetLevel"), 1, "\(model)")
                XCTAssertEqual(machine.baseDashboard?.steamBoilerLevel?.targetLevel, .level2, "\(model)")
            } else {
                let before = machine.baseDashboard
                await assertUnsupported(machine, "steam level is only supported on Linea Micra, Linea Mini R", "\(model)") {
                    try await machine.setSteamTargetLevel(.level2)
                }
                XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingSteamBoilerTargetLevel"), 0, "\(model)")
                XCTAssertEqual(machine.baseDashboard, before, "\(model)")
            }

            // Steam temperature.
            if Model.steamTemperatureModels.contains(model) {
                let response = try await machine.setSteamTargetTemperature(celsius: 130)
                XCTAssertEqual(response.id, "cmd1", "\(model)")
                XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingSteamBoilerTargetTemperature"), 1, "\(model)")
                XCTAssertEqual(machine.baseDashboard?.steamBoilerTemperature?.targetTemperature, 130, "\(model)")
            } else {
                let before = machine.baseDashboard
                await assertUnsupported(machine, "steam temperature is only supported on GS3, GS3 AV, GS3 MP, Strada X",
                                        "\(model)") {
                    try await machine.setSteamTargetTemperature(celsius: 130)
                }
                XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingSteamBoilerTargetTemperature"), 0, "\(model)")
                XCTAssertEqual(machine.baseDashboard, before, "\(model)")
            }
        }

        // Model unknown (nothing loaded): gated, not defaulted.
        let unknown = BluetoothMachineHarness(seed: .none, bluetooth: false)
        XCTAssertNil(unknown.machine.model)
        await assertUnsupported(unknown.machine, "steam level is only supported on Linea Micra, Linea Mini R", "nil") {
            try await unknown.machine.setSteamTargetLevel(.level1)
        }
        await assertUnsupported(unknown.machine, "steam temperature is only supported on GS3, GS3 AV, GS3 MP, Strada X",
                                "nil") {
            try await unknown.machine.setSteamTargetTemperature(celsius: 126)
        }
        XCTAssertEqual(unknown.backend?.recordedPaths.filter { $0.contains("/command/") }.count, 0)
    }

    // MARK: - Private helpers

    /// A harness without a Bluetooth client whose machine is seeded (through a snapshot) with a decoded
    /// dashboard fixture.
    private func harness(fixture: String) throws -> BluetoothMachineHarness {
        BluetoothMachineHarness(seed: .custom(try decodeDashboard(fixture)), bluetooth: false)
    }

    private func decodeDashboard(_ name: String) throws -> Dashboard {
        try JSONDecoder.laMarzocco().decode(Dashboard.self, from: Fixture.data(name))
    }

    /// A rendered dashboard that differs from `base` the way the BLE overlay would — `CMMachineStatus`
    /// with `status = .brewing` and a start time — and shares no other widget with it.
    private func overlayStandIn(_ base: Dashboard) -> Dashboard {
        let widgets = base.widgets.compactMap { widget -> Widget? in
            guard case .machineStatus(let status) = widget.kind else { return nil }
            return Widget(code: widget.code, index: widget.index, kind: .machineStatus(MachineStatus(
                status: .brewing, availableModes: status.availableModes, mode: status.mode,
                nextStatus: status.nextStatus, brewingStartTime: Date(timeIntervalSince1970: 1_767_268_800))))
        }
        return Dashboard(machine: base.machine, widgets: widgets)
    }

    /// With the rendered dashboard set to `overlayStandIn(base)`, run `operation`; the base, the snapshot
    /// and the re-rendered dashboard must all equal `transform(base)`.
    private func assertBaseWrite<T>(
        _ machine: LaMarzoccoMachine, _ transform: (Dashboard) -> Dashboard, _ operation: () async throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let base = try XCTUnwrap(machine.baseDashboard, file: file, line: line)
        let standIn = overlayStandIn(base)
        XCTAssertNotEqual(standIn, base, "the stand-in must differ from the base", file: file, line: line)
        machine.dashboard = standIn
        _ = try await operation()
        let expected = transform(base)
        XCTAssertEqual(machine.baseDashboard, expected, "base written from the base", file: file, line: line)
        XCTAssertEqual(machine.snapshot.dashboard, expected, "snapshot persists the base", file: file, line: line)
        XCTAssertEqual(machine.dashboard, expected, "rendered re-derived from the base", file: file, line: line)
        XCTAssertNil(machine.lastError, file: file, line: line)
    }

    /// With the rendered dashboard set to `overlayStandIn(base)` (no group-dose widget), `operation` must
    /// still be rejected by the base's widget: `.operationNotAvailable`, no `command` request, base intact.
    private func assertGuardReadsBase<T>(
        _ machine: LaMarzoccoMachine, _ harness: BluetoothMachineHarness, _ command: String,
        _ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let base = try XCTUnwrap(machine.baseDashboard, file: file, line: line)
        machine.dashboard = overlayStandIn(base)
        let sentBefore = harness.cloudCommandCount(command)
        do {
            _ = try await operation()
            XCTFail("expected .operationNotAvailable from the base's widget", file: file, line: line)
        } catch LaMarzoccoError.operationNotAvailable {
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
        XCTAssertEqual(harness.cloudCommandCount(command), sentBefore, "nothing sent", file: file, line: line)
        XCTAssertEqual(machine.baseDashboard, base, file: file, line: line)
    }

    /// `operation` throws exactly `.cloudOnlyFunctionality`, records it in `lastError`, and changes neither
    /// the base nor the rendered dashboard.
    private func assertCloudOnly<T>(
        _ machine: LaMarzoccoMachine, _ label: String, _ operation: () async throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let base = machine.baseDashboard
        let rendered = machine.dashboard
        machine.lastError = nil
        do {
            _ = try await operation()
            XCTFail("\(label): expected .cloudOnlyFunctionality", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .cloudOnlyFunctionality, label, file: file, line: line)
        }
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, .cloudOnlyFunctionality, label, file: file, line: line)
        XCTAssertEqual(machine.baseDashboard, base, label, file: file, line: line)
        XCTAssertEqual(machine.dashboard, rendered, label, file: file, line: line)
    }

    /// `operation` throws exactly `.unsupportedModel(message)` and records it in `lastError`.
    private func assertUnsupported<T>(
        _ machine: LaMarzoccoMachine, _ message: String, _ label: String, _ operation: () async throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        machine.lastError = nil
        do {
            _ = try await operation()
            XCTFail("\(label): expected .unsupportedModel", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .unsupportedModel(message), label, file: file, line: line)
        }
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, .unsupportedModel(message), label, file: file, line: line)
    }

    /// The last body of cloud command `name` equals `expected` (and has exactly its keys).
    private func assertBody(
        _ harness: BluetoothMachineHarness, _ name: String, _ expected: [String: Any],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let body = try XCTUnwrap(try harness.cloudCommandBody(name), "no \(name) body", file: file, line: line)
        XCTAssertEqual(Set(body.keys), Set(expected.keys), name, file: file, line: line)
        XCTAssertEqual(body as NSDictionary, expected as NSDictionary, name, file: file, line: line)
    }

    private func messageFrame(_ json: String) -> String {
        Stomp.encode(.message, headers: [("destination", "/ws/sn/\(BluetoothMachineHarness.serial)/dashboard")],
                     body: json)
    }

    /// Run `trigger`, then wait until `machine.lastUpdateAt` is written (the push merge stamps it right
    /// after the base write, in the same MainActor job). Observation-driven; the timeout is a hang guard.
    private func awaitLastUpdateAt(of machine: LaMarzoccoMachine, _ trigger: () -> Void) async {
        let written = expectation(description: "lastUpdateAt written")
        withObservationTracking {
            _ = machine.lastUpdateAt
        } onChange: {
            written.fulfill()
        }
        trigger()
        await fulfillment(of: [written], timeout: 5)
    }
}
