import XCTest
@testable import Angstrom

/// Covers the M0 auth-lifecycle work: token expiry/refresh logic, fetch
/// coalescing under actor re-entrancy, the refresh path, and 401 retry.
final class AuthTests: XCTestCase {

    private func makeClient(backend: MockBackend, registered: Bool = false) -> LaMarzoccoCloudClient {
        LaMarzoccoCloudClient(
            username: "user@example.com",
            password: "pw",
            installationKey: .generate(),
            registered: registered,
            urlSession: MockURLProtocol.session(backend: backend)
        )
    }

    // MARK: - AccessToken expiry windows

    func testAccessTokenExpiryWindows() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let token = AccessToken(accessToken: "a", refreshToken: "r", now: t0)
        // lifetime 3600s, refreshWindow 600s → refresh from t0+3000, expire at t0+3600.
        XCTAssertFalse(token.isExpired(at: t0))
        XCTAssertFalse(token.needsRefresh(at: t0))
        XCTAssertFalse(token.needsRefresh(at: t0.addingTimeInterval(2999)))
        XCTAssertTrue(token.needsRefresh(at: t0.addingTimeInterval(3000)))
        XCTAssertFalse(token.isExpired(at: t0.addingTimeInterval(3599)))
        XCTAssertTrue(token.isExpired(at: t0.addingTimeInterval(3600)))
    }

    // MARK: - Coalescing

    func testConcurrentCallsCoalesceIntoSingleSignIn() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") {
                return .json(["accessToken": "a1", "refreshToken": "r1"])
            }
            if path.hasSuffix("/things") {
                return .jsonArray([["serialNumber": "SN1", "name": "M", "modelName": "Linea Micra"]])
            }
            return MockBackend.Reply(status: 404)
        }
        let client = makeClient(backend: backend)

        try await withThrowingTaskGroup(of: [Machine].self) { group in
            for _ in 0..<10 { group.addTask { try await client.machines() } }
            for try await _ in group {}
        }

        XCTAssertEqual(backend.count(pathSuffix: "/auth/init"), 1, "registers exactly once")
        XCTAssertEqual(backend.count(pathSuffix: "/auth/signin"), 1, "signs in exactly once despite 10 racing callers")
        XCTAssertEqual(backend.count(pathSuffix: "/things"), 10)
    }

    // MARK: - Refresh

    func testRefreshUsedWithinRefreshWindow() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a1", "refreshToken": "r1"]) }
            if path.hasSuffix("/auth/refreshtoken") { return .json(["accessToken": "a2", "refreshToken": "r2"]) }
            if path.hasSuffix("/things") { return .jsonArray([["serialNumber": "SN1"]]) }
            return MockBackend.Reply(status: 404)
        }
        let clock = TestClock(Date(timeIntervalSince1970: 2_000_000))
        let client = makeClient(backend: backend)
        await client.setClockForTesting { clock.now }

        _ = try await client.machines() // signs in at t0
        clock.advance(by: 3300)         // within the 600s refresh window, not expired
        _ = try await client.machines() // should refresh, not re-sign-in

        XCTAssertEqual(backend.count(pathSuffix: "/auth/signin"), 1)
        XCTAssertEqual(backend.count(pathSuffix: "/auth/refreshtoken"), 1)
        XCTAssertEqual(backend.count(pathSuffix: "/auth/init"), 1)
    }

    func testRefreshRejectionFallsBackToSignIn() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a1", "refreshToken": "r1"]) }
            if path.hasSuffix("/auth/refreshtoken") { return MockBackend.Reply(status: 401) }
            if path.hasSuffix("/things") { return .jsonArray([["serialNumber": "SN1"]]) }
            return MockBackend.Reply(status: 404)
        }
        let clock = TestClock(Date(timeIntervalSince1970: 3_000_000))
        let client = makeClient(backend: backend)
        await client.setClockForTesting { clock.now }

        _ = try await client.machines() // sign in at t0
        clock.advance(by: 3300)         // into the refresh window
        _ = try await client.machines() // refresh is rejected → must fall back to sign-in

        XCTAssertEqual(backend.count(pathSuffix: "/auth/refreshtoken"), 1)
        XCTAssertEqual(backend.count(pathSuffix: "/auth/signin"), 2, "fell back to a full sign-in")
    }

    func testEmptyRefreshTokenSignsInAgain() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a1"]) } // no refreshToken
            if path.hasSuffix("/things") { return .jsonArray([["serialNumber": "SN1"]]) }
            return MockBackend.Reply(status: 404)
        }
        let clock = TestClock(Date(timeIntervalSince1970: 4_000_000))
        let client = makeClient(backend: backend)
        await client.setClockForTesting { clock.now }

        _ = try await client.machines()
        clock.advance(by: 3300)
        _ = try await client.machines() // no refresh token → sign in, don't POST an empty refresh

        XCTAssertEqual(backend.count(pathSuffix: "/auth/refreshtoken"), 0, "never refreshes without a refresh token")
        XCTAssertEqual(backend.count(pathSuffix: "/auth/signin"), 2)
    }

    func testConcurrentSignInFailurePropagatesAndResets() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            return MockBackend.Reply(status: 401) // sign-in always rejected
        }
        let client = makeClient(backend: backend)

        await withTaskGroup(of: Error?.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do { _ = try await client.machines(); return nil }
                    catch { return error }
                }
            }
            var failures = 0
            for await error in group {
                if case LaMarzoccoError.authenticationFailed = (error ?? LaMarzoccoError.noMachines) { failures += 1 }
            }
            XCTAssertEqual(failures, 10, "every coalesced awaiter observes the failure")
        }
        XCTAssertEqual(backend.count(pathSuffix: "/auth/signin"), 1, "the 10 racing callers coalesced into one attempt")

        // A later call must start a fresh attempt (proves `tokenTask` was reset).
        _ = try? await client.machines()
        XCTAssertEqual(backend.count(pathSuffix: "/auth/signin"), 2)
    }

    func testValidTokenIsReusedWithoutRefresh() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a1", "refreshToken": "r1"]) }
            if path.hasSuffix("/things") { return .jsonArray([["serialNumber": "SN1"]]) }
            return MockBackend.Reply(status: 404)
        }
        let client = makeClient(backend: backend)
        _ = try await client.machines()
        _ = try await client.machines() // token still fresh → no new auth calls

        XCTAssertEqual(backend.count(pathSuffix: "/auth/signin"), 1)
        XCTAssertEqual(backend.count(pathSuffix: "/auth/refreshtoken"), 0)
    }

    // MARK: - 401 retry

    func test401InvalidatesTokenAndRetriesOnce() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a1", "refreshToken": "r1"]) }
            if path.hasSuffix("/things") {
                // First /things attempt is rejected; the retry succeeds.
                return backend.count(pathSuffix: "/things") == 0
                    ? MockBackend.Reply(status: 401)
                    : .jsonArray([["serialNumber": "SN1"]])
            }
            return MockBackend.Reply(status: 404)
        }
        let client = makeClient(backend: backend)

        let machines = try await client.machines()
        XCTAssertEqual(machines.first?.serialNumber, "SN1")
        XCTAssertEqual(backend.count(pathSuffix: "/things"), 2, "retried once after 401")
        XCTAssertEqual(backend.count(pathSuffix: "/auth/signin"), 2, "re-signed-in after the 401")
    }

    func testPersistentAuthFailureSurfaces() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a1", "refreshToken": "r1"]) }
            return MockBackend.Reply(status: 401) // /things always rejects
        }
        let client = makeClient(backend: backend)
        do {
            _ = try await client.machines()
            XCTFail("expected authenticationFailed")
        } catch LaMarzoccoError.authenticationFailed {
            // expected after the single retry also 401s
        }
    }
}
