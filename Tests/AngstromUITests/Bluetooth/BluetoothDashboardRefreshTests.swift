import XCTest
@testable import Angstrom
@testable import AngstromUI
import AngstromTestSupport

/// `refreshDashboardFromBluetooth()` and `refreshModelFromBluetooth()` (SPEC §4.17, §4.18; upstream
/// `get_dashboard_from_bluetooth` / `get_model_info_from_bluetooth`, `devices/_machine.py:325-485`).
///
/// Upstream's tests inject decoded values into a mocked client; here a real `LaMarzoccoBluetoothClient`
/// reads them over the AngstromTestSupport fakes, so every injected value is scripted as its wire reply
/// (SPEC §3.6 / §9.3.2): the mode as a JSON string, the tank as `"true"` (BT-RSP-TANK-001) or `false`,
/// plumb-in as a JSON boolean (BT-RSP-PLUMB-001/002; upstream's conftest default is `False`,
/// `tests/conftest.py:195`), boilers as `{"id","isEnabled","target","current"}` objects and the
/// capabilities as upstream's `_capabilities` helper (`tests/test_bluetooth_dashboard.py:34-50`) on the wire.
@MainActor
final class BluetoothDashboardRefreshTests: XCTestCase {

    // MARK: - Parity

    /// Upstream: test_get_dashboard_from_bluetooth (tests/test_bluetooth_dashboard.py:110) [D01]
    func testRefreshMicraFromBluetooth() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: [
            // Scripted but must NOT be read: the model is known.
            .machineCapabilities: capabilitiesReply(family: "MICRA"),
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("false".utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: boilersReply([("CoffeeBoiler1", true, 95, 94), ("SteamBoiler", false, 128, 50)]),
        ])
        let machine = harness.machine

        let returned = try await machine.refreshDashboardFromBluetooth()

        // Capabilities are not read; each of the four settings exactly once, in order.
        XCTAssertEqual(readRequests(harness), frames([.machineMode, .isPlumbedIn, .tankStatus, .boilers]))

