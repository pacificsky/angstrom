import Foundation
import ArgumentParser
import Angstrom

/// `angcli ble gatt --peripheral <uuid>` (SPEC §10.1; settles H1).
///
/// One connect attempt, no auth (`gattTable`, SPEC §4.14). stdout gets one
/// `{"service","characteristic","properties":[…]}` line per characteristic.
struct BleGatt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gatt",
        abstract: "Print the GATT table (services, characteristics, properties) of a peripheral."
    )

    @Option(name: .long, help: "Peripheral identifier from `angcli ble scan` (a CoreBluetooth UUID, not a MAC).")
    var peripheral: String

    func validate() throws {
        // BleSession treats an empty --peripheral as "not given"; here it is required.
        guard !peripheral.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("--peripheral must not be empty.")
        }
    }

    func run() async throws {
        let transport = BleSession.makeTransport()
        let services: [BluetoothGATTService]
        do {
            services = try await LaMarzoccoBluetoothClient.gattTable(
                transport: transport, peripheral: BluetoothPeripheralID(rawValue: peripheral))
        } catch {
            throw BleSession.cliError(error)
        }
        for line in BleOutput.gattLines(services) {
            Stdout.line(line)
        }
    }
}
