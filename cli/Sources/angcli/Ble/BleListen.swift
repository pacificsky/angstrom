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
        // and poll reads, and the subscribe frames are all captured. The shot-counter stream is
        // registered in every mode (raw-only included): it carries the terminal `.gaveUp` event
        // (SPEC §10.3), even when its lines are not printed.
        let rawStream = mode.includesRaw ? await client.rawFrames() : nil
        let connectionStream = mode.includesDecoded ? await client.connectionEvents() : nil
        let shotCounterStream = await client.shotCounterEvents()

        // Clean SIGINT → stopShotCounter() + disconnect(), then the run ends with exit 0
        // (mirrors Listen.swift). Ignored once the shot counter has given up or run() has claimed
        // the shutdown: run() is already disconnecting and exits non-zero. finish() repeats the
        // teardown afterwards, so a start that lands after the handler cannot leave the link up.
        let stop = ListenStopSignal()
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

        let outcome: ListenEnd = try await withThrowingTaskGroup(of: Void.self) { group in
            if let rawStream {
                group.addTask { for await frame in rawStream { Self.emit(BleOutput.rawLine(frame)) } }
            }
            if let connectionStream {
                group.addTask { for await event in connectionStream { Self.emit(BleOutput.connectionLine(event)) } }
            }
            group.addTask {
                for await event in shotCounterStream {
                    if mode.includesDecoded { Self.emit(BleOutput.shotCounterLine(event)) }
                    if let error = Self.giveUpError(for: event) { await stop.giveUp(error) }
                }
            }

            // Whatever startShotCounter() did, finish() leaves the link down and decides how the run
            // ends, also when Ctrl-C raced it (see finish(after:stop:link:)).
            let start: ListenStart
            do {
                start = try await client.startShotCounter() ? .subscribed : .unsupported
            } catch {
                start = .failed(error)
            }
            let end = await Self.finish(after: start, stop: stop, link: client)

            // The teardown has emitted its final events (`.unsubscribed`, `.disconnected`, the
            // raw markers) into the buffers; the cancelled printers drain them, then end.
            group.cancelAll()
            try await group.waitForAll()
            return end
        }

        switch outcome {
        case .interrupted:
            Stderr.log("Connection closed.")
        case .gaveUp(let error):
            // Printed to stderr by ArgumentParser ("Error: …"), exit status 1.
            throw error
        case .unsupported:
            Stderr.log("Shot counter not supported by this machine")
            throw ExitCode.failure
        case .failed(let error):
            throw Self.mapError(error)
        }
    }

    /// The shutdown after `startShotCounter()` returned (or threw): waits as long as the run
    /// should keep listening, then brings the link down and says how the run ends. Every path
    /// returns with the shot counter stopped and the link disconnected:
    ///
    /// - Ctrl-C (at any point, including before `startShotCounter()` reached the client, whose
    ///   connect and subscribe would then run *after* the handler's teardown) → wait for the
    ///   SIGINT teardown, then `stopShotCounter()` + `disconnect()` once more (both idempotent:
    ///   no-ops normally, the real teardown when the start reached the client after the handler) → `.interrupted`, exit 0.
    /// - Subscribed → wait for Ctrl-C or a give-up; a give-up → `disconnect()` → `.gaveUp`.
    /// - Unsupported or a start failure without Ctrl-C → the run claims the shutdown (a later
    ///   Ctrl-C starts no second teardown), `disconnect()` → `.unsupported` / `.failed`.
    static func finish(after start: ListenStart, stop: ListenStopSignal,
                       link: some ListenLink) async -> ListenEnd {
        switch start {
        case .subscribed:
            if let error = await stop.waitForEnd() {
                await link.disconnect()
                return .gaveUp(error)
            }
        case .unsupported, .failed:
            if await stop.claimShutdown() {
                await link.disconnect()
                if case .failed(let error) = start { return .failed(error) }
                return .unsupported
            }
            await stop.waitForTeardown()
        }
        // Interrupted: the handler's teardown has finished. Repeat it, in case the start
        // connected or subscribed after it ran.
        await link.stopShotCounter()
        await link.disconnect()
        return .interrupted
    }

    /// The SPEC §10.3 decision for one shot-counter event: `.gaveUp(error)` ends the run with the
    /// mapped error (disconnect, non-zero exit, every output mode); any other event → nil, keep
    /// listening.
    static func giveUpError(for event: ShotCounterEvent) -> CLIError? {
        guard case .gaveUp(let error) = event else { return nil }
        return BleSession.cliError(error)
    }

    // MARK: Private

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

/// What `startShotCounter()` produced.
enum ListenStart: Sendable {
    case subscribed
    case unsupported
    case failed(any Error)
}

/// How `ble listen` ends: `.interrupted` exits 0; the others exit non-zero (SPEC §10.3).
enum ListenEnd: Sendable {
    case interrupted
    case gaveUp(CLIError)
    case unsupported
    case failed(any Error)
}

/// The two client calls the listen shutdown makes; the client conforms, tests use a recorder.
protocol ListenLink: Sendable {
    func stopShotCounter() async
    func disconnect() async
}

extension LaMarzoccoBluetoothClient: ListenLink {}

/// The handshake between the SIGINT handler, the shot-counter printer and `run()`.
///
/// Exactly one of the three owns the shutdown: the first Ctrl-C, the first give-up, or run()
/// via `claimShutdown()`.
///
/// `interrupted` flips as soon as Ctrl-C arrives (before the teardown). `waitForEnd()` returns
/// once the teardown has finished, or as soon as the shot counter gives up. Whichever comes
/// first wins: a give-up during the SIGINT teardown is ignored (exit 0), and a Ctrl-C after a
/// give-up, or after `claimShutdown()`, starts no teardown (run() is already disconnecting).
actor ListenStopSignal {
    private(set) var interrupted = false
    private var tornDown = false
    private var claimedByRun = false
    private var gaveUpError: CLIError?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// True for the first Ctrl-C only, and only before a give-up; later ones are ignored.
    func beginTeardown() -> Bool {
        guard !interrupted, gaveUpError == nil, !claimedByRun else { return false }
        interrupted = true
        return true
    }

    /// run() takes over the shutdown (unsupported, or a start failure): true unless a Ctrl-C
    /// already owns it. Later Ctrl-Cs and give-ups are then ignored.
    func claimShutdown() -> Bool {
        guard !interrupted else { return false }
        claimedByRun = true
        return true
    }

    func finishTeardown() {
        tornDown = true
        resumeWaiters()
    }

    /// Records the first give-up, unless a SIGINT teardown already owns the shutdown.
    func giveUp(_ error: CLIError) {
        guard !interrupted, gaveUpError == nil, !claimedByRun else { return }
        gaveUpError = error
        resumeWaiters()
    }

    /// Returns once the SIGINT teardown has finished (nil) or the shot counter has given up
    /// (the mapped error).
    func waitForEnd() async -> CLIError? {
        if gaveUpError == nil, !tornDown {
            await withCheckedContinuation { waiters.append($0) }
        }
        return gaveUpError
    }

    /// Returns once the SIGINT teardown has finished.
    func waitForTeardown() async {
        while !tornDown {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
