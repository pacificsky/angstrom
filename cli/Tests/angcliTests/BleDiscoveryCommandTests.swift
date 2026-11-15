import XCTest
import ArgumentParser
import Angstrom
@testable import angcli

/// Argument parsing of `angcli ble scan`, `ble gatt` and `ble token` (SPEC §10.1). No hardware:
/// these only call `parse`, never `run`.
final class BleDiscoveryCommandTests: XCTestCase {
    private let peripheralID = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"

    /// Angstrom-only: §10.1 — `ble scan` takes `--duration <s>` (default 5) and `--all` (default off).
    func testScanParsesDurationAndAll() throws {
        let defaults = try BleScan.parse([])
        XCTAssertEqual(defaults.duration, 5)
        XCTAssertFalse(defaults.all)

        let both = try BleScan.parse(["--duration", "2.5", "--all"])
        XCTAssertEqual(both.duration, 2.5)
        XCTAssertTrue(both.all)

        let durationOnly = try BleScan.parse(["--duration", "12"])
        XCTAssertEqual(durationOnly.duration, 12)
        XCTAssertFalse(durationOnly.all)

        let allOnly = try BleScan.parse(["--all"])
        XCTAssertEqual(allOnly.duration, 5)
        XCTAssertTrue(allOnly.all)

        // Reached through the `ble` parent command as `scan`.
        let routed = try XCTUnwrap(try Ble.parseAsRoot(["scan", "--all", "--duration", "3"]) as? BleScan)
        XCTAssertEqual(routed.duration, 3)
        XCTAssertTrue(routed.all)

        // Non-numeric, zero and non-finite durations are rejected at parse time.
        for bad in ["abc", "0", "-1", "inf", "nan"] {
            XCTAssertThrowsError(try BleScan.parse(["--duration", bad]), "--duration \(bad)")
        }
        // Huge finite durations would trap in Duration.seconds(_:) / Task.sleep; they must fail
        // validation (a ValidationError naming --duration) instead of crashing the process.
        for huge in ["86400.001", "1e12", "1e30", "1.7976931348623157e308"] {
            XCTAssertThrowsError(try BleScan.parse(["--duration", huge]), "--duration \(huge)") { error in
                XCTAssertTrue(BleScan.message(for: error).contains("--duration"),
                              "out-of-range message: \(BleScan.message(for: error))")
            }
        }
        // The bound itself is accepted, and converting it to a Duration is safe.
        let longest = try BleScan.parse(["--duration", "86400"])
        XCTAssertEqual(longest.duration, BleScan.maximumDuration)
        XCTAssertEqual(Duration.seconds(longest.duration), .seconds(86_400))
        // scan selects no machine: it takes no peripheral/token options.
        XCTAssertThrowsError(try BleScan.parse(["--peripheral", peripheralID]))
    }

    /// Angstrom-only: §10.1 — `ble gatt` requires `--peripheral <uuid>` and takes it verbatim.
    func testGattRequiresPeripheral() throws {
        XCTAssertThrowsError(try BleGatt.parse([])) { error in
            XCTAssertTrue(BleGatt.message(for: error).contains("--peripheral"),
                          "missing-option message: \(BleGatt.message(for: error))")
        }

        let gatt = try BleGatt.parse(["--peripheral", peripheralID])
        XCTAssertEqual(gatt.peripheral, peripheralID)

        let routed = try XCTUnwrap(try Ble.parseAsRoot(["gatt", "--peripheral", peripheralID]) as? BleGatt)
        XCTAssertEqual(routed.peripheral, peripheralID)

        // An empty --peripheral is "not given" elsewhere (BleSession); here it is rejected.
        for empty in ["", "  "] {
            XCTAssertThrowsError(try BleGatt.parse(["--peripheral", empty]), "--peripheral '\(empty)'")
        }

        // gatt needs no token (SPEC §10.1): the token-selection options do not exist on it.
        XCTAssertThrowsError(try BleGatt.parse(["--peripheral", peripheralID, "--ble-token", "t"]))
        XCTAssertThrowsError(try BleGatt.parse(["--peripheral", peripheralID, "--serial", "MR123"]))
    }

    /// Angstrom-only: §10.4 — `ble token` requires `--peripheral` and masks unless `--show-secret` is given.
    func testTokenShowSecretDefaultsOff() throws {
        let masked = try BleToken.parse(["--peripheral", peripheralID])
        XCTAssertEqual(masked.peripheral, peripheralID)
        XCTAssertFalse(masked.showSecret)

        let revealed = try BleToken.parse(["--peripheral", peripheralID, "--show-secret"])
        XCTAssertEqual(revealed.peripheral, peripheralID)
        XCTAssertTrue(revealed.showSecret)

        let routed = try XCTUnwrap(try Ble.parseAsRoot(["token", "--peripheral", peripheralID]) as? BleToken)
        XCTAssertFalse(routed.showSecret)

        XCTAssertThrowsError(try BleToken.parse([])) { error in
            XCTAssertTrue(BleToken.message(for: error).contains("--peripheral"),
                          "missing-option message: \(BleToken.message(for: error))")
        }
        XCTAssertThrowsError(try BleToken.parse(["--show-secret"]))
        for empty in ["", "  "] {
            XCTAssertThrowsError(try BleToken.parse(["--peripheral", empty, "--show-secret"]), "--peripheral '\(empty)'")
        }
        // --show-secret is a flag; it takes no value.
        XCTAssertThrowsError(try BleToken.parse(["--peripheral", peripheralID, "--show-secret", "false"]))
    }
}
