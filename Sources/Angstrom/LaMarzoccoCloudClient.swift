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

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date = .distantPast
    private var registered: Bool

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
        try await ensureToken()
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

    private func signIn() async throws {
        var req = URLRequest(url: url("/auth/signin"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in try Proof.requestHeaders(for: installationKey) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])

        let data = try await send(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["accessToken"] as? String else {
            throw LaMarzoccoError.decoding("missing accessToken")
        }
        accessToken = access
        refreshToken = obj["refreshToken"] as? String
        tokenExpiry = Date().addingTimeInterval(50 * 60) // tokens last ~1h
    }

    private func ensureToken() async throws {
        if !registered { try await register() }
        if accessToken == nil || Date() >= tokenExpiry {
            try await signIn()
        }
    }

    // MARK: - Plumbing

    private func authed(path: String, method: String, body: [String: String]? = nil) async throws -> Data {
        try await ensureToken()
        do {
            return try await send(authedRequest(path: path, method: method, body: body))
        } catch LaMarzoccoError.authenticationFailed {
            try await signIn() // token may have expired early — retry once
            return try await send(authedRequest(path: path, method: method, body: body))
        }
    }

    private func authedRequest(path: String, method: String, body: [String: String]?) throws -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        for (k, v) in try Proof.requestHeaders(for: installationKey) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
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
