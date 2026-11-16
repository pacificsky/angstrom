import XCTest
import ArgumentParser
import Angstrom
@testable import angcli

/// `angcli ble listen` (SPEC §10.1, §10.3): argument parsing, plus the hardware-free pieces of the
/// run loop (the per-event give-up decision and the SIGINT / give-up handshake). Running the
/// command end to end needs Bluetooth hardware.
final class BleListenTests: XCTestCase {
    /// Angstrom-only: §10.1 — no view flag (or both `--raw --decoded`) prints raw frames and decoded events.
    func testListenDefaultsToBoth() throws {
        let command = try BleListen.parse([])
        XCTAssertFalse(command.raw)
        XCTAssertFalse(command.decoded)
        XCTAssertTrue(command.outputMode.includesRaw)
        XCTAssertTrue(command.outputMode.includesDecoded)
        XCTAssertNil(command.target.peripheral)
        XCTAssertNil(command.target.serial)
        XCTAssertNil(command.target.bleToken)

        let contradiction = try BleListen.parse(["--raw", "--decoded"])
        XCTAssertTrue(contradiction.raw)
        XCTAssertTrue(contradiction.decoded)
        XCTAssertTrue(contradiction.outputMode.includesRaw)
        XCTAssertTrue(contradiction.outputMode.includesDecoded)
    }

    /// Angstrom-only: §10.1 — `--raw` prints only raw frames (and `--decoded` only decoded events).
    func testListenRawOnly() throws {
        let rawOnly = try BleListen.parse(["--raw"])
        XCTAssertTrue(rawOnly.raw)
        XCTAssertFalse(rawOnly.decoded)
        XCTAssertTrue(rawOnly.outputMode.includesRaw)
        XCTAssertFalse(rawOnly.outputMode.includesDecoded)

        let decodedOnly = try BleListen.parse(["--decoded"])
        XCTAssertFalse(decodedOnly.raw)
        XCTAssertTrue(decodedOnly.decoded)
        XCTAssertFalse(decodedOnly.outputMode.includesRaw)
        XCTAssertTrue(decodedOnly.outputMode.includesDecoded)
    }

    /// Angstrom-only: §10.2 — `ble listen` takes the shared selection options, also via the `angcli ble` tree.
    func testListenAcceptsTargetOptions() throws {
        let peripheral = "6F1C2D3E-4A5B-4C6D-8E7F-9A0B1C2D3E4F"
        let arguments = ["--peripheral", peripheral, "--serial", "LM012345", "--ble-token", "token-value", "--raw"]

        let command = try BleListen.parse(arguments)
        XCTAssertEqual(command.target.peripheral, peripheral)
        XCTAssertEqual(command.target.serial, "LM012345")
        XCTAssertEqual(command.target.bleToken, "token-value")
        XCTAssertTrue(command.outputMode.includesRaw)
        XCTAssertFalse(command.outputMode.includesDecoded)

        let parsed = try AngCLI.parseAsRoot(["ble", "listen"] + arguments)
        let routed = try XCTUnwrap(parsed as? BleListen)
        XCTAssertEqual(routed.target.peripheral, peripheral)
        XCTAssertEqual(routed.target.serial, "LM012345")
        XCTAssertEqual(routed.target.bleToken, "token-value")
        XCTAssertTrue(routed.raw)
        XCTAssertFalse(routed.decoded)

        // The selection options are --long only; an option of another subcommand is rejected.
        XCTAssertThrowsError(try BleListen.parse(["--show-secret"]))
    }

