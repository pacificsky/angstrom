import Foundation
import ArgumentParser
import Angstrom

/// One-shot REST read printed as pretty, verbatim JSON — so the REST shape can
/// be diffed against the websocket push shape (`listen`).
struct Dump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "One-shot REST read (dashboard|settings|schedule), printed as pretty JSON."
    )

    @Argument(help: "Which endpoint to read: \(RawEndpoint.allCases.map(\.rawValue).joined(separator: ", ")).")
    var endpoint: RawEndpoint

    @Option(name: .long, help: "Machine serial number (defaults to the only machine, or prompts).")
    var serial: String?

    func run() async throws {
        let session = try await Bootstrap.connect()
        let machine = try MachineSelector.choose(session.machines, serial: serial)
        Stderr.log("Reading \(endpoint.rawValue) for \(machine.serialNumber)…")
        let data: Data
        do {
            data = try await session.client.rawRead(endpoint, serial: machine.serialNumber)
        } catch {
            throw CLIError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        Stdout.line(PrettyJSON.string(from: data))
    }
}
