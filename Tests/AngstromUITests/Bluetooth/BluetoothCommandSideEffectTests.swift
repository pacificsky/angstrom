import XCTest
@testable import Angstrom
@testable import AngstromUI
import AngstromTestSupport

/// BT-W3-07: the optimistic updates (SPEC §4.20) that follow a BLE-first command (§4.16), and their
/// absence when the command fails. Upstream's `mock_machine_with_dashboard` is a Bluetooth-only machine
/// seeded with BT-DASH-SEED-001 (`tests/test_bluetooth_dashboard.py:68-105`): here
/// `BluetoothMachineHarness(cloud: false)` with the `.standard` seed. The expected widgets are
/// BT-DASH-SNAP-003…005 (§9.3.6, `tests/__snapshots__/test_bluetooth_dashboard.ambr:110-145`).
@MainActor
final class BluetoothCommandSideEffectTests: XCTestCase {
    private let write = BluetoothConstants.writeCharacteristic
    /// The synthesized response for `BluetoothTestVectors.commandSuccess` (D18).
    private let bluetoothSuccess = CommandResponse(id: "test-id", status: .success, errorCode: nil)

    /// Upstream: test_set_power_updates_dashboard (tests/test_bluetooth_dashboard.py:396) [D07]
    ///
    /// BT-DASH-SNAP-004: `setPower(on: true)` over Bluetooth → `CMMachineStatus` `mode` brewing, **status
    /// still standby**, available modes and the optionals untouched; nothing else changes.
    func testSetPowerUpdatesModeOnly() async throws {
        let harness = BluetoothMachineHarness(cloud: false)
        let machine = harness.machine
        let seed = try XCTUnwrap(machine.dashboard)

        let response = try await machine.setPower(on: true)

        XCTAssertEqual(response, bluetoothSuccess)
        XCTAssertEqual(harness.bluetoothWrites(to: write),
                       [frame(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#)])
        let dashboard = try XCTUnwrap(machine.dashboard)
        XCTAssertEqual(dashboard.machineStatus, MachineStatus(status: .standby, availableModes: [.brewing, .standby],
                                                              mode: .brewing, nextStatus: nil, brewingStartTime: nil))
        XCTAssertEqual(Array(dashboard.widgets.dropFirst()), Array(seed.widgets.dropFirst()))
        XCTAssertEqual(dashboard.widgets.map(\.code), seed.widgets.map(\.code))
        XCTAssertEqual(dashboard.machine, seed.machine)
        XCTAssertEqual(machine.baseDashboard, dashboard)
        XCTAssertNil(machine.lastError)
    }

    /// Upstream: test_set_power_off_updates_dashboard (tests/test_bluetooth_dashboard.py:414) [D08]
    ///
    /// From mode brewing, `setPower(on: false)` (BT-REQ-002) → mode standby.
    func testSetPowerOffUpdatesMode() async throws {
        let seed = BluetoothMachineHarness.seedDashboard(model: .lineaMicra).settingMachineMode(.brewing)
        XCTAssertEqual(seed.machineStatus?.mode, .brewing)
        let harness = BluetoothMachineHarness(seed: .custom(seed), cloud: false)
        let machine = harness.machine

        let response = try await machine.setPower(on: false)

        XCTAssertEqual(response, bluetoothSuccess)
        XCTAssertEqual(harness.bluetoothWrites(to: write),
                       [frame(#"{"name":"MachineChangeMode","parameter":{"mode":"StandBy"}}"#)])
        XCTAssertEqual(machine.dashboard?.machineStatus,
                       MachineStatus(status: .standby, availableModes: [.brewing, .standby],
                                     mode: .standby, nextStatus: nil, brewingStartTime: nil))
        XCTAssertEqual(machine.dashboard, BluetoothMachineHarness.seedDashboard(model: .lineaMicra))
        XCTAssertEqual(machine.baseDashboard, machine.dashboard)
    }

    /// Upstream: test_set_steam_updates_dashboard (tests/test_bluetooth_dashboard.py:436) [D09]
    ///
    /// `setSteam(on: false)` over Bluetooth → `CMSteamBoilerLevel.enabled == false`, its other fields kept.
    func testSetSteamUpdatesEnabled() async throws {
        let harness = BluetoothMachineHarness(cloud: false)
        let machine = harness.machine

        let response = try await machine.setSteam(on: false)

        XCTAssertEqual(response, bluetoothSuccess)
        XCTAssertEqual(harness.bluetoothWrites(to: write),
                       [frame(#"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":false}}"#)])
        XCTAssertEqual(machine.dashboard?.steamBoilerLevel,
                       SteamBoilerLevel(status: .standby, enabled: false, enabledSupported: true,
                                        targetLevel: .level1, targetLevelSupported: true, readyStartTime: nil))
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .standby)
        XCTAssertEqual(machine.dashboard?.coffeeBoiler?.enabled, true)
    }

    /// Upstream: test_set_coffee_temp_updates_dashboard (tests/test_bluetooth_dashboard.py:452) [D10]
    ///
    /// BT-DASH-SNAP-003: `setCoffeeTargetTemperature(celsius: 96.5)` writes `"value":96.5` unrounded
    /// (BT-REQ-006) → Coffee `(standby, true, false, 96.5, 80, 100, 0.1)`.
    func testSetCoffeeTempUpdatesWidget() async throws {
        let harness = BluetoothMachineHarness(cloud: false)
        let machine = harness.machine

        let response = try await machine.setCoffeeTargetTemperature(celsius: 96.5)

        XCTAssertEqual(response, bluetoothSuccess)
        XCTAssertEqual(harness.bluetoothWrites(to: write),
                       [frame(#"{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":96.5}}"#)])
        XCTAssertEqual(machine.dashboard?.coffeeBoiler,
                       CoffeeBoiler(status: .standby, enabled: true, enabledSupported: false, targetTemperature: 96.5,
                                    targetTemperatureMin: 80, targetTemperatureMax: 100, targetTemperatureStep: 0.1,
                                    readyStartTime: nil))
        XCTAssertEqual(machine.baseDashboard, machine.dashboard)
    }

    /// Upstream: test_set_steam_level_updates_dashboard (tests/test_bluetooth_dashboard.py:470) [D11]
    ///
    /// `setSteamTargetLevel(.level3)` writes the steam target 131 → `CMSteamBoilerLevel.targetLevel == .level3`.
    func testSetSteamLevelUpdatesWidget() async throws {
        let harness = BluetoothMachineHarness(cloud: false)
        let machine = harness.machine

        let response = try await machine.setSteamTargetLevel(.level3)

        XCTAssertEqual(response, bluetoothSuccess)
        XCTAssertEqual(harness.bluetoothWrites(to: write),
                       [frame(#"{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":131}}"#)])
        XCTAssertEqual(machine.dashboard?.steamBoilerLevel,
                       SteamBoilerLevel(status: .standby, enabled: true, enabledSupported: true,
                                        targetLevel: .level3, targetLevelSupported: true, readyStartTime: nil))
        // The steam-temperature widget is not touched by a level change.
        XCTAssertEqual(machine.dashboard?.steamBoilerTemperature?.targetTemperature, 126.0)
    }

    /// Upstream: test_set_steam_temp_updates_dashboard (tests/test_bluetooth_dashboard.py:488) [D12]
    ///
    /// BT-DASH-SNAP-005: model GS3, `setSteamTargetTemperature(celsius: 122.5)` →
    /// SteamTemperature `(standby, true, false, 122.5, 126, 131, 1.0, supported true)`.
    func testSetSteamTempUpdatesWidget() async throws {
        let harness = BluetoothMachineHarness(model: .gs3, cloud: false)
        let machine = harness.machine

        let response = try await machine.setSteamTargetTemperature(celsius: 122.5)

        XCTAssertEqual(response, bluetoothSuccess)
        XCTAssertEqual(harness.bluetoothWrites(to: write),
                       [frame(#"{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":122.5}}"#)])
        XCTAssertEqual(machine.dashboard?.steamBoilerTemperature,
                       SteamBoilerTemperature(status: .standby, enabled: true, enabledSupported: false,
                                              targetTemperature: 122.5, targetTemperatureMin: 126,
                                              targetTemperatureMax: 131, targetTemperatureStep: 1.0,
                                              targetTemperatureSupported: true, readyStartTime: nil))
        XCTAssertEqual(machine.baseDashboard, machine.dashboard)
    }

    /// Upstream: test_failed_command_does_not_update_dashboard (tests/test_bluetooth_dashboard.py:506) [D13]
    ///
    /// Restated (D18): the BLE status `{"id":"ble","message":"Failed","status":"error"}` on a machine without
    /// a cloud client. Upstream returns `False`; Angstrom throws `.commandFailed(status: "error",
    /// errorCode: "Failed")`, records it, and leaves the mode (and the whole dashboard) unchanged.
    func testNonSuccessStatusWithoutCloudThrowsCommandFailed() async throws {
        let harness = BluetoothMachineHarness(cloud: false,
                                              commandResponse: Data(#"{"id":"ble","message":"Failed","status":"error"}"#.utf8))
        let machine = harness.machine
        let seed = machine.dashboard
        let expected = LaMarzoccoError.commandFailed(status: "error", errorCode: "Failed")

        do {
            _ = try await machine.setPower(on: true)
            XCTFail("a non-success status without a cloud client must throw")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, expected)
        }
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, expected)
        XCTAssertEqual(harness.bluetoothWrites(to: write),
                       [frame(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#)])
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .standby)
        XCTAssertEqual(machine.dashboard, seed)
        XCTAssertEqual(machine.baseDashboard, seed)
    }

    /// Upstream: test_bluetooth_exception_does_not_update_dashboard (tests/test_bluetooth_dashboard.py:533) [D14]
    ///
    /// Restated (D18): the BLE temperature command fails with a connection error on a machine without a
    /// cloud client. Upstream returns `False`; Angstrom rethrows the `.bluetoothConnectionFailed` error and
    /// leaves the coffee target at 93.0.
    func testBluetoothErrorWithoutCloudRethrows() async throws {
        let harness = BluetoothMachineHarness(cloud: false, failure: .commandWrite)
        let machine = harness.machine
        let seed = machine.dashboard

        do {
            _ = try await machine.setCoffeeTargetTemperature(celsius: 96.5)
            XCTFail("a Bluetooth connection failure without a cloud client must be rethrown")
        } catch let error as LaMarzoccoError {
            guard case .bluetoothConnectionFailed(let message) = error else {
                return XCTFail("expected .bluetoothConnectionFailed, got \(error)")
            }
            // Request-phase GATT failure: `.bluetoothConnectionFailed("<e>")` (SPEC §4.4.1).
            XCTAssertEqual(message, String(describing: BluetoothTransportError.gatt(domain: "CBATTErrorDomain", code: 14)))
            XCTAssertEqual(machine.lastError as? LaMarzoccoError, error)
        }
        XCTAssertEqual(harness.bluetoothWrites(to: write),
                       [frame(#"{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":96.5}}"#)])
        XCTAssertEqual(machine.dashboard?.coffeeBoiler?.targetTemperature, 93.0)
        XCTAssertEqual(machine.dashboard, seed)
        XCTAssertEqual(machine.baseDashboard, seed)
        await harness.bluetooth?.drainBackgroundWorkForTesting()
    }

    /// Upstream: test_set_power_updates_group_status (tests/test_machine.py:1089) [M29]
    ///
    /// The Strada X fixture's `CMMachineGroupStatus` (mode standby) added to the machine: a successful
    /// `setPower(on: true)` (over Bluetooth; the cloud is never called) sets its mode to brewing too,
    /// keeping its status and available modes.
    func testSetPowerUpdatesGroupStatus() async throws {
        let strada = try JSONDecoder.laMarzocco().decode(Dashboard.self, from: Fixture.data("dashboard_stradax"))
        let group = try XCTUnwrap(strada.widgets.first { $0.code == "CMMachineGroupStatus" })
        guard case .machineGroupStatus(let status) = group.kind else {
            return XCTFail("the Strada X fixture must carry a decoded CMMachineGroupStatus")
        }
        XCTAssertEqual(status.mode, .standby)
        let micra = BluetoothMachineHarness.seedDashboard(model: .lineaMicra)
        let seed = Dashboard(machine: micra.machine, widgets: micra.widgets + [group])
        let harness = BluetoothMachineHarness(seed: .custom(seed))
        let machine = harness.machine

        let response = try await machine.setPower(on: true)

        XCTAssertEqual(response, bluetoothSuccess)
        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineChangeMode"), 0)
        XCTAssertEqual(machine.dashboard?.machineGroupStatus,
                       MachineStatus(status: .standby, availableModes: [.brewing, .standby, .eco],
                                     mode: .brewing, nextStatus: nil, brewingStartTime: nil))
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .brewing)
        XCTAssertEqual(machine.dashboard?.widgets.first { $0.code == "CMMachineGroupStatus" }?.index, group.index)
    }

    /// Angstrom-only: G-DEV-11 — `setSteam` updates **both** steam widgets (`CMSteamBoilerLevel` and
    /// `CMSteamBoilerTemperature`) when both exist (`MACH:777-780`), off then on, keeping every other
    /// field; also after a cloud fallback (the update follows success on either transport).
    func testSetSteamUpdatesBothSteamWidgets() async throws {
        let level = { (enabled: Bool) in
            SteamBoilerLevel(status: .standby, enabled: enabled, enabledSupported: true,
                             targetLevel: .level1, targetLevelSupported: true, readyStartTime: nil)
        }
        let temperature = { (enabled: Bool) in
            SteamBoilerTemperature(status: .standby, enabled: enabled, enabledSupported: false,
                                   targetTemperature: 126.0, targetTemperatureMin: 126, targetTemperatureMax: 131,
                                   targetTemperatureStep: 1.0, targetTemperatureSupported: true, readyStartTime: nil)
        }

        let harness = BluetoothMachineHarness(cloud: false)
        let machine = harness.machine
        XCTAssertEqual(machine.dashboard?.steamBoilerLevel, level(true))
        XCTAssertEqual(machine.dashboard?.steamBoilerTemperature, temperature(true))

        _ = try await machine.setSteam(on: false)
        XCTAssertEqual(machine.dashboard?.steamBoilerLevel, level(false))
        XCTAssertEqual(machine.dashboard?.steamBoilerTemperature, temperature(false))

        _ = try await machine.setSteam(on: true)
        XCTAssertEqual(machine.dashboard?.steamBoilerLevel, level(true))
        XCTAssertEqual(machine.dashboard?.steamBoilerTemperature, temperature(true))
        XCTAssertEqual(machine.dashboard, BluetoothMachineHarness.seedDashboard(model: .lineaMicra))
        XCTAssertEqual(harness.bluetoothWrites(to: write), [
            frame(#"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":false}}"#),
            frame(#"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":true}}"#),
        ])

        // Cloud fallback: the same update.
        let fallback = BluetoothMachineHarness(failure: .commandWrite)
        let response = try await fallback.machine.setSteam(on: false)
        XCTAssertEqual(response.id, "cmd1")
        XCTAssertEqual(fallback.cloudCommandCount("CoffeeMachineSettingSteamBoilerEnabled"), 1)
        XCTAssertEqual(fallback.machine.dashboard?.steamBoilerLevel, level(false))
        XCTAssertEqual(fallback.machine.dashboard?.steamBoilerTemperature, temperature(false))
        await fallback.bluetooth?.drainBackgroundWorkForTesting()
    }

    // MARK: - Private

    /// A command frame: the JSON bytes plus the trailing NUL (SPEC §3.7).
    private func frame(_ json: String) -> Data { Data(json.utf8) + [0x00] }
}
