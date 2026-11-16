import XCTest
@testable import Angstrom
import AngstromTestSupport

/// `LaMarzoccoCloudClient.bluetoothAuthToken(serial:)` (SPEC §4.21, §6.13) and the redaction
/// guarantees of `BluetoothAuthToken` (SPEC §6.3, D2).
final class BluetoothTokenTests: XCTestCase {

    private static let secret = "secret-token"

    /// The 64 × "0" placeholder carried by `dashboard_strada_profile.json`, read from the fixture.
    private func placeholderToken() throws -> String {
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Fixture.data("dashboard_strada_profile")) as? [String: Any])
        return try XCTUnwrap(obj["bleAuthToken"] as? String)
    }

    /// A backend that signs in and answers `GET /things` with `things` (raw bytes).
    private func backend(things body: Data, status: Int = 200) -> MockBackend {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.hasSuffix("/things") { return MockBackend.Reply(status: status, body: body) }
            return MockBackend.Reply(status: 404)
        }
        return backend
    }

    private func backend(things: [Any]) throws -> MockBackend {
        backend(things: try JSONSerialization.data(withJSONObject: things))
    }

    private func client(_ backend: MockBackend) -> LaMarzoccoCloudClient {
        LaMarzoccoCloudClient(username: "u", password: "p", installationKey: .generate(),
                              urlSession: MockURLProtocol.session(backend: backend))
    }

    private func assertDecodingError(
        _ expected: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected .decoding(\(expected))", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .decoding(expected), file: file, line: line)
        }
    }

    // MARK: - X01

    /// Upstream: test_debug_log_masks_bluetooth_token (tests/test_cloud_client.py:322) [X01]
    func testTokenDescriptionIsRedacted() throws {
        let token = BluetoothAuthToken(Self.secret)
        XCTAssertEqual(token.rawValue, Self.secret)
        XCTAssertEqual(token.description, "**REDACTED**")
        XCTAssertEqual(token.debugDescription, "BluetoothAuthToken(**REDACTED**)")
        XCTAssertEqual(String(describing: token), "**REDACTED**")
        XCTAssertEqual(String(reflecting: token), "BluetoothAuthToken(**REDACTED**)")
        XCTAssertEqual("\(token)", "**REDACTED**")
        // Wrapped in an optional or a collection, printing still goes through debugDescription.
        let optional: BluetoothAuthToken? = token
        XCTAssertFalse(String(describing: optional).contains(Self.secret))
        XCTAssertFalse(String(describing: [token]).contains(Self.secret))
        var dumped = ""
        dump(token, to: &dumped)
        XCTAssertFalse(dumped.isEmpty)
        XCTAssertFalse(dumped.contains(Self.secret), dumped)

        // The placeholder token redacts the same way.
        let placeholder = BluetoothAuthToken(try placeholderToken())
        XCTAssertEqual(placeholder.description, "**REDACTED**")
        XCTAssertEqual(placeholder.debugDescription, "BluetoothAuthToken(**REDACTED**)")
    }

    /// Upstream: test_debug_log_masks_bluetooth_token (tests/test_cloud_client.py:322) [X01]
    func testBluetoothAuthTokenFromThings() async throws {
        let placeholder = try placeholderToken()
        XCTAssertEqual(placeholder, String(repeating: "0", count: 64))
        let things: [Any] = [
            ["serialNumber": "OTHER", "bleAuthToken": "other-token"],
            ["serialNumber": "SECRET", "bleAuthToken": Self.secret, "shotCounterSupported": true],
            ["serialNumber": "NULL", "bleAuthToken": NSNull()],
            ["serialNumber": "EMPTY", "bleAuthToken": ""],
            ["serialNumber": "ABSENT"],
            // Only the top-level key counts, not one nested in another object.
            ["serialNumber": "NESTED", "coffeeStation": ["bleAuthToken": "nested-token"]],
            ["serialNumber": "ZERO", "bleAuthToken": placeholder],
            // First match wins.
            ["serialNumber": "DUP", "bleAuthToken": "first"],
            ["serialNumber": "DUP", "bleAuthToken": "second"],
        ]
        let backend = try backend(things: things)
        let client = client(backend)

        let secret = try await client.bluetoothAuthToken(serial: "SECRET")
        XCTAssertEqual(secret?.rawValue, Self.secret)
        let other = try await client.bluetoothAuthToken(serial: "OTHER")
        XCTAssertEqual(other?.rawValue, "other-token")
        let null = try await client.bluetoothAuthToken(serial: "NULL")
        XCTAssertNil(null)
        let empty = try await client.bluetoothAuthToken(serial: "EMPTY")
        XCTAssertNil(empty)
        let absent = try await client.bluetoothAuthToken(serial: "ABSENT")
        XCTAssertNil(absent)
        let nested = try await client.bluetoothAuthToken(serial: "NESTED")
        XCTAssertNil(nested)
        let zero = try await client.bluetoothAuthToken(serial: "ZERO")
        XCTAssertEqual(zero, BluetoothAuthToken(String(repeating: "0", count: 64)))
        let dup = try await client.bluetoothAuthToken(serial: "DUP")
        XCTAssertEqual(dup?.rawValue, "first")

        // Every call is one authenticated GET /things (path is prefixed with /api/customer-app).
        XCTAssertEqual(backend.count(pathSuffix: "/things"), 8)
        XCTAssertEqual(backend.method(pathSuffix: "/things"), "GET")
        XCTAssertEqual(backend.count(pathSuffix: "/auth/signin"), 1)
        XCTAssertEqual(backend.recordedPaths.filter { $0.hasSuffix("/things") },
                       Array(repeating: "/api/customer-app/things", count: 8))
    }

    // MARK: - Errors

    /// Angstrom-only: §4.21 — no thing with the serial throws `.decoding("things: no thing with serial <serial>")`
    func testMissingSerialThrows() async throws {
        let populated = client(try backend(things: [
            ["serialNumber": "MR123456", "bleAuthToken": Self.secret],
            ["serialNumber": 42, "bleAuthToken": Self.secret],
            ["bleAuthToken": Self.secret],
        ]))
        await assertDecodingError("things: no thing with serial XX999") {
            _ = try await populated.bluetoothAuthToken(serial: "XX999")
        }
        // A numeric serialNumber is not a string match.
        await assertDecodingError("things: no thing with serial 42") {
            _ = try await populated.bluetoothAuthToken(serial: "42")
        }
        // Serial comparison is exact (case-sensitive).
        await assertDecodingError("things: no thing with serial mr123456") {
            _ = try await populated.bluetoothAuthToken(serial: "mr123456")
        }
        let empty = client(try backend(things: []))
        await assertDecodingError("things: no thing with serial MR123456") {
            _ = try await empty.bluetoothAuthToken(serial: "MR123456")
        }
    }

    /// Angstrom-only: §4.21 — a body that is not an array of objects throws `.decoding("things shape")`
    func testWrongShapeThrows() async throws {
        let bodies: [String] = [
            #"{"serialNumber":"MR123456","bleAuthToken":"secret-token"}"#,
            #"[{"serialNumber":"MR123456","bleAuthToken":"secret-token"},"MR123456"]"#,
            #"["MR123456"]"#,
            #"[[{"serialNumber":"MR123456"}]]"#,
            #"[1]"#,
            "null",
            "\"MR123456\"",
            "not json",
            "",
        ]
        for body in bodies {
            let client = client(backend(things: Data(body.utf8)))
            await assertDecodingError("things shape") {
                _ = try await client.bluetoothAuthToken(serial: "MR123456")
            }
        }
        // A non-success status is the request error, not a shape error.
        let failing = client(backend(things: Data("[]".utf8), status: 500))
        do {
            _ = try await failing.bluetoothAuthToken(serial: "MR123456")
            XCTFail("expected requestFailed")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .requestFailed(status: 500, body: "[]"))
        }
    }

    // MARK: - D2

    /// Angstrom-only: D2 — the token is neither Encodable nor Decodable and reflects no children
    func testTokenIsNotEncodableAndMirrorIsEmpty() throws {
        let token = BluetoothAuthToken(Self.secret)
        XCTAssertFalse((token as Any) is any Encodable)
        XCTAssertFalse((token as Any) is any Decodable)
        XCTAssertFalse(BluetoothAuthToken.self is any Encodable.Type)
        XCTAssertFalse(BluetoothAuthToken.self is any Decodable.Type)

        let mirror = Mirror(reflecting: token)
        XCTAssertEqual(mirror.children.count, 0)
        XCTAssertEqual(mirror.displayStyle, .struct)
        XCTAssertTrue(mirror.subjectType == BluetoothAuthToken.self)
        XCTAssertNil(mirror.superclassMirror)
        XCTAssertNil(mirror.descendant("rawValue"))
        XCTAssertNil(mirror.descendant(0))

        // Equality and hashing are by raw value.
        XCTAssertEqual(token, BluetoothAuthToken(Self.secret))
        XCTAssertNotEqual(token, BluetoothAuthToken("other"))
        XCTAssertEqual(Set([token, BluetoothAuthToken(Self.secret)]).count, 1)
    }
}
