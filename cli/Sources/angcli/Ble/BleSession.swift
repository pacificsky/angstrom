import Foundation
import ArgumentParser
import Angstrom
import AngstromBluetooth

/// Options shared by every subcommand that talks to one machine (use with @OptionGroup).
struct BleTargetOptions: ParsableArguments {
    @Option(name: .long, help: "Peripheral identifier from `angcli ble scan` (a CoreBluetooth UUID, not a MAC).")
    var peripheral: String?
    @Option(name: .long, help: "Machine serial number; used to fetch the Bluetooth token from the cloud.")
    var serial: String?
    @Option(name: .customLong("ble-token"), help: "Bluetooth token. Discouraged: it lands in your shell history; prefer LAMARZOCCO_BLE_TOKEN.")
    var bleToken: String?
    init() {}
}

/// Where the Bluetooth token came from (SPEC §10.2 precedence).
enum BleTokenSource: String, Equatable, Sendable { case flag, environment, cloud }

/// Peripheral and token selection for the `ble` subcommands (SPEC §10.2).
///
/// Nothing here persists the token or the peripheral id (SPEC §8.7, §10.2): both live only for
/// the life of the process, and the token never reaches stdout, stderr or an error message.
enum BleSession {
    static let tokenEnvironmentVariable = "LAMARZOCCO_BLE_TOKEN"

    /// The process-wide transport. Creating it touches no Bluetooth API (the manager, and the
    /// permission prompt, come with the first Bluetooth operation).
    private static let sharedTransport = BluetoothTransport.coreBluetooth()

    /// Scan length when `--peripheral` is not given (SPEC §10.2).
    private static let scanDuration: Duration = .seconds(5)

    /// `BluetoothTransport.coreBluetooth()`, created once per process.
    static func makeTransport() -> BluetoothTransport {
        sharedTransport
    }

    /// Pure precedence (SPEC §10.2): non-empty flag, then non-empty env var; nil → ask the cloud.
    static func localToken(flag: String?, environment: [String: String]) -> (token: BluetoothAuthToken, source: BleTokenSource)? {
        if let flag, !flag.isEmpty {
            return (BluetoothAuthToken(flag), .flag)
        }
        if let value = environment[tokenEnvironmentVariable], !value.isEmpty {
            return (BluetoothAuthToken(value), .environment)
        }
        return nil
    }

    /// localToken, else Bootstrap.connect() + MachineSelector.choose(serial:) + bluetoothAuthToken(serial:).
    static func resolveToken(_ options: BleTargetOptions,
                             environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> BluetoothAuthToken {
        if let local = localToken(flag: options.bleToken, environment: environment) {
            switch local.source {
            case .flag: Stderr.log("Using the Bluetooth token from --ble-token.")
            case .environment: Stderr.log("Using the Bluetooth token from \(tokenEnvironmentVariable).")
            case .cloud: break
            }
            return local.token
        }

        let session = try await Bootstrap.connect()
        let machine = try MachineSelector.choose(session.machines, serial: options.serial)
        let serial = machine.serialNumber
        let token: BluetoothAuthToken?
        do {
            token = try await session.client.bluetoothAuthToken(serial: serial)
        } catch {
            throw cliError(error)
        }
        guard let token else {
            throw CLIError("The cloud has no Bluetooth token for \(serial). Use 'angcli ble token' in pairing mode or the QR label.")
        }
        Stderr.log("Using the Bluetooth token from the cloud for \(serial).")
        return token
    }

    /// Pure rule: exactly one → it; none → throws CLIError("No La Marzocco machine found nearby"); several → nil (caller prompts).
    static func selectPeripheral(from found: [DiscoveredPeripheral]) throws -> DiscoveredPeripheral? {
        switch found.count {
        case 0: throw CLIError("No La Marzocco machine found nearby")
        case 1: return found[0]
        default: return nil
        }
    }

    /// --peripheral, else a 5 s discoverMachines scan + selectPeripheral + an interactive pick on stderr.
    static func resolvePeripheral(_ options: BleTargetOptions, transport: BluetoothTransport) async throws -> BluetoothPeripheralID {
        if let peripheral = options.peripheral, !peripheral.isEmpty {
            return BluetoothPeripheralID(rawValue: peripheral)
        }

        Stderr.log("Scanning for La Marzocco machines (5 s)…")
        let found: [DiscoveredPeripheral]
        do {
            found = try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport, duration: scanDuration)
        } catch {
            throw cliError(error)
        }
        if let only = try selectPeripheral(from: found) {
            Stderr.log("Found \(describe(only)).")
            return only.id
        }
        return try pick(from: found).id
    }

    static func makeClient(_ options: BleTargetOptions, transport: BluetoothTransport) async throws -> LaMarzoccoBluetoothClient {
        // Token first: a missing or unreachable cloud token fails before any Bluetooth scan.
        let token = try await resolveToken(options)
        let peripheral = try await resolvePeripheral(options, transport: transport)
        return LaMarzoccoBluetoothClient(transport: transport, peripheral: peripheral, token: token,
                                         logHandler: { Stderr.log("· \($0)") })
    }

    /// SPEC §10.3 error texts for .bluetoothUnavailable; other errors → their errorDescription.
    static func cliError(_ error: any Error) -> CLIError {
        if let error = error as? CLIError { return error }
        if let error = error as? LaMarzoccoError {
            switch error {
            case .bluetoothUnavailable(.unauthorized(_)):
                return CLIError("Bluetooth access denied. Grant it to your terminal app in System Settings › Privacy & Security › Bluetooth.")
            case .bluetoothUnavailable(.poweredOff):
                return CLIError("Bluetooth is off.")
            default:
                break
            }
        }
        return CLIError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    // MARK: Private helpers

    /// Interactive choice among several machines on stderr, defaulting to the first (as
    /// `MachineSelector.choose` does for cloud machines).
    private static func pick(from found: [DiscoveredPeripheral]) throws -> DiscoveredPeripheral {
        Stderr.log("Several La Marzocco machines nearby:")
        for (index, peripheral) in found.enumerated() {
            Stderr.log("  [\(index)] \(describe(peripheral))")
        }
        Stderr.prompt("Select a machine [0]: ")
        let entry = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
        let index = entry.isEmpty ? 0 : (Int(entry) ?? -1)
        guard found.indices.contains(index) else {
            throw CLIError("Invalid selection '\(entry)'.")
        }
        return found[index]
    }

    private static func describe(_ peripheral: DiscoveredPeripheral) -> String {
        let rssi = peripheral.rssi.map { "  \($0) dBm" } ?? ""
        return "\(peripheral.name ?? "(no name)")  \(peripheral.id.rawValue)\(rssi)"
    }
}
