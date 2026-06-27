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
