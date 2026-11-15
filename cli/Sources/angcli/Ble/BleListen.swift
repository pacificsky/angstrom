import Foundation
import ArgumentParser
import Angstrom

/// `angcli ble listen` (SPEC §10.1, §10.3): connect, authenticate, start the shot counter, and
/// stream raw BLE frames plus decoded connection / shot-counter events until Ctrl-C.
///
/// Settles the hardware checks H2 (`[mtu n]` marker), H12 (auth polls), H13 (replay vs CCCD ack),
/// H14 (notification lengths), H18 (sleep/wake) and H20 (`[services invalidated]`) (SPEC §9.6).
struct BleListen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "listen",
        abstract: "Stream raw BLE frames and decoded shot-counter events until Ctrl-C."
    )

    @OptionGroup var target: BleTargetOptions

    @Flag(name: .long, help: "Print only raw BLE frames.")
    var raw = false
    @Flag(name: .long, help: "Print only decoded connection and shot-counter events.")
    var decoded = false

    /// Which views to print. Both by default (and for the contradictory `--raw --decoded`).
    var outputMode: OutputMode { OutputMode(raw: raw, decoded: decoded, both: false) }

    func run() async throws {
        let mode = outputMode
        let client: LaMarzoccoBluetoothClient
        do {
            client = try await BleSession.makeClient(target, transport: BleSession.makeTransport())
        } catch {
            throw Self.mapError(error)
        }

        // Register every tap BEFORE startShotCounter() so the connect markers, the auth write
        // and poll reads, and the subscribe frames are all captured.
        let rawStream = mode.includesRaw ? await client.rawFrames() : nil
        let connectionStream = mode.includesDecoded ? await client.connectionEvents() : nil
        let shotCounterStream = mode.includesDecoded ? await client.shotCounterEvents() : nil

        // Clean SIGINT → stopShotCounter() + disconnect(), then the run ends with exit 0
        // (mirrors Listen.swift).
        let stop = StopSignal()
        let interrupt = SignalHandler.install(SIGINT) {
            guard await stop.beginTeardown() else { return }
            Stderr.log("\nDisconnecting…")
            await client.stopShotCounter()
            await client.disconnect()
            await stop.finishTeardown()
        }
        defer { interrupt.cancel() }

        let views = [mode.includesRaw ? "raw" : nil, mode.includesDecoded ? "decoded" : nil].compactMap { $0 }
        Stderr.log("Listening on \(client.peripheral) — \(views.joined(separator: " + ")). Ctrl-C to stop.")

        let outcome: Outcome = try await withThrowingTaskGroup(of: Void.self) { group in
            if let rawStream {
                group.addTask { for await frame in rawStream { Self.emit(BleOutput.rawLine(frame)) } }
            }
            if let connectionStream {
                group.addTask { for await event in connectionStream { Self.emit(BleOutput.connectionLine(event)) } }
            }
            if let shotCounterStream {
                group.addTask { for await event in shotCounterStream { Self.emit(BleOutput.shotCounterLine(event)) } }
            }

            let outcome: Outcome
            do {
                outcome = try await client.startShotCounter() ? .listening : .unsupported
            } catch {
                if await stop.interrupted {
                    outcome = .interrupted
                } else {
                    await client.disconnect()
                    // Cancelled printers still deliver what is already buffered, then end.
                    group.cancelAll()
                    try await group.waitForAll()
                    throw Self.mapError(error)
                }
            }

            switch outcome {
            case .listening, .interrupted:
                // Runs until the SIGINT teardown has completed (also when Ctrl-C arrived
                // while startShotCounter() was still in flight).
                await stop.waitForTeardown()
            case .unsupported:
                if await stop.interrupted {
                    await stop.waitForTeardown()
                } else {
                    await client.disconnect()
                }
            }
            // The teardown has emitted its final events (`.unsubscribed`, `.disconnected`, the
            // raw markers) into the buffers; the cancelled printers drain them, then end.
            group.cancelAll()
            try await group.waitForAll()
            return outcome
        }

        if outcome == .unsupported, !(await stop.interrupted) {
            Stderr.log("Shot counter not supported by this machine")
            throw ExitCode.failure
        }
        Stderr.log("Connection closed.")
    }

    // MARK: Private

    private enum Outcome: Equatable { case listening, unsupported, interrupted }

    private static func emit(_ line: String?) {
        guard let line else {
            Stderr.log("· (failed to encode a frame for output)")
            return
        }
        Stdout.line(line)
    }

    /// CLI errors and exit codes pass through; everything else gets the SPEC §10.3 texts.
    private static func mapError(_ error: any Error) -> any Error {
        switch error {
        case is CLIError, is ExitCode, is CancellationError: return error
        default: return BleSession.cliError(error)
        }
    }
}

/// The SIGINT handshake between the signal handler and `run()`: `interrupted` flips as soon as
/// Ctrl-C arrives (before the teardown), and `waitForTeardown()` returns once it has finished.
private actor StopSignal {
    private(set) var interrupted = false
    private var tornDown = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// True for the first Ctrl-C only; later ones are ignored while the teardown runs.
    func beginTeardown() -> Bool {
        guard !interrupted else { return false }
        interrupted = true
        return true
    }

    func finishTeardown() {
        tornDown = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func waitForTeardown() async {
        guard !tornDown else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
