import ArgumentParser

/// `angcli ble gatt` (SPEC §10.1). Stub until BT-W2-04 implements it; its options belong to BT-W2-04.
struct BleGatt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gatt",
        abstract: "Print the GATT table (services, characteristics, properties) of a peripheral."
    )

    func run() async throws {
        throw CLIError("unimplemented: BT-W2-04")
    }
}
