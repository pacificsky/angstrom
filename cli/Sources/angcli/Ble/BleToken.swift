import ArgumentParser

/// `angcli ble token` (SPEC §10.1). Stub until BT-W2-04 implements it; its options belong to BT-W2-04.
struct BleToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Read the Bluetooth token in pairing mode (masked unless --show-secret)."
    )

    func run() async throws {
        throw CLIError("unimplemented: BT-W2-04")
    }
}
