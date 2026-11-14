import XCTest
@testable import Angstrom
import AngstromTestSupport

/// Pure dashboard transforms of SPEC §4.17 (widget synthesis from Bluetooth), §4.19 (the
/// shot-counter overlay) and §6.12 (upsert/remove/state helpers). Vectors: SPEC §9.3.6.
final class DashboardBluetoothTests: XCTestCase {

    // MARK: - §6.12 helpers

    /// Angstrom-only: §6.12 — upserting replaces the first widget with the code in place, keeping its index; else appends as given.
    func testUpsertingKeepsIndex() {
        let a = Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false)))
        let first = Widget(code: "CMCoffeeBoiler", index: 3, kind: .coffeeBoiler(coffee(target: 90)))
        let second = Widget(code: "CMCoffeeBoiler", index: 4, kind: .coffeeBoiler(coffee(target: 91)))
        let d = dashboard([a, first, second])

        // Replace: the incoming index (9) is ignored; position and the existing index (3) are kept.
        let replaced = d.upserting(Widget(code: "CMCoffeeBoiler", index: 9, kind: .coffeeBoiler(coffee(target: 96.5))))
        XCTAssertEqual(replaced.widgets, [
            a,
            Widget(code: "CMCoffeeBoiler", index: 3, kind: .coffeeBoiler(coffee(target: 96.5))),
            second,
        ])
        XCTAssertEqual(replaced.machine, d.machine)

        // Append: a new code is appended verbatim, including its index.
        let newWidget = Widget(code: "CMSteamFlush", index: 7, kind: .steamFlush(SteamFlush(enabled: true)))
        let appended = d.upserting(newWidget)
        XCTAssertEqual(appended.widgets, [a, first, second, newWidget])

        // Code-based: an `.unknown` widget with the code is replaced in place too.
        let unknown = Widget(code: "CMNoWater", index: 5, kind: .unknown(code: "CMNoWater"))
        let withUnknown = dashboard([unknown, first])
        XCTAssertEqual(withUnknown.upserting(a).widgets, [
            Widget(code: "CMNoWater", index: 5, kind: .noWater(NoWater(alarm: false))),
            first,
        ])

        // Empty dashboard: appended.
        XCTAssertEqual(dashboard([]).upserting(a).widgets, [a])
    }

    /// Angstrom-only: §6.12 — removingWidgets(code:) removes every widget with the code (any index or kind) and keeps the rest in order.
    func testRemovingWidgets() {
        let status = Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(machineStatus()))
        let temp1 = Widget(code: "CMSteamBoilerTemperature", index: 1, kind: .steamBoilerTemperature(steamTemp()))
        let noWater = Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: true)))
        let temp2 = Widget(code: "CMSteamBoilerTemperature", index: 2, kind: .steamBoilerTemperature(steamTemp(target: 130)))
        let tempUnknown = Widget(code: "CMSteamBoilerTemperature", index: 3, kind: .unknown(code: "CMSteamBoilerTemperature"))
        let d = dashboard([status, temp1, noWater, temp2, tempUnknown])

        let removed = d.removingWidgets(code: "CMSteamBoilerTemperature")
        XCTAssertEqual(removed.widgets, [status, noWater])
        XCTAssertEqual(removed.machine, d.machine)

        XCTAssertEqual(d.removingWidgets(code: "CMSteamBoilerLevel"), d)
        XCTAssertEqual(dashboard([]).removingWidgets(code: "CMNoWater"), dashboard([]))
    }

    /// Angstrom-only: §6.12 — settingMachineState writes only CMMachineStatus.status; the group status and every other field are untouched.
    func testSettingMachineStateOnlyMachineStatus() {
        let next = NextStatus(status: .standby, startTime: Date(timeIntervalSince1970: 1_800_000_000))
        let start = Date(timeIntervalSince1970: 1_767_265_200)
        let group = Widget(code: "CMMachineGroupStatus", index: 1, kind: .machineGroupStatus(
            MachineStatus(status: .standby, availableModes: [.brewing, .standby], mode: .standby,
                          nextStatus: nil, brewingStartTime: nil)))
        let status = Widget(code: "CMMachineStatus", index: 2, kind: .machineStatus(
            MachineStatus(status: .standby, availableModes: [.brewing, .eco, .standby], mode: .brewing,
                          nextStatus: next, brewingStartTime: start)))
        let d = dashboard([group, status])

        let set = d.settingMachineState(.poweredOn)
        XCTAssertEqual(set.widgets, [
            group,
            Widget(code: "CMMachineStatus", index: 2, kind: .machineStatus(
                MachineStatus(status: .poweredOn, availableModes: [.brewing, .eco, .standby], mode: .brewing,
                              nextStatus: next, brewingStartTime: start))),
        ])
        XCTAssertEqual(set.machine, d.machine)

        // No CMMachineStatus (only the group status, or only an undecodable one): no-op.
        let groupOnly = dashboard([group])
        XCTAssertEqual(groupOnly.settingMachineState(.eco), groupOnly)
        let unknownOnly = dashboard([Widget(code: "CMMachineStatus", index: 1, kind: .unknown(code: "CMMachineStatus"))])
        XCTAssertEqual(unknownOnly.settingMachineState(.eco), unknownOnly)
    }

    // MARK: - §4.17 applyingBluetoothState (vectors §9.3.6)

    /// Upstream: test_get_dashboard_from_bluetooth (tests/test_bluetooth_dashboard.py:110) [BT-DASH-SNAP-001]
    func testApplyMicraSnapshot() {
        let seed = seedDashboard()
        let state = BluetoothDashboardState(
            machineMode: .brewing, isPlumbedIn: false, tankStatus: true,
            boilers: [
                BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 95, current: 94),
                BluetoothBoilerDetails(id: .steam, isEnabled: false, target: 128, current: 50),
            ])

        let result = seed.applyingBluetoothState(state, model: .lineaMicra)

        XCTAssertEqual(result.widgets, [
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(
                MachineStatus(status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                              nextStatus: nil, brewingStartTime: nil))),
            // The existing widget keeps its max 100 (not the 110 default).
            Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(
                CoffeeBoiler(status: .ready, enabled: true, enabledSupported: false, targetTemperature: 95.0,
                             targetTemperatureMin: 80, targetTemperatureMax: 100, targetTemperatureStep: 0.1,
                             readyStartTime: nil))),
            Widget(code: "CMSteamBoilerLevel", index: 1, kind: .steamBoilerLevel(
                SteamBoilerLevel(status: .off, enabled: false, enabledSupported: true, targetLevel: .level2,
                                 targetLevelSupported: true, readyStartTime: nil))),
            // No CMSteamBoilerTemperature; CMNoWater appended with index 1.
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ])
        XCTAssertNil(result.steamBoilerTemperature)
        XCTAssertEqual(result.machine, seed.machine)
        XCTAssertFalse(result.machine.isConnected)
        XCTAssertEqual(result.machine.model, .lineaMicra)
    }

    /// Upstream: test_get_dashboard_initializes_missing_widgets (tests/test_bluetooth_dashboard.py:213) [BT-DASH-SNAP-002]
    func testApplyEmptyMiniR() {
        let empty = Dashboard(machine: Machine(serialNumber: "MR123456", model: .lineaMiniR), widgets: [])
        let state = BluetoothDashboardState(
            machineMode: .brewing, isPlumbedIn: false, tankStatus: true,
            boilers: [
                BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 92, current: 91),
                BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 130, current: 125),
            ])

        let result = empty.applyingBluetoothState(state, model: .lineaMiniR)

        XCTAssertEqual(result.widgets, [
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(
                MachineStatus(status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                              nextStatus: nil, brewingStartTime: nil))),
            Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(
                CoffeeBoiler(status: .ready, enabled: true, enabledSupported: false, targetTemperature: 92.0,
                             targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1,
                             readyStartTime: nil))),
            Widget(code: "CMSteamBoilerLevel", index: 1, kind: .steamBoilerLevel(
                SteamBoilerLevel(status: .ready, enabled: true, enabledSupported: true, targetLevel: .level2,
                                 targetLevelSupported: true, readyStartTime: nil))),
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ])
        XCTAssertEqual(result.machine, empty.machine)
    }

    /// Upstream: test_get_dashboard_without_steam_level_support (tests/test_bluetooth_dashboard.py:269) [BT-DASH-GS3-001]
    func testApplyGS3UsesTemperature() {
        let state = BluetoothDashboardState(
            machineMode: .brewing, isPlumbedIn: false, tankStatus: true,
            boilers: [
                BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 94, current: 93),
                BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 128, current: 120),
            ])

        // Upstream's ModelName.GS3; BLE family "GS3" resolves to .gs3AV (D8). Both take the temperature path.
        for model in [Model.gs3, .gs3AV] {
            let empty = Dashboard(machine: Machine(serialNumber: "MR123456", model: model), widgets: [])
            let result = empty.applyingBluetoothState(state, model: model)
            XCTAssertEqual(result.widgets, [
                Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(
                    MachineStatus(status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                                  nextStatus: nil, brewingStartTime: nil))),
                Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(
                    CoffeeBoiler(status: .ready, enabled: true, enabledSupported: false, targetTemperature: 94.0,
                                 targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1,
                                 readyStartTime: nil))),
                Widget(code: "CMSteamBoilerTemperature", index: 1, kind: .steamBoilerTemperature(
                    SteamBoilerTemperature(status: .ready, enabled: true, enabledSupported: false,
                                           targetTemperature: 128.0, targetTemperatureMin: 20,
                                           targetTemperatureMax: 134, targetTemperatureStep: 0.1,
                                           targetTemperatureSupported: true, readyStartTime: nil))),
                Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
            ], "\(model)")
            XCTAssertNil(result.steamBoilerLevel, "\(model)")
        }

        // Over the seed (which carries both steam widgets): the level widget goes, the existing
        // temperature widget is updated in place and keeps its 126…131 step 1.0 range.
        let result = seedDashboard(model: .gs3).applyingBluetoothState(state, model: .gs3)
        XCTAssertEqual(result.widgets.map(\.code),
                       ["CMMachineStatus", "CMCoffeeBoiler", "CMSteamBoilerTemperature", "CMNoWater"])
        XCTAssertEqual(result.steamBoilerTemperature, SteamBoilerTemperature(
            status: .ready, enabled: true, enabledSupported: false, targetTemperature: 128.0,
            targetTemperatureMin: 126, targetTemperatureMax: 131, targetTemperatureStep: 1.0,
            targetTemperatureSupported: true, readyStartTime: nil))
    }

    /// Upstream: test_get_dashboard_mini_original_temperature_only (tests/test_bluetooth_dashboard.py:334) [BT-DASH-MINI-001]
    func testApplyOriginalMiniDefaults() {
        let empty = Dashboard(machine: Machine(serialNumber: "MR123456", model: .lineaMini), widgets: [])
        let state = BluetoothDashboardState(
            machineMode: .brewing, isPlumbedIn: false, tankStatus: true,
            boilers: [
                BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 93, current: 92),
                BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 127, current: 115),
            ])

        let result = empty.applyingBluetoothState(state, model: .lineaMini)

        XCTAssertEqual(result.widgets.map(\.code),
                       ["CMMachineStatus", "CMCoffeeBoiler", "CMSteamBoilerTemperature", "CMNoWater"])
        XCTAssertNil(result.steamBoilerLevel)
        XCTAssertEqual(result.widgets[2], Widget(code: "CMSteamBoilerTemperature", index: 1, kind: .steamBoilerTemperature(
            SteamBoilerTemperature(status: .ready, enabled: true, enabledSupported: false, targetTemperature: 127.0,
                                   targetTemperatureMin: 95, targetTemperatureMax: 140, targetTemperatureStep: 0.1,
                                   targetTemperatureSupported: false, readyStartTime: nil))))
        XCTAssertEqual(result.coffeeBoiler, CoffeeBoiler(
            status: .ready, enabled: true, enabledSupported: false, targetTemperature: 93.0,
            targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1, readyStartTime: nil))
    }

    /// Upstream: test_get_dashboard_from_bluetooth_statuses (tests/test_bluetooth_dashboard.py:606) [BT-DASH-STATUS-001, BT-DASH-STATUS-002, BT-DASH-STATUS-003, BT-DASH-STATUS-004, BT-DASH-STATUS-005]
    func testStatusTable() {
        struct Row {
            let id: String
            let mode: MachineMode, plumbedIn: Bool, tankOK: Bool, steamEnabled: Bool
            let machine: MachineState, coffee: BoilerStatus, steam: BoilerStatus, alarm: Bool
        }
        let rows = [
            Row(id: "BT-DASH-STATUS-001", mode: .brewing, plumbedIn: false, tankOK: true, steamEnabled: true,
                machine: .poweredOn, coffee: .ready, steam: .ready, alarm: false),
            Row(id: "BT-DASH-STATUS-002", mode: .eco, plumbedIn: false, tankOK: true, steamEnabled: true,
                machine: .eco, coffee: .eco, steam: .eco, alarm: false),
            Row(id: "BT-DASH-STATUS-003", mode: .standby, plumbedIn: false, tankOK: true, steamEnabled: false,
                machine: .standby, coffee: .standby, steam: .off, alarm: false),
            Row(id: "BT-DASH-STATUS-004", mode: .brewing, plumbedIn: false, tankOK: false, steamEnabled: true,
                machine: .poweredOn, coffee: .noWater, steam: .noWater, alarm: true),
            Row(id: "BT-DASH-STATUS-005", mode: .brewing, plumbedIn: true, tankOK: false, steamEnabled: true,
                machine: .poweredOn, coffee: .ready, steam: .ready, alarm: false),
        ]
        for row in rows {
            let state = BluetoothDashboardState(
                machineMode: row.mode, isPlumbedIn: row.plumbedIn, tankStatus: row.tankOK,
                boilers: [
                    BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 93, current: 92),
                    BluetoothBoilerDetails(id: .steam, isEnabled: row.steamEnabled, target: 128, current: 120),
                ])
            let result = seedDashboard().applyingBluetoothState(state, model: .lineaMicra)

            XCTAssertEqual(result.machineStatus?.status, row.machine, row.id)
            XCTAssertEqual(result.machineStatus?.mode, row.mode, row.id)
            XCTAssertEqual(result.coffeeBoiler?.status, row.coffee, row.id)
            XCTAssertEqual(result.coffeeBoiler?.enabled, true, row.id)
            XCTAssertEqual(result.steamBoilerLevel?.status, row.steam, row.id)
            XCTAssertEqual(result.steamBoilerLevel?.enabled, row.steamEnabled, row.id)
            XCTAssertEqual(result.steamBoilerLevel?.targetLevel, .level2, row.id)
            XCTAssertEqual(result.noWater?.alarm, row.alarm, row.id)
            XCTAssertNil(result.steamBoilerTemperature, row.id)
            XCTAssertEqual(result.widgets.map(\.code),
                           ["CMMachineStatus", "CMCoffeeBoiler", "CMSteamBoilerLevel", "CMNoWater"], row.id)
        }
    }

    /// Upstream: test_get_dashboard_from_bluetooth_plumb_in_unsupported (tests/test_bluetooth_dashboard.py:674) [BT-DASH-PLUMB-001]
    func testPlumbInFalseTankFalseRaisesAlarm() {
        // The device layer maps an unparsable plumb-in reply to false (§4.17 step 3); the pure part
        // sees isPlumbedIn false.
        let seed = seedDashboard()
        let state = BluetoothDashboardState(machineMode: .brewing, isPlumbedIn: false, tankStatus: false, boilers: [])

        let result = seed.applyingBluetoothState(state, model: .lineaMicra)

        XCTAssertEqual(result.noWater, NoWater(alarm: true))
        // No boiler entries: every boiler widget of the seed is untouched (both steam widgets stay).
        XCTAssertEqual(result.widgets, [
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(
                MachineStatus(status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                              nextStatus: nil, brewingStartTime: nil))),
            seed.widgets[1], seed.widgets[2], seed.widgets[3],
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: true))),
        ])

        // An existing CMNoWater is overwritten in place, never duplicated.
        let withNoWater = dashboard([Widget(code: "CMNoWater", index: 4, kind: .noWater(NoWater(alarm: false)))])
        let overwritten = withNoWater.applyingBluetoothState(state, model: .lineaMicra)
        XCTAssertEqual(overwritten.widgets, [
            Widget(code: "CMNoWater", index: 4, kind: .noWater(NoWater(alarm: true))),
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(
                MachineStatus(status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                              nextStatus: nil, brewingStartTime: nil))),
        ])
    }

    /// Angstrom-only: G-DEV-3 — BLE widget defaults (Mini vs others), coffee never .off, missing steam entry keeps stale steam widgets, duplicate ids: last wins.
    func testWidgetDefaultsAndEdgeCases() {
        let water = BluetoothDashboardState(machineMode: .brewing, isPlumbedIn: false, tankStatus: true, boilers: [])
        func state(_ boilers: [BluetoothBoilerDetails], mode: MachineMode = .brewing,
                   tank: Bool = true) -> BluetoothDashboardState {
            BluetoothDashboardState(machineMode: mode, isPlumbedIn: false, tankStatus: tank, boilers: boilers)
        }
        let steamOn = BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 125.5, current: 100)

        // Steam-temperature defaults: 95/140/supported=false only for the original Linea Mini;
        // 20/134/supported=true for every other non-level model (including an unknown one).
        for model in [Model.gs3, .gs3AV, .gs3MP, .stradaX, .unknown("X")] {
            let r = dashboard([]).applyingBluetoothState(state([steamOn]), model: model)
            XCTAssertEqual(r.steamBoilerTemperature, SteamBoilerTemperature(
                status: .ready, enabled: true, enabledSupported: false, targetTemperature: 125.5,
                targetTemperatureMin: 20, targetTemperatureMax: 134, targetTemperatureStep: 0.1,
                targetTemperatureSupported: true, readyStartTime: nil), "\(model)")
            XCTAssertNil(r.steamBoilerLevel, "\(model)")
        }
        let mini = dashboard([]).applyingBluetoothState(state([steamOn]), model: .lineaMini)
        XCTAssertEqual(mini.steamBoilerTemperature, SteamBoilerTemperature(
            status: .ready, enabled: true, enabledSupported: false, targetTemperature: 125.5,
            targetTemperatureMin: 95, targetTemperatureMax: 140, targetTemperatureStep: 0.1,
            targetTemperatureSupported: false, readyStartTime: nil))
        // Steam-level defaults for both level models: enabledSupported and targetLevelSupported true.
        for model in [Model.lineaMicra, .lineaMiniR] {
            let r = dashboard([]).applyingBluetoothState(state([steamOn]), model: model)
            XCTAssertEqual(r.steamBoilerLevel, SteamBoilerLevel(
                status: .ready, enabled: true, enabledSupported: true, targetLevel: .level1,
                targetLevelSupported: true, readyStartTime: nil), "\(model)")
            XCTAssertNil(r.steamBoilerTemperature, "\(model)")
        }
        // The `model` argument chooses the path, not `machine.model`.
        let mislabelled = Dashboard(machine: Machine(serialNumber: "MR123456", model: .gs3), widgets: [])
            .applyingBluetoothState(state([steamOn]), model: .lineaMicra)
        XCTAssertNotNil(mislabelled.steamBoilerLevel)
        XCTAssertNil(mislabelled.steamBoilerTemperature)

        // The coffee boiler never shows .off, even when disabled; a disabled steam boiler does.
        let disabled = state([
            BluetoothBoilerDetails(id: .coffee, isEnabled: false, target: 93, current: 20),
            BluetoothBoilerDetails(id: .steam, isEnabled: false, target: 131, current: 20),
        ])
        let off = dashboard([]).applyingBluetoothState(disabled, model: .lineaMicra)
        XCTAssertEqual(off.coffeeBoiler, CoffeeBoiler(
            status: .ready, enabled: false, enabledSupported: false, targetTemperature: 93,
            targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1, readyStartTime: nil))
        XCTAssertEqual(off.steamBoilerLevel?.status, .off)
        XCTAssertEqual(off.steamBoilerLevel?.enabled, false)
        XCTAssertEqual(off.steamBoilerLevel?.targetLevel, .level3)
        let standbyDisabled = dashboard([]).applyingBluetoothState(
            state(disabled.boilers, mode: .standby), model: .lineaMicra)
        XCTAssertEqual(standbyDisabled.coffeeBoiler?.status, .standby)
        // No water wins over off.
        let dry = dashboard([]).applyingBluetoothState(state(disabled.boilers, tank: false), model: .lineaMicra)
        XCTAssertEqual(dry.coffeeBoiler?.status, .noWater)
        XCTAssertEqual(dry.steamBoilerLevel?.status, .noWater)
        XCTAssertEqual(dry.noWater, NoWater(alarm: true))
        // An unrecognised mode maps through as .other on both the machine and the boilers.
        let odd = dashboard([]).applyingBluetoothState(
            state([BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 93, current: 92)],
                  mode: .other("Turbo")), model: .lineaMicra)
        XCTAssertEqual(odd.machineStatus?.status, .other("Turbo"))
        XCTAssertEqual(odd.machineStatus?.mode, .other("Turbo"))
        XCTAssertEqual(odd.coffeeBoiler?.status, .other("Turbo"))

        // A missing steam entry keeps both stale steam widgets of the seed untouched.
        let seed = seedDashboard()
        let coffeeOnly = seed.applyingBluetoothState(
            state([BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 94, current: 90)]), model: .lineaMicra)
        XCTAssertEqual(coffeeOnly.widgets.map(\.code),
                       ["CMMachineStatus", "CMCoffeeBoiler", "CMSteamBoilerLevel", "CMSteamBoilerTemperature", "CMNoWater"])
        XCTAssertEqual(coffeeOnly.widgets[2], seed.widgets[2])
        XCTAssertEqual(coffeeOnly.widgets[3], seed.widgets[3])

        // Duplicate ids: the last entry wins, and there is still one widget per code.
        let dup = dashboard([]).applyingBluetoothState(state([
            BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 90, current: 89),
            BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 126, current: 100),
            BluetoothBoilerDetails(id: .coffee, isEnabled: false, target: 93.5, current: 92),
            BluetoothBoilerDetails(id: .steam, isEnabled: false, target: 131, current: 100),
        ]), model: .lineaMicra)
        XCTAssertEqual(dup.widgets.map(\.code), ["CMMachineStatus", "CMCoffeeBoiler", "CMSteamBoilerLevel", "CMNoWater"])
        XCTAssertEqual(dup.coffeeBoiler, CoffeeBoiler(
            status: .ready, enabled: false, enabledSupported: false, targetTemperature: 93.5,
            targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1, readyStartTime: nil))
        XCTAssertEqual(dup.steamBoilerLevel, SteamBoilerLevel(
            status: .off, enabled: false, enabledSupported: true, targetLevel: .level3,
            targetLevelSupported: true, readyStartTime: nil))

        // `.other` ids are ignored: nothing is created for them.
        let other = dashboard([]).applyingBluetoothState(state([
            BluetoothBoilerDetails(id: .other("CoffeeBoiler2"), isEnabled: true, target: 93, current: 92),
            BluetoothBoilerDetails(id: .other("SteamBoiler2"), isEnabled: true, target: 128, current: 92),
        ]), model: .lineaMicra)
        XCTAssertEqual(other.widgets.map(\.code), ["CMMachineStatus", "CMNoWater"])

        // Append order is fixed (status, coffee, steam, no water) whatever the wire order.
        let reversed = dashboard([]).applyingBluetoothState(state([
            BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 128, current: 100),
            BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 93, current: 92),
        ]), model: .gs3)
        XCTAssertEqual(reversed.widgets.map(\.code),
                       ["CMMachineStatus", "CMCoffeeBoiler", "CMSteamBoilerTemperature", "CMNoWater"])
        XCTAssertEqual(reversed.widgets.map(\.index), [1, 1, 1, 1])

        // Existing widgets keep position, index and non-overwritten fields; every opposite steam
        // widget (any index, even undecodable) is removed; CMMachineGroupStatus is untouched.
        let ready = Date(timeIntervalSince1970: 1_767_000_000)
        let group = Widget(code: "CMMachineGroupStatus", index: 1, kind: .machineGroupStatus(
            MachineStatus(status: .standby, availableModes: [.brewing, .standby], mode: .standby,
                          nextStatus: nil, brewingStartTime: nil)))
        let existing = dashboard([
            Widget(code: "CMSteamBoilerTemperature", index: 1, kind: .steamBoilerTemperature(steamTemp())),
            Widget(code: "CMCoffeeBoiler", index: 3, kind: .coffeeBoiler(
                CoffeeBoiler(status: .heatingUp, enabled: false, enabledSupported: true, targetTemperature: 90,
                             targetTemperatureMin: 85, targetTemperatureMax: 99, targetTemperatureStep: 0.5,
                             readyStartTime: ready))),
            group,
            Widget(code: "CMSteamBoilerTemperature", index: 2, kind: .steamBoilerTemperature(steamTemp(target: 130))),
            Widget(code: "CMSteamBoilerLevel", index: 6, kind: .steamBoilerLevel(
                SteamBoilerLevel(status: .heatingUp, enabled: false, enabledSupported: false, targetLevel: .level1,
                                 targetLevelSupported: false, readyStartTime: ready))),
            Widget(code: "CMSteamBoilerTemperature", index: 3, kind: .unknown(code: "CMSteamBoilerTemperature")),
        ])
        let updated = existing.applyingBluetoothState(state([
            BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 94, current: 90),
            BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 129, current: 100),
        ]), model: .lineaMicra)
        XCTAssertEqual(updated.widgets, [
            Widget(code: "CMCoffeeBoiler", index: 3, kind: .coffeeBoiler(
                CoffeeBoiler(status: .ready, enabled: true, enabledSupported: true, targetTemperature: 94,
                             targetTemperatureMin: 85, targetTemperatureMax: 99, targetTemperatureStep: 0.5,
                             readyStartTime: ready))),
            group,
            Widget(code: "CMSteamBoilerLevel", index: 6, kind: .steamBoilerLevel(
                SteamBoilerLevel(status: .ready, enabled: true, enabledSupported: false, targetLevel: .level2,
                                 targetLevelSupported: false, readyStartTime: ready))),
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(
                MachineStatus(status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                              nextStatus: nil, brewingStartTime: nil))),
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ])

        // The temperature path removes every level widget, and keeps an existing temperature widget's fields.
        let gs3Existing = dashboard([
            Widget(code: "CMSteamBoilerLevel", index: 1, kind: .steamBoilerLevel(steamLevel())),
            Widget(code: "CMSteamBoilerTemperature", index: 2, kind: .steamBoilerTemperature(
                SteamBoilerTemperature(status: .standby, enabled: false, enabledSupported: true,
                                       targetTemperature: 120, targetTemperatureMin: 100,
                                       targetTemperatureMax: 140, targetTemperatureStep: 0.5,
                                       targetTemperatureSupported: false, readyStartTime: ready))),
            Widget(code: "CMSteamBoilerLevel", index: 2, kind: .unknown(code: "CMSteamBoilerLevel")),
        ])
        let gs3 = gs3Existing.applyingBluetoothState(state([steamOn], mode: .eco), model: .gs3)
        XCTAssertEqual(gs3.widgets, [
            Widget(code: "CMSteamBoilerTemperature", index: 2, kind: .steamBoilerTemperature(
                SteamBoilerTemperature(status: .eco, enabled: true, enabledSupported: true,
                                       targetTemperature: 125.5, targetTemperatureMin: 100,
                                       targetTemperatureMax: 140, targetTemperatureStep: 0.5,
                                       targetTemperatureSupported: false, readyStartTime: ready))),
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(
                MachineStatus(status: .eco, availableModes: [.brewing, .standby], mode: .eco,
                              nextStatus: nil, brewingStartTime: nil))),
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ])

        // Machine identity is never touched.
        XCTAssertEqual(dashboard([]).applyingBluetoothState(water, model: .lineaMicra).machine, dashboard([]).machine)
    }

    /// Angstrom-only: G-DEV-10 — a created CMMachineStatus gets [brewing, standby]; an existing one keeps availableModes/nextStatus/brewingStartTime.
    func testAvailableModesKept() {
        let state = BluetoothDashboardState(machineMode: .eco, isPlumbedIn: false, tankStatus: true, boilers: [])

        let created = dashboard([]).applyingBluetoothState(state, model: .lineaMicra)
        XCTAssertEqual(created.widgets.first, Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(
            MachineStatus(status: .eco, availableModes: [.brewing, .standby], mode: .eco,
                          nextStatus: nil, brewingStartTime: nil))))

        let next = NextStatus(status: .poweredOn, startTime: Date(timeIntervalSince1970: 1_800_000_000))
        let start = Date(timeIntervalSince1970: 1_767_265_200)
        let existing = dashboard([Widget(code: "CMMachineStatus", index: 2, kind: .machineStatus(
            MachineStatus(status: .brewing, availableModes: [.brewing, .eco, .standby], mode: .brewing,
                          nextStatus: next, brewingStartTime: start)))])
        let kept = existing.applyingBluetoothState(state, model: .lineaMicra)
        XCTAssertEqual(kept.widgets, [
            Widget(code: "CMMachineStatus", index: 2, kind: .machineStatus(
                MachineStatus(status: .eco, availableModes: [.brewing, .eco, .standby], mode: .eco,
                              nextStatus: next, brewingStartTime: start))),
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ])
    }

    /// Angstrom-only: §4.17 — an "existing W" must have the matching typed kind; an .unknown (or other-kind) widget counts as absent and is left in place.
    func testUnknownWidgetCountsAsAbsent() {
        let unknownStatus = Widget(code: "CMMachineStatus", index: 2, kind: .unknown(code: "CMMachineStatus"))
        let unknownCoffee = Widget(code: "CMCoffeeBoiler", index: 3, kind: .unknown(code: "CMCoffeeBoiler"))
        let unknownLevel = Widget(code: "CMSteamBoilerLevel", index: 4, kind: .unknown(code: "CMSteamBoilerLevel"))
        let unknownNoWater = Widget(code: "CMNoWater", index: 5, kind: .unknown(code: "CMNoWater"))
        let d = dashboard([unknownStatus, unknownCoffee, unknownLevel, unknownNoWater])
        let state = BluetoothDashboardState(
            machineMode: .brewing, isPlumbedIn: false, tankStatus: true,
            boilers: [
                BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 93, current: 92),
                BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 128, current: 120),
            ])

        let result = d.applyingBluetoothState(state, model: .lineaMicra)

        XCTAssertEqual(result.widgets, [
            unknownStatus, unknownCoffee, unknownLevel, unknownNoWater,
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(
                MachineStatus(status: .poweredOn, availableModes: [.brewing, .standby], mode: .brewing,
                              nextStatus: nil, brewingStartTime: nil))),
            Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(
                CoffeeBoiler(status: .ready, enabled: true, enabledSupported: false, targetTemperature: 93,
                             targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1,
                             readyStartTime: nil))),
            Widget(code: "CMSteamBoilerLevel", index: 1, kind: .steamBoilerLevel(
                SteamBoilerLevel(status: .ready, enabled: true, enabledSupported: true, targetLevel: .level2,
                                 targetLevelSupported: true, readyStartTime: nil))),
            Widget(code: "CMNoWater", index: 1, kind: .noWater(NoWater(alarm: false))),
        ])

        // A typed widget after an undecodable one with the same code is the "existing" one.
        let typedLater = dashboard([
            unknownCoffee,
            Widget(code: "CMCoffeeBoiler", index: 7, kind: .coffeeBoiler(coffee(target: 90))),
        ]).applyingBluetoothState(state, model: .gs3)
        XCTAssertEqual(Array(typedLater.widgets.prefix(2)), [
            unknownCoffee,
            Widget(code: "CMCoffeeBoiler", index: 7, kind: .coffeeBoiler(
                CoffeeBoiler(status: .ready, enabled: true, enabledSupported: false, targetTemperature: 93,
                             targetTemperatureMin: 80, targetTemperatureMax: 100, targetTemperatureStep: 0.1,
                             readyStartTime: nil))),
        ])
        XCTAssertEqual(typedLater.widgets.filter { $0.code == "CMCoffeeBoiler" }.count, 2)

        // A CMMachineStatus code carrying another typed kind is not the machine status either.
        let wrongKind = Widget(code: "CMMachineStatus", index: 1, kind: .machineGroupStatus(machineStatus()))
        let mismatched = dashboard([wrongKind]).applyingBluetoothState(state, model: .lineaMicra)
        XCTAssertEqual(mismatched.widgets.first, wrongKind)
        XCTAssertEqual(mismatched.widgets.filter { $0.code == "CMMachineStatus" }.count, 2)
        XCTAssertEqual(mismatched.machineStatus?.status, .poweredOn)
    }

    // MARK: - §4.19 overlayingBluetoothBrewing

    /// Angstrom-only: D12 — every row of the §4.19 overlay table on CMMachineStatus (nil, absent, brewing, every other state).
    func testOverlayTable() {
        let cloudStart = Date(timeIntervalSince1970: 1_767_265_200)        // 2026-01-01T11:00:00Z
        let receivedAt = Date(timeIntervalSince1970: 1_767_268_800)        // 2026-01-01T12:00:00Z
        let next = NextStatus(status: .standby, startTime: Date(timeIntervalSince1970: 1_800_000_000))
        func base(_ status: MachineState, start: Date? = cloudStart) -> Dashboard {
            dashboard([
                Widget(code: "CMMachineGroupStatus", index: 1, kind: .machineGroupStatus(
                    MachineStatus(status: .brewing, availableModes: [.brewing, .standby], mode: .brewing,
                                  nextStatus: nil, brewingStartTime: cloudStart))),
                Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(coffee(target: 93))),
                Widget(code: "CMMachineStatus", index: 2, kind: .machineStatus(
                    MachineStatus(status: status, availableModes: [.brewing, .eco, .standby], mode: .brewing,
                                  nextStatus: next, brewingStartTime: start))),
            ])
        }
        func expected(_ d: Dashboard, status: MachineState, start: Date?) -> Dashboard {
            Dashboard(machine: d.machine, widgets: [
                d.widgets[0], d.widgets[1],
                Widget(code: "CMMachineStatus", index: 2, kind: .machineStatus(
                    MachineStatus(status: status, availableModes: [.brewing, .eco, .standby], mode: .brewing,
                                  nextStatus: next, brewingStartTime: start))),
            ])
        }
        let brewing = BluetoothShotCounterUpdate(state: .brewing, timerValue: 12.5, receivedAt: receivedAt,
                                                 raw: BluetoothBrewingData(brewingTime: 12.5))
        let bleStart = Date(timeIntervalSince1970: 1_767_268_787.5)        // 11:59:47.5Z
        XCTAssertEqual(brewing.brewingStartTime, bleStart)

        // nil → self, whatever the base.
        for status in [MachineState.brewing, .poweredOn, .standby] {
            XCTAssertEqual(base(status).overlayingBluetoothBrewing(nil), base(status))
        }

        // Non-nil but no CMMachineStatus (group status only, or undecodable): unchanged.
        let noStatus = dashboard([base(.poweredOn).widgets[0], base(.poweredOn).widgets[1],
                                  Widget(code: "CMMachineStatus", index: 1, kind: .unknown(code: "CMMachineStatus"))])
        XCTAssertEqual(noStatus.overlayingBluetoothBrewing(brewing), noStatus)

        // .brewing → status .brewing, start = update.brewingStartTime (only CMMachineStatus changes).
        for status in [MachineState.poweredOn, .standby, .brewing, .eco] {
            let d = base(status)
            XCTAssertEqual(d.overlayingBluetoothBrewing(brewing), expected(d, status: .brewing, start: bleStart), "\(status)")
        }
        // A brewing update without a start time overwrites the cloud start with nil (MACH:306).
        let noTimer = BluetoothShotCounterUpdate(state: .brewing, receivedAt: receivedAt, raw: BluetoothBrewingData())
        XCTAssertNil(noTimer.brewingStartTime)
        XCTAssertEqual(base(.poweredOn).overlayingBluetoothBrewing(noTimer),
                       expected(base(.poweredOn), status: .brewing, start: nil))

        // Any other state → base .brewing becomes .poweredOn, other statuses pass through; the base
        // start time is kept even when the update carries one.
        let otherStart = Date(timeIntervalSince1970: 1_767_268_000)
        for state in [BluetoothBrewingState.brewingStopped, .flushed, .backflushing] {
            let update = BluetoothShotCounterUpdate(state: state, timerValue: 3, finalShotTime: 27.4,
                                                    receivedAt: receivedAt, raw: BluetoothBrewingData(),
                                                    brewingStartTime: otherStart)
            XCTAssertEqual(update.brewingStartTime, otherStart)
            let pairs: [(MachineState, MachineState)] = [(.brewing, .poweredOn), (.poweredOn, .poweredOn),
                                                         (.standby, .standby), (.eco, .eco), (.off, .off),
                                                         (.other("X"), .other("X"))]
            for (baseStatus, rendered) in pairs {
                let d = base(baseStatus)
                XCTAssertEqual(d.overlayingBluetoothBrewing(update),
                               expected(d, status: rendered, start: cloudStart), "\(state) over \(baseStatus)")
            }
            let nilStart = base(.brewing, start: nil)
            XCTAssertEqual(nilStart.overlayingBluetoothBrewing(update),
                           expected(nilStart, status: .poweredOn, start: nil), "\(state) nil start")
        }
    }

    // MARK: - Private helpers

    /// BT-DASH-SEED-001 (`TBD:68-105`).
    private func seedDashboard(model: Model = .lineaMicra) -> Dashboard {
        Dashboard(machine: Machine(serialNumber: "MR123456", model: model), widgets: [
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(machineStatus())),
            Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(coffee(target: 93.0))),
            Widget(code: "CMSteamBoilerLevel", index: 1, kind: .steamBoilerLevel(steamLevel())),
            Widget(code: "CMSteamBoilerTemperature", index: 1, kind: .steamBoilerTemperature(steamTemp())),
        ])
    }

    private func dashboard(_ widgets: [Widget]) -> Dashboard {
        Dashboard(machine: Machine(serialNumber: "MR123456", model: .lineaMicra), widgets: widgets)
    }

    private func machineStatus() -> MachineStatus {
        MachineStatus(status: .standby, availableModes: [.brewing, .standby], mode: .standby,
                      nextStatus: nil, brewingStartTime: nil)
    }

    private func coffee(target: Double) -> CoffeeBoiler {
        CoffeeBoiler(status: .standby, enabled: true, enabledSupported: false, targetTemperature: target,
                     targetTemperatureMin: 80, targetTemperatureMax: 100, targetTemperatureStep: 0.1,
                     readyStartTime: nil)
    }

    private func steamLevel() -> SteamBoilerLevel {
        SteamBoilerLevel(status: .standby, enabled: true, enabledSupported: true, targetLevel: .level1,
                         targetLevelSupported: true, readyStartTime: nil)
    }

    private func steamTemp(target: Double = 126.0) -> SteamBoilerTemperature {
        SteamBoilerTemperature(status: .standby, enabled: true, enabledSupported: false,
                               targetTemperature: target, targetTemperatureMin: 126, targetTemperatureMax: 131,
                               targetTemperatureStep: 1.0, targetTemperatureSupported: true, readyStartTime: nil)
    }
}
