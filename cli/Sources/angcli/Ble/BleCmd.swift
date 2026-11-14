import ArgumentParser

/// `angcli ble cmd` (SPEC §10.1). Stub until BT-W2-05 implements it; its options belong to BT-W2-05.
struct BleCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cmd",
        abstract: "Send a command over Bluetooth (actuates hardware; requires --confirm)."
    )

    func run() async throws {
        throw CLIError("unimplemented: BT-W2-05")
    }
}
