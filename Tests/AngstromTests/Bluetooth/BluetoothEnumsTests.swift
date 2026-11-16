import XCTest
@testable import Angstrom
import AngstromTestSupport

/// Leaf enums and constants of the Bluetooth port: SPEC §2.2, §2.3, §6.1, §6.5.
final class BluetoothEnumsTests: XCTestCase {

    // MARK: - Constants (§2.2, §6.1)

    /// Angstrom-only: §2.2 — every BLE constant is verbatim from `_bluetooth.py:40-54` (and the bleak/§6.1 defaults).
    func testConstantsVerbatim() {
        // Characteristic UUIDs, copied from $UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:40-44.
        XCTAssertEqual(BluetoothConstants.readCharacteristic.string, "0a0b7847-e12b-09a8-b04b-8e0922a9abab")
        XCTAssertEqual(BluetoothConstants.writeCharacteristic.string, "0b0b7847-e12b-09a8-b04b-8e0922a9abab")
        XCTAssertEqual(BluetoothConstants.tokenCharacteristic.string, "0c0b7847-e12b-09a8-b04b-8e0922a9abab")
        XCTAssertEqual(BluetoothConstants.authCharacteristic.string, "0d0b7847-e12b-09a8-b04b-8e0922a9abab")
        XCTAssertEqual(BluetoothConstants.shotCounterCharacteristic.string, "0e0b7847-e12b-09a8-b04b-8e0922a9abab")
        XCTAssertEqual(BluetoothConstants.readCharacteristic.description, "0a0b7847-e12b-09a8-b04b-8e0922a9abab")

        // The four session characteristics: everything except the pairing-mode token characteristic.
        XCTAssertEqual(BluetoothConstants.sessionCharacteristics, [
            GATTUUID("0a0b7847-e12b-09a8-b04b-8e0922a9abab"),
            GATTUUID("0b0b7847-e12b-09a8-b04b-8e0922a9abab"),
            GATTUUID("0d0b7847-e12b-09a8-b04b-8e0922a9abab"),
            GATTUUID("0e0b7847-e12b-09a8-b04b-8e0922a9abab"),
        ])
        XCTAssertEqual(BluetoothConstants.sessionCharacteristics.count, 4)
        XCTAssertFalse(BluetoothConstants.sessionCharacteristics.contains(BluetoothConstants.tokenCharacteristic))

        // GATTUUID normalises to lowercase, so an upper-case UUID from CoreBluetooth compares equal.
        let upper = GATTUUID("0A0B7847-E12B-09A8-B04B-8E0922A9ABAB")
        XCTAssertEqual(upper.string, "0a0b7847-e12b-09a8-b04b-8e0922a9abab")
        XCTAssertEqual(upper, BluetoothConstants.readCharacteristic)

        // BT_MODEL_PREFIXES = ("MICRA", "MINI", "LINEA", "GS3"), in order, also on the public client.
        XCTAssertEqual(BluetoothConstants.machineNamePrefixes, ["MICRA", "MINI", "LINEA", "GS3"])
        XCTAssertEqual(LaMarzoccoBluetoothClient.machineNamePrefixes, ["MICRA", "MINI", "LINEA", "GS3"])

        // AUTH_SUCCESS = b"\x01".
        XCTAssertEqual(BluetoothConstants.authSuccess, Data([0x01]))

        // Timing defaults (§2.2 upstream values; §6.1 for the Angstrom-only bounds).
        let timing = BluetoothTiming()
        XCTAssertEqual(timing.idleTimeout, .seconds(30))                 // IDLE_TIMEOUT = 30
        XCTAssertEqual(timing.authReadAttempts, 10)                      // AUTH_READ_ATTEMPTS = 10
        XCTAssertEqual(timing.authReadInterval, .milliseconds(50))       // AUTH_READ_INTERVAL = 0.05
        XCTAssertEqual(timing.maxAuthFailures, 3)                        // MAX_AUTH_FAILURES = 3
        XCTAssertEqual(timing.reconnectInitialDelay, .seconds(1))        // RECONNECT_INITIAL_DELAY = 1
        XCTAssertEqual(timing.reconnectMaxDelay, .seconds(60))           // RECONNECT_MAX_DELAY = 60
        XCTAssertEqual(timing.connectAttempts, 3)                        // establish_connection max_attempts=3
        XCTAssertEqual(timing.connectTimeout, .seconds(20))              // BLEAK_TIMEOUT = 20.0
        XCTAssertEqual(timing.connectBackoffAfterTimeout, .milliseconds(250))
        XCTAssertEqual(timing.connectBackoff, .milliseconds(100))
        XCTAssertEqual(timing.operationTimeout, .seconds(20))
        XCTAssertEqual(timing.poweredOnWait, .seconds(10))
        XCTAssertEqual(timing.tokenReadConnectTimeout, .seconds(10))
        XCTAssertEqual(timing.scanDuration, .seconds(5))
    }

