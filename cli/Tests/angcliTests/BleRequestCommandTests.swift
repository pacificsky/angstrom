import XCTest
import ArgumentParser
import Angstrom
@testable import angcli

/// Parsing and validation of `angcli ble read` and `angcli ble cmd` (SPEC §10.1). Nothing here
/// runs a command: no Bluetooth, no cloud.
final class BleRequestCommandTests: XCTestCase {
    /// Angstrom-only: §10.1 — `ble read <setting|all>` parses every wire setting name, the
    /// `capabilities` alias and `all` (in `const.py:322-330` order), plus the shared selection options.
    func testReadParsesSettingAndAll() throws {
        let wireNames: [(String, BluetoothReadSetting)] = [
            ("machineCapabilities", .machineCapabilities),
            ("machineMode", .machineMode),
            ("tankStatus", .tankStatus),
            ("boilers", .boilers),
            ("smartStandBy", .smartStandBy),
            ("isPlumbedIn", .isPlumbedIn),
        ]
        for (argument, expected) in wireNames {
            let read = try parseRead(["read", argument])
            XCTAssertEqual(read.setting, .one(expected), argument)
            XCTAssertEqual(read.setting.settings, [expected], argument)
            XCTAssertNil(read.target.peripheral, argument)
            XCTAssertNil(read.target.serial, argument)
            XCTAssertNil(read.target.bleToken, argument)
        }

        // SPEC §9.6 H22 spells it `read capabilities`.
        let capabilities = try parseRead(["read", "capabilities"])
        XCTAssertEqual(capabilities.setting, .one(.machineCapabilities))
        XCTAssertEqual(capabilities.setting.settings, [.machineCapabilities])

        let all = try parseRead(["read", "all"])
        XCTAssertEqual(all.setting, .all)
        XCTAssertEqual(all.setting.settings,
                       [.machineCapabilities, .machineMode, .tankStatus, .boilers, .smartStandBy, .isPlumbedIn])

        let selected = try parseRead(["read", "boilers", "--peripheral", "1B2C3D4E-0000-0000-0000-000000000001",
                                      "--serial", "MR012345", "--ble-token", "tok"])
        XCTAssertEqual(selected.setting, .one(.boilers))
        XCTAssertEqual(selected.target.peripheral, "1B2C3D4E-0000-0000-0000-000000000001")
        XCTAssertEqual(selected.target.serial, "MR012345")
        XCTAssertEqual(selected.target.bleToken, "tok")

        // Case-sensitive wire names; unknown names and a missing argument are rejected.
        for bad in [["read", "MachineMode"], ["read", "machinemode"], ["read", "ALL"], ["read", "bogus"],
                    ["read", "machineStatistics"], ["read"]] {
            XCTAssertThrowsError(try AngCLI.parseAsRoot(["ble"] + bad), bad.joined(separator: " ")) { error in
                XCTAssertEqual(AngCLI.exitCode(for: error), .validationFailure, bad.joined(separator: " "))
            }
        }
    }

    /// Angstrom-only: §10.1 — every `ble cmd` subcommand actuates hardware, so validation refuses it
    /// without `--confirm` (exit 64, the confirmation message) and accepts it with `--confirm`.
    func testCmdRefusesWithoutConfirm() throws {
        let invocations: [[String]] = [
            ["power", "on"],
            ["power", "off"],
            ["steam", "on"],
            ["steam", "off"],
            ["temp", "coffee", "93"],
            ["temp", "steam", "130.5"],
            ["standby", "--enabled", "true", "--minutes", "30", "--mode", "PowerOn"],
        ]
        for arguments in invocations {
            let label = arguments.joined(separator: " ")
            XCTAssertThrowsError(try AngCLI.parseAsRoot(["ble", "cmd"] + arguments), label) { error in
                XCTAssertEqual(AngCLI.exitCode(for: error), .validationFailure, label)
                XCTAssertEqual(AngCLI.message(for: error), BleCmd.confirmationRequiredMessage, label)
            }
            // Also refused when only the selection options are given.
            XCTAssertThrowsError(try AngCLI.parseAsRoot(["ble", "cmd"] + arguments + ["--ble-token", "tok"]), label) { error in
                XCTAssertEqual(AngCLI.message(for: error), BleCmd.confirmationRequiredMessage, label)
            }
            let confirmed = try AngCLI.parseAsRoot(["ble", "cmd"] + arguments + ["--confirm"])
            XCTAssertTrue(confirmed is BleCmd.Power || confirmed is BleCmd.Steam
                          || confirmed is BleCmd.Temp || confirmed is BleCmd.Standby, label)
        }
        XCTAssertEqual(BleCmd.confirmationRequiredMessage,
                       "This command actuates the machine over Bluetooth. Pass --confirm to send it.")
        // `cmd` alone is a parent: it has no `run()` of its own that could actuate anything.
        XCTAssertEqual(BleCmd.configuration.subcommands.map { $0.configuration.commandName },
                       ["power", "steam", "temp", "standby"])
    }

