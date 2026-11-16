import Foundation
import ArgumentParser
import Angstrom

/// `angcli ble read <setting|all>` (SPEC §10.1): for each setting, one `rawRead` (the verbatim
/// response bytes) followed by the typed read, printed as one `{"ts","setting","raw","decoded"}`
/// line (SPEC §10.3) through `BleOutput.readLine`.
struct BleRead: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a setting (or all settings) over Bluetooth, raw and decoded."
    )

    /// The `<setting|all>` argument: one read setting, or every one in `const.py:322-330` order.
    enum Target: Equatable, ExpressibleByArgument {
        case one(BluetoothReadSetting)
        case all

        /// The settings to read, in order. `all` is `BluetoothReadSetting.allCases`
        /// (machineCapabilities, machineMode, tankStatus, boilers, smartStandBy, isPlumbedIn).
        var settings: [BluetoothReadSetting] {
            switch self {
            case .one(let setting): [setting]
            case .all: BluetoothReadSetting.allCases
            }
        }

        /// The wire names verbatim (case-sensitive), `all`, and `capabilities` as a short alias of
        /// `machineCapabilities` (the spelling SPEC §9.6 H22 uses).
        init?(argument: String) {
            switch argument {
            case "all": self = .all
            case "capabilities": self = .one(.machineCapabilities)
            default:
                guard let setting = BluetoothReadSetting(rawValue: argument) else { return nil }
                self = .one(setting)
            }
        }

        static var allValueStrings: [String] {
            BluetoothReadSetting.allCases.map(\.rawValue) + ["all"]
        }
    }

    @Argument(help: "What to read: \(Target.allValueStrings.joined(separator: ", ")) (or capabilities, short for machineCapabilities).")
    var setting: Target

    @OptionGroup var target: BleTargetOptions

    func run() async throws {
        let transport = BleSession.makeTransport()
        let client: LaMarzoccoBluetoothClient
        do {
            client = try await BleSession.makeClient(target, transport: transport)
        } catch {
            throw BleSession.cliError(error)
        }

        var firstFailure: (any Error)?
        for setting in setting.settings {
            let raw: Data
            do {
                raw = try await client.rawRead(setting)
            } catch {
                // A failed request (no link, wrong token, timeout) would fail every remaining
                // setting the same way, so stop here.
                await client.disconnect()
                throw BleSession.cliError(error)
            }
            let decoded: DecodedSetting?
            do {
                decoded = try await Self.typedRead(setting, from: client)
            } catch {
                // The raw bytes are still worth printing (that is what this command is for);
                // report the decode failure and carry on with the next setting.
                Stderr.log("· \(setting.rawValue): \(BleSession.cliError(error).message)")
                firstFailure = firstFailure ?? error
                decoded = nil
            }
            if let line = BleOutput.readLine(setting: setting, raw: raw, decoded: decoded) {
                Stdout.line(line)
            } else {
                Stderr.log("· (failed to encode the \(setting.rawValue) read for output)")
            }
        }
        await client.disconnect()
        if let firstFailure {
            throw BleSession.cliError(firstFailure)
        }
    }

    private static func typedRead(_ setting: BluetoothReadSetting,
                                  from client: LaMarzoccoBluetoothClient) async throws -> DecodedSetting {
        switch setting {
        case .machineCapabilities: .capabilities(CapabilitiesMirror(try await client.machineCapabilities()))
        case .machineMode: .string(try await client.machineMode().rawValue)
        case .tankStatus: .bool(try await client.tankStatus())
        case .boilers: .boilers(try await client.boilers().map(BoilerMirror.init))
        case .smartStandBy: .smartStandby(SmartStandbyMirror(try await client.smartStandby()))
        case .isPlumbedIn: .bool(try await client.isPlumbedIn())
        }
    }
}

// MARK: - CLI-local Encodable mirrors of the typed reads

/// The `decoded` value of one read line: the typed read's result, encoded as itself.
private enum DecodedSetting: Encodable {
    case capabilities(CapabilitiesMirror)
    case string(String)
    case bool(Bool)
    case boilers([BoilerMirror])
    case smartStandby(SmartStandbyMirror)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .capabilities(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .boilers(let value): try container.encode(value)
        case .smartStandby(let value): try container.encode(value)
        }
    }
}

/// `BluetoothMachineCapabilities` with the upstream key names (MBT:22-39). `family` is the
/// resolved model's code; `rawFamily` is the string the machine sent (SPEC §9.6 H22).
private struct CapabilitiesMirror: Encodable {
    let family: String
    let rawFamily: String
    let groupsNumber: Int
    let coffeeBoilersNumber: Int
    let hasCupWarmer: Bool
    let steamBoilersNumber: Int
    let teaDosesNumber: Int
    let machineModes: [String]
    let schedulingType: String

    init(_ capabilities: BluetoothMachineCapabilities) {
        family = capabilities.family.code
        rawFamily = capabilities.rawFamily
        groupsNumber = capabilities.groupsNumber
        coffeeBoilersNumber = capabilities.coffeeBoilersNumber
        hasCupWarmer = capabilities.hasCupWarmer
        steamBoilersNumber = capabilities.steamBoilersNumber
        teaDosesNumber = capabilities.teaDosesNumber
        machineModes = capabilities.machineModes.map(\.rawValue)
        schedulingType = capabilities.schedulingType
    }
}

/// One `BluetoothBoilerDetails` with the upstream key names (MBT:42-49).
private struct BoilerMirror: Encodable {
    let id: String
    let isEnabled: Bool
    let target: Double
    let current: Double

    init(_ boiler: BluetoothBoilerDetails) {
        id = boiler.id.rawValue
        isEnabled = boiler.isEnabled
        target = boiler.target
        current = boiler.current
    }
}

/// `BluetoothSmartStandbyDetails` with the upstream key names (MBT:51-57).
private struct SmartStandbyMirror: Encodable {
    let mode: String
    let minutes: Int
    let enabled: Bool

    init(_ details: BluetoothSmartStandbyDetails) {
        mode = details.mode.rawValue
        minutes = details.minutes
        enabled = details.enabled
    }
}
