import XCTest
import Foundation
import Angstrom
@testable import angcli

final class OutputModeTests: XCTestCase {
    func testDefaultIsBoth() {
        let mode = OutputMode(raw: false, decoded: false, both: false)
        XCTAssertTrue(mode.includesRaw)
        XCTAssertTrue(mode.includesDecoded)
    }

    func testRawOnly() {
        let mode = OutputMode(raw: true, decoded: false, both: false)
        XCTAssertTrue(mode.includesRaw)
        XCTAssertFalse(mode.includesDecoded)
    }

    func testDecodedOnly() {
        let mode = OutputMode(raw: false, decoded: true, both: false)
        XCTAssertFalse(mode.includesRaw)
        XCTAssertTrue(mode.includesDecoded)
    }

    func testExplicitBothOverridesContradiction() {
        // --both wins, and the contradictory --raw --decoded also means "both".
        XCTAssertTrue(OutputMode(raw: true, decoded: false, both: true).includesDecoded)
        let contradiction = OutputMode(raw: true, decoded: true, both: false)
        XCTAssertTrue(contradiction.includesRaw)
        XCTAssertTrue(contradiction.includesDecoded)
    }
}

final class DirectionArrowTests: XCTestCase {
    func testArrows() {
        XCTAssertEqual(RawFrame.Direction.outbound.arrow, ">>")
        XCTAssertEqual(RawFrame.Direction.inbound.arrow, "<<")
    }
}

final class PrettyJSONTests: XCTestCase {
    func testSortsKeysAndPreservesUnknownFields() {
        let raw = Data(#"{"b":2,"a":1,"unknownFutureField":42}"#.utf8)
        let pretty = PrettyJSON.string(from: raw)
        // Verbatim fields are preserved (nothing dropped) and keys are sorted.
        XCTAssertTrue(pretty.contains("\"unknownFutureField\" : 42"))
        let aIndex = pretty.range(of: "\"a\"")!.lowerBound
        let bIndex = pretty.range(of: "\"b\"")!.lowerBound
        XCTAssertLessThan(aIndex, bIndex)
    }

    func testFallsBackToRawTextOnInvalidJSON() {
        let notJSON = Data("CONNECT\nheart-beat:0,0\n\n".utf8)
        XCTAssertEqual(PrettyJSON.string(from: notJSON), "CONNECT\nheart-beat:0,0\n\n")
    }
}

final class InstallationStoreTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("angcli-tests-\(UUID().uuidString)", isDirectory: true)
        setenv("XDG_CONFIG_HOME", tempHome.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("XDG_CONFIG_HOME")
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testRoundTripAndFilePermissions() throws {
        let original = StoredInstallation(installationKey: .generate(), isRegistered: true)
        try InstallationStore.save(original)

        let loaded = try XCTUnwrap(InstallationStore.load())
        XCTAssertEqual(loaded.installationKey, original.installationKey)
        XCTAssertTrue(loaded.isRegistered)

        // The file holding the private-key scalar must be owner-only (0600).
        let attributes = try FileManager.default.attributesOfItem(atPath: InstallationStore.fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testLoadReturnsNilWhenAbsent() {
        XCTAssertNil(InstallationStore.load())
    }
}
