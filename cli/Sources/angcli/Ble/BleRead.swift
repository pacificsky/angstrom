import ArgumentParser

/// `angcli ble read` (SPEC §10.1). Stub until BT-W2-05 implements it; its options belong to BT-W2-05.
struct BleRead: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a setting (or all settings) over Bluetooth, raw and decoded."
    )

    func run() async throws {
        throw CLIError("unimplemented: BT-W2-05")
    }
}
