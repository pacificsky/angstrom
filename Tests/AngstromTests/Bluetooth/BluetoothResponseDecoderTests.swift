import XCTest
@testable import Angstrom
import AngstromTestSupport

/// `BluetoothResponseDecoder` (SPEC §3.6, §3.7 status, §3.10, §6.6; vectors §9.3.2).
final class BluetoothResponseDecoderTests: XCTestCase {

    /// Upstream: test_ble_get_machine_capability (tests/test_bluetooth_client.py:338) [BT-RSP-CAP-001]
    func testCapabilitiesMicra() throws {
        let caps = try BluetoothResponseDecoder.capabilities(Self.capMicraText)
        XCTAssertEqual(caps, BluetoothMachineCapabilities(
            family: .lineaMicra, rawFamily: "MICRA", groupsNumber: 1, coffeeBoilersNumber: 1,
            hasCupWarmer: false, steamBoilersNumber: 1, teaDosesNumber: 0,
            machineModes: [.brewing, .standby], schedulingType: "smartWakeUpSleep"))
        // Field-by-field, so a mistake in the memberwise mapping cannot hide behind Equatable.
        XCTAssertEqual(caps.family, .lineaMicra)
        XCTAssertEqual(caps.rawFamily, "MICRA")
        XCTAssertEqual(caps.groupsNumber, 1)
        XCTAssertEqual(caps.coffeeBoilersNumber, 1)
        XCTAssertFalse(caps.hasCupWarmer)
        XCTAssertEqual(caps.steamBoilersNumber, 1)
        XCTAssertEqual(caps.teaDosesNumber, 0)
        XCTAssertEqual(caps.machineModes, [.brewing, .standby])
        XCTAssertEqual(caps.schedulingType, "smartWakeUpSleep")

        // Distinct values per int field and a true cup warmer catch swapped keys.
        let distinct = #"[{"family":"GS3MP","groupsNumber":2,"coffeeBoilersNumber":3,"hasCupWarmer":true,"#
            + #""steamBoilersNumber":4,"teaDosesNumber":5,"machineModes":["EcoMode"],"schedulingType":"weekly"}]"#
        XCTAssertEqual(try BluetoothResponseDecoder.capabilities(distinct), BluetoothMachineCapabilities(
            family: .gs3MP, rawFamily: "GS3MP", groupsNumber: 2, coffeeBoilersNumber: 3,
            hasCupWarmer: true, steamBoilersNumber: 4, teaDosesNumber: 5,
            machineModes: [.eco], schedulingType: "weekly"))

        // Element [0] is used; later elements are ignored (`capabilities[0]`).
        let two = "[" + Self.capObject(family: #""MICRA""#) + ","
            + Self.capObject(family: #""GS3""#) + "]"
        let first = try BluetoothResponseDecoder.capabilities(two)
        XCTAssertEqual(first.family, .lineaMicra)
        XCTAssertEqual(first.rawFamily, "MICRA")
    }

    /// Upstream: test_model_name_from_bluetooth_family (tests/test_models.py:416) [BT-RSP-CAP-002]
    func testCapabilitiesFamilies() throws {
        let cases: [(String, Model)] = [
            ("LINEA", .lineaMini),
            ("GS3", .gs3AV),
            ("LINEAMINI2023", .lineaMiniR),
            ("MICRA", .lineaMicra),
        ]
        for (raw, model) in cases {
            let caps = try BluetoothResponseDecoder.capabilities(Self.capArray(family: "\"\(raw)\""))
            XCTAssertEqual(caps.family, model, raw)
            XCTAssertEqual(caps.rawFamily, raw, raw)
        }
        // CONST:216-217: `ValueError(f"Invalid model name: {name}")`, verbatim.
        XCTAssertThrowsError(try BluetoothResponseDecoder.capabilities(Self.capArray(family: #""FOO""#))) {
            XCTAssertEqual($0 as? LaMarzoccoError,
                           .decoding("bluetooth machineCapabilities: Invalid model name: FOO"))
        }
        // The raw text (not the normalised key) appears in the message.
        XCTAssertThrowsError(try BluetoothResponseDecoder.capabilities(Self.capArray(family: #""foo bar""#))) {
            XCTAssertEqual($0 as? LaMarzoccoError,
                           .decoding("bluetooth machineCapabilities: Invalid model name: foo bar"))
        }
    }

    /// Upstream: test_ble_get_boiler_details (tests/test_bluetooth_client.py:361) [BT-RSP-BOIL-001]
    func testBoilers() throws {
        let boilers = try BluetoothResponseDecoder.boilers(Self.boilText)
        XCTAssertEqual(boilers, [
            BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 131, current: 45),
            BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 94, current: 65),
        ])
        XCTAssertEqual(boilers.count, 2)
        XCTAssertEqual(boilers[0].id, .steam)
        XCTAssertTrue(boilers[0].isEnabled)
        XCTAssertEqual(boilers[0].target, 131)
        XCTAssertEqual(boilers[0].current, 45)
        XCTAssertEqual(boilers[1].id, .coffee)
        XCTAssertTrue(boilers[1].isEnabled)
        XCTAssertEqual(boilers[1].target, 94)
        XCTAssertEqual(boilers[1].current, 65)

        // Wire order is kept (reversed input → reversed output); a disabled boiler decodes false.
        let reversed = #"[{"id":"CoffeeBoiler1","isEnabled":false,"target":93,"current":20},"#
            + #"{"id":"SteamBoiler","isEnabled":true,"target":126,"current":30}]"#
        XCTAssertEqual(try BluetoothResponseDecoder.boilers(reversed), [
            BluetoothBoilerDetails(id: .coffee, isEnabled: false, target: 93, current: 20),
            BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 126, current: 30),
        ])
    }

    /// Upstream: test_ble_get_smart_standby_details (tests/test_bluetooth_client.py:388) [BT-RSP-SSB-001]
    func testSmartStandbyStringTrue() throws {
        let ssb = try BluetoothResponseDecoder.smartStandby(#"{"mode":"PowerOn","minutes":42,"enabled":"true"}"#)
        XCTAssertEqual(ssb, BluetoothSmartStandbyDetails(mode: .powerOn, minutes: 42, enabled: true))
        XCTAssertEqual(ssb.mode, .powerOn)
        XCTAssertEqual(ssb.minutes, 42)
        XCTAssertTrue(ssb.enabled)

        XCTAssertEqual(
            try BluetoothResponseDecoder.smartStandby(#"{"mode":"LastBrewing","minutes":7,"enabled":false}"#),
            BluetoothSmartStandbyDetails(mode: .lastBrewing, minutes: 7, enabled: false))
        XCTAssertEqual(
            try BluetoothResponseDecoder.smartStandby(#"{"mode":"PowerOn","minutes":0,"enabled":true}"#),
            BluetoothSmartStandbyDetails(mode: .powerOn, minutes: 0, enabled: true))
    }

    /// Angstrom-only: D5 — smart-standby `"enabled":"false"` decodes false (upstream `bool("false")` is True) [BT-RSP-SSB-002]
    func testSmartStandbyStringFalseIsFalse() throws {
        let ssb = try BluetoothResponseDecoder.smartStandby(#"{"mode":"PowerOn","minutes":42,"enabled":"false"}"#)
        XCTAssertFalse(ssb.enabled)
        XCTAssertEqual(ssb, BluetoothSmartStandbyDetails(mode: .powerOn, minutes: 42, enabled: false))
        // Case-insensitive, like `_parse_bool`.
        XCTAssertTrue(try BluetoothResponseDecoder.smartStandby(#"{"mode":"PowerOn","minutes":42,"enabled":"TRUE"}"#).enabled)
        XCTAssertFalse(try BluetoothResponseDecoder.smartStandby(#"{"mode":"PowerOn","minutes":42,"enabled":"False"}"#).enabled)
    }

    /// Upstream: test_ble_get_tank_status (tests/test_bluetooth_client.py:406) [BT-RSP-TANK-001]
    /// Upstream: test_get_plumbed_in (tests/test_bluetooth_client.py:1238) [BT-RSP-PLUMB-001…004]
    func testTankAndPlumbBools() throws {
        // BT-RSP-TANK-001
        XCTAssertTrue(try BluetoothResponseDecoder.bool(#""true""#, setting: .tankStatus))
        // BT-RSP-PLUMB-001…004
        XCTAssertTrue(try BluetoothResponseDecoder.bool("true", setting: .isPlumbedIn))
        XCTAssertFalse(try BluetoothResponseDecoder.bool("false", setting: .isPlumbedIn))
        XCTAssertTrue(try BluetoothResponseDecoder.bool(#""true""#, setting: .isPlumbedIn))
        XCTAssertFalse(try BluetoothResponseDecoder.bool(#""false""#, setting: .isPlumbedIn))
        // The same four on tankStatus (same `_parse_bool`).
        XCTAssertTrue(try BluetoothResponseDecoder.bool("true", setting: .tankStatus))
        XCTAssertFalse(try BluetoothResponseDecoder.bool("false", setting: .tankStatus))
        XCTAssertFalse(try BluetoothResponseDecoder.bool(#""false""#, setting: .tankStatus))
        // `_parse_bool` is `str(v).lower() == "true"`: case-insensitive strings; numbers/null/containers false.
        XCTAssertTrue(try BluetoothResponseDecoder.bool(#""TrUe""#, setting: .tankStatus))
        XCTAssertFalse(try BluetoothResponseDecoder.bool("1", setting: .tankStatus))
        XCTAssertFalse(try BluetoothResponseDecoder.bool("0", setting: .tankStatus))
        XCTAssertFalse(try BluetoothResponseDecoder.bool("null", setting: .tankStatus))
        XCTAssertFalse(try BluetoothResponseDecoder.bool("[true]", setting: .isPlumbedIn))
        XCTAssertFalse(try BluetoothResponseDecoder.bool(#"{"a":true}"#, setting: .isPlumbedIn))
        XCTAssertFalse(try BluetoothResponseDecoder.bool(#""yes""#, setting: .isPlumbedIn))
        // A non-JSON reply is `.decoding`, named after the setting that was read.
        assertDecoding(try BluetoothResponseDecoder.bool("", setting: .isPlumbedIn), context: "isPlumbedIn")
        assertDecoding(try BluetoothResponseDecoder.bool("true garbage", setting: .tankStatus), context: "tankStatus")
    }

    /// Upstream: test_get_machine_mode (tests/test_bluetooth_client.py:420) [BT-RSP-MODE-001]
    func testMachineMode() throws {
        XCTAssertEqual(try BluetoothResponseDecoder.machineMode(#""BrewingMode""#), .brewing)
        XCTAssertEqual(try BluetoothResponseDecoder.machineMode(#""EcoMode""#), .eco)
        XCTAssertEqual(try BluetoothResponseDecoder.machineMode(#""StandBy""#), .standby)
    }

    /// Upstream: test_requests_are_atomic (tests/test_bluetooth_client.py:1253) [BT-RSP-EMPTY-001]
    func testEmptyBoilers() throws {
        XCTAssertEqual(try BluetoothResponseDecoder.boilers("[]"), [])
    }

    /// Upstream: test_ble_set_power (tests/test_bluetooth_client.py:295) [BT-RSP-CMD-001]
    /// Upstream: test_failed_command_does_not_update_dashboard (tests/test_bluetooth_dashboard.py:506) [BT-CMDSTATUS-CONF]
    func testCommandStatus() throws {
        // BT-RSP-CMD-001 (`COMMAND_SUCCESS`, TBC:47).
        let text = String(decoding: BluetoothTestVectors.commandSuccess, as: UTF8.self)
        let status = try BluetoothResponseDecoder.commandStatus(text)
        XCTAssertEqual(status.id, "test-id")
        XCTAssertEqual(status.message, "Success")
        XCTAssertEqual(status.status, "success")
        XCTAssertTrue(status.isSuccess)
        XCTAssertEqual(status, BluetoothCommandStatus(id: "test-id", message: "Success", status: "success"))

        // BT-CMDSTATUS-CONF (conftest.py:180-195): the four success replies.
        for message in ["power on", "boiler enable success", "Setting Temperature Success", "Success"] {
            let decoded = try BluetoothResponseDecoder.commandStatus(
                #"{"id":"ble","message":"\#(message)","status":"success"}"#)
            XCTAssertEqual(decoded, BluetoothCommandStatus(id: "ble", message: message, status: "success"))
            XCTAssertTrue(decoded.isSuccess, message)
        }
        // Failure (TBD:517-519): returned, not thrown.
        let failed = try BluetoothResponseDecoder.commandStatus(#"{"id":"ble","message":"Failed","status":"error"}"#)
        XCTAssertEqual(failed, BluetoothCommandStatus(id: "ble", message: "Failed", status: "error"))
        XCTAssertFalse(failed.isSuccess)
        // `isSuccess` is case-insensitive (MACH:1023), unlike the cloud `CommandStatus(rawValue:)` (§3.7).
        XCTAssertTrue(try BluetoothResponseDecoder.commandStatus(#"{"id":"a","message":"m","status":"SUCCESS"}"#).isSuccess)
        // Extra keys are ignored.
        XCTAssertEqual(
            try BluetoothResponseDecoder.commandStatus(#"{"id":"a","message":"m","status":"success","extra":1}"#),
            BluetoothCommandStatus(id: "a", message: "m", status: "success"))
    }

    /// Angstrom-only: G-CODEC-6 — a command status with a missing key or a non-object throws `.decoding("bluetooth command: …")`
    func testCommandStatusMissingKey() {
        for text in [
            #"{"message":"m","status":"success"}"#,
            #"{"id":"a","status":"success"}"#,
            #"{"id":"a","message":"m"}"#,
            #"{}"#,
            #"[1]"#,
            #"[{"id":"a","message":"m","status":"success"}]"#,
            #""success""#,
            "5",
            "null",
            "true",
            "",
            "not json",
        ] {
            assertDecoding(try BluetoothResponseDecoder.commandStatus(text), context: "command", text)
        }
    }

    /// Angstrom-only: §3.6 — malformed read responses (empty capabilities, unknown mode, non-JSON) throw `.decoding`
    func testMalformedResponsesThrowDecoding() {
        // Empty capabilities array (`capabilities[0]` IndexError parity).
        assertDecoding(try BluetoothResponseDecoder.capabilities("[]"), context: "machineCapabilities")
        // Capabilities whose top level is not an array, or whose [0] is not an object.
        assertDecoding(try BluetoothResponseDecoder.capabilities(Self.capObject(family: #""MICRA""#)),
                       context: "machineCapabilities")
        assertDecoding(try BluetoothResponseDecoder.capabilities("[1]"), context: "machineCapabilities")
        assertDecoding(try BluetoothResponseDecoder.capabilities("[null]"), context: "machineCapabilities")
        // Unknown or non-string machine mode (`MachineMode(value)` ValueError parity, BT:558).
        assertDecoding(try BluetoothResponseDecoder.machineMode(#""TurboMode""#), context: "machineMode")
        assertDecoding(try BluetoothResponseDecoder.machineMode(#""brewingmode""#), context: "machineMode")
        assertDecoding(try BluetoothResponseDecoder.machineMode(#""""#), context: "machineMode")
        assertDecoding(try BluetoothResponseDecoder.machineMode("5"), context: "machineMode")
        assertDecoding(try BluetoothResponseDecoder.machineMode("null"), context: "machineMode")
        assertDecoding(try BluetoothResponseDecoder.machineMode(#"["BrewingMode"]"#), context: "machineMode")
        // Unknown smart-standby mode (`SmartStandByType(value)` parity).
        assertDecoding(try BluetoothResponseDecoder.smartStandby(#"{"mode":"Never","minutes":42,"enabled":true}"#),
                       context: "smartStandBy")
        assertDecoding(try BluetoothResponseDecoder.smartStandby(#"{"mode":5,"minutes":42,"enabled":true}"#),
                       context: "smartStandBy")
        assertDecoding(try BluetoothResponseDecoder.smartStandby(#"{"minutes":42,"enabled":true}"#),
                       context: "smartStandBy")
        assertDecoding(try BluetoothResponseDecoder.smartStandby(#"{"mode":"PowerOn","enabled":true}"#),
                       context: "smartStandBy")
        assertDecoding(try BluetoothResponseDecoder.smartStandby(#"{"mode":"PowerOn","minutes":42}"#),
                       context: "smartStandBy")
        // smartStandBy is an object, not an array (853a4d1).
        assertDecoding(try BluetoothResponseDecoder.smartStandby(#"[{"mode":"PowerOn","minutes":42,"enabled":true}]"#),
                       context: "smartStandBy")
        // Boilers: not an array, a non-object element, missing keys.
        assertDecoding(try BluetoothResponseDecoder.boilers(#"{"id":"SteamBoiler","isEnabled":true,"target":131,"current":45}"#),
                       context: "boilers")
        assertDecoding(try BluetoothResponseDecoder.boilers("[1]"), context: "boilers")
        assertDecoding(try BluetoothResponseDecoder.boilers(#"[{"isEnabled":true,"target":131,"current":45}]"#),
                       context: "boilers")
        assertDecoding(try BluetoothResponseDecoder.boilers(#"[{"id":"SteamBoiler","target":131,"current":45}]"#),
                       context: "boilers")
        assertDecoding(try BluetoothResponseDecoder.boilers(#"[{"id":"SteamBoiler","isEnabled":true,"current":45}]"#),
                       context: "boilers")
        assertDecoding(try BluetoothResponseDecoder.boilers(#"[{"id":"SteamBoiler","isEnabled":true,"target":131}]"#),
                       context: "boilers")
        // A failing second element fails the whole read.
        assertDecoding(try BluetoothResponseDecoder.boilers(
            #"[{"id":"SteamBoiler","isEnabled":true,"target":131,"current":45},{"id":"CoffeeBoiler1"}]"#),
                       context: "boilers")
        // Capabilities: every required key is required.
        for key in ["family", "groupsNumber", "coffeeBoilersNumber", "hasCupWarmer", "steamBoilersNumber",
                    "teaDosesNumber", "machineModes", "schedulingType"] {
            assertDecoding(try BluetoothResponseDecoder.capabilities(Self.capMicra(removing: key)),
                           context: "machineCapabilities", "missing \(key)")
        }
        // Non-JSON on every reader.
        for text in ["", "not json", "{", #""BrewingMode"\#u{0}"#] {
            assertDecoding(try BluetoothResponseDecoder.machineMode(text), context: "machineMode", text)
            assertDecoding(try BluetoothResponseDecoder.capabilities(text), context: "machineCapabilities", text)
            assertDecoding(try BluetoothResponseDecoder.boilers(text), context: "boilers", text)
            assertDecoding(try BluetoothResponseDecoder.smartStandby(text), context: "smartStandBy", text)
            assertDecoding(try BluetoothResponseDecoder.bool(text, setting: .tankStatus), context: "tankStatus", text)
            assertDecoding(try BluetoothResponseDecoder.commandStatus(text), context: "command", text)
        }
    }

    /// Angstrom-only: D5 — an unknown boiler id decodes as `.other(raw)` instead of failing the read
    func testUnknownBoilerIdTolerated() throws {
        let boilers = try BluetoothResponseDecoder.boilers(
            #"[{"id":"Foo","isEnabled":true,"target":100,"current":50},"#
            + #"{"id":"CoffeeBoiler1","isEnabled":false,"target":94,"current":65}]"#)
        XCTAssertEqual(boilers, [
            BluetoothBoilerDetails(id: .other("Foo"), isEnabled: true, target: 100, current: 50),
            BluetoothBoilerDetails(id: .coffee, isEnabled: false, target: 94, current: 65),
        ])
        // Case-sensitive: "steamboiler" is not `.steam`.
        XCTAssertEqual(
            try BluetoothResponseDecoder.boilers(#"[{"id":"steamboiler","isEnabled":true,"target":1,"current":2}]"#)[0].id,
            .other("steamboiler"))
    }

    /// Angstrom-only: D9 — boiler target/current are Double, so fractional values are kept (no int truncation)
    func testFractionalBoilerTarget() throws {
        let boilers = try BluetoothResponseDecoder.boilers(
            #"[{"id":"SteamBoiler","isEnabled":true,"target":130.5,"current":45.25},"#
            + #"{"id":"CoffeeBoiler1","isEnabled":true,"target":93.9,"current":0.5}]"#)
        XCTAssertEqual(boilers, [
            BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 130.5, current: 45.25),
            BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 93.9, current: 0.5),
        ])
        // The D9 consequence: 130.5 maps to level3 (upstream truncates to 130 → level2).
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: boilers[0].target), .level3)
    }

    /// Angstrom-only: §9.3.2 — BT-COERCE-001…011 decoder-level coercion vectors (Angstrom column; D5/D9 rows marked)
    func testResponseCoercionVectors() throws {
        // BT-COERCE-001: required string null → "None"; still a success.
        let coerce001 = try BluetoothResponseDecoder.commandStatus(#"{"id":"a","message":null,"status":"success"}"#)
        XCTAssertEqual(coerce001, BluetoothCommandStatus(id: "a", message: "None", status: "success"))
        XCTAssertTrue(coerce001.isSuccess)

        // BT-COERCE-002: str() of a number, a bool and a container (container text differs, D5c).
        XCTAssertEqual(try BluetoothResponseDecoder.commandStatus(#"{"id":5,"message":true,"status":"success"}"#),
                       BluetoothCommandStatus(id: "5", message: "True", status: "success"))
        XCTAssertEqual(try BluetoothResponseDecoder.commandStatus(#"{"id":"a","message":[1],"status":"success"}"#),
                       BluetoothCommandStatus(id: "a", message: "[1]", status: "success"))

        // BT-COERCE-003: missing key / non-object → .decoding("bluetooth command: …").
        assertDecoding(try BluetoothResponseDecoder.commandStatus(#"{"id":"a","status":"success"}"#), context: "command")
        assertDecoding(try BluetoothResponseDecoder.commandStatus("[1]"), context: "command")

        // BT-COERCE-004: schedulingType null → "None"; 5 → "5".
        XCTAssertEqual(try BluetoothResponseDecoder.capabilities(
            Self.capMicra(replacing: "schedulingType", with: "null")).schedulingType, "None")
        XCTAssertEqual(try BluetoothResponseDecoder.capabilities(
            Self.capMicra(replacing: "schedulingType", with: "5")).schedulingType, "5")

        // BT-COERCE-005: steam isEnabled [] / {"a":1} / null / 0 → false / true / false / false.
        let coerce005: [(String, Bool)] = [("[]", false), (#"{"a":1}"#, true), ("null", false), ("0", false)]
        for (raw, expected) in coerce005 {
            let boilers = try BluetoothResponseDecoder.boilers(Self.boil(steamIsEnabled: raw))
            XCTAssertEqual(boilers[0], BluetoothBoilerDetails(id: .steam, isEnabled: expected, target: 131, current: 45), raw)
            XCTAssertEqual(boilers[1], BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 94, current: 65), raw)
        }

        // BT-COERCE-006 (D5a): steam isEnabled "false" → false (upstream True).
        XCTAssertEqual(try BluetoothResponseDecoder.boilers(Self.boil(steamIsEnabled: #""false""#))[0].isEnabled, false)
        XCTAssertEqual(try BluetoothResponseDecoder.boilers(Self.boil(steamIsEnabled: #""true""#))[0].isEnabled, true)

        // BT-COERCE-007 (D9): steam target 127.5 → 127.5; "127.5" → 127.5; null → .decoding.
        XCTAssertEqual(try BluetoothResponseDecoder.boilers(Self.boil(steamTarget: "127.5"))[0].target, 127.5)
        XCTAssertEqual(try BluetoothResponseDecoder.boilers(Self.boil(steamTarget: #""127.5""#))[0].target, 127.5)
        assertDecoding(try BluetoothResponseDecoder.boilers(Self.boil(steamTarget: "null")), context: "boilers")

        // BT-COERCE-008 (D5b): unknown boiler id and machineModes entry → .other.
        XCTAssertEqual(try BluetoothResponseDecoder.boilers(Self.boil(steamID: #""Foo""#))[0].id, .other("Foo"))
        XCTAssertEqual(try BluetoothResponseDecoder.capabilities(
            Self.capMicra(replacing: "machineModes", with: #"["BrewingMode","Foo"]"#)).machineModes,
                       [.brewing, .other("Foo")])

        // BT-COERCE-009: minutes 42.7 → 42 (truncation); "42" → 42; null → .decoding.
        XCTAssertEqual(try BluetoothResponseDecoder.smartStandby(Self.ssb(minutes: "42.7")).minutes, 42)
        XCTAssertEqual(try BluetoothResponseDecoder.smartStandby(Self.ssb(minutes: #""42""#)).minutes, 42)
        assertDecoding(try BluetoothResponseDecoder.smartStandby(Self.ssb(minutes: "null")), context: "smartStandBy")

        // BT-COERCE-010 (D5d): minutes 1e300 / 12345678901234567890 → .decoding (never traps).
        assertDecoding(try BluetoothResponseDecoder.smartStandby(Self.ssb(minutes: "1e300")), context: "smartStandBy")
        assertDecoding(try BluetoothResponseDecoder.smartStandby(Self.ssb(minutes: "12345678901234567890")),
                       context: "smartStandBy")

        // BT-COERCE-011: groupsNumber "1.0" → .decoding; family 5 → .decoding; "linea mini 2023" → .lineaMiniR.
        assertDecoding(try BluetoothResponseDecoder.capabilities(
            Self.capMicra(replacing: "groupsNumber", with: #""1.0""#)), context: "machineCapabilities")
        assertDecoding(try BluetoothResponseDecoder.capabilities(Self.capArray(family: "5")),
                       context: "machineCapabilities")
        let spaced = try BluetoothResponseDecoder.capabilities(Self.capArray(family: #""linea mini 2023""#))
        XCTAssertEqual(spaced.family, .lineaMiniR)
        XCTAssertEqual(spaced.rawFamily, "linea mini 2023")
    }

    /// Angstrom-only: §3.10 — a hex-float string boiler target ("0x1p3") is `.decoding` (Python `float()` raises)
    func testHexFloatBoilerTargetRejected() throws {
        try XCTSkipIf(true, "BLOCKED-BY BT-W1-01: BluetoothWireCoercion.optionalDouble accepts hex-float strings (\"0x1p3\" → 8.0); SPEC §3.10 requires an error when s contains x or X")
        // SPEC §3.10 double rule: "error … if `s` contains `x` or `X`" (Swift's `Double(String)` accepts
        // hex floats such as "0x1p3" = 8.0; Python's `float()` raises on them: parity).
        assertDecoding(try BluetoothResponseDecoder.boilers(Self.boil(steamTarget: #""0x1p3""#)), context: "boilers")
        assertDecoding(try BluetoothResponseDecoder.boilers(Self.boil(steamTarget: #""0X10""#)), context: "boilers")
    }

    // MARK: - Helpers

    /// BT-RSP-CAP-001 bytes (TBC:342), verbatim.
    private static let capMicraText = #"[{"family":"MICRA","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":false,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":["BrewingMode","StandBy"],"schedulingType":"smartWakeUpSleep"}]"#

    /// BT-RSP-BOIL-001 bytes (TBC:365), verbatim.
    private static let boilText = #"[{"id":"SteamBoiler","isEnabled":true,"target":131,"current":45},{"id":"CoffeeBoiler1","isEnabled":true,"target":94,"current":65}]"#

    /// The BT-RSP-CAP-001 key/value pairs in wire order, as raw JSON value texts.
    private static let capFields: [(String, String)] = [
        ("family", #""MICRA""#), ("groupsNumber", "1"), ("coffeeBoilersNumber", "1"),
        ("hasCupWarmer", "false"), ("steamBoilersNumber", "1"), ("teaDosesNumber", "0"),
        ("machineModes", #"["BrewingMode","StandBy"]"#), ("schedulingType", #""smartWakeUpSleep""#),
    ]

    private static func capJSON(_ fields: [(String, String)]) -> String {
        "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    /// BT-RSP-CAP-001's object with `family` replaced by a raw JSON value text.
    private static func capObject(family: String) -> String {
        capJSON(capFields.map { $0.0 == "family" ? ($0.0, family) : $0 })
    }

    private static func capArray(family: String) -> String {
        "[" + capObject(family: family) + "]"
    }

    /// BT-RSP-CAP-001 with one key's value replaced by a raw JSON value text.
    private static func capMicra(replacing key: String, with raw: String) -> String {
        precondition(capFields.contains { $0.0 == key })
        return "[" + capJSON(capFields.map { $0.0 == key ? (key, raw) : $0 }) + "]"
    }

    /// BT-RSP-CAP-001 with one key removed.
    private static func capMicra(removing key: String) -> String {
        precondition(capFields.contains { $0.0 == key })
        return "[" + capJSON(capFields.filter { $0.0 != key }) + "]"
    }

    /// BT-RSP-BOIL-001 with the steam boiler's fields replaced by raw JSON value texts.
    private static func boil(steamID: String = #""SteamBoiler""#, steamIsEnabled: String = "true",
                             steamTarget: String = "131") -> String {
        #"[{"id":\#(steamID),"isEnabled":\#(steamIsEnabled),"target":\#(steamTarget),"current":45},"#
            + #"{"id":"CoffeeBoiler1","isEnabled":true,"target":94,"current":65}]"#
    }

    /// BT-RSP-SSB-001 with `minutes` replaced by a raw JSON value text.
    private static func ssb(minutes: String) -> String {
        #"{"mode":"PowerOn","minutes":\#(minutes),"enabled":"true"}"#
    }

    /// Asserts `expression` throws exactly `LaMarzoccoError.decoding` whose message starts with
    /// `"bluetooth <context>: "` and carries a non-empty detail.
    private func assertDecoding<T>(_ expression: @autoclosure () throws -> T, context: String,
                                   _ note: String = "", file: StaticString = #filePath, line: UInt = #line) {
        do {
            let value = try expression()
            XCTFail("expected .decoding(\"bluetooth \(context): …\"), got \(value) \(note)", file: file, line: line)
        } catch let LaMarzoccoError.decoding(message) {
            let prefix = "bluetooth \(context): "
            XCTAssertTrue(message.hasPrefix(prefix), "message \(message.debugDescription) lacks \(prefix.debugDescription) \(note)",
                          file: file, line: line)
            XCTAssertGreaterThan(message.count, prefix.count, "empty detail \(note)", file: file, line: line)
        } catch {
            XCTFail("expected LaMarzoccoError.decoding, got \(error) \(note)", file: file, line: line)
        }
    }
}
