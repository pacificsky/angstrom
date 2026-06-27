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

    /// Host for the websocket (no scheme/path).
    static let webSocketHost = "lion.lamarzocco.io"

    // MARK: WebSocket state
    private var webSocketFactory: (@Sendable (URLRequest) -> any WebSocketChannel)?
    private var channel: (any WebSocketChannel)?
    private var subscriptionId: String?
    private var maintenanceTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var manuallyDisconnected = false
    private var firstConnect: CheckedContinuation<Void, Error>?
    private var updateListeners: [UUID: AsyncStream<DashboardUpdate>.Continuation] = [:]
    private var pendingCommands: [String: PendingCommand] = [:]
    private var reconnectAttempt = 0

    // Timings (overridable in tests via setWebSocketTimingForTesting).
    private var commandTimeout: Duration = .seconds(10)
    private var heartbeatInterval: Duration = .seconds(15)
    private var reconnectBackoff: Duration = .seconds(2)

    /// Whether the live websocket is currently connected.
    public private(set) var isWebSocketConnected = false

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
            return try JSONDecoder.laMarzocco().decode([Machine].self, from: data)
        } catch {
            throw LaMarzoccoError.decoding("things: \(error.localizedDescription)")
        }
    }

    /// Fetch and decode a machine's full dashboard (identity + typed widgets).
    public func dashboard(serial: String) async throws -> Dashboard {
        let data = try await authed(path: "/things/\(serial)/dashboard", method: "GET")
        do {
            return try JSONDecoder.laMarzocco().decode(Dashboard.self, from: data)
        } catch {
            throw LaMarzoccoError.decoding("dashboard: \(error)")
        }
    }

    /// Fetch and decode a machine's settings (wifi, plumb-in, firmware).
    public func settings(serial: String) async throws -> MachineSettings {
        let data = try await authed(path: "/things/\(serial)/settings", method: "GET")
        do {
            return try JSONDecoder.laMarzocco().decode(MachineSettings.self, from: data)
        } catch {
            throw LaMarzoccoError.decoding("settings: \(error)")
        }
    }

    /// Fetch and decode a machine's scheduling settings (smart standby, wake-ups).
    public func schedule(serial: String) async throws -> MachineSchedule {
        let data = try await authed(path: "/things/\(serial)/scheduling", method: "GET")
        do {
            return try JSONDecoder.laMarzocco().decode(MachineSchedule.self, from: data)
        } catch {
            throw LaMarzoccoError.decoding("scheduling: \(error)")
        }
    }

    /// Read the current power state of a machine or grinder.
    ///
    /// Handles both `CMMachineStatus` (coffee machines) and `GMachineStatus`
    /// (grinders); the full typed state is available via ``dashboard(serial:)``.
    public func powerState(serial: String) async throws -> PowerState {
        let data = try await authed(path: "/things/\(serial)/dashboard", method: "GET")
        return try Self.parsePowerState(fromDashboard: data)
    }

    /// Parse a dashboard payload into a ``PowerState``. Coffee machines report a
    /// `CMMachineStatus` widget and grinders a `GMachineStatus` widget; both
    /// carry the same `output.mode` shape, differing only in the "on" value
    /// (`BrewingMode` vs `GrindingMode`). Both use `StandBy` for off.
    static func parsePowerState(fromDashboard data: Data) throws -> PowerState {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let widgets = obj["widgets"] as? [[String: Any]] else {
            throw LaMarzoccoError.decoding("dashboard shape")
        }
        for widget in widgets {
            guard let code = widget["code"] as? String,
                  code == "CMMachineStatus" || code == "GMachineStatus" else { continue }
            let output = widget["output"] as? [String: Any]
            switch output?["mode"] as? String {
            case "BrewingMode", "GrindingMode": return .on
            case "StandBy": return .off
            case let other?: return .other(other)
            default: return .unknown
            }
        }
        return .unknown
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

    func authed(path: String, method: String, bodyData: Data? = nil) async throws -> Data {
        let bearer = try await accessToken()
        do {
            return try await send(authedRequest(path: path, method: method, bearer: bearer, bodyData: bodyData))
        } catch LaMarzoccoError.authenticationFailed {
            // Token rejected mid-flight. Invalidate it (unless another fetch has
            // already replaced it) and retry once with a fresh token.
            if token?.accessToken == bearer { token = nil }
            let retry = try await accessToken()
            return try await send(authedRequest(path: path, method: method, bearer: retry, bodyData: bodyData))
        }
    }

    /// Encode an arbitrary JSON body and send an authenticated request.
    func authedJSON(path: String, method: String, body: some Encodable & Sendable) async throws -> Data {
        try await authed(path: path, method: method, bodyData: try JSONEncoder.laMarzocco().encode(body))
    }

    private func authedRequest(path: String, method: String, bearer: String, bodyData: Data?) throws -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        for (k, v) in try Proof.requestHeaders(for: installationKey) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        // Only body-carrying requests get a Content-Type, matching pylamarzocco
        // (aiohttp emits none for body-less GETs).
        if let bodyData {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
        }
        return req
    }

    /// POST a command and decode its immediate ``CommandResponse``.
    ///
    /// The cloud returns a one-element array; we decode `[0]`. When a websocket
    /// is connected (M3) this is where we await the matching confirmation — with
    /// no socket the command is fire-and-forget (per the two-tier design).
    @discardableResult
    func executeCommand(serial: String, _ command: String, body: some Encodable & Sendable) async throws -> CommandResponse {
        let data = try await authedJSON(
            path: "/things/\(serial)/command/\(command)", method: "POST", body: body)
        let responses: [CommandResponse]
        do {
            responses = try JSONDecoder.laMarzocco().decode([CommandResponse].self, from: data)
        } catch {
            throw LaMarzoccoError.decoding("command \(command): \(error)")
        }
        guard let response = responses.first else {
            throw LaMarzoccoError.decoding("command \(command): empty response")
        }
        // Two-tier confirmation: with a live websocket, await the matching final
        // result (up to 10s) and surface rejection/timeout; with no socket the
        // command is fire-and-forget.
        guard isWebSocketConnected else { return response }
        guard let confirmation = await awaitConfirmation(id: response.id) else {
            throw LaMarzoccoError.commandTimedOut
        }
        guard confirmation.status == .success else {
            throw LaMarzoccoError.commandFailed(
                status: confirmation.status.rawValue, errorCode: confirmation.errorCode)
        }
        return confirmation
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

    // MARK: - WebSocket

    /// Open the live-status websocket for a machine and keep it connected
    /// (auto-reconnecting) until ``disconnectWebSocket()``. Returns once the
    /// first connection is established; throws if it cannot connect.
    public func connectWebSocket(serial: String) async throws {
        manuallyDisconnected = false
        guard maintenanceTask == nil else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            firstConnect = cont
            maintenanceTask = Task { await self.maintainConnection(serial: serial) }
        }
    }

    /// Disconnect the websocket and stop reconnecting.
    public func disconnectWebSocket() async {
        manuallyDisconnected = true
        // Unblock a caller still awaiting the initial handshake.
        if let cont = firstConnect { firstConnect = nil; cont.resume(throwing: CancellationError()) }
        maintenanceTask?.cancel()
        maintenanceTask = nil
        await teardownConnection()
        for listener in updateListeners.values { listener.finish() }
        updateListeners.removeAll()
    }

    /// Test seam: shrink the websocket timings so reconnect/heartbeat/timeout
    /// paths run fast and deterministically.
    func setWebSocketTimingForTesting(commandTimeout: Duration, heartbeatInterval: Duration, reconnectBackoff: Duration) {
        self.commandTimeout = commandTimeout
        self.heartbeatInterval = heartbeatInterval
        self.reconnectBackoff = reconnectBackoff
    }

    /// A stream of dashboard updates pushed over the websocket. Each call returns
    /// an independent stream; all registered streams receive every update.
    public func dashboardUpdates() -> AsyncStream<DashboardUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DashboardUpdate>.makeStream()
        updateListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    private func removeListener(_ id: UUID) { updateListeners[id] = nil }

    /// Test seam: inject a websocket channel factory.
    func setWebSocketFactoryForTesting(_ factory: @escaping @Sendable (URLRequest) -> any WebSocketChannel) {
        webSocketFactory = factory
    }

    // MARK: WebSocket internals

    private func maintainConnection(serial: String) async {
        defer { maintenanceTask = nil } // clear on every exit so connectWebSocket() can retry
        while !manuallyDisconnected {
            do {
                try await openAndRun(serial: serial)
            } catch is CancellationError {
                break
            } catch {
                if let cont = firstConnect {
                    // Initial connection failed: surface to connectWebSocket() and stop.
                    firstConnect = nil
                    cont.resume(throwing: error)
                    return
                }
                log?("websocket dropped: \(error.localizedDescription)")
            }
            if manuallyDisconnected { break }
            reconnectAttempt += 1
            try? await Task.sleep(for: min(.seconds(30), reconnectBackoff * reconnectAttempt))
        }
        await teardownConnection()
    }

    private func openAndRun(serial: String) async throws {
        let token = try await accessToken()
        let channel = makeChannel(request: webSocketRequest())
        // Store immediately so disconnect/teardown can close a hung handshake,
        // and so any handshake-phase throw still closes the socket via the defer.
        self.channel = channel
        defer {
            isWebSocketConnected = false
            stopHeartbeat()
            channel.close()
            if self.channel === channel { self.channel = nil; self.subscriptionId = nil }
        }

        try await channel.send(Stomp.encode(.connect, headers: [
            ("host", Self.webSocketHost),
            ("accept-version", "1.2,1.1,1.0"),
            ("heart-beat", "0,0"),
            ("Authorization", "Bearer \(token)"),
        ]))
        guard let connected = Stomp.decode(try await channel.receive()),
              connected.command == Stomp.Command.connected.rawValue else {
            throw LaMarzoccoError.webSocket("expected CONNECTED frame")
        }

        let subscription = UUID().uuidString
        try await channel.send(Stomp.encode(.subscribe, headers: [
            ("destination", "/ws/sn/\(serial)/dashboard"),
            ("ack", "auto"),
            ("id", subscription),
            ("content-length", "0"),
        ]))

        self.subscriptionId = subscription
        isWebSocketConnected = true
        reconnectAttempt = 0 // a successful (re)connection resets the backoff
        if let cont = firstConnect { firstConnect = nil; cont.resume() }
        startHeartbeat()

        while true {
            handleFrame(try await channel.receive())
        }
    }

    private func handleFrame(_ raw: String) {
        guard let frame = Stomp.decode(raw) else { return }
        switch frame.command {
        case Stomp.Command.message.rawValue:
            guard let body = frame.body,
                  let update = try? JSONDecoder.laMarzocco().decode(DashboardUpdate.self, from: Data(body.utf8))
            else { return }
            for command in update.commands { resolveCommand(command) }
            for listener in updateListeners.values { listener.yield(update) }
        case Stomp.Command.error.rawValue:
            log?("websocket ERROR frame: \(frame.body ?? "")")
        default:
            break
        }
    }

    private func teardownConnection() async {
        stopHeartbeat()
        if let channel, let subscriptionId {
            try? await channel.send(Stomp.encode(.unsubscribe, headers: [("id", subscriptionId)]))
        }
        channel?.close()
        channel = nil
        subscriptionId = nil
        isWebSocketConnected = false
        // Fail any in-flight command awaits so callers don't hang.
        let pending = pendingCommands
        pendingCommands.removeAll()
        for (_, command) in pending {
            command.timeoutTask?.cancel()
            command.continuation.resume(returning: nil)
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.pingChannel()
            }
        }
    }
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
    private func pingChannel() async { try? await channel?.sendPing() }

    private func awaitConfirmation(id: String) async -> CommandResponse? {
        let timeoutDuration = commandTimeout
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandResponse?, Never>) in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: timeoutDuration)
                await self?.timeoutCommand(id: id)
            }
            pendingCommands[id] = PendingCommand(continuation: cont, timeoutTask: timeout)
        }
    }
    private func resolveCommand(_ response: CommandResponse) {
        guard let pending = pendingCommands.removeValue(forKey: response.id) else { return }
        pending.timeoutTask?.cancel()
        pending.continuation.resume(returning: response)
    }
    private func timeoutCommand(id: String) {
        guard let pending = pendingCommands.removeValue(forKey: id) else { return }
        pending.continuation.resume(returning: nil)
    }

    private func makeChannel(request: URLRequest) -> any WebSocketChannel {
        if let webSocketFactory { return webSocketFactory(request) }
        return URLSessionWebSocketChannel(task: session.webSocketTask(with: request))
    }

    private func webSocketRequest() -> URLRequest {
        var req = URLRequest(url: URL(string: "wss://\(Self.webSocketHost)/ws/connect")!)
        if let headers = try? Proof.requestHeaders(for: installationKey) {
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }
        return req
    }
}

/// An in-flight command awaiting websocket confirmation.
private struct PendingCommand {
    let continuation: CheckedContinuation<CommandResponse?, Never>
    let timeoutTask: Task<Void, Never>?
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
