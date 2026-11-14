import ArgumentParser

/// `angcli ble listen` (SPEC §10.1). Stub until BT-W2-06 implements it; its options belong to BT-W2-06.
struct BleListen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "listen",
        abstract: "Stream raw BLE frames and decoded shot-counter events until Ctrl-C."
    )

    func run() async throws {
        throw CLIError("unimplemented: BT-W2-06")
    }
}
