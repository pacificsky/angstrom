import XCTest
@testable import Angstrom

/// Verifies M2 commands POST to the right `/command/{Command}` path with the
/// right JSON body (including nested objects, Int/Bool/Float, and rounding).
final class CommandTests: XCTestCase {

    /// A backend that authenticates and acks every command with a Pending response.
    private func commandBackend() -> MockBackend {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.contains("/command/") { return .jsonArray([["id": "cmd1", "status": "Pending"]]) }
            if path.hasSuffix("/update-fw") {
                return .json(["status": "ToUpdate", "progressPercentage": 0])
            }
            return MockBackend.Reply(status: 404)
        }
        return backend
    }

    private func client(_ backend: MockBackend) -> LaMarzoccoCloudClient {
        LaMarzoccoCloudClient(username: "u", password: "p", installationKey: .generate(),
                              urlSession: MockURLProtocol.session(backend: backend))
    }

    private func body(_ backend: MockBackend, _ command: String) throws -> [String: Any] {
        let data = try XCTUnwrap(backend.body(pathSuffix: "/command/\(command)"),
                                 "no body recorded for \(command)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Simple bodies

    func testSetPower() async throws {
        let backend = commandBackend()
        try await client(backend).setPower(serial: "SN1", on: true)
        XCTAssertEqual(try body(backend, "CoffeeMachineChangeMode")["mode"] as? String, "BrewingMode")
        try await client(backend).setPower(serial: "SN1", on: false)
        XCTAssertEqual(try body(backend, "CoffeeMachineChangeMode")["mode"] as? String, "StandBy")
    }

    func testSetSteam() async throws {
        let backend = commandBackend()
        try await client(backend).setSteam(serial: "SN1", on: true)
        let b = try body(backend, "CoffeeMachineSettingSteamBoilerEnabled")
        XCTAssertEqual(b["boilerIndex"] as? Int, 1)
        XCTAssertEqual(b["enabled"] as? Bool, true)
    }

    func testSetSteamTargetLevel() async throws {
        let backend = commandBackend()
        try await client(backend).setSteamTargetLevel(serial: "SN1", .level2)
        let b = try body(backend, "CoffeeMachineSettingSteamBoilerTargetLevel")
        XCTAssertEqual(b["targetLevel"] as? String, "Level2")
        XCTAssertEqual(b["boilerIndex"] as? Int, 1)
    }

    func testCoffeeTargetTemperatureRoundsToOneDecimal() async throws {
        let backend = commandBackend()
        try await client(backend).setCoffeeTargetTemperature(serial: "SN1", celsius: 93.456)
        let b = try body(backend, "CoffeeMachineSettingCoffeeBoilerTargetTemperature")
        XCTAssertEqual(b["targetTemperature"] as? Double, 93.5)
        XCTAssertEqual(b["boilerIndex"] as? Int, 1)
    }

    func testSmartStandby() async throws {
        let backend = commandBackend()
        try await client(backend).setSmartStandby(serial: "SN1", enabled: true, minutes: 10, after: .powerOn)
        let b = try body(backend, "CoffeeMachineSettingSmartStandBy")
        XCTAssertEqual(b["enabled"] as? Bool, true)
        XCTAssertEqual(b["minutes"] as? Int, 10)
        XCTAssertEqual(b["after"] as? String, "PowerOn")
    }

    func testGrinderBaristaLight() async throws {
        let backend = commandBackend()
        try await client(backend).setGrinderBaristaLight(serial: "G1", on: true)
        let b = try body(backend, "GrinderSettingBaristaLightEnabled")
        XCTAssertEqual(b["index"] as? Int, 1)
        XCTAssertEqual(b["enabled"] as? Bool, true)
    }

    func testSteamTargetTemperatureUsesSteamCommandString() async throws {
        // Guards against a copy-paste of the (byte-similar) coffee command string.
        let backend = commandBackend()
        try await client(backend).setSteamTargetTemperature(serial: "SN1", celsius: 128.0)
        let b = try body(backend, "CoffeeMachineSettingSteamBoilerTargetTemperature")
        XCTAssertEqual(b["targetTemperature"] as? Double, 128.0)
        XCTAssertEqual(b["boilerIndex"] as? Int, 1)
        // The coffee command must NOT have been hit.
        XCTAssertEqual(backend.count(pathSuffix: "/command/CoffeeMachineSettingCoffeeBoilerTargetTemperature"), 0)
    }

    func testPreExtractionMode() async throws {
        let backend = commandBackend()
        try await client(backend).setPreExtractionMode(serial: "SN1", .preInfusion)
        XCTAssertEqual(try body(backend, "CoffeeMachinePreBrewingChangeMode")["mode"] as? String, "PreInfusion")
    }

    func testBrewByWeightModeEncodesDoseMode() async throws {
        let backend = commandBackend()
        try await client(backend).setBrewByWeightMode(serial: "SN1", .pulses)
        XCTAssertEqual(try body(backend, "CoffeeMachineBrewByWeightChangeMode")["mode"] as? String, "PulsesType")
    }

    func testAutoStandbyAndAutoOnOff() async throws {
        let backend = commandBackend()
        try await client(backend).setAutoStandby(serial: "SN1", mode: "Enabled")
        XCTAssertEqual(try body(backend, "CoffeeMachineSettingAutoStandBy")["mode"] as? String, "Enabled")
        try await client(backend).setAutoOnOff(serial: "SN1", schedule: "00:30")
        XCTAssertEqual(try body(backend, "CoffeeMachineSettingAutoOnOff")["schedule"] as? String, "00:30")
    }

    // MARK: Strada X commands (upstream v2.4.2)

    func testSetModeSendsRawMachineMode() async throws {
        let backend = commandBackend()
        try await client(backend).setMode(serial: "SN1", .eco)
        XCTAssertEqual(try body(backend, "CoffeeMachineChangeMode")["mode"] as? String, "EcoMode")
    }

    func testFlushEnableCommands() async throws {
        let backend = commandBackend()
        let c = client(backend)
        try await c.setAutoFlush(serial: "SN1", on: true)
        XCTAssertEqual(try body(backend, "CoffeeMachineSettingAutoFlushEnabled")["enabled"] as? Bool, true)
        try await c.setSteamFlush(serial: "SN1", on: false)
        XCTAssertEqual(try body(backend, "CoffeeMachineSettingSteamFlushEnabled")["enabled"] as? Bool, false)
        try await c.setRinseFlush(serial: "SN1", on: true)
        XCTAssertEqual(try body(backend, "CoffeeMachineSettingRinseFlushEnabled")["enabled"] as? Bool, true)
        try await c.setRinseFlushTime(serial: "SN1", seconds: 3.456)
        XCTAssertEqual(try body(backend, "CoffeeMachineSettingRinseFlushTime")["timeSeconds"] as? Double, 3.5)
    }

    func testEnableToggleCommands() async throws {
        let backend = commandBackend()
        let c = client(backend)
        try await c.setHotWaterDoseEnabled(serial: "SN1", on: true)
        XCTAssertEqual(try body(backend, "CoffeeMachineSettingHotWaterDoseEnabled")["enabled"] as? Bool, true)
        try await c.setCupWarmer(serial: "SN1", on: true)
        XCTAssertEqual(try body(backend, "CoffeeMachineSettingCupWarmerEnabled")["enabled"] as? Bool, true)
        try await c.setPlumbIn(serial: "SN1", on: false)
        XCTAssertEqual(try body(backend, "CoffeeMachineSettingPlumbIn")["enabled"] as? Bool, false)
        try await c.setCoffeeBoilerEnabled(serial: "SN1", on: true)
        let boiler = try body(backend, "CoffeeMachineSettingCoffeeBoilerEnabled")
        XCTAssertEqual(boiler["boilerIndex"] as? Int, 1)
        XCTAssertEqual(boiler["enabled"] as? Bool, true)
    }

    func testGroupModeAndDoseCommands() async throws {
        let backend = commandBackend()
        let c = client(backend)
        try await c.setGroupMode(serial: "SN1", .brewing)
        let mode = try body(backend, "CoffeeMachineGroupChangeMode")
        XCTAssertEqual(mode["groupIndex"] as? Int, 1)
        XCTAssertEqual(mode["mode"] as? String, "BrewingMode")

        try await c.setGroupDoseMode(serial: "SN1", .mass)
        let doseMode = try body(backend, "CoffeeMachineGroupDoseChangeMode")
        XCTAssertEqual(doseMode["mode"] as? String, "MassType")

        try await c.setGroupDose(serial: "SN1", mode: .mass, doseIndex: .doseA, dose: 18.44)
        let dose = try body(backend, "CoffeeMachineGroupDoseSettingDose")
        XCTAssertEqual(dose["groupIndex"] as? Int, 1)
        XCTAssertEqual(dose["mode"] as? String, "MassType")
        XCTAssertEqual(dose["doseIndex"] as? String, "DoseA")
        XCTAssertEqual(dose["dose"] as? Double, 18.4)

        try await c.setHotWaterDose(serial: "SN1", dose: 7.85, doseIndex: .doseB)
        let hot = try body(backend, "CoffeeMachineSettingHotWaterDose")
        XCTAssertEqual(hot["doseIndex"] as? String, "DoseB")
        XCTAssertEqual(hot["dose"] as? Double, 7.8) // round-half-to-even, like Python

        try await c.setBrewingPressure(serial: "SN1", pressure: 9.02)
        let pressure = try body(backend, "CoffeeMachineGroupDoseSettingGroupBrewingPressure")
        XCTAssertEqual(pressure["groupIndex"] as? Int, 1)
        XCTAssertEqual(pressure["pressure"] as? Double, 9.0)

        try await c.setContinuousDoseEnabled(serial: "SN1", on: true)
        XCTAssertEqual(try body(backend, "CoffeeMachineGroupDoseSettingContinuousDoseEnabled")["rinseEnabled"] as? Bool, true)
        try await c.setContinuousDose(serial: "SN1", seconds: 4.26)
        XCTAssertEqual(try body(backend, "CoffeeMachineGroupDoseSettingContinuousDose")["rinseSeconds"] as? Double, 4.3)

        try await c.setMirrorGroup1(serial: "SN1", on: true)
        let mirror = try body(backend, "CoffeeMachineGroupDoseSettingMirrorGroup1")
        XCTAssertEqual(mirror["groupIndex"] as? Int, 2, "group 1 can't mirror itself; defaults to 2")
        XCTAssertEqual(mirror["enabled"] as? Bool, true)
    }

    // MARK: Grinder commands (upstream v2.4.2)

    func testGrinderModeAndSwanCommands() async throws {
        let backend = commandBackend()
        let c = client(backend)
        try await c.setGrinderMode(serial: "G1", .grinding)
        XCTAssertEqual(try body(backend, "GrinderChangeMode")["mode"] as? String, "GrindingMode")

        try await c.setGrinderGrindWith(serial: "G1", .portafilter)
        let grindWith = try body(backend, "GrinderSettingGrindWithMode")
        XCTAssertEqual(grindWith["index"] as? Int, 1)
        XCTAssertEqual(grindWith["mode"] as? String, "Portafilter")

        try await c.setGrinderDose(serial: "G1", doseIndex: .doseA, dose: 9.5, mode: .rev, speedLevel: .high)
        let dose = try body(backend, "GrinderSettingDose")
        XCTAssertEqual(dose["index"] as? Int, 1)
        XCTAssertEqual(dose["mode"] as? String, "RevType")
        XCTAssertEqual(dose["doseIndex"] as? String, "DoseA")
        XCTAssertEqual(dose["dose"] as? Double, 9.5)
        XCTAssertEqual(dose["speedLevel"] as? String, "High")

        try await c.setGrinderDose(serial: "G1", doseIndex: .doseB, dose: 3.0, mode: .time)
        let noSpeed = try body(backend, "GrinderSettingDose")
        XCTAssertNil(noSpeed["speedLevel"], "speedLevel key omitted when not provided")

        try await c.setGrinderMoreDose(serial: "G1", revolutions: 1.5)
        let more = try body(backend, "GrinderSettingMoreDose")
        XCTAssertEqual(more["index"] as? Int, 1)
        XCTAssertEqual(more["revolutions"] as? Double, 1.5)
    }

    func testCommandReturnsResponse() async throws {
        let backend = commandBackend()
        let response = try await client(backend).setPower(serial: "SN1", on: true)
        XCTAssertEqual(response.id, "cmd1")
        XCTAssertEqual(response.status, .pending)
    }

    // MARK: Nested bodies

    func testPreExtractionTimesNestedAndRounded() async throws {
        let backend = commandBackend()
        try await client(backend).setPreExtractionTimes(serial: "SN1", secondsIn: 1.04, secondsOut: 4.16)
        let b = try body(backend, "CoffeeMachinePreBrewingSettingTimes")
        let times = try XCTUnwrap(b["times"] as? [String: Any])
        XCTAssertEqual(times["In"] as? Double, 1.0)
        XCTAssertEqual(times["Out"] as? Double, 4.2)
        XCTAssertEqual(b["groupIndex"] as? Int, 1)
        XCTAssertEqual(b["doseIndex"] as? String, "ByGroup")
    }

    func testBrewByWeightDosesNested() async throws {
        let backend = commandBackend()
        try await client(backend).setBrewByWeightDoses(serial: "SN1", dose1: 18.04, dose2: 36.0)
        let doses = try XCTUnwrap(try body(backend, "CoffeeMachineBrewByWeightSettingDoses")["doses"] as? [String: Any])
        XCTAssertEqual(doses["Dose1"] as? Double, 18.0)
        XCTAssertEqual(doses["Dose2"] as? Double, 36.0)
    }

    func testSetWakeUpScheduleOmitsIdAndSendsDays() async throws {
        let backend = commandBackend()
        let schedule = WakeUpSchedule(enabled: true, onTimeMinutes: 420, offTimeMinutes: 480,
                                      steamBoiler: false, days: [.monday, .friday])
        try await client(backend).setWakeUpSchedule(serial: "SN1", schedule)
        let b = try body(backend, "CoffeeMachineSettingWakeUpSchedule")
        XCTAssertNil(b["id"])
        XCTAssertEqual(b["onTimeMinutes"] as? Int, 420)
        XCTAssertEqual(b["days"] as? [String], ["Monday", "Friday"])
    }

    func testDeleteWakeUpSchedule() async throws {
        let backend = commandBackend()
        try await client(backend).deleteWakeUpSchedule(serial: "SN1", id: "abc")
        XCTAssertEqual(try body(backend, "CoffeeMachineDeleteWakeUpSchedule")["id"] as? String, "abc")
    }

    // MARK: Dispatch behavior

    func testCommandToleratesPendingResponse() async throws {
        // No websocket → fire-and-forget: a Pending ack must not throw.
        let backend = commandBackend()
        try await client(backend).startBackflush(serial: "SN1")
        XCTAssertEqual(try body(backend, "CoffeeMachineBackFlushStartCleaning")["enabled"] as? Bool, true)
    }

    func testEmptyCommandResponseThrows() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.contains("/command/") { return .jsonArray([]) } // empty
            return MockBackend.Reply(status: 404)
        }
        do {
            try await client(backend).setPower(serial: "SN1", on: true)
            XCTFail("expected decoding error on empty command response")
        } catch LaMarzoccoError.decoding {}
    }

    func testHTTPErrorSurfaces() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            return MockBackend.Reply(status: 500)
        }
        do {
            try await client(backend).setPower(serial: "SN1", on: true)
            XCTFail("expected requestFailed")
        } catch LaMarzoccoError.requestFailed(let status, _) {
            XCTAssertEqual(status, 500)
        }
    }

    // MARK: Firmware

    func testInstallFirmwareUpdatePosts() async throws {
        let backend = commandBackend()
        let details = try await client(backend).installFirmwareUpdate(serial: "SN1")
        XCTAssertEqual(details.status, .toUpdate)
        XCTAssertEqual(backend.method(pathSuffix: "/things/SN1/update-fw"), "POST")
    }

    func testFirmwareUpdateStatusGets() async throws {
        // Same path as install — only the HTTP method must distinguish a read
        // from an install (a GET accidentally POSTing would trigger an install).
        let backend = commandBackend()
        let details = try await client(backend).firmwareUpdateStatus(serial: "SN1")
        XCTAssertEqual(details.status, .toUpdate)
        XCTAssertEqual(backend.method(pathSuffix: "/things/SN1/update-fw"), "GET")
    }

    // MARK: CommandResponse decoding

    func testCommandResponseDecodesStatusAndErrorCode() throws {
        let json = """
        [ { "id": "x", "status": "Error", "errorCode": "E42" } ]
        """
        let responses = try JSONDecoder.laMarzocco().decode([CommandResponse].self, from: Data(json.utf8))
        XCTAssertEqual(responses.first?.status, .error)
        XCTAssertEqual(responses.first?.errorCode, "E42")

        let success = try JSONDecoder.laMarzocco().decode(
            [CommandResponse].self, from: Data(#"[{"id":"y","status":"Success"}]"#.utf8))
        XCTAssertEqual(success.first?.status, .success)
        XCTAssertNil(success.first?.errorCode)
    }
}
