import XCTest
@testable import Angstrom

/// Decodes real captured dashboards (Micra, Mini, Mini R, GS3 AV, Pico grinder)
/// into the typed widget model and asserts the M1 read layer is faithful.
final class DashboardTests: XCTestCase {

    private func dashboard(_ name: String) throws -> Dashboard {
        try JSONDecoder.laMarzocco().decode(Dashboard.self, from: try Fixture.data(name))
    }

    // MARK: - Identity

    func testMachineIdentityDecodes() throws {
        let micra = try dashboard("dashboard_micra")
        XCTAssertEqual(micra.machine.serialNumber, "MR123456")
        XCTAssertEqual(micra.machine.model, .lineaMicra)
        XCTAssertEqual(micra.machine.modelName, "Linea Micra") // normalized from "LINEA MICRA"
        XCTAssertEqual(micra.machine.type, .coffeeMachine)
        XCTAssertTrue(micra.machine.isConnected)
        XCTAssertNotNil(micra.machine.connectionDate)
        XCTAssertEqual(micra.machine.imageURL?.scheme, "https")
    }

    func testModelNormalizationAcrossFixtures() throws {
        XCTAssertEqual(try dashboard("dashboard_mini").machine.model, .lineaMini)
        XCTAssertEqual(try dashboard("dashboard_minir").machine.model, .lineaMiniR)   // "LINEA MINI 2023"
        XCTAssertEqual(try dashboard("dashboard_gs3av").machine.model, .gs3AV)
    }

    // MARK: - Every machine widget decodes (no demotion to .unknown)

    func testMicraWidgetsAllDecode() throws {
        let d = try dashboard("dashboard_micra")
        XCTAssertEqual(d.unknownWidgetCodes, [], "no widget should fail to decode")
        XCTAssertEqual(d.machineStatus?.status, .standby)
        XCTAssertEqual(d.machineStatus?.mode, .standby)
        XCTAssertEqual(d.machineStatus?.availableModes, [.brewing, .standby])
        XCTAssertEqual(d.coffeeBoiler?.targetTemperature, 94.0)
        XCTAssertEqual(d.coffeeBoiler?.targetTemperatureMin, 80)
        XCTAssertEqual(d.coffeeBoiler?.target.unit, .celsius)
        XCTAssertEqual(d.steamBoilerLevel?.targetLevel, .level3)
        XCTAssertEqual(d.backFlush?.status, .off)
        XCTAssertNotNil(d.preExtraction)
        XCTAssertEqual(d.preExtraction?.mode, .preInfusion)
        XCTAssertNotNil(d.preBrewing)
        XCTAssertNil(d.steamBoilerTemperature) // Micra is level-based
    }

    func testGS3AVWidgetsAllDecode() throws {
        let d = try dashboard("dashboard_gs3av")
        XCTAssertEqual(d.unknownWidgetCodes, [])
        XCTAssertNotNil(d.steamBoilerTemperature)
        XCTAssertNil(d.steamBoilerLevel) // GS3 is temperature-based
        XCTAssertNotNil(d.groupDoses)
        XCTAssertFalse(d.groupDoses?.doses.pulsesType.isEmpty ?? true)
        XCTAssertNotNil(d.hotWaterDose)
        XCTAssertNotNil(d.backFlush)
    }

    func testMiniWidgetsAllDecode() throws {
        let d = try dashboard("dashboard_mini")
        XCTAssertEqual(d.unknownWidgetCodes, [])
        XCTAssertNotNil(d.brewByWeightDoses)
        XCTAssertNotNil(d.scale)
        XCTAssertNotNil(d.steamBoilerTemperature)
    }

    func testMiniRWidgetsAllDecode() throws {
        let d = try dashboard("dashboard_minir")
        XCTAssertEqual(d.unknownWidgetCodes, [])
        XCTAssertNotNil(d.rinseFlush)
        XCTAssertNotNil(d.steamBoilerLevel)
        XCTAssertNotNil(d.preExtraction)
    }

    // MARK: - Resilience

    func testGrinderWidgetsDecode() throws {
        // M5: grinder widgets are now typed (no longer demoted to `.unknown`).
        let d = try dashboard("dashboard_pico")
        XCTAssertEqual(d.machine.type, .grinder)
        XCTAssertTrue(d.machine.model.isGrinder)
        XCTAssertEqual(d.unknownWidgetCodes, [], "all grinder widgets should decode")
        XCTAssertNotNil(d.scale)

        XCTAssertEqual(d.grinderStatus?.status, .standby)
        XCTAssertEqual(d.grinderStatus?.mode, .standby)
        XCTAssertEqual(d.grinderStatus?.availableModes, [.grinding, .standby])

        XCTAssertEqual(d.grinderDoses?.mode, .time)
        XCTAssertEqual(d.grinderDoses?.scaleConnected, false)
        XCTAssertEqual(d.grinderDoses?.doses.timeType.first?.doseIndex, .doseA)
        XCTAssertEqual(d.grinderDoses?.doses.timeType.first?.dose, 1.5)
        XCTAssertEqual(d.grinderDoses?.doses.massType.count, 2)

        XCTAssertEqual(d.grinderSingleDose?.enabled, false)
        XCTAssertEqual(d.grinderBaristaLight?.enabled, true)
    }