    // MARK: - Raw values (const.py:307-339)

    /// Angstrom-only: §6.5 — `BluetoothReadSetting` raw values and order are verbatim from `const.py:322-330`.
    func testReadSettingRawValues() {
        XCTAssertEqual(BluetoothReadSetting.machineCapabilities.rawValue, "machineCapabilities")
        XCTAssertEqual(BluetoothReadSetting.machineMode.rawValue, "machineMode")
        XCTAssertEqual(BluetoothReadSetting.tankStatus.rawValue, "tankStatus")
        XCTAssertEqual(BluetoothReadSetting.boilers.rawValue, "boilers")
        XCTAssertEqual(BluetoothReadSetting.smartStandBy.rawValue, "smartStandBy")
        XCTAssertEqual(BluetoothReadSetting.isPlumbedIn.rawValue, "isPlumbedIn")
        XCTAssertEqual(BluetoothReadSetting.allCases.map(\.rawValue),
                       ["machineCapabilities", "machineMode", "tankStatus", "boilers", "smartStandBy", "isPlumbedIn"])
        for setting in BluetoothReadSetting.allCases {
            XCTAssertEqual(BluetoothReadSetting(rawValue: setting.rawValue), setting)
        }
        XCTAssertNil(BluetoothReadSetting(rawValue: "MachineCapabilities"))
        XCTAssertNil(BluetoothReadSetting(rawValue: "smartStandby"))
    }

