import Foundation
import ArgumentParser
import Angstrom

/// `angcli ble cmd <power|steam|temp|standby>` (SPEC §10.1). Every subcommand actuates the
/// machine, so each refuses to run without `--confirm` (checked in `validate()`, before any
/// Bluetooth or cloud work). Each prints one `{"ts","command","status":{id,message,status},"success":bool}`
/// line (SPEC §10.3) through `BleOutput.commandLine`; a non-success status is printed, not thrown.
struct BleCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cmd",
        abstract: "Send a command over Bluetooth (actuates hardware; requires --confirm).",
        subcommands: [Power.self, Steam.self, Temp.self, Standby.self]
    )

    /// The validation message printed when `--confirm` is missing.
    static let confirmationRequiredMessage =
        "This command actuates the machine over Bluetooth. Pass --confirm to send it."

    /// `--confirm`, shared by every `cmd` subcommand; its `validate()` refuses without it.
    struct Confirmation: ParsableArguments {
        @Flag(name: .long, help: "Required: acknowledge that this command actuates the machine.")
        var confirm = false

        init() {}

        func validate() throws {
            guard confirm else { throw ValidationError(BleCmd.confirmationRequiredMessage) }
        }
    }

    /// `on` / `off`.
    enum Switch: String, CaseIterable, ExpressibleByArgument {
        case on, off

        var isOn: Bool { self == .on }
    }

    /// `ble cmd power <on|off>` → `setPower(on:)` (`_bluetooth.py:595-599`).
    struct Power: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "power",
            abstract: "Power the machine on (BrewingMode) or put it in standby (StandBy)."
        )

        @Argument(help: "on or off.")
        var state: Switch

        @OptionGroup var confirmation: Confirmation
        @OptionGroup var target: BleTargetOptions

        var commandDescription: String { "power \(state.rawValue)" }

        func run() async throws {
            let state = state
            try await BleCmd.send(commandDescription, target: target) { client in
                try await client.setPower(on: state.isOn)
            }
        }
    }

    /// `ble cmd steam <on|off>` → `setSteam(on:)` (`_bluetooth.py:601-607`).
    struct Steam: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "steam",
            abstract: "Enable or disable the steam boiler."
        )

        @Argument(help: "on or off.")
        var state: Switch

        @OptionGroup var confirmation: Confirmation
        @OptionGroup var target: BleTargetOptions

        var commandDescription: String { "steam \(state.rawValue)" }

        func run() async throws {
            let state = state
            try await BleCmd.send(commandDescription, target: target) { client in
                try await client.setSteam(on: state.isOn)
            }
        }
    }

    /// `ble cmd temp <coffee|steam> <celsius>` → `setTemperature(boiler:celsius:)` (`_bluetooth.py:619-625`).
    struct Temp: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "temp",
            abstract: "Set a boiler's target temperature in °C (sent as given, no rounding)."
        )

        /// The boiler argument: `coffee` → CoffeeBoiler1, `steam` → SteamBoiler.
        enum Boiler: String, CaseIterable, ExpressibleByArgument {
            case coffee, steam

            var bluetoothBoiler: BluetoothBoilerType {
                switch self {
                case .coffee: .coffee
                case .steam: .steam
                }
            }
        }

        /// The validation message printed for a NaN or infinite temperature.
        static let nonFiniteMessage = "The temperature must be a finite number of degrees Celsius."

        @Argument(help: "coffee or steam.")
        var boiler: Boiler

        @Argument(help: "Target temperature in °C, e.g. 93 or 93.5.")
        var celsius: Double

        @OptionGroup var confirmation: Confirmation
        @OptionGroup var target: BleTargetOptions

        var commandDescription: String { "temp \(boiler.rawValue) \(celsius)" }

        func validate() throws {
            // `Double(argument:)` accepts "nan" and "inf"; the library would refuse them too (D21),
            // but only after connecting. Refuse before any Bluetooth work.
            guard celsius.isFinite else { throw ValidationError(Self.nonFiniteMessage) }
        }

        func run() async throws {
            let boiler = boiler.bluetoothBoiler
            let celsius = celsius
            try await BleCmd.send(commandDescription, target: target) { client in
                try await client.setTemperature(boiler: boiler, celsius: celsius)
            }
        }
    }

    /// `ble cmd standby --enabled <bool> --minutes <n> --mode <LastBrewing|PowerOn>` →
    /// `setSmartStandby(enabled:mode:minutes:)` (`_bluetooth.py:609-617`).
    struct Standby: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "standby",
            abstract: "Configure smart standby."
        )

        /// The `--mode` values, spelled as on the wire (`SmartStandByType`).
        enum Mode: String, CaseIterable, ExpressibleByArgument {
            case lastBrewing = "LastBrewing"
            case powerOn = "PowerOn"

            var smartStandbyAfter: SmartStandbyAfter {
                switch self {
                case .lastBrewing: .lastBrewing
                case .powerOn: .powerOn
                }
            }
        }

        @Option(name: .long, help: "true or false.")
        var enabled: Bool

        @Option(name: .long, help: "Minutes until standby.")
        var minutes: Int

        @Option(name: .long, help: "When the timer starts: LastBrewing or PowerOn.")
        var mode: Mode

        @OptionGroup var confirmation: Confirmation
        @OptionGroup var target: BleTargetOptions

        var commandDescription: String {
            "standby --enabled \(enabled) --minutes \(minutes) --mode \(mode.rawValue)"
        }

        func run() async throws {
            let enabled = enabled
            let minutes = minutes
            let mode = mode.smartStandbyAfter
            try await BleCmd.send(commandDescription, target: target) { client in
                try await client.setSmartStandby(enabled: enabled, mode: mode, minutes: minutes)
            }
        }
    }

    /// Connect per `target`, run one command, print its status line, and disconnect.
    private static func send(
        _ command: String,
        target: BleTargetOptions,
        _ operation: @Sendable (LaMarzoccoBluetoothClient) async throws -> BluetoothCommandStatus
    ) async throws {
        let transport = BleSession.makeTransport()
        let client: LaMarzoccoBluetoothClient
        do {
            client = try await BleSession.makeClient(target, transport: transport)
        } catch {
            throw BleSession.cliError(error)
        }
        Stderr.log("Sending `\(command)` to \(client.peripheral)…")
        let status: BluetoothCommandStatus
        do {
            status = try await operation(client)
        } catch {
            await client.disconnect()
            throw BleSession.cliError(error)
        }
        await client.disconnect()
        if let line = BleOutput.commandLine(command: command, status: status) {
            Stdout.line(line)
        } else {
            Stderr.log("· (failed to encode the command status for output)")
        }
    }
}
