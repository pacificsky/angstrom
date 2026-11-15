import XCTest
import Angstrom
@testable import angcli

/// Pure parts of `BleSession` (SPEC §10.2, §10.3): no CoreBluetooth, no network.
final class BleSessionTests: XCTestCase {
    /// Angstrom-only: §10.2 — `--ble-token` beats `LAMARZOCCO_BLE_TOKEN`, which beats the cloud.
    func testTokenPrecedenceFlagThenEnvironment() async throws {
        XCTAssertEqual(BleSession.tokenEnvironmentVariable, "LAMARZOCCO_BLE_TOKEN")

        let both = try XCTUnwrap(BleSession.localToken(flag: "FLAGTOKEN",
                                                       environment: ["LAMARZOCCO_BLE_TOKEN": "ENVTOKEN"]))
        XCTAssertEqual(both.token, BluetoothAuthToken("FLAGTOKEN"))
        XCTAssertEqual(both.source, .flag)

        let flagOnly = try XCTUnwrap(BleSession.localToken(flag: "FLAGTOKEN", environment: [:]))
        XCTAssertEqual(flagOnly.token, BluetoothAuthToken("FLAGTOKEN"))
        XCTAssertEqual(flagOnly.source, .flag)

        let envOnly = try XCTUnwrap(BleSession.localToken(
            flag: nil, environment: ["PATH": "/usr/bin", "LAMARZOCCO_BLE_TOKEN": "ENVTOKEN"]))
        XCTAssertEqual(envOnly.token, BluetoothAuthToken("ENVTOKEN"))
        XCTAssertEqual(envOnly.source, .environment)

        // The token is passed verbatim (no trimming).
        let verbatim = try XCTUnwrap(BleSession.localToken(flag: " a b ", environment: [:]))
        XCTAssertEqual(verbatim.token.rawValue, " a b ")

        // resolveToken takes the local path without touching the cloud.
        let withFlag = try BleTargetOptions.parse(["--ble-token", "FLAGTOKEN"])
        let fromFlag = try await BleSession.resolveToken(withFlag, environment: ["LAMARZOCCO_BLE_TOKEN": "ENVTOKEN"])
        XCTAssertEqual(fromFlag.rawValue, "FLAGTOKEN")

        let withoutFlag = try BleTargetOptions.parse([])
        let fromEnvironment = try await BleSession.resolveToken(withoutFlag, environment: ["LAMARZOCCO_BLE_TOKEN": "ENVTOKEN"])
        XCTAssertEqual(fromEnvironment.rawValue, "ENVTOKEN")
    }

    /// Angstrom-only: §10.2 — an empty flag or env var is no token: it falls through to the next source.
    func testEmptyLocalTokensFallThroughToCloud() {
        XCTAssertNil(BleSession.localToken(flag: nil, environment: [:]))
        XCTAssertNil(BleSession.localToken(flag: "", environment: [:]))
        XCTAssertNil(BleSession.localToken(flag: nil, environment: ["LAMARZOCCO_BLE_TOKEN": ""]))
        XCTAssertNil(BleSession.localToken(flag: "", environment: ["LAMARZOCCO_BLE_TOKEN": ""]))
        // The variable name is exact and case-sensitive; other variables are ignored.
        XCTAssertNil(BleSession.localToken(flag: nil, environment: ["lamarzocco_ble_token": "x",
                                                                    "LAMARZOCCO_TOKEN": "y",
                                                                    "BLE_TOKEN": "z"]))

        // An empty flag falls through to a non-empty env var.
        let fallback = BleSession.localToken(flag: "", environment: ["LAMARZOCCO_BLE_TOKEN": "ENVTOKEN"])
        XCTAssertEqual(fallback?.token, BluetoothAuthToken("ENVTOKEN"))
        XCTAssertEqual(fallback?.source, .environment)
    }

