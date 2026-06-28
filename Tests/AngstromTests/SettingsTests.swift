import XCTest
@testable import Angstrom

/// Decodes the captured `/settings` and `/scheduling` payloads (M1.4).
final class SettingsTests: XCTestCase {

    func testSettingsDecode() throws {
        let settings = try JSONDecoder.laMarzocco().decode(
            MachineSettings.self, from: try Fixture.data("settings_micra"))
        XCTAssertEqual(settings.machine.model, .lineaMicra)
        XCTAssertEqual(settings.wifiSSID, "MyWifi")
        XCTAssertTrue(settings.plumbInSupported)
        XCTAssertFalse(settings.autoUpdate)
        XCTAssertFalse(settings.firmware.isEmpty)
        XCTAssertNotNil(settings.gatewayFirmware)
        XCTAssertEqual(settings.gatewayFirmware?.type, .gateway)
        XCTAssertFalse(settings.gatewayFirmware?.buildVersion.isEmpty ?? true)
    }

    func testScheduleDecode() throws {
        let schedule = try JSONDecoder.laMarzocco().decode(
            MachineSchedule.self, from: try Fixture.data("schedule"))
        XCTAssertEqual(schedule.autoStandBy, "00:30")
        XCTAssertEqual(schedule.autoOnOff, "00:30")
        XCTAssertFalse(schedule.wakeUpSchedules.isEmpty)
        let first = try XCTUnwrap(schedule.wakeUpSchedules.first)
        XCTAssertEqual(first.id, "KofUy56")
        XCTAssertTrue(first.enabled)
        XCTAssertEqual(first.offTimeMinutes, 514)
        XCTAssertTrue(first.steamBoiler)
        XCTAssertEqual(first.days, [.tuesday])
    }

    func testSettingsResilienceDefaults() throws {
        // A near-empty payload must decode with safe defaults, not throw.
        let settings = try JSONDecoder.laMarzocco().decode(
            MachineSettings.self, from: Data(#"{"serialNumber":"X"}"#.utf8))
        XCTAssertEqual(settings.machine.serialNumber, "X")
        XCTAssertNil(settings.wifiSSID)
        XCTAssertFalse(settings.isPlumbedIn)
        XCTAssertEqual(settings.firmware, [])
    }

    func testScheduleResilienceDefaults() throws {
        let schedule = try JSONDecoder.laMarzocco().decode(
            MachineSchedule.self, from: Data(#"{"serialNumber":"X"}"#.utf8))
        XCTAssertEqual(schedule.wakeUpSchedules, [])
        XCTAssertNil(schedule.smartStandby)
        XCTAssertEqual(schedule.smartWakeUpSleep.smartStandbyAfter, .powerOn)
        // Absent key defaults to `true` (parity with pylamarzocco), but an
        // explicit `false` is still honored.
        XCTAssertTrue(schedule.smartWakeUpSleepSupported)
        let explicit = try JSONDecoder.laMarzocco().decode(
            MachineSchedule.self, from: Data(#"{"serialNumber":"X","smartWakeUpSleepSupported":false}"#.utf8))
        XCTAssertFalse(explicit.smartWakeUpSleepSupported)
    }

    func testSmartWakeUpSleepDecodesMinuteBounds() throws {
        let schedule = try JSONDecoder.laMarzocco().decode(
            MachineSchedule.self, from: try Fixture.data("schedule"))
        let sws = schedule.smartWakeUpSleep
        XCTAssertEqual(sws.smartStandbyMinutes, 10)
        XCTAssertEqual(sws.smartStandbyMinutesMin, 1)
        XCTAssertEqual(sws.smartStandbyMinutesMax, 30)
        XCTAssertEqual(sws.smartStandbyMinutesStep, 1)
    }

    func testSmartStandbyBlockDecodesMinuteBounds() throws {
        let json = """
        { "serialNumber": "X",
          "smartStandBy": { "enabled": true, "minutes": 20, "minutesMin": 5,
                            "minutesMax": 40, "minutesStep": 5, "after": "PowerOn" } }
        """
        let schedule = try JSONDecoder.laMarzocco().decode(MachineSchedule.self, from: Data(json.utf8))
        XCTAssertEqual(schedule.smartStandby?.minutesMin, 5)
        XCTAssertEqual(schedule.smartStandby?.minutesMax, 40)
        XCTAssertEqual(schedule.smartStandby?.minutesStep, 5)
    }

    func testSettingsDecodesCropsterHemroFactoryReset() throws {
        let json = """
        { "serialNumber": "X", "cropsterSupported": true, "cropsterActive": true,
          "hemroSupported": true, "hemroActive": false, "factoryResetSupported": true }
        """
        let settings = try JSONDecoder.laMarzocco().decode(MachineSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.cropsterSupported)
        XCTAssertTrue(settings.cropsterActive)
        XCTAssertTrue(settings.hemroSupported)
        XCTAssertFalse(settings.hemroActive)
        XCTAssertTrue(settings.factoryResetSupported)

        // Absent keys default to false.
        let sparse = try JSONDecoder.laMarzocco().decode(
            MachineSettings.self, from: Data(#"{"serialNumber":"X"}"#.utf8))
        XCTAssertFalse(sparse.cropsterSupported)
        XCTAssertFalse(sparse.factoryResetSupported)
    }

    func testSmartStandbyBlockDecodes() throws {
        let json = """
        { "serialNumber": "X",
          "smartStandBy": { "enabled": true, "minutes": 20, "after": "LastBrewing" } }
        """
        let schedule = try JSONDecoder.laMarzocco().decode(MachineSchedule.self, from: Data(json.utf8))
        XCTAssertEqual(schedule.smartStandby?.enabled, true)
        XCTAssertEqual(schedule.smartStandby?.minutes, 20)
        XCTAssertEqual(schedule.smartStandby?.after, .lastBrewing)
    }

    func testMalformedScheduleEntrySkippedNotWiping() throws {
        // One sparse entry (missing onTimeMinutes) must be skipped, leaving the
        // valid entry — not zero the whole list.
        let json = """
        { "serialNumber": "X", "smartWakeUpSleep": { "schedules": [
            { "id": "good", "onTimeMinutes": 60, "offTimeMinutes": 120, "steamBoiler": true, "days": ["Monday"] },
            { "id": "bad", "offTimeMinutes": 120, "steamBoiler": true }
        ] } }
        """
        let schedule = try JSONDecoder.laMarzocco().decode(MachineSchedule.self, from: Data(json.utf8))
        XCTAssertEqual(schedule.wakeUpSchedules.count, 1)
        XCTAssertEqual(schedule.wakeUpSchedules.first?.id, "good")
        XCTAssertEqual(schedule.wakeUpSchedules.first?.enabled, false) // defaulted
    }

    func testWakeUpScheduleOmitsIdWhenCreating() throws {
        let schedule = WakeUpSchedule(
            enabled: true, onTimeMinutes: 420, offTimeMinutes: 480,
            steamBoiler: false, days: [.monday, .friday]
        )
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(schedule)) as? [String: Any]
        XCTAssertNil(json?["id"], "a new schedule must not send a null id")
        XCTAssertEqual(json?["onTimeMinutes"] as? Int, 420)
        XCTAssertEqual(json?["days"] as? [String], ["Monday", "Friday"])

        // A schedule with an id round-trips that id.
        let existing = WakeUpSchedule(
            id: "abc", enabled: false, onTimeMinutes: 0, offTimeMinutes: 0,
            steamBoiler: true, days: []
        )
        let existingJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(existing)) as? [String: Any]
        XCTAssertEqual(existingJSON?["id"] as? String, "abc")
    }
}