    /// Angstrom-only: §6.5 — `BluetoothBrewingState` raw values are verbatim from `const.py:333-339`, and it round-trips as JSON.
    func testBrewingStateRawValues() throws {
        let expected: [(BluetoothBrewingState, String)] = [
            (.brewing, "Brewing"),
            (.brewingStopped, "BrewingStopped"),
            (.flushed, "Flushed"),
            (.backflushing, "Backflushing"),
        ]
        for (state, raw) in expected {
            XCTAssertEqual(state.rawValue, raw)
            XCTAssertEqual(BluetoothBrewingState(rawValue: raw), state)
            let encoded = try JSONEncoder().encode(state)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(raw)\"")
            XCTAssertEqual(try JSONDecoder().decode(BluetoothBrewingState.self, from: encoded), state)
        }
        XCTAssertNil(BluetoothBrewingState(rawValue: "brewing"))
        XCTAssertNil(BluetoothBrewingState(rawValue: "Backflush"))
    }

    /// Angstrom-only: §6.5 — `BluetoothBoilerType` maps `const.py:307-311` and keeps unknown ids as `.other` (D5b).
    func testBoilerTypeRoundTrip() {
        XCTAssertEqual(BluetoothBoilerType(rawValue: "CoffeeBoiler1"), .coffee)
        XCTAssertEqual(BluetoothBoilerType(rawValue: "SteamBoiler"), .steam)
        XCTAssertEqual(BluetoothBoilerType.coffee.rawValue, "CoffeeBoiler1")
        XCTAssertEqual(BluetoothBoilerType.steam.rawValue, "SteamBoiler")

        // Unknown values, including case variants of the known ones, are kept verbatim.
        for raw in ["Foo", "coffeeboiler1", "SteamBoiler2", "CoffeeBoiler2", ""] {
            let type = BluetoothBoilerType(rawValue: raw)
            XCTAssertEqual(type, .other(raw), raw)
            XCTAssertEqual(type.rawValue, raw)
        }
        XCTAssertEqual(BluetoothBoilerType.other("Foo").rawValue, "Foo")
        for type in [BluetoothBoilerType.coffee, .steam, .other("X")] {
            XCTAssertEqual(BluetoothBoilerType(rawValue: type.rawValue), type)
        }
    }

    // MARK: - Model from the BLE family (const.py:198-218, D8)

    /// Upstream: test_model_name_from_bluetooth_family (tests/test_models.py:416) [O04, O05, O06, O07]
    func testFamilyMapping() {
        // The four upstream cases.
        XCTAssertEqual(Model(bluetoothFamily: "LINEA"), .lineaMini)          // O04
        XCTAssertEqual(Model(bluetoothFamily: "LINEAMINI2023"), .lineaMiniR) // O05
        XCTAssertEqual(Model(bluetoothFamily: "MICRA"), .lineaMicra)         // O06
        XCTAssertEqual(Model(bluetoothFamily: "GS3"), .gs3AV)                // O07

        // Every row of the §6.5 table (`ModelName.from_string` mapping).
        let table: [(String, Model)] = [
            ("GS3", .gs3AV),
            ("GS3MP", .gs3MP),
            ("GS3AV", .gs3AV),
            ("LINEAMINI2023", .lineaMiniR),
            ("LINEAMICRA", .lineaMicra),
            ("LINEAMINI", .lineaMini),
            ("LINEA", .lineaMini),
            ("MICRA", .lineaMicra),
            ("STRADAX", .stradaX),
            ("PICOGRINDER", .pico),
            ("SWANGRINDER", .swan),
        ]
        for (family, model) in table {
            XCTAssertEqual(Model(bluetoothFamily: family), model, family)
        }

        // Normalisation: upper-case, then strip ALL whitespace (`"".join(name.upper().split())`).
        XCTAssertEqual(Model(bluetoothFamily: "gs3 av"), .gs3AV)
        XCTAssertEqual(Model(bluetoothFamily: "linea mini 2023"), .lineaMiniR)
        XCTAssertEqual(Model(bluetoothFamily: "Linea Micra"), .lineaMicra)
        XCTAssertEqual(Model(bluetoothFamily: "  micra  "), .lineaMicra)
        XCTAssertEqual(Model(bluetoothFamily: "Strada\tX\n"), .stradaX)
        XCTAssertEqual(Model(bluetoothFamily: "G S 3 M P"), .gs3MP)
        XCTAssertEqual(Model(bluetoothFamily: "Swan\r\nGrinder"), .swan)
        XCTAssertEqual(Model(bluetoothFamily: "pico\u{00A0}grinder"), .pico)   // NBSP: str.isspace() is True
        XCTAssertEqual(Model(bluetoothFamily: "LINEA\u{1F}MINI"), .lineaMini)  // U+001F: str.isspace() is True

        // Anything else → nil (upstream raises ValueError "Invalid model name").
        for family in ["FOO", "", "   ", "LINEAMINIR", "PICO", "SWAN", "GS-3", "MINI", "LINEA_MINI",
                       "LINEA\u{200B}MINI"] {   // U+200B is not whitespace in Python either
            XCTAssertNil(Model(bluetoothFamily: family), family)
        }
    }

    /// Angstrom-only: D8 — the cloud parser keeps `"GS3"` → `.gs3` (and `"LINEA"` unrecognised), unlike the BLE family mapping.
    func testCloudModelMatchUnchanged() {
        XCTAssertEqual(Model(code: "GS3"), .gs3)
        XCTAssertEqual(Model(code: "gs3"), .gs3)
        XCTAssertEqual(Model(code: "", name: "GS3"), .gs3)
        XCTAssertEqual(Model(code: "GS3AV"), .gs3AV)
        XCTAssertEqual(Model(code: "LINEAMINI"), .lineaMini)
        XCTAssertEqual(Model(code: "LINEAMINIR"), .lineaMiniR)
        XCTAssertEqual(Model(code: "MICRA"), .lineaMicra)
        XCTAssertEqual(Model(code: "LINEA"), .unknown("LINEA"))
        // And the BLE mapping really differs for the same strings.
        XCTAssertNotEqual(Model(bluetoothFamily: "GS3"), Model(code: "GS3"))
        XCTAssertEqual(Model(bluetoothFamily: "LINEA"), .lineaMini)
    }

    /// Angstrom-only: §6.5 — the steam-level and steam-temperature model sets (`const.py:182`, `MACH:823`).
    func testSteamModelSets() {
        XCTAssertEqual(Model.steamLevelModels, [.lineaMicra, .lineaMiniR])
        XCTAssertEqual(Model.steamTemperatureModels, [.gs3, .gs3AV, .gs3MP, .stradaX])
    }

    // MARK: - Mode maps (MACH:65-75)

    /// Angstrom-only: §6.5 — `BLE_MACHINE_STATE` (MACH:65-69) for all four `MachineMode` cases.
    func testMachineStateFromBluetoothMode() {
        XCTAssertEqual(MachineState(bluetoothMode: .brewing), .poweredOn)
        XCTAssertEqual(MachineState(bluetoothMode: .eco), .eco)
        XCTAssertEqual(MachineState(bluetoothMode: .standby), .standby)
        XCTAssertEqual(MachineState(bluetoothMode: .other("Foo")), .other("Foo"))
        XCTAssertEqual(MachineState(bluetoothMode: MachineMode(rawValue: "BrewingMode")), .poweredOn)
        XCTAssertEqual(MachineState(bluetoothMode: MachineMode(rawValue: "EcoMode")), .eco)
        XCTAssertEqual(MachineState(bluetoothMode: MachineMode(rawValue: "StandBy")), .standby)
    }

    /// Angstrom-only: §6.5 — `BLE_BOILER_STATUS` (MACH:71-75) for all four `MachineMode` cases.
    func testBoilerStatusFromBluetoothMode() {
        XCTAssertEqual(BoilerStatus(bluetoothMode: .brewing), .ready)
        XCTAssertEqual(BoilerStatus(bluetoothMode: .eco), .eco)
        XCTAssertEqual(BoilerStatus(bluetoothMode: .standby), .standby)
        XCTAssertEqual(BoilerStatus(bluetoothMode: .other("Foo")), .other("Foo"))
        XCTAssertEqual(BoilerStatus(bluetoothMode: MachineMode(rawValue: "BrewingMode")), .ready)
        XCTAssertEqual(BoilerStatus(bluetoothMode: MachineMode(rawValue: "EcoMode")), .eco)
        XCTAssertEqual(BoilerStatus(bluetoothMode: MachineMode(rawValue: "StandBy")), .standby)
    }

    // MARK: - Steam level ↔ temperature (MACH:58-62, 78-84)

    /// Upstream: test_get_dashboard_from_bluetooth_steam_level (tests/test_bluetooth_dashboard.py:650) [D20, D21, D22, D23, D24, D25]
    func testSteamLevelFromTarget() {
        let cases: [(Double, SteamLevel)] = [
            (0, .level3),       // D20
            (126, .level1),     // D21
            (127.9, .level1),   // D22
            (128, .level2),     // D23
            (130, .level2),     // D24
            (131, .level3),     // D25
        ]
        for (target, level) in cases {
            XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: target), level, "target \(target)")
        }
    }

    /// Angstrom-only: §6.5 — `STEAM_LEVEL_MAPPING` (MACH:58-62) and its round trip through the reverse map.
    func testSteamLevelToTarget() {
        XCTAssertEqual(SteamLevel.level1.bluetoothTargetTemperature, 126)
        XCTAssertEqual(SteamLevel.level2.bluetoothTargetTemperature, 128)
        XCTAssertEqual(SteamLevel.level3.bluetoothTargetTemperature, 131)
        for level in SteamLevel.allCases {
            XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: Double(level.bluetoothTargetTemperature)), level)
        }
    }

    /// Angstrom-only: G-DEV-4 — steam-level edges on `Double` targets: 130.5 → level3, −1 → level3, 127.99 → level1.
    func testSteamLevelEdges() {
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: 130.5), .level3)
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: -1), .level3)
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: 127.99), .level1)
        // Boundaries of the half-open/closed intervals: 0 < t < 128, 128 <= t <= 130.
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: 0.5), .level1)   // D9: upstream int(0.5) == 0 → level3
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: 128.0.nextDown), .level1)
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: 130.0.nextUp), .level3)
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: 129.5), .level2)
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: 0.0.nextUp), .level1)
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: -0.0), .level3)
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: .infinity), .level3)
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: -.infinity), .level3)
        XCTAssertEqual(SteamLevel(bluetoothTargetTemperature: .nan), .level3)
    }

    // MARK: - Machine.shotCounterSupported (cloud field)

    /// Upstream: test_shot_counter_supported (tests/test_models.py:395) [O01, O02, O03]
    func testShotCounterSupportedNull() throws {
        func decode(_ json: String) throws -> Bool {
            try JSONDecoder.laMarzocco().decode(Machine.self, from: Data(json.utf8)).shotCounterSupported
        }
        XCTAssertTrue(try decode(#"{"serialNumber":"MR123456","shotCounterSupported":true}"#))    // O01
        XCTAssertFalse(try decode(#"{"serialNumber":"MR123456","shotCounterSupported":false}"#))  // O02
        XCTAssertFalse(try decode(#"{"serialNumber":"MR123456","shotCounterSupported":null}"#))   // O03
        XCTAssertFalse(try decode(#"{"serialNumber":"MR123456"}"#))                               // absent
    }
}