    func testUnknownWidgetCodeIsCapturedNotFatal() throws {
        let json = """
        { "serialNumber": "SN9", "modelName": "Linea Micra",
          "widgets": [
            { "code": "CMMachineStatus", "index": 1,
              "output": { "status": "StandBy", "availableModes": ["StandBy"], "mode": "StandBy", "nextStatus": null, "brewingStartTime": null } },
            { "code": "CMFutureGizmo", "index": 1, "output": { "wat": true } }
          ] }
        """
        let d = try JSONDecoder.laMarzocco().decode(Dashboard.self, from: Data(json.utf8))
        XCTAssertNotNil(d.machineStatus)
        XCTAssertEqual(d.unknownWidgetCodes, ["CMFutureGizmo"])
    }

    // MARK: - Machine Codable round-trip

    func testMachineCodableRoundTrip() throws {
        let machine = Machine(
            serialNumber: "SN1", name: "Kitchen",
            model: .lineaMicra, type: .coffeeMachine, location: "Home",
            isConnected: true, connectionDate: Date(timeIntervalSince1970: 1_700_000_000),
            requiresFirmwareUpdate: false, hasFirmwareUpdateAvailable: true,
            imageURL: URL(string: "https://example.com/x.png")
        )
        // The matched encoder/decoder must preserve the date exactly.
        let data = try JSONEncoder.laMarzocco().encode(machine)
        let restored = try JSONDecoder.laMarzocco().decode(Machine.self, from: data)
        XCTAssertEqual(restored, machine)
        XCTAssertEqual(restored.connectionDate, machine.connectionDate)
        XCTAssertEqual(restored.modelName, "Linea Micra")
    }

    func testRealEpochDatesDecodeWithMillisecondPrecision() throws {
        // Pin the ms-epoch strategy on the real decode path (a seconds strategy
        // would silently decode the same numbers to a 1970-era date).
        let micra = try dashboard("dashboard_micra")
        XCTAssertEqual(micra.machine.connectionDate, Date(timeIntervalSince1970: 1_742_526_019.892))
        let gs3 = try dashboard("dashboard_gs3av")
        XCTAssertEqual(gs3.machineStatus?.nextStatus?.startTime,
                       Date(timeIntervalSince1970: 1_742_857_195.332))
    }

    func testPreBrewingTimesContentDecodes() throws {
        // Assert decoded content, not just non-nil, so the capitalized
        // PreInfusion/PreBrewing key mapping can't silently default to empty.
        let micra = try dashboard("dashboard_micra")
        let pb = try XCTUnwrap(micra.preBrewing)
        XCTAssertEqual(pb.times.preBrewing.count, 1)
        XCTAssertEqual(pb.times.preInfusion.count, 1)
        XCTAssertEqual(pb.times.preBrewing.first?.doseIndex, .byGroup)
        XCTAssertEqual(pb.times.preBrewing.first?.seconds.out, 5.0)
        let pe = try XCTUnwrap(micra.preExtraction)
        XCTAssertEqual(pe.times.out.seconds, 4.0)
        XCTAssertEqual(pe.times.in.secondsMax.preInfusion, 9)
    }

    func testNoWaterAlarmKeyMapping() throws {
        let json = """
        { "serialNumber": "SN9", "modelName": "Linea Micra",
          "widgets": [ { "code": "CMNoWater", "index": 1, "output": { "allarm": true } } ] }
        """
        let d = try JSONDecoder.laMarzocco().decode(Dashboard.self, from: Data(json.utf8))
        XCTAssertEqual(d.noWater?.alarm, true)
        XCTAssertEqual(d.unknownWidgetCodes, [])
    }