    /// Angstrom-only: §10.2 — exactly one match → it; none → the exact CLIError; several → nil (prompt).
    func testSelectPeripheralNoneOneMany() throws {
        XCTAssertThrowsError(try BleSession.selectPeripheral(from: [])) { error in
            XCTAssertEqual((error as? CLIError)?.message, "No La Marzocco machine found nearby")
        }

        let micra = DiscoveredPeripheral(id: BluetoothPeripheralID(rawValue: "1B6B3B2C-6F0E-4C55-9E1A-2D3C4B5A6978"),
                                         name: "MICRA_123456", rssi: -60)
        let mini = DiscoveredPeripheral(id: BluetoothPeripheralID(rawValue: "2C7C4C3D-7A1F-4D66-8F2B-3E4D5C6B7A89"),
                                        name: "MINI_654321", rssi: nil)
        XCTAssertEqual(try BleSession.selectPeripheral(from: [micra]), micra)
        XCTAssertEqual(try BleSession.selectPeripheral(from: [mini]), mini)
        XCTAssertNil(try BleSession.selectPeripheral(from: [micra, mini]))
        XCTAssertNil(try BleSession.selectPeripheral(from: [mini, micra, micra]))
    }

    /// Angstrom-only: §10.3 — `.bluetoothUnavailable(.unauthorized(_))` and `.poweredOff` get the CLI texts.
    func testUnavailableErrorTexts() {
        let denied = "Bluetooth access denied. Grant it to your terminal app in System Settings › Privacy & Security › Bluetooth."
        for authorization in [BluetoothAuthorization.denied, .restricted, .notDetermined, .allowedAlways] {
            XCTAssertEqual(BleSession.cliError(LaMarzoccoError.bluetoothUnavailable(.unauthorized(authorization))).message,
                           denied, "\(authorization)")
        }
        XCTAssertEqual(BleSession.cliError(LaMarzoccoError.bluetoothUnavailable(.poweredOff)).message,
                       "Bluetooth is off.")

        // Every other error keeps its errorDescription (SPEC §6.4 texts).
        XCTAssertEqual(BleSession.cliError(LaMarzoccoError.bluetoothUnavailable(.unsupported)).message,
                       "Bluetooth Low Energy is not supported on this device.")
        XCTAssertEqual(BleSession.cliError(LaMarzoccoError.bluetoothUnavailable(.unknown)).message,
                       "Bluetooth is not ready.")
        XCTAssertEqual(BleSession.cliError(LaMarzoccoError.bluetoothUnavailable(.resetting)).message,
                       "Bluetooth is not ready.")
        XCTAssertEqual(BleSession.cliError(LaMarzoccoError.bluetoothAuthenticationFailed).message,
                       "Bluetooth authentication failed. The Bluetooth token is likely wrong.")
        XCTAssertEqual(BleSession.cliError(LaMarzoccoError.bluetoothConnectionFailed("Unknown peripheral X; scan again")).message,
                       "Bluetooth connection failed: Unknown peripheral X; scan again")
        XCTAssertEqual(BleSession.cliError(LaMarzoccoError.bluetoothTimedOut("read")).message,
                       "The machine did not answer over Bluetooth in time (read).")
        // A CLIError passes through unchanged.
        XCTAssertEqual(BleSession.cliError(CLIError("No La Marzocco machine found nearby")).message,
                       "No La Marzocco machine found nearby")
    }

    /// Angstrom-only: §10.2 — `--peripheral`, `--serial` and `--ble-token` parse; the token help discourages the flag.
    func testTargetOptionsParse() throws {
        let all = try BleTargetOptions.parse([
            "--peripheral", "1B6B3B2C-6F0E-4C55-9E1A-2D3C4B5A6978",
            "--serial", "MR012345",
            "--ble-token", "FLAGTOKEN",
        ])
        XCTAssertEqual(all.peripheral, "1B6B3B2C-6F0E-4C55-9E1A-2D3C4B5A6978")
        XCTAssertEqual(all.serial, "MR012345")
        XCTAssertEqual(all.bleToken, "FLAGTOKEN")

        let none = try BleTargetOptions.parse([])
        XCTAssertNil(none.peripheral)
        XCTAssertNil(none.serial)
        XCTAssertNil(none.bleToken)

        XCTAssertThrowsError(try BleTargetOptions.parse(["--token", "x"]))
        XCTAssertThrowsError(try BleTargetOptions.parse(["--ble-token"]))

        let help = BleTargetOptions.helpMessage(columns: 1000)
        XCTAssertTrue(help.contains("--ble-token"), help)
        XCTAssertTrue(help.contains("Bluetooth token. Discouraged: it lands in your shell history; prefer LAMARZOCCO_BLE_TOKEN."), help)
        XCTAssertTrue(help.contains("(a CoreBluetooth UUID, not a MAC)"), help)
    }
}