    /// Angstrom-only: §10.1 — `power`/`steam <on|off>`, `temp <coffee|steam> <celsius>` and
    /// `standby --enabled --minutes --mode` parse to the values the library calls receive.
    func testCmdSubcommandsParse() throws {
        let powerOn = try parse(BleCmd.Power.self, ["power", "on", "--confirm"])
        XCTAssertEqual(powerOn.state, .on)
        XCTAssertTrue(powerOn.state.isOn)
        XCTAssertTrue(powerOn.confirmation.confirm)
        XCTAssertEqual(powerOn.commandDescription, "power on")
        let powerOff = try parse(BleCmd.Power.self, ["power", "off", "--confirm"])
        XCTAssertEqual(powerOff.state, .off)
        XCTAssertFalse(powerOff.state.isOn)
        XCTAssertEqual(powerOff.commandDescription, "power off")

        let steamOn = try parse(BleCmd.Steam.self, ["steam", "on", "--confirm"])
        XCTAssertEqual(steamOn.state, .on)
        XCTAssertTrue(steamOn.state.isOn)
        XCTAssertEqual(steamOn.commandDescription, "steam on")
        let steamOff = try parse(BleCmd.Steam.self, ["steam", "off", "--confirm"])
        XCTAssertEqual(steamOff.state, .off)
        XCTAssertFalse(steamOff.state.isOn)
        XCTAssertEqual(steamOff.commandDescription, "steam off")

        let coffee = try parse(BleCmd.Temp.self, ["temp", "coffee", "93", "--confirm"])
        XCTAssertEqual(coffee.boiler, .coffee)
        XCTAssertEqual(coffee.boiler.bluetoothBoiler, .coffee)
        XCTAssertEqual(coffee.boiler.bluetoothBoiler.rawValue, "CoffeeBoiler1")
        XCTAssertEqual(coffee.celsius, 93)
        XCTAssertEqual(coffee.commandDescription, "temp coffee 93.0")
        let steam = try parse(BleCmd.Temp.self, ["temp", "steam", "130.5", "--confirm"])
        XCTAssertEqual(steam.boiler, .steam)
        XCTAssertEqual(steam.boiler.bluetoothBoiler, .steam)
        XCTAssertEqual(steam.boiler.bluetoothBoiler.rawValue, "SteamBoiler")
        XCTAssertEqual(steam.celsius, 130.5)
        XCTAssertEqual(steam.commandDescription, "temp steam 130.5")

        let standby = try parse(BleCmd.Standby.self,
                                ["standby", "--enabled", "false", "--minutes", "30", "--mode", "LastBrewing", "--confirm"])
        XCTAssertFalse(standby.enabled)
        XCTAssertEqual(standby.minutes, 30)
        XCTAssertEqual(standby.mode, .lastBrewing)
        XCTAssertEqual(standby.mode.smartStandbyAfter, .lastBrewing)
        XCTAssertEqual(standby.commandDescription, "standby --enabled false --minutes 30 --mode LastBrewing")
        let standbyOn = try parse(BleCmd.Standby.self,
                                  ["standby", "--confirm", "--mode", "PowerOn", "--minutes", "1440", "--enabled", "true"])
        XCTAssertTrue(standbyOn.enabled)
        XCTAssertEqual(standbyOn.minutes, 1440)
        XCTAssertEqual(standbyOn.mode, .powerOn)
        XCTAssertEqual(standbyOn.mode.smartStandbyAfter, .powerOn)
        XCTAssertEqual(standbyOn.commandDescription, "standby --enabled true --minutes 1440 --mode PowerOn")

        // The selection options ride along on every subcommand.
        let selected = try parse(BleCmd.Power.self, ["power", "on", "--confirm", "--peripheral", "P-1",
                                                     "--serial", "MR012345", "--ble-token", "tok"])
        XCTAssertEqual(selected.target.peripheral, "P-1")
        XCTAssertEqual(selected.target.serial, "MR012345")
        XCTAssertEqual(selected.target.bleToken, "tok")
        XCTAssertNil(powerOn.target.peripheral)
        XCTAssertNil(powerOn.target.serial)
        XCTAssertNil(powerOn.target.bleToken)

        // Malformed values are rejected even with --confirm.
        let rejected: [[String]] = [
            ["power", "On", "--confirm"],
            ["power", "true", "--confirm"],
            ["power", "--confirm"],
            ["steam", "1", "--confirm"],
            ["temp", "tea", "93", "--confirm"],
            ["temp", "CoffeeBoiler1", "93", "--confirm"],
            ["temp", "coffee", "hot", "--confirm"],
            ["temp", "coffee", "--confirm"],
            ["standby", "--enabled", "yes", "--minutes", "30", "--mode", "PowerOn", "--confirm"],
            ["standby", "--enabled", "true", "--minutes", "half", "--mode", "PowerOn", "--confirm"],
            ["standby", "--enabled", "true", "--minutes", "30", "--mode", "powerOn", "--confirm"],
            ["standby", "--enabled", "true", "--minutes", "30", "--mode", "Never", "--confirm"],
            ["standby", "--minutes", "30", "--mode", "PowerOn", "--confirm"],
            ["standby", "--enabled", "true", "--mode", "PowerOn", "--confirm"],
            ["standby", "--enabled", "true", "--minutes", "30", "--confirm"],
            ["boil", "--confirm"],
        ]
        for arguments in rejected {
            let label = arguments.joined(separator: " ")
            XCTAssertThrowsError(try AngCLI.parseAsRoot(["ble", "cmd"] + arguments), label) { error in
                XCTAssertNotEqual(AngCLI.message(for: error), BleCmd.confirmationRequiredMessage, label)
            }
        }
    }