    func testUnknownEnumValueDemotesWidgetNotDashboard() throws {
        // An out-of-range enum value inside a known widget code must demote just
        // that widget (SteamLevel has no `.other` case), not fail the dashboard.
        let json = """
        { "serialNumber": "SN9",
          "widgets": [
            { "code": "CMSteamBoilerLevel", "index": 1,
              "output": { "status": "Ready", "enabled": true, "enabledSupported": true,
                          "targetLevel": "Level4", "targetLevelSupported": true, "readyStartTime": null } }
          ] }
        """
        let d = try JSONDecoder.laMarzocco().decode(Dashboard.self, from: Data(json.utf8))
        XCTAssertNil(d.steamBoilerLevel)
        XCTAssertEqual(d.unknownWidgetCodes, ["CMSteamBoilerLevel"])
    }

    func testDosesTolerateMissingKeys() throws {
        // pylamarzocco defaults these lists/flags; missing keys must not demote
        // the whole widget.
        let json = """
        { "serialNumber": "SN9",
          "widgets": [
            { "code": "CMHotWaterDose", "index": 1, "output": { "enabled": true, "enabledSupported": false } },
            { "code": "CMGroupDoses", "index": 1, "output": { "doses": {} } }
          ] }
        """
        let d = try JSONDecoder.laMarzocco().decode(Dashboard.self, from: Data(json.utf8))
        XCTAssertEqual(d.unknownWidgetCodes, [])
        XCTAssertEqual(d.hotWaterDose?.doses, [])
        XCTAssertEqual(d.groupDoses?.doses.pulsesType, [])
        // mode is absent in the payload → defaults to PulsesType (parity with
        // pylamarzocco's GroupDosesSettings.mode default).
        XCTAssertEqual(d.groupDoses?.mode, .pulses)
    }

    func testGroupDosesModelsAllFields() throws {
        // The GS3 group-dose widget carries the mirror/continuous/pressure fields
        // that used to be silently dropped.
        let g = try XCTUnwrap(try dashboard("dashboard_gs3av").groupDoses)
        XCTAssertEqual(g.mode, .pulses)
        XCTAssertEqual(g.availableModes, [.pulses])
        XCTAssertFalse(g.mirrorWithGroup1Supported)
        XCTAssertNil(g.mirrorWithGroup1)
        XCTAssertFalse(g.mirrorWithGroup1NotEffective)
        XCTAssertNil(g.profile)
        XCTAssertFalse(g.continuousDoseSupported)
        XCTAssertNil(g.continuousDose)
        XCTAssertFalse(g.brewingPressureSupported)
        XCTAssertNil(g.brewingPressure)
        XCTAssertEqual(g.doses.pulsesType.count, 4)
    }

    func testMachineOfflineModeAndCoffeeStationDecode() throws {
        let json = """
        { "serialNumber": "SN9", "modelName": "Linea Mini", "offlineMode": true,
          "coffeeStation": { "id": "cs1", "name": "My station",
            "accessories": [
              { "type": "ScaleAcaiaLunar", "name": "LMZ-1", "connected": false, "batteryLevel": null, "imageUrl": null }
            ] } }
        """
        let m = try JSONDecoder.laMarzocco().decode(Machine.self, from: Data(json.utf8))
        XCTAssertTrue(m.offlineMode)
        XCTAssertEqual(m.coffeeStation?.id, "cs1")
        XCTAssertEqual(m.coffeeStation?.name, "My station")
        XCTAssertEqual(m.coffeeStation?.accessories.first?.type, "ScaleAcaiaLunar")
        XCTAssertEqual(m.coffeeStation?.accessories.first?.connected, false)

        // Round-trips through the matched encoder/decoder.
        let restored = try JSONDecoder.laMarzocco().decode(
            Machine.self, from: JSONEncoder.laMarzocco().encode(m))
        XCTAssertEqual(restored, m)
    }

    func testMachineDefaultsWhenOfflineAndStationAbsent() throws {
        let m = try JSONDecoder.laMarzocco().decode(
            Machine.self, from: Data(#"{"serialNumber":"X"}"#.utf8))
        XCTAssertFalse(m.offlineMode)
        XCTAssertNil(m.coffeeStation)
    }

    func testBrewByWeightToleratesMissingScaleConnected() throws {
        let json = """
        { "serialNumber": "SN9",
          "widgets": [
            { "code": "CMBrewByWeightDoses", "index": 1, "output": {
                "doses": { "Dose1": { "dose": 18, "doseMin": 1, "doseMax": 100, "doseStep": 0.1 },
                           "Dose2": { "dose": 36, "doseMin": 1, "doseMax": 100, "doseStep": 0.1 } } } }
          ] }
        """
        let d = try JSONDecoder.laMarzocco().decode(Dashboard.self, from: Data(json.utf8))
        XCTAssertEqual(d.unknownWidgetCodes, [])
        XCTAssertEqual(d.brewByWeightDoses?.scaleConnected, false)
        XCTAssertEqual(d.brewByWeightDoses?.doses.dose1.dose, 18)
    }
}
