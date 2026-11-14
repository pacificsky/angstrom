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
enum BleSession {
    static let tokenEnvironmentVariable = "LAMARZOCCO_BLE_TOKEN"

    /// `BluetoothTransport.coreBluetooth()`, created once per process.
    static func makeTransport() -> BluetoothTransport {
        fatalError("unimplemented: BT-W2-03")
    }

    /// Pure precedence (SPEC §10.2): non-empty flag, then non-empty env var; nil → ask the cloud.
    static func localToken(flag: String?, environment: [String: String]) -> (token: BluetoothAuthToken, source: BleTokenSource)? {
        fatalError("unimplemented: BT-W2-03")
    }

    /// localToken, else Bootstrap.connect() + MachineSelector.choose(serial:) + bluetoothAuthToken(serial:).
    static func resolveToken(_ options: BleTargetOptions,
                             environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> BluetoothAuthToken {
        throw CLIError("unimplemented: BT-W2-03")
    }

    /// Pure rule: exactly one → it; none → throws CLIError("No La Marzocco machine found nearby"); several → nil (caller prompts).
    static func selectPeripheral(from found: [DiscoveredPeripheral]) throws -> DiscoveredPeripheral? {
        throw CLIError("unimplemented: BT-W2-03")
    }

    /// --peripheral, else a 5 s discoverMachines scan + selectPeripheral + an interactive pick on stderr.
    static func resolvePeripheral(_ options: BleTargetOptions, transport: BluetoothTransport) async throws -> BluetoothPeripheralID {
        throw CLIError("unimplemented: BT-W2-03")
    }

    static func makeClient(_ options: BleTargetOptions, transport: BluetoothTransport) async throws -> LaMarzoccoBluetoothClient {
        throw CLIError("unimplemented: BT-W2-03")
    }

    /// SPEC §10.3 error texts for .bluetoothUnavailable; other errors → their errorDescription.
    static func cliError(_ error: any Error) -> CLIError {
        fatalError("unimplemented: BT-W2-03")
    }
}
