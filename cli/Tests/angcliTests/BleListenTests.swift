import XCTest
import ArgumentParser
import Angstrom
@testable import angcli

/// `angcli ble listen` argument parsing (SPEC §10.1, §10.3). Parsing only: running the command
/// needs Bluetooth hardware.
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
}
