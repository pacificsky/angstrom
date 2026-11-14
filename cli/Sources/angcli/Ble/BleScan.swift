import ArgumentParser

/// `angcli ble scan` (SPEC §10.1). Stub until BT-W2-04 implements it; its options belong to BT-W2-04.
struct BleScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan for nearby La Marzocco machines and print one JSON line per peripheral."
    )

    func run() async throws {
        throw CLIError("unimplemented: BT-W2-04")
    }
}