    /// Angstrom-only: §10.3 (amended) — `.gaveUp(error)` ends the run with the §10.3-mapped error;
    /// every other shot-counter event keeps it listening.
    func testGaveUpEventEndsListenWithMappedError() throws {
        let auth = try XCTUnwrap(BleListen.giveUpError(for: .gaveUp(.bluetoothAuthenticationFailed)))
        XCTAssertEqual(auth.message, LaMarzoccoError.bluetoothAuthenticationFailed.errorDescription)
        XCTAssertEqual(auth.message, BleSession.cliError(LaMarzoccoError.bluetoothAuthenticationFailed).message)

        let missing = LaMarzoccoError.bluetoothConnectionFailed(
            "Could not find characteristic 0e0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")
        XCTAssertEqual(BleListen.giveUpError(for: .gaveUp(missing))?.message, missing.errorDescription)

        // The §10.3 Bluetooth-availability texts apply to a give-up too.
        XCTAssertEqual(BleListen.giveUpError(for: .gaveUp(.bluetoothUnavailable(.poweredOff)))?.message,
                       "Bluetooth is off.")

        let update = BluetoothShotCounterUpdate(state: .brewing, timerValue: 3, receivedAt: Date(timeIntervalSince1970: 0),
                                                raw: BluetoothBrewingData())
        let others: [ShotCounterEvent] = [.subscribed, .unsubscribed, .brewing(update),
                                          .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 93))]
        for event in others {
            XCTAssertNil(BleListen.giveUpError(for: event), "\(event) must not end the run")
        }
    }

    /// Angstrom-only: §10.3 (amended) — a give-up wakes the waiting run without any SIGINT (it used
    /// to sit silent until Ctrl-C), and a later Ctrl-C starts no second teardown.
    func testGiveUpWakesListenerWithoutSigint() async throws {
        let stop = ListenStopSignal()
        let waiter = Task { await stop.waitForEnd() }
        await Task.yield()

        await stop.giveUp(CLIError("Bluetooth authentication failed."))
        let ended = await waiter.value
        XCTAssertEqual(ended?.message, "Bluetooth authentication failed.")

        // Ctrl-C after the give-up: run() is already disconnecting, the handler stands down.
        let interruptStarted = await stop.beginTeardown()
        XCTAssertFalse(interruptStarted)
        let interrupted = await stop.interrupted
        XCTAssertFalse(interrupted)

        // Only the first give-up counts; a late waiter returns at once with it.
        await stop.giveUp(CLIError("second"))
        let late = await stop.waitForEnd()
        XCTAssertEqual(late?.message, "Bluetooth authentication failed.")
    }

    /// Angstrom-only: §10.1/§10.3 — Ctrl-C first owns the shutdown: a give-up during the SIGINT
    /// teardown is ignored, and the run ends cleanly (exit 0) once the teardown has finished.
    func testSigintBeforeGiveUpEndsCleanly() async throws {
        let stop = ListenStopSignal()
        let teardownStarted = await stop.beginTeardown()
        XCTAssertTrue(teardownStarted)
        let secondInterrupt = await stop.beginTeardown()
        XCTAssertFalse(secondInterrupt)

        let waiter = Task { await stop.waitForEnd() }
        await stop.giveUp(CLIError("ignored"))
        await stop.finishTeardown()

        let ended = await waiter.value
        XCTAssertNil(ended)
        await stop.waitForTeardown()   // already torn down: returns at once
    }

    // MARK: finish(after:stop:link:) — every ending leaves the link down

    /// Angstrom-only: §10.3 (review fix) — Ctrl-C whose teardown finishes before
    /// `startShotCounter()` reaches the client: the start then connects and subscribes, and the run
    /// must still stop the shot counter and disconnect before it exits 0 (it used to return with the
    /// link up and subscribed).
    func testSigintTeardownBeforeStartReachesClientStillDisconnects() async throws {
        let stop = ListenStopSignal()
        let link = RecordingListenLink()
        // The SIGINT handler runs to completion first (its calls are no-ops on the idle client).
        let handlerStarted = await stop.beginTeardown()
        XCTAssertTrue(handlerStarted)
        await link.stopShotCounter()
        await link.disconnect()
        await stop.finishTeardown()
        await link.reset()

        // Then startShotCounter() lands and subscribes.
        let end = await BleListen.finish(after: .subscribed, stop: stop, link: link)

        XCTAssertTrue(Self.isInterrupted(end), "\(end)")
        let calls = await link.calls
        XCTAssertEqual(calls, [.stopShotCounter, .disconnect])
    }

    /// Angstrom-only: §10.3 (review fix) — Ctrl-C while subscribed: the run waits for the SIGINT
    /// teardown, then repeats it (idempotent) and ends cleanly.
    func testSigintWhileSubscribedWaitsForTeardownThenDisconnects() async throws {
        let stop = ListenStopSignal()
        let link = RecordingListenLink()
        let run = Task { await BleListen.finish(after: .subscribed, stop: stop, link: link) }
        await Task.yield()

        let began1 = await stop.beginTeardown()
        XCTAssertTrue(began1)
        await stop.finishTeardown()

        let end = await run.value
        XCTAssertTrue(Self.isInterrupted(end), "\(end)")
        let calls = await link.calls
        XCTAssertEqual(calls, [.stopShotCounter, .disconnect])
    }

    /// Angstrom-only: §10.3 (review fix) — an unsupported result or a start failure that raced a
    /// Ctrl-C (the start may have connected after the handler ran) still ends with the link down
    /// and exit 0.
    func testSigintDuringUnsupportedOrFailedStartStillDisconnects() async throws {
        let starts: [ListenStart] = [.unsupported, .failed(LaMarzoccoError.bluetoothAuthenticationFailed)]
        for start in starts {
            let stop = ListenStopSignal()
            let link = RecordingListenLink()
            let began2 = await stop.beginTeardown()
            XCTAssertTrue(began2)
            await stop.finishTeardown()

            let end = await BleListen.finish(after: start, stop: stop, link: link)

            XCTAssertTrue(Self.isInterrupted(end), "\(start) → \(end)")
            let calls = await link.calls
            XCTAssertEqual(calls, [.stopShotCounter, .disconnect], "\(start)")
        }
    }

    /// Angstrom-only: §10.3 — unsupported / a start failure without Ctrl-C: the run claims the
    /// shutdown and disconnects; a later Ctrl-C or give-up starts nothing.
    func testUnsupportedOrFailedStartClaimsShutdownAndDisconnects() async throws {
        let stop = ListenStopSignal()
        let link = RecordingListenLink()
        let unsupported = await BleListen.finish(after: .unsupported, stop: stop, link: link)
        guard case .unsupported = unsupported else { return XCTFail("\(unsupported)") }
        var calls = await link.calls
        XCTAssertEqual(calls, [.disconnect])
        let began3 = await stop.beginTeardown()
        XCTAssertFalse(began3)
        await stop.giveUp(CLIError("ignored"))

        let failingStop = ListenStopSignal()
        let failingLink = RecordingListenLink()
        let failed = await BleListen.finish(after: .failed(LaMarzoccoError.bluetoothAuthenticationFailed),
                                            stop: failingStop, link: failingLink)
        guard case .failed(let error) = failed else { return XCTFail("\(failed)") }
        XCTAssertEqual(error as? LaMarzoccoError, .bluetoothAuthenticationFailed)
        calls = await failingLink.calls
        XCTAssertEqual(calls, [.disconnect])
        let began4 = await failingStop.beginTeardown()
        XCTAssertFalse(began4)
    }

    /// Angstrom-only: §10.3 (amended) — a give-up while subscribed ends the run with the mapped
    /// error after a disconnect.
    func testGiveUpWhileSubscribedDisconnects() async throws {
        let stop = ListenStopSignal()
        let link = RecordingListenLink()
        let run = Task { await BleListen.finish(after: .subscribed, stop: stop, link: link) }
        await Task.yield()

        await stop.giveUp(CLIError("Bluetooth authentication failed."))

        let end = await run.value
        guard case .gaveUp(let error) = end else { return XCTFail("\(end)") }
        XCTAssertEqual(error.message, "Bluetooth authentication failed.")
        let calls = await link.calls
        XCTAssertEqual(calls, [.disconnect])
    }

    // MARK: Helpers

    private static func isInterrupted(_ end: ListenEnd) -> Bool {
        if case .interrupted = end { return true }
        return false
    }
}

/// Records the shutdown calls `BleListen.finish` makes, in order.
private actor RecordingListenLink: ListenLink {
    enum Call: Equatable { case stopShotCounter, disconnect }
    private(set) var calls: [Call] = []

    func stopShotCounter() async { calls.append(.stopShotCounter) }
    func disconnect() async { calls.append(.disconnect) }
    func reset() { calls = [] }
}
