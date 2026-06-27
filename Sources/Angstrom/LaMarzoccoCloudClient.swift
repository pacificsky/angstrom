import Foundation

/// A client for the La Marzocco customer-app cloud API.
///
/// The client manages access tokens in memory and never touches persistent
/// storage — persist the ``installationKey`` and ``isRegistered`` flag yourself
/// (e.g. in the Keychain) and pass them back on the next launch.
///
/// ```swift
/// let key = loadInstallationKey() ?? .generate()
/// let client = LaMarzoccoCloudClient(
///     username: email, password: password,
///     installationKey: key, registered: wasRegistered
/// )
/// let machines = try await client.connect()
/// save(client.installationKey, registered: await client.isRegistered)
/// try await client.setPower(serial: machines[0].serialNumber, on: true)
/// ```
///
/// The cloud protocol and authentication are ported from
/// [`pylamarzocco`](https://github.com/zweckj/pylamarzocco) by Josef Zweck.
public actor LaMarzoccoCloudClient {
    /// Base URL of the customer-app API.
    public static let baseURL = "https://lion.lamarzocco.io/api/customer-app"

    /// The installation identity. Persist this and reuse it across launches.
    public nonisolated let installationKey: InstallationKey

    private let username: String
    private let password: String
    private let session: URLSession
    private let log: (@Sendable (String) -> Void)?

    private var token: AccessToken?
    /// Coalesces concurrent token fetches: Swift actors are re-entrant across
    /// `await`, so several authenticated calls can each observe a missing or
    /// stale token at once. Routing every fetch through one in-flight `Task`
    /// means they share a single sign-in/refresh instead of racing into
    /// duplicate requests.
    private var tokenTask: Task<AccessToken, Error>?
    private var registered: Bool

    /// Clock driving token-expiry decisions. Overridable in tests via
    /// ``setClockForTesting(_:)`` so the refresh path can be exercised without
    /// waiting out a real token lifetime.
    private var clock: @Sendable () -> Date = { Date() }

    /// Whether this installation has been registered with the server.
    /// Persist this so you don't re-register on every launch.
    public var isRegistered: Bool { registered }

    public init(
        username: String,
        password: String,
        installationKey: InstallationKey,
        registered: Bool = false,
        urlSession: URLSession? = nil,
        logHandler: (@Sendable (String) -> Void)? = nil
    ) {
        self.username = username
        self.password = password
        self.installationKey = installationKey
        self.registered = registered
        self.log = logHandler
        if let urlSession {
            self.session = urlSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - High-level

    /// Validate credentials, registering + signing in as needed, and return the
    /// machines on the account.
    public func connect() async throws -> [Machine] {
        _ = try await accessToken()
        let machines = try await self.machines()
        guard !machines.isEmpty else { throw LaMarzoccoError.noMachines }
        return machines
    }

    // MARK: - Endpoints

    /// List the machines registered to the account.
    public func machines() async throws -> [Machine] {
        let data = try await authed(path: "/things", method: "GET")
        do {
            return try JSONDecoder().decode([Machine].self, from: data)
        } catch {
            throw LaMarzoccoError.decoding("things: \(error.localizedDescription)")
        }
    }

    /// Read the current power state of a machine.
    public func powerState(serial: String) async throws -> PowerState {
        let data = try await authed(path: "/things/\(serial)/dashboard", method: "GET")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let widgets = obj["widgets"] as? [[String: Any]] else {
            throw LaMarzoccoError.decoding("dashboard shape")
        }
        for widget in widgets where (widget["code"] as? String) == "CMMachineStatus" {
            let output = widget["output"] as? [String: Any]
            switch output?["mode"] as? String {
            case "BrewingMode": return .on
            case "StandBy": return .off
            case let other?: return .other(other)
            default: return .unknown
            }
        }
        return .unknown
    }

    /// Turn the machine on (`BrewingMode`) or off (`StandBy`).
    public func setPower(serial: String, on: Bool) async throws {
        let body = ["mode": on ? "BrewingMode" : "StandBy"]
        _ = try await authed(
            path: "/things/\(serial)/command/CoffeeMachineChangeMode",
            method: "POST", body: body
        )
    }

    // MARK: - Auth

    /// Register this installation's public key with the server (one-time).
    public func register() async throws {
        var req = URLRequest(url: url("/auth/init"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(installationKey.installationId, forHTTPHeaderField: "X-App-Installation-Id")
        req.setValue(
            Proof.requestProof(baseString: try installationKey.baseString(),
                               secret: try installationKey.secret()),
            forHTTPHeaderField: "X-Request-Proof"
        )
        req.httpBody = try JSONSerialization.data(withJSONObject: ["pk": try installationKey.publicKeyBase64()])
        _ = try await send(req)
        registered = true
    }

    /// Return a valid bearer access token, signing in or refreshing as needed.
    ///
    /// Concurrent callers coalesce on ``tokenTask`` so only one sign-in/refresh
    /// is ever in flight (the Swift-actor analogue of `pylamarzocco`'s
    /// `asyncio.Lock` around token acquisition).
    private func accessToken() async throws -> String {
        if let tokenTask {
            return try await tokenTask.value.accessToken
        }
        if let token, !token.needsRefresh(at: clock()) {
            return token.accessToken
        }
        // `Task.init` inherits this actor's isolation, so the body's mutations
        // of `token`/`tokenTask` stay actor-isolated. `tokenTask` is assigned
        // before the first `await` below, so a re-entrant caller sees it.
        let task = Task { () throws -> AccessToken in
            defer { self.tokenTask = nil }
            let fresh = try await self.fetchOrRefreshToken()
            self.token = fresh
            return fresh
        }
        tokenTask = task
        return try await task.value.accessToken
    }

    /// Register first if needed, then refresh when we hold a still-valid token,
    /// otherwise perform a full sign-in.
    private func fetchOrRefreshToken() async throws -> AccessToken {
        if !registered { try await register() }
        if let token, !token.isExpired(at: clock()), !token.refreshToken.isEmpty {
            do {
                return try await requestToken(
                    path: "/auth/refreshtoken",
                    body: ["username": username, "refreshToken": token.refreshToken]
                )
            } catch LaMarzoccoError.authenticationFailed {
                // Refresh token rejected — fall through to a full sign-in.
            }
        }
        return try await requestToken(
            path: "/auth/signin",
            body: ["username": username, "password": password]
        )
    }

    /// POST a credential or refresh body to an auth endpoint and decode the token.
    private func requestToken(path: String, body: [String: String]) async throws -> AccessToken {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in try Proof.requestHeaders(for: installationKey) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["accessToken"] as? String else {
            throw LaMarzoccoError.decoding("missing accessToken")
        }
        let refresh = obj["refreshToken"] as? String ?? ""
        return AccessToken(accessToken: access, refreshToken: refresh, now: clock())
    }

    /// Test seam: override the clock driving token-expiry decisions.
    func setClockForTesting(_ clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    // MARK: - Plumbing

    private func authed(path: String, method: String, body: [String: String]? = nil) async throws -> Data {
        let bearer = try await accessToken()
        do {
            return try await send(authedRequest(path: path, method: method, bearer: bearer, body: body))
        } catch LaMarzoccoError.authenticationFailed {
            // Token rejected mid-flight. Invalidate it (unless another fetch has
            // already replaced it) and retry once with a fresh token.
            if token?.accessToken == bearer { token = nil }
            let retry = try await accessToken()
            return try await send(authedRequest(path: path, method: method, bearer: retry, body: body))
        }
    }

    private func authedRequest(path: String, method: String, bearer: String, body: [String: String]?) throws -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        for (k, v) in try Proof.requestHeaders(for: installationKey) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        // Only body-carrying requests get a Content-Type, matching pylamarzocco
        // (aiohttp emits none for body-less GETs).
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        log?("\(request.httpMethod ?? "?") \(request.url?.path ?? "")")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LaMarzoccoError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LaMarzoccoError.network("no HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw LaMarzoccoError.authenticationFailed
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LaMarzoccoError.requestFailed(status: http.statusCode, body: String(body.prefix(300)))
        }
    }

    private func url(_ path: String) -> URL {
        URL(string: "\(Self.baseURL)\(path)")!
    }
}

// MARK: - Token

/// An access/refresh token pair with a locally-computed expiry.
///
/// La Marzocco's token responses carry no explicit lifetime, so — matching the
/// `pylamarzocco` reference — tokens are treated as valid for one hour from
/// receipt and refreshed once within ``refreshWindow`` of expiry.
struct AccessToken: Sendable {
    /// Assumed token lifetime from receipt (the server states none).
    static let lifetime: TimeInterval = 60 * 60
    /// Refresh once the token is within this window of expiry.
    static let refreshWindow: TimeInterval = 10 * 60

    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    init(accessToken: String, refreshToken: String, now: Date = Date()) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = now.addingTimeInterval(Self.lifetime)
    }

    /// Whether the token is past its assumed expiry (→ requires a full sign-in).
    func isExpired(at now: Date = Date()) -> Bool { now >= expiresAt }

    /// Whether the token is within the refresh window of expiry (or past it).
    func needsRefresh(at now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-Self.refreshWindow)
    }
}