        // BT-DASH-SNAP-001 (tests/__snapshots__/test_bluetooth_dashboard.ambr:2-54).
        let expected = Dashboard(machine: Machine(serialNumber: BluetoothMachineHarness.serial, model: .lineaMicra),
                                 widgets: [
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(MachineStatus(
                status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                nextStatus: nil, brewingStartTime: nil))),
            Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(CoffeeBoiler(
                status: .ready, enabled: true, enabledSupported: false, targetTemperature: 95.0,
                targetTemperatureMin: 80, targetTemperatureMax: 100, targetTemperatureStep: 0.1,
                readyStartTime: nil))),
            Widget(code: "CMSteamBoilerLevel", index: 1, kind: .steamBoilerLevel(SteamBoilerLevel(
                status: .off, enabled: false, enabledSupported: true, targetLevel: .level2,
                targetLevelSupported: true, readyStartTime: nil))),
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ])
        XCTAssertEqual(returned, expected)
        XCTAssertEqual(machine.dashboard, expected)
        XCTAssertEqual(machine.baseDashboard, expected)
        XCTAssertEqual(machine.snapshot.dashboard, expected)

        // The upstream test's spot checks, restated.
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .brewing)
        XCTAssertEqual(machine.dashboard?.coffeeBoiler?.enabled, true)
        XCTAssertEqual(machine.dashboard?.coffeeBoiler?.targetTemperature, 95.0)
        XCTAssertEqual(machine.dashboard?.coffeeBoiler?.targetTemperatureMax, 100, "the existing widget keeps max 100")
        XCTAssertEqual(machine.dashboard?.steamBoilerLevel?.enabled, false)
        XCTAssertNil(machine.dashboard?.steamBoilerTemperature, "the Micra has no steam-temperature widget")
        XCTAssertFalse(machine.dashboard?.widgets.contains { $0.code == "CMSteamBoilerTemperature" } ?? true)
        XCTAssertEqual(machine.dashboard?.noWater?.alarm, false)
        XCTAssertEqual(machine.dashboard?.machine.isConnected, false)
        XCTAssertEqual(machine.model, .lineaMicra)
        XCTAssertEqual(harness.backend?.count(pathSuffix: ""), 0, "no cloud request")
    }

    /// Upstream: test_get_dashboard_no_bluetooth (tests/test_bluetooth_dashboard.py:183) [D02]
    func testRefreshWithoutClientThrows() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, bluetooth: false)
        let machine = harness.machine
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)
        XCTAssertFalse(machine.hasBluetoothClient)

        let expected = LaMarzoccoError.bluetoothConnectionFailed("Bluetooth client not initialized")
        let dashboardError = await captureError { try await machine.refreshDashboardFromBluetooth() }
        XCTAssertEqual(dashboardError as? LaMarzoccoError, expected)
        let modelError = await captureError { try await machine.refreshModelFromBluetooth() }
        XCTAssertEqual(modelError as? LaMarzoccoError, expected)

        XCTAssertEqual(machine.baseDashboard, seed)
        XCTAssertEqual(machine.dashboard, seed)
        XCTAssertEqual(harness.backend?.count(pathSuffix: ""), 0, "no cloud fallback")

        // Also without either client and without any dashboard.
        let bare = BluetoothMachineHarness(seed: .none, cloud: false, bluetooth: false)
        let bareError = await captureError { try await bare.machine.refreshDashboardFromBluetooth() }
        XCTAssertEqual(bareError as? LaMarzoccoError, expected)
        XCTAssertNil(bare.machine.dashboard)
        XCTAssertNil(bare.machine.baseDashboard)
    }

    /// Upstream: test_get_model_info_from_bluetooth (tests/test_bluetooth_dashboard.py:189) [D03]
    ///
    /// Upstream injects `ModelName.GS3`; on the wire the GS3 AV reports family `"GS3"`, which maps to
    /// `.gs3AV` (D8, BT-RSP-CAP-002).
    func testModelInfoFromCapabilities() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: [
            .machineCapabilities: capabilitiesReply(family: "GS3", groupsNumber: 3, coffeeBoilersNumber: 2,
                                                    hasCupWarmer: true),
        ])
        let machine = harness.machine
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)

        let capabilities = try await machine.refreshModelFromBluetooth()

        XCTAssertEqual(capabilities, BluetoothMachineCapabilities(
            family: .gs3AV, rawFamily: "GS3", groupsNumber: 3, coffeeBoilersNumber: 2, hasCupWarmer: true,
            steamBoilersNumber: 1, teaDosesNumber: 0, machineModes: [.brewing, .standby],
            schedulingType: "weekly"))
        XCTAssertEqual(readRequests(harness), frames([.machineCapabilities]), "capabilities read exactly once")
        XCTAssertEqual(machine.model, .gs3AV)

        // Only machine.model changes: every other identity field and every widget is kept.
        var expectedMachine = seed.machine
        expectedMachine.model = .gs3AV
        let expected = Dashboard(machine: expectedMachine, widgets: seed.widgets)
        XCTAssertEqual(machine.baseDashboard, expected)
        XCTAssertEqual(machine.dashboard, expected)
    }

    /// Upstream: test_get_dashboard_initializes_missing_widgets (tests/test_bluetooth_dashboard.py:213) [D04]
    func testRefreshCreatesMissingWidgetsMiniR() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .empty, settingResponses: [
            .machineCapabilities: capabilitiesReply(family: "LINEAMINI2023", hasCupWarmer: true),
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("false".utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: boilersReply([("CoffeeBoiler1", true, 92, 91), ("SteamBoiler", true, 130, 125)]),
        ])
        let machine = harness.machine
        XCTAssertEqual(machine.baseDashboard?.widgets, [])

        let capabilities = try await machine.refreshModelFromBluetooth()
        XCTAssertEqual(capabilities.family, .lineaMiniR)
        let returned = try await machine.refreshDashboardFromBluetooth()

        XCTAssertEqual(machine.model, .lineaMiniR)
        // Capabilities read once (explicitly); the dashboard refresh doesn't read them again.
        XCTAssertEqual(readRequests(harness),
                       frames([.machineCapabilities, .machineMode, .isPlumbedIn, .tankStatus, .boilers]))

        // BT-DASH-SNAP-002 (tests/__snapshots__/test_bluetooth_dashboard.ambr:56-108): appended in the
        // fixed order, every index 1, coffee max 110 (the upstream default), no steam-temperature widget.
        let expected = Dashboard(machine: Machine(serialNumber: BluetoothMachineHarness.serial, model: .lineaMiniR),
                                 widgets: [
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(MachineStatus(
                status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                nextStatus: nil, brewingStartTime: nil))),
            Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(CoffeeBoiler(
                status: .ready, enabled: true, enabledSupported: false, targetTemperature: 92.0,
                targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1,
                readyStartTime: nil))),
            Widget(code: "CMSteamBoilerLevel", index: 1, kind: .steamBoilerLevel(SteamBoilerLevel(
                status: .ready, enabled: true, enabledSupported: true, targetLevel: .level2,
                targetLevelSupported: true, readyStartTime: nil))),
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ])
        XCTAssertEqual(returned, expected)
        XCTAssertEqual(machine.dashboard, expected)
        XCTAssertEqual(machine.baseDashboard, expected)
    }

    /// Upstream: test_get_dashboard_without_steam_level_support (tests/test_bluetooth_dashboard.py:269) [D05]
    ///
    /// Family `"GS3"` resolves to `.gs3AV` (D8); neither GS3 model sets steam by level.
    func testRefreshGS3UsesSteamTemperature() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .empty, settingResponses: [
            .machineCapabilities: capabilitiesReply(family: "GS3", groupsNumber: 3, coffeeBoilersNumber: 2,
                                                    hasCupWarmer: true),
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("false".utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: boilersReply([("CoffeeBoiler1", true, 94, 93), ("SteamBoiler", true, 128, 120)]),
        ])
        let machine = harness.machine

        try await machine.refreshModelFromBluetooth()
        let returned = try await machine.refreshDashboardFromBluetooth()

        XCTAssertEqual(machine.model, .gs3AV)
        XCTAssertFalse(Model.steamLevelModels.contains(.gs3AV))
        XCTAssertNil(returned.steamBoilerLevel, "the GS3 has no steam-level widget")
        XCTAssertEqual(returned.steamBoilerTemperature?.enabled, true)
        XCTAssertEqual(returned.steamBoilerTemperature?.targetTemperature, 128.0)

        // Non-Mini defaults: 20…134, enabledSupported false, supported true (Q12).
        let expected = Dashboard(machine: Machine(serialNumber: BluetoothMachineHarness.serial, model: .gs3AV),
                                 widgets: [
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(MachineStatus(
                status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                nextStatus: nil, brewingStartTime: nil))),
            Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(CoffeeBoiler(
                status: .ready, enabled: true, enabledSupported: false, targetTemperature: 94.0,
                targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1,
                readyStartTime: nil))),
            Widget(code: "CMSteamBoilerTemperature", index: 1, kind: .steamBoilerTemperature(SteamBoilerTemperature(
                status: .ready, enabled: true, enabledSupported: false, targetTemperature: 128.0,
                targetTemperatureMin: 20, targetTemperatureMax: 134, targetTemperatureStep: 0.1,
                targetTemperatureSupported: true, readyStartTime: nil))),
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ])
        XCTAssertEqual(returned, expected)
        XCTAssertEqual(machine.baseDashboard, expected)
    }

    /// Upstream: test_get_dashboard_mini_original_temperature_only (tests/test_bluetooth_dashboard.py:334) [D06]
    ///
    /// Upstream injects `ModelName.LINEA_MINI`; the original Linea Mini reports family `"LINEA"` (D8).
    func testRefreshOriginalMiniUsesSteamTemperature() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .empty, settingResponses: [
            .machineCapabilities: capabilitiesReply(family: "LINEA"),
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("false".utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: boilersReply([("CoffeeBoiler1", true, 93, 92), ("SteamBoiler", true, 127, 115)]),
        ])
        let machine = harness.machine

        try await machine.refreshModelFromBluetooth()
        let returned = try await machine.refreshDashboardFromBluetooth()

        XCTAssertEqual(machine.model, .lineaMini)
        XCTAssertNil(returned.steamBoilerLevel, "the original Mini has no steam-level widget")
        XCTAssertEqual(returned.steamBoilerTemperature?.enabled, true)
        XCTAssertEqual(returned.steamBoilerTemperature?.targetTemperature, 127.0)

        // Mini defaults: 95…140, not adjustable (supported false).
        let expected = Dashboard(machine: Machine(serialNumber: BluetoothMachineHarness.serial, model: .lineaMini),
                                 widgets: [
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(MachineStatus(
                status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                nextStatus: nil, brewingStartTime: nil))),
            Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(CoffeeBoiler(
                status: .ready, enabled: true, enabledSupported: false, targetTemperature: 93.0,
                targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1,
                readyStartTime: nil))),
            Widget(code: "CMSteamBoilerTemperature", index: 1, kind: .steamBoilerTemperature(SteamBoilerTemperature(
                status: .ready, enabled: true, enabledSupported: false, targetTemperature: 127.0,
                targetTemperatureMin: 95, targetTemperatureMax: 140, targetTemperatureStep: 0.1,
                targetTemperatureSupported: false, readyStartTime: nil))),
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ])
        XCTAssertEqual(returned, expected)
        XCTAssertEqual(machine.baseDashboard, expected)
    }

    /// Upstream: test_get_dashboard_from_bluetooth_statuses (tests/test_bluetooth_dashboard.py:606) [D15, D16, D17, D18, D19]
    ///
    /// BT-DASH-STATUS-001…005 (SPEC §4.17): `(mode, plumbedIn, tankOK, steamEnabled)` →
    /// `(machine status, coffee status, steam-level status, NoWater.alarm)`.
    func testStatusDerivation() async throws {
        struct Case {
            let id: String
            let mode: String
            let plumbedIn: Bool
            let tankOK: Bool
            let steamEnabled: Bool
            let expected: (MachineState, BoilerStatus, BoilerStatus, Bool)
        }
        let cases = [
            Case(id: "D15", mode: "BrewingMode", plumbedIn: false, tankOK: true, steamEnabled: true,
                 expected: (.poweredOn, .ready, .ready, false)),
            Case(id: "D16", mode: "EcoMode", plumbedIn: false, tankOK: true, steamEnabled: true,
                 expected: (.eco, .eco, .eco, false)),
            Case(id: "D17", mode: "StandBy", plumbedIn: false, tankOK: true, steamEnabled: false,
                 expected: (.standby, .standby, .off, false)),
            Case(id: "D18", mode: "BrewingMode", plumbedIn: false, tankOK: false, steamEnabled: true,
                 expected: (.poweredOn, .noWater, .noWater, true)),
            // Plumbed-in machines report an empty tank; that's not a water alarm.
            Case(id: "D19", mode: "BrewingMode", plumbedIn: true, tankOK: false, steamEnabled: true,
                 expected: (.poweredOn, .ready, .ready, false)),
        ]
        for c in cases {
            let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: [
                .machineMode: Data("\"\(c.mode)\"".utf8),
                .isPlumbedIn: Data((c.plumbedIn ? "true" : "false").utf8),
                .tankStatus: Data((c.tankOK ? #""true""# : "false").utf8),
                .boilers: boilersReply([("CoffeeBoiler1", true, 93, 92), ("SteamBoiler", c.steamEnabled, 128, 120)]),
            ])
            let dashboard = try await harness.machine.refreshDashboardFromBluetooth()
            XCTAssertEqual(dashboard.machineStatus?.status, c.expected.0, "\(c.id) machine status")
            XCTAssertEqual(dashboard.coffeeBoiler?.status, c.expected.1, "\(c.id) coffee status")
            XCTAssertEqual(dashboard.steamBoilerLevel?.status, c.expected.2, "\(c.id) steam-level status")
            XCTAssertEqual(dashboard.noWater?.alarm, c.expected.3, "\(c.id) NoWater.alarm")
            XCTAssertEqual(harness.machine.baseDashboard, dashboard, "\(c.id) stored as the base")
        }
    }

    /// Upstream: test_get_dashboard_from_bluetooth_plumb_in_unsupported (tests/test_bluetooth_dashboard.py:674) [D26]
    ///
    /// Upstream's `get_plumbed_in` raises `ValueError("bad")`; here the reply `bad` is not JSON, so the
    /// read throws `.decoding`, which counts as "not plumbed in": the empty tank then raises the alarm.
    func testPlumbInUnsupportedFallsBackToTank() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: [
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("bad".utf8),
            .tankStatus: Data("false".utf8),
            .boilers: Data("[]".utf8),
        ])
        let machine = harness.machine
        let bluetooth = try XCTUnwrap(harness.bluetooth)

        // The plumb-in read on its own really is a decoding failure.
        let plumbError = await captureError { _ = try await bluetooth.isPlumbedIn() }
        guard case .decoding = plumbError as? LaMarzoccoError else {
            return XCTFail("expected .decoding from the plumb-in read, got \(String(describing: plumbError))")
        }

        let dashboard = try await machine.refreshDashboardFromBluetooth()

        XCTAssertEqual(dashboard.noWater?.alarm, true)
        // Boilers `[]`: the boiler widgets of the seed are kept untouched.
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)
        XCTAssertEqual(dashboard.coffeeBoiler, seed.coffeeBoiler)
        XCTAssertEqual(dashboard.steamBoilerLevel, seed.steamBoilerLevel)
        XCTAssertEqual(dashboard.machineStatus?.status, .poweredOn)
        // The refresh went on after the undecodable plumb-in reply.
        XCTAssertEqual(Array(readRequests(harness).suffix(4)),
                       frames([.machineMode, .isPlumbedIn, .tankStatus, .boilers]))

        // Plumb-in errors other than `.decoding` propagate, with no mutation and no further reads.
        let timeout = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: [
            .machineMode: Data(#""BrewingMode""#.utf8),
            .tankStatus: Data("false".utf8),
            .boilers: Data("[]".utf8),
        ])
        failReads(of: .isPlumbedIn, with: .timedOut("read"), in: timeout)
        let error = await captureError { try await timeout.machine.refreshDashboardFromBluetooth() }
        XCTAssertEqual(error as? LaMarzoccoError, .bluetoothTimedOut("read"))
        XCTAssertEqual(readRequests(timeout), frames([.machineMode, .isPlumbedIn]))
        XCTAssertEqual(timeout.machine.baseDashboard, seed)
        XCTAssertEqual(timeout.machine.dashboard, seed)
    }

    /// Upstream: test_get_model_info_from_bluetooth_errors (tests/test_machine.py:1049) [M26]
    ///
    /// Upstream's `BleakError("boom")` from `get_machine_capabilities` is a GATT error on the read here.
    func testModelInfoErrors() async throws {
        // No Bluetooth client.
        let noClient = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, bluetooth: false)
        let noClientError = await captureError { try await noClient.machine.refreshModelFromBluetooth() }
        XCTAssertEqual(noClientError as? LaMarzoccoError,
                       .bluetoothConnectionFailed("Bluetooth client not initialized"))

        // A transport error on the capabilities read propagates; the model is unchanged.
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: [
            .machineCapabilities: capabilitiesReply(family: "GS3"),
        ])
        let gatt = BluetoothTransportError.gatt(domain: "CBATTErrorDomain", code: 14)
        failReads(of: .machineCapabilities, with: gatt, in: harness)
        let error = await captureError { try await harness.machine.refreshModelFromBluetooth() }
        XCTAssertEqual(error as? LaMarzoccoError, .bluetoothConnectionFailed(gatt.description))
        XCTAssertEqual(readRequests(harness), frames([.machineCapabilities]))
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)
        XCTAssertEqual(harness.machine.model, .lineaMicra)
        XCTAssertEqual(harness.machine.baseDashboard, seed)
        XCTAssertEqual(harness.machine.dashboard, seed)

        // A failed connect propagates too (every connect attempt fails).
        let unreachable = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, failure: .connect)
        let connectError = await captureError { try await unreachable.machine.refreshModelFromBluetooth() }
        guard case .bluetoothConnectionFailed = connectError as? LaMarzoccoError else {
            return XCTFail("expected .bluetoothConnectionFailed, got \(String(describing: connectError))")
        }
        XCTAssertEqual(unreachable.machine.baseDashboard, seed)
    }

    /// Upstream: test_get_model_info_from_bluetooth_unknown_model (tests/test_machine.py:1063) [M27]
    ///
    /// Restated: upstream stores the unknown family and keeps the model code. Angstrom's decoder rejects
    /// an unknown family (`.decoding`, BT-RSP-CAP-002), so the read throws and the model is unchanged.
    func testUnknownFamilyThrowsAndKeepsModel() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: [
            .machineCapabilities: capabilitiesReply(family: "FOO"),
        ])
        let machine = harness.machine
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)

        let error = await captureError { try await machine.refreshModelFromBluetooth() }
        guard case .decoding = error as? LaMarzoccoError else {
            return XCTFail("expected .decoding, got \(String(describing: error))")
        }
        XCTAssertEqual(machine.model, .lineaMicra)
        XCTAssertEqual(machine.baseDashboard, seed)
        XCTAssertEqual(machine.dashboard, seed)

        // On an unidentified machine the dashboard refresh fails the same way, before any other read.
        let unknown = Self.seed(model: .unknown("X"))
        let unidentified = BluetoothMachineHarness(model: .unknown("X"), seed: .custom(unknown), settingResponses: [
            .machineCapabilities: capabilitiesReply(family: "FOO"),
            .machineMode: Data(#""BrewingMode""#.utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: Data("[]".utf8),
        ])
        let refreshError = await captureError { try await unidentified.machine.refreshDashboardFromBluetooth() }
        guard case .decoding = refreshError as? LaMarzoccoError else {
            return XCTFail("expected .decoding, got \(String(describing: refreshError))")
        }
        XCTAssertEqual(readRequests(unidentified), frames([.machineCapabilities]))
        XCTAssertEqual(unidentified.machine.model, .unknown("X"))
        XCTAssertEqual(unidentified.machine.baseDashboard, unknown)
    }

    /// Upstream: test_get_dashboard_from_bluetooth_error (tests/test_machine.py:1079) [M28]
    ///
    /// Upstream's `BleakError("boom")` from `get_machine_mode` is a GATT error on the read here.
    func testRefreshErrorPropagatesWithoutMutation() async throws {
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)
        let responses: [BluetoothReadSetting: Data] = [
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("false".utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: boilersReply([("CoffeeBoiler1", true, 95, 94), ("SteamBoiler", false, 128, 50)]),
        ]
        let gatt = BluetoothTransportError.gatt(domain: "CBATTErrorDomain", code: 14)

        // A failure at each read: everything before it was read, nothing after, nothing changed.
        let ordered: [BluetoothReadSetting] = [.machineMode, .isPlumbedIn, .tankStatus, .boilers]
        for (position, failing) in ordered.enumerated() {
            let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: responses)
            let machine = harness.machine
            failReads(of: failing, with: gatt, in: harness)

            let error = await captureError { try await machine.refreshDashboardFromBluetooth() }
            XCTAssertEqual(error as? LaMarzoccoError, .bluetoothConnectionFailed(gatt.description), "\(failing)")
            XCTAssertEqual(readRequests(harness), frames(Array(ordered.prefix(position + 1))), "\(failing)")
            XCTAssertEqual(machine.baseDashboard, seed, "\(failing): base unchanged")
            XCTAssertEqual(machine.dashboard, seed, "\(failing): dashboard unchanged")
            XCTAssertNil(machine.lastUpdateAt, "\(failing)")
            XCTAssertEqual(harness.backend?.count(pathSuffix: ""), 0, "\(failing): no cloud fallback")
        }

        // A malformed reply (`.decoding`) on a read other than plumb-in also propagates.
        var malformed = responses
        malformed[.boilers] = Data("bad".utf8)
        let decoding = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: malformed)
        let decodingError = await captureError { try await decoding.machine.refreshDashboardFromBluetooth() }
        guard case .decoding = decodingError as? LaMarzoccoError else {
            return XCTFail("expected .decoding, got \(String(describing: decodingError))")
        }
        XCTAssertEqual(decoding.machine.baseDashboard, seed)
        XCTAssertEqual(decoding.machine.dashboard, seed)
    }

    // MARK: - Angstrom-only

    /// Angstrom-only: D17 — with no model (nil) or an `.unknown` one, the capabilities are read first and
    /// the reported family (not a silent Linea Micra default) drives the widget synthesis.
    func testUnknownModelReadsCapabilitiesFirst() async throws {
        let responses: [BluetoothReadSetting: Data] = [
            .machineCapabilities: capabilitiesReply(family: "GS3"),
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("false".utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: boilersReply([("CoffeeBoiler1", true, 94, 93), ("SteamBoiler", true, 128, 120)]),
        ]
        let gs3Widgets = [
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(MachineStatus(
                status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                nextStatus: nil, brewingStartTime: nil))),
            Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(CoffeeBoiler(
                status: .ready, enabled: true, enabledSupported: false, targetTemperature: 94.0,
                targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1,
                readyStartTime: nil))),
            Widget(code: "CMSteamBoilerTemperature", index: 1, kind: .steamBoilerTemperature(SteamBoilerTemperature(
                status: .ready, enabled: true, enabledSupported: false, targetTemperature: 128.0,
                targetTemperatureMin: 20, targetTemperatureMax: 134, targetTemperatureStep: 0.1,
                targetTemperatureSupported: true, readyStartTime: nil))),
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ]

        // 1. No dashboard, no settings, no schedule: the model is nil.
        let none = BluetoothMachineHarness(seed: .none, cloud: false, settingResponses: responses)
        XCTAssertNil(none.machine.model)
        let fromNothing = try await none.machine.refreshDashboardFromBluetooth()
        XCTAssertEqual(readRequests(none),
                       frames([.machineCapabilities, .machineMode, .isPlumbedIn, .tankStatus, .boilers]))
        let created = Dashboard(machine: Machine(serialNumber: BluetoothMachineHarness.serial, model: .gs3AV),
                                widgets: gs3Widgets)
        XCTAssertEqual(fromNothing, created)
        XCTAssertEqual(none.machine.baseDashboard, created)
        XCTAssertEqual(none.machine.model, .gs3AV)

        // 2. A dashboard whose model is `.unknown`: identity kept except the model.
        var identity = Machine(serialNumber: BluetoothMachineHarness.serial, name: "Bar", model: .unknown("X"),
                               isConnected: true, connectionDate: Date(timeIntervalSince1970: 1_704_110_400))
        let unknownSeed = Dashboard(machine: identity, widgets: [])
        let unknown = BluetoothMachineHarness(model: .unknown("X"), seed: .custom(unknownSeed),
                                              settingResponses: responses)
        XCTAssertEqual(unknown.machine.model, .unknown("X"))
        let fromUnknown = try await unknown.machine.refreshDashboardFromBluetooth()
        XCTAssertEqual(readRequests(unknown),
                       frames([.machineCapabilities, .machineMode, .isPlumbedIn, .tankStatus, .boilers]))
        identity.model = .gs3AV
        XCTAssertEqual(fromUnknown, Dashboard(machine: identity, widgets: gs3Widgets))
        XCTAssertEqual(unknown.machine.model, .gs3AV)
        XCTAssertNil(fromUnknown.steamBoilerLevel, "no Micra default: no steam-level widget")
        XCTAssertEqual(unknown.backend?.count(pathSuffix: ""), 0)

        // 3. The model step's write stands when a later read fails (step 4 covers only the reads).
        let failing = BluetoothMachineHarness(model: .unknown("X"), seed: .custom(unknownSeed),
                                              settingResponses: responses)
        failReads(of: .machineMode, with: .timedOut("read"), in: failing)
        let error = await captureError { try await failing.machine.refreshDashboardFromBluetooth() }
        XCTAssertEqual(error as? LaMarzoccoError, .bluetoothTimedOut("read"))
        XCTAssertEqual(readRequests(failing), frames([.machineCapabilities, .machineMode]))
        var modelOnly = unknownSeed.machine
        modelOnly.model = .gs3AV
        XCTAssertEqual(failing.machine.baseDashboard, Dashboard(machine: modelOnly, widgets: []))
    }

    /// Angstrom-only: §4.17 — with a known model the capabilities are never read, even when the machine
    /// would report another family; the known model drives the synthesis.
    func testKnownModelSkipsCapabilities() async throws {
        let responses: [BluetoothReadSetting: Data] = [
            .machineCapabilities: capabilitiesReply(family: "GS3"),
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("false".utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: boilersReply([("CoffeeBoiler1", true, 93, 92), ("SteamBoiler", true, 128, 120)]),
        ]

        // Known from the dashboard.
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: responses)
        let dashboard = try await harness.machine.refreshDashboardFromBluetooth()
        XCTAssertFalse(readRequests(harness).contains(frame(.machineCapabilities)))
        XCTAssertEqual(harness.machine.model, .lineaMicra)
        XCTAssertNotNil(dashboard.steamBoilerLevel, "Micra synthesis: steam level kept")
        XCTAssertNil(dashboard.steamBoilerTemperature, "Micra synthesis: steam temperature removed")

        // Known only from the settings (no dashboard yet): the dashboard is created with that model.
        let settingsOnly = BluetoothMachineHarness(model: .lineaMicra, seed: .none, settingResponses: responses)
        try await settingsOnly.machine.refreshSettings()
        XCTAssertNil(settingsOnly.machine.dashboard)
        let settingsModel = try XCTUnwrap(settingsOnly.machine.settings?.machine.model)
        XCTAssertFalse(Self.isUnknown(settingsModel))
        XCTAssertEqual(settingsOnly.machine.model, settingsModel)
        let created = try await settingsOnly.machine.refreshDashboardFromBluetooth()
        XCTAssertFalse(readRequests(settingsOnly).contains(frame(.machineCapabilities)))
        XCTAssertEqual(created.machine, Machine(serialNumber: BluetoothMachineHarness.serial, model: settingsModel))
        XCTAssertEqual(created.widgets.map(\.code),
                       ["CMMachineStatus", "CMCoffeeBoiler", "CMSteamBoilerLevel", "CMNoWater"])
        XCTAssertEqual(settingsOnly.machine.baseDashboard, created)
    }

    /// Angstrom-only: §4.17 — the four reads go out in upstream order (MACH:356-364): machine mode,
    /// plumb-in, tank, boilers; one request each, nothing else on the read characteristic.
    func testReadOrder() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: [
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("false".utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: boilersReply([("CoffeeBoiler1", true, 93, 92), ("SteamBoiler", true, 128, 120)]),
        ])
        try await harness.machine.refreshDashboardFromBluetooth()

        XCTAssertEqual(readRequests(harness), [
            Data("machineMode\0".utf8), Data("isPlumbedIn\0".utf8), Data("tankStatus\0".utf8), Data("boilers\0".utf8),
        ])
        // All over one authenticated link, each request a write then a read of 0a0b….
        XCTAssertEqual(harness.links.count, 1)
        let link = try XCTUnwrap(harness.links.first)
        let readOps = link.recordedOps.filter { op in
            switch op {
            case .write(let c, _), .read(let c): return c == BluetoothConstants.readCharacteristic
            default: return false
            }
        }
        XCTAssertEqual(readOps, [
            .write(BluetoothConstants.readCharacteristic, Data("machineMode\0".utf8)),
            .read(BluetoothConstants.readCharacteristic),
            .write(BluetoothConstants.readCharacteristic, Data("isPlumbedIn\0".utf8)),
            .read(BluetoothConstants.readCharacteristic),
            .write(BluetoothConstants.readCharacteristic, Data("tankStatus\0".utf8)),
            .read(BluetoothConstants.readCharacteristic),
            .write(BluetoothConstants.readCharacteristic, Data("boilers\0".utf8)),
            .read(BluetoothConstants.readCharacteristic),
        ])
    }

    /// Angstrom-only: Q11 — a Bluetooth refresh doesn't stamp `lastUpdateAt` (a cloud freshness signal)
    /// and leaves `settings`, `schedule` and the machine identity (name, `connected`, `connectionDate`)
    /// untouched.
    func testDoesNotStampLastUpdateAt() async throws {
        let responses: [BluetoothReadSetting: Data] = [
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("false".utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: boilersReply([("CoffeeBoiler1", true, 95, 94), ("SteamBoiler", false, 128, 50)]),
        ]

        // Never stamped before: stays nil.
        let fresh = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: responses)
        XCTAssertNil(fresh.machine.lastUpdateAt)
        try await fresh.machine.refreshDashboardFromBluetooth()
        XCTAssertNil(fresh.machine.lastUpdateAt)

        // Stamped by the cloud before: kept as is.
        let identity = Machine(serialNumber: BluetoothMachineHarness.serial, name: "Bar", model: .lineaMicra,
                               isConnected: true, connectionDate: Date(timeIntervalSince1970: 1_704_110_400))
        let seed = Dashboard(machine: identity,
                             widgets: BluetoothMachineHarness.seedDashboard(model: .lineaMicra).widgets)
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .custom(seed), settingResponses: responses)
        let machine = harness.machine
        try await machine.refreshSettings()
        try await machine.refreshSchedule()
        let settings = try XCTUnwrap(machine.settings)
        let schedule = try XCTUnwrap(machine.schedule)
        let stamp = Date(timeIntervalSince1970: 1_767_000_000)
        machine.lastUpdateAt = stamp

        let dashboard = try await machine.refreshDashboardFromBluetooth()

        XCTAssertEqual(machine.lastUpdateAt, stamp)
        XCTAssertEqual(machine.settings, settings)
        XCTAssertEqual(machine.schedule, schedule)
        XCTAssertEqual(dashboard.machine, identity)
        XCTAssertEqual(machine.isMachineConnected, true)
        XCTAssertEqual(machine.machineLastConnectionDate, Date(timeIntervalSince1970: 1_704_110_400))
        XCTAssertEqual(dashboard.machineStatus?.status, .poweredOn, "the refresh did apply")
        XCTAssertEqual(harness.backend?.count(pathSuffix: "/dashboard"), 0)
    }

    /// Angstrom-only: §4.19 — with a shot-counter overlay held, a Bluetooth refresh writes the base and
    /// the overlay is re-applied over the new base: the returned and rendered dashboards carry the
    /// brewing status, the base (and the snapshot) the plain Bluetooth state.
    func testRefreshReappliesActiveOverlay() async throws {
        let harness = BluetoothMachineHarness(model: .lineaMicra, seed: .standard, settingResponses: [
            .machineMode: Data(#""BrewingMode""#.utf8),
            .isPlumbedIn: Data("false".utf8),
            .tankStatus: Data(#""true""#.utf8),
            .boilers: boilersReply([("CoffeeBoiler1", true, 95, 94), ("SteamBoiler", false, 128, 50)]),
        ])
        let machine = harness.machine
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)

        let receivedAt = Date(timeIntervalSince1970: 1_767_268_830)
        let update = BluetoothShotCounterUpdate(state: .brewing, timerValue: 30, receivedAt: receivedAt,
                                                raw: BluetoothBrewingData(ev: true, brewingTime: 30))
        let startTime = Date(timeIntervalSince1970: 1_767_268_800)
        XCTAssertEqual(update.brewingStartTime, startTime)
        machine.bluetoothBrewingUpdate = update
        machine.renderDashboard()
        XCTAssertEqual(machine.dashboard?.machineStatus?.status, .brewing, "overlay active before the refresh")
        XCTAssertEqual(machine.baseDashboard, seed)

        let returned = try await machine.refreshDashboardFromBluetooth()

        let expectedBase = seed.applyingBluetoothState(
            BluetoothDashboardState(machineMode: .brewing, isPlumbedIn: false, tankStatus: true, boilers: [
                BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 95, current: 94),
                BluetoothBoilerDetails(id: .steam, isEnabled: false, target: 128, current: 50),
            ]), model: .lineaMicra)
        XCTAssertEqual(expectedBase.machineStatus?.status, .poweredOn)
        XCTAssertEqual(machine.baseDashboard, expectedBase, "the overlay never leaks into the base")
        XCTAssertEqual(machine.snapshot.dashboard, expectedBase)

        let expectedRendered = expectedBase.overlayingBluetoothBrewing(update)
        XCTAssertNotEqual(expectedRendered, expectedBase)
        XCTAssertEqual(returned, expectedRendered, "returns the rendered dashboard")
        XCTAssertEqual(machine.dashboard, expectedRendered)
        XCTAssertEqual(returned.machineStatus, MachineStatus(status: .brewing, availableModes: [.brewing, .standby],
                                                             mode: .brewing, nextStatus: nil,
                                                             brewingStartTime: startTime))
        // The new base's Bluetooth values show through the overlay.
        XCTAssertEqual(returned.coffeeBoiler?.targetTemperature, 95.0)
        XCTAssertEqual(returned.steamBoilerLevel?.status, .off)
        XCTAssertNil(returned.steamBoilerTemperature)
        XCTAssertEqual(returned.noWater?.alarm, false)
        XCTAssertEqual(machine.bluetoothBrewingUpdate, update, "the refresh doesn't clear the overlay")
    }

    // MARK: - Private helpers

    /// `Machine(serialNumber:model:)` with no widgets.
    private static func seed(model: Model) -> Dashboard {
        Dashboard(machine: Machine(serialNumber: BluetoothMachineHarness.serial, model: model), widgets: [])
    }

    private static func isUnknown(_ model: Model) -> Bool {
        if case .unknown = model { return true }
        return false
    }

    /// Upstream's `_capabilities(family, **overrides)` (`tests/test_bluetooth_dashboard.py:34-50`) as the
    /// `machineCapabilities` wire reply (shape of BT-RSP-CAP-001).
    private func capabilitiesReply(family: String, groupsNumber: Int = 1, coffeeBoilersNumber: Int = 1,
                                   hasCupWarmer: Bool = false) -> Data {
        Data("""
        [{"family":"\(family)","groupsNumber":\(groupsNumber),"coffeeBoilersNumber":\(coffeeBoilersNumber),\
        "hasCupWarmer":\(hasCupWarmer),"steamBoilersNumber":1,"teaDosesNumber":0,\
        "machineModes":["BrewingMode","StandBy"],"schedulingType":"weekly"}]
        """.utf8)
    }

    /// The `boilers` wire reply (shape of BT-RSP-BOIL-001), in the given order.
    private func boilersReply(_ boilers: [(id: String, enabled: Bool, target: Int, current: Int)]) -> Data {
        let objects = boilers.map { b in
            #"{"id":"\#(b.id)","isEnabled":\#(b.enabled),"target":\#(b.target),"current":\#(b.current)}"#
        }
        return Data("[\(objects.joined(separator: ","))]".utf8)
    }

    /// The read-request frame of `setting` (BT-READ-REQ: raw value + NUL).
    private func frame(_ setting: BluetoothReadSetting) -> Data {
        Data((setting.rawValue + "\0").utf8)
    }

    private func frames(_ settings: [BluetoothReadSetting]) -> [Data] {
        settings.map(frame)
    }

    /// Every read request the client wrote (to 0a0b…), across all links, in order.
    private func readRequests(_ harness: BluetoothMachineHarness) -> [Data] {
        harness.bluetoothWrites(to: BluetoothConstants.readCharacteristic)
    }

    /// Makes every link the harness central hands out fail the 0a0b… read that answers `setting`.
    private func failReads(of setting: BluetoothReadSetting, with error: BluetoothTransportError,
                           in harness: BluetoothMachineHarness) {
        let original = harness.central.makeLink
        harness.central.makeLink = {
            let link = original()
            let last = LastRequestedSetting()
            let machineWrite = link.onWrite
            let machineRead = link.onRead
            link.onWrite = { characteristic, data in
                if characteristic == BluetoothConstants.readCharacteristic {
                    last.set(BluetoothReadSetting(rawValue: String(decoding: data.filter { $0 != 0 }, as: UTF8.self)))
                }
                try machineWrite(characteristic, data)
            }
            link.onRead = { characteristic in
                if characteristic == BluetoothConstants.readCharacteristic, last.get() == setting { throw error }
                return try machineRead(characteristic)
            }
            return link
        }
    }

    private func captureError(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }
}

/// The setting last requested on one fake link (written to 0a0b…).
private final class LastRequestedSetting: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BluetoothReadSetting?

    func set(_ setting: BluetoothReadSetting?) {
        lock.lock()
        defer { lock.unlock() }
        value = setting
    }

    func get() -> BluetoothReadSetting? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
