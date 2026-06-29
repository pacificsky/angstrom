import ArgumentParser

/// List the machines on the account, tab-separated (serial, model, type).
struct Machines: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the account's machines (serial, model, type)."
    )

    func run() async throws {
        let session = try await Bootstrap.connect()
        for machine in session.machines {
            Stdout.line("\(machine.serialNumber)\t\(machine.modelName)\t\(machine.type.rawValue)")
        }
    }
}
