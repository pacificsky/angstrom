import Foundation
import ArgumentParser
import Angstrom

/// The default command: authenticate, open the websocket, and stream frames
/// until Ctrl-C.
struct Listen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Authenticate, connect the websocket, and stream frames until Ctrl-C."
    )

    @Option(name: .long, help: "Machine serial number (defaults to the only machine, or prompts).")
    var serial: String?

    @Flag(name: .long, help: "Print only verbatim raw frames.")
    var raw = false
    @Flag(name: .long, help: "Print only decoded DashboardUpdates.")
    var decoded = false
    @Flag(name: .long, help: "Print both raw and decoded frames (default).")
    var both = false

    func run() async throws {
        let mode = OutputMode(raw: raw, decoded: decoded, both: both)
        let session = try await Bootstrap.connect()
        let machine = try MachineSelector.choose(session.machines, serial: serial)
        let client = session.client

        // Register the taps BEFORE connecting so the STOMP handshake frames are
        // captured. The decoded stream is independent of the raw tap.
        let rawStream = mode.includesRaw ? await client.rawFrames() : nil
        let decodedStream = mode.includesDecoded ? await client.dashboardUpdates() : nil

        // Clean SIGINT → disconnect, which finishes the streams and ends the run.
        let interrupt = SignalHandler.install(SIGINT) {
            Stderr.log("\nDisconnecting…")
            await client.disconnectWebSocket()
        }
        defer { interrupt.cancel() }

        let views = [mode.includesRaw ? "raw" : nil, mode.includesDecoded ? "decoded" : nil].compactMap { $0 }
        Stderr.log("Listening on \(machine.serialNumber) (\(machine.modelName)) — \(views.joined(separator: " + ")). Ctrl-C to stop.")

        do {
            try await client.connectWebSocket(serial: machine.serialNumber)
        } catch is CancellationError {
            return
        } catch {
            throw CLIError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }

        await withTaskGroup(of: Void.self) { group in
            if let rawStream {
                group.addTask { await FramePrinter.printRaw(rawStream) }
            }
            if let decodedStream {
                group.addTask { await FramePrinter.printDecoded(decodedStream) }
            }
        }

        Stderr.log("Connection closed.")
    }
}