    /// Angstrom-only: D21 — `ble cmd temp` refuses NaN and infinite temperatures in validation,
    /// before any Bluetooth work, while finite values pass unchanged (no rounding).
    func testTempRejectsNonFinite() throws {
        // Swift's `Double(_:)` (behind ArgumentParser's `Double(argument:)`) accepts all of these.
        for value in ["nan", "NaN", "inf", "infinity", "Infinity", "+inf"] {
            XCTAssertNotNil(Double(value), value)
            for boiler in ["coffee", "steam"] {
                let arguments = ["ble", "cmd", "temp", boiler, value, "--confirm"]
                XCTAssertThrowsError(try AngCLI.parseAsRoot(arguments), arguments.joined(separator: " ")) { error in
                    XCTAssertEqual(AngCLI.exitCode(for: error), .validationFailure, value)
                    XCTAssertEqual(AngCLI.message(for: error), BleCmd.Temp.nonFiniteMessage, value)
                }
            }
        }
        // A negative infinity has to be passed after `--` (it would otherwise parse as flags).
        let negative = ["ble", "cmd", "temp", "--confirm", "coffee", "--", "-inf"]
        XCTAssertThrowsError(try AngCLI.parseAsRoot(negative)) { error in
            XCTAssertEqual(AngCLI.message(for: error), BleCmd.Temp.nonFiniteMessage)
        }
        XCTAssertEqual(BleCmd.Temp.nonFiniteMessage, "The temperature must be a finite number of degrees Celsius.")

        // Finite values are kept exactly as given.
        let fractional = try parse(BleCmd.Temp.self, ["temp", "coffee", "93.25", "--confirm"])
        XCTAssertEqual(fractional.celsius, 93.25)
        let negativeFinite = try parse(BleCmd.Temp.self, ["temp", "--confirm", "steam", "--", "-1.5"])
        XCTAssertEqual(negativeFinite.celsius, -1.5)
        XCTAssertEqual(negativeFinite.boiler, .steam)
    }

    /// Angstrom-only: §10.3 — a success status (compared case-insensitively, as `isSuccess` does)
    /// ends `ble cmd` normally; any other status ends it with an error, so the exit is non-zero.
    func testCmdFailsOnNonSuccessStatus() {
        for status in ["success", "Success", "SUCCESS"] {
            let ok = BluetoothCommandStatus(id: "1", message: "", status: status)
            XCTAssertNil(BleCmd.refusalError(for: ok, command: "power on"), status)
        }
        for status in ["error", "Failed", "", "successful", " success"] {
            let refused = BluetoothCommandStatus(id: "1", message: "boiler busy", status: status)
            let error = BleCmd.refusalError(for: refused, command: "temp coffee 200.0")
            XCTAssertEqual(error?.message, "The machine did not report success for `temp coffee 200.0`.", status)
            // The machine's own text stays out of the stderr message (it is in the JSON line).
            XCTAssertFalse(error?.message.contains("boiler busy") ?? true, status)
        }
    }

    // MARK: - Helpers

    /// Parses `angcli ble <arguments>` from the real root and requires a `BleRead`.
    private func parseRead(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) throws -> BleRead {
        let command = try AngCLI.parseAsRoot(["ble"] + arguments)
        return try XCTUnwrap(command as? BleRead, "parsed \(type(of: command))", file: file, line: line)
    }

    /// Parses `angcli ble cmd <arguments>` from the real root and requires the given subcommand type.
    private func parse<C: ParsableCommand>(_ type: C.Type, _ arguments: [String],
                                           file: StaticString = #filePath, line: UInt = #line) throws -> C {
        let command = try AngCLI.parseAsRoot(["ble", "cmd"] + arguments)
        return try XCTUnwrap(command as? C, "parsed \(Swift.type(of: command))", file: file, line: line)
    }
}
