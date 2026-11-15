import ArgumentParser
import Angstrom

/// `angcli ble token --peripheral <uuid> [--show-secret]` (SPEC §10.1; H17).
///
/// Reads the Bluetooth token over the air, which works only in pairing mode (`readToken`,
/// SPEC §4.14). stdout gets `{"token":"**REDACTED**","length":n}`; the real value only with
/// `--show-secret`, and then on stdout only (SPEC §10.4). The token never reaches stderr or
/// an error message.
struct BleToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Read the Bluetooth token in pairing mode (masked unless --show-secret)."
    )

    @Option(name: .long, help: "Peripheral identifier from `angcli ble scan` (a CoreBluetooth UUID, not a MAC).")
    var peripheral: String

    @Flag(name: .long, help: "Print the real token (to stdout only) instead of masking it.")
    var showSecret = false

    func run() async throws {
        let transport = BleSession.makeTransport()
        let token: BluetoothAuthToken
        do {
            token = try await LaMarzoccoBluetoothClient.readToken(
                transport: transport, peripheral: BluetoothPeripheralID(rawValue: peripheral))
        } catch {
            throw BleSession.cliError(error)
        }
        guard let line = BleOutput.tokenLine(token, showSecret: showSecret) else {
            throw CLIError("Could not encode the token line.")
        }
        Stdout.line(line)
    }
}
