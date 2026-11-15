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
}
