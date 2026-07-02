import XCTest
@testable import Angstrom

/// Covers the M3 live layer: handshake/subscribe, update streaming, two-tier
/// command confirmation, and the dashboard merge.
final class WebSocketTests: XCTestCase {

    private func authBackend(commandId: String = "cmd1") -> MockBackend {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.contains("/command/") { return .jsonArray([["id": commandId, "status": "Pending"]]) }
            return MockBackend.Reply(status: 404)
        }
        return backend
    }

    private func connect(_ backend: MockBackend, _ channel: MockWebSocketChannel) async throws -> LaMarzoccoCloudClient {
        let client = LaMarzoccoCloudClient(username: "u", password: "p", installationKey: .generate(),
                                           urlSession: MockURLProtocol.session(backend: backend))
        await client.setWebSocketFactoryForTesting { _ in channel }
        channel.push(Stomp.encode(.connected, headers: [("version", "1.2")]))
        try await client.connectWebSocket(serial: "SN1")
        return client
    }

    private func messageFrame(_ json: String) -> String {
        Stomp.encode(.message, headers: [("destination", "/ws/sn/SN1/dashboard")], body: json)
    }

    private func connectedFrame() -> String { Stomp.encode(.connected, headers: [("version", "1.2")]) }

    private func waitUntil(_ message: String = "condition", _ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(message)")
    }

    /// Vends a fixed sequence of channels (then fresh ones), for reconnect tests.
    private final class ChannelVendor: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [MockWebSocketChannel]
        init(_ channels: [MockWebSocketChannel]) { queue = channels }
        func next() -> MockWebSocketChannel {
            lock.withLock { queue.isEmpty ? MockWebSocketChannel() : queue.removeFirst() }
        }
    }

    private func makeClient(_ backend: MockBackend) -> LaMarzoccoCloudClient {
        LaMarzoccoCloudClient(username: "u", password: "p", installationKey: .generate(),
                              urlSession: MockURLProtocol.session(backend: backend))
    }

    // MARK: Handshake

    func testHandshakeAndSubscribe() async throws {
        let channel = MockWebSocketChannel()
        let client = try await connect(authBackend(), channel)

        let connected = await client.isWebSocketConnected
        XCTAssertTrue(connected)
        let connect = channel.sentFrame(command: "CONNECT")
        XCTAssertEqual(connect?.headers["Authorization"], "Bearer a")
        XCTAssertEqual(connect?.headers["host"], "lion.lamarzocco.io")
        XCTAssertEqual(connect?.headers["accept-version"], "1.2,1.1,1.0")
        let subscribe = channel.sentFrame(command: "SUBSCRIBE")
        XCTAssertEqual(subscribe?.headers["destination"], "/ws/sn/SN1/dashboard")
        XCTAssertEqual(subscribe?.headers["ack"], "auto")
        XCTAssertNotNil(subscribe?.headers["id"])
    }

    // MARK: Streaming

    func testDashboardUpdateStreamed() async throws {
        let channel = MockWebSocketChannel()
        let client = try await connect(authBackend(), channel)
        let stream = await client.dashboardUpdates()

        channel.push(messageFrame("""
        { "connected": true, "removedWidgets": [], "commands": [],
          "widgets": [ { "code": "CMMachineStatus", "index": 1,
            "output": { "status": "PoweredOn", "availableModes": ["BrewingMode","StandBy"],
                        "mode": "BrewingMode", "nextStatus": null, "brewingStartTime": null } } ] }
        """))

        var iterator = stream.makeAsyncIterator()
        let update = await iterator.next()
        XCTAssertEqual(update?.connected, true)
        XCTAssertEqual(update?.widgets.first?.code, "CMMachineStatus")
    }

    // MARK: Raw-frame tap (diagnostic)

    /// The raw-frame tap surfaces every frame in both directions, in order:
    /// outbound CONNECT, inbound CONNECTED, outbound SUBSCRIBE, then the inbound
    /// MESSAGE — verbatim, before STOMP decoding.
    func testRawFrameTapCapturesBothDirections() async throws {
        let channel = MockWebSocketChannel()
        let client = makeClient(authBackend())
        await client.setWebSocketFactoryForTesting { _ in channel }
        // Register the tap before connecting so the handshake frames are captured.
        let frames = await client.rawFrames()
        channel.push(connectedFrame())
        try await client.connectWebSocket(serial: "SN1")
        channel.push(messageFrame(#"{"connected":true,"widgets":[],"removedWidgets":[],"commands":[]}"#))

        var iterator = frames.makeAsyncIterator()
        func expect(_ direction: RawFrame.Direction, prefix: String) async {
            let frame = await iterator.next()
            XCTAssertEqual(frame?.direction, direction)
            XCTAssertTrue(frame?.text.hasPrefix(prefix) ?? false, "expected \(prefix), got \(frame?.text ?? "nil")")
        }
        await expect(.outbound, prefix: "CONNECT")
        await expect(.inbound, prefix: "CONNECTED")
        await expect(.outbound, prefix: "SUBSCRIBE")
        await expect(.inbound, prefix: "MESSAGE")

        await client.disconnectWebSocket()
    }

    /// A completed ping round-trip surfaces a synthetic inbound pong marker on
    /// the tap (after its ping marker), so wire-debugging tools show liveness
    /// directly instead of inferring it from the absence of reconnect churn.
    func testHeartbeatPongSurfacesOnRawFrameTap() async throws {
        final class FrameLog: @unchecked Sendable {
            private let lock = NSLock()
            private var frames: [RawFrame] = []
            func append(_ frame: RawFrame) { lock.withLock { frames.append(frame) } }
            func firstIndex(_ direction: RawFrame.Direction, _ text: String) -> Int? {
                lock.withLock { frames.firstIndex { $0.direction == direction && $0.text == text } }
            }
        }
        let channel = MockWebSocketChannel()
        let client = makeClient(authBackend())
        await client.setWebSocketTimingForTesting(commandTimeout: .seconds(10),
                                                  heartbeatInterval: .milliseconds(20),
                                                  reconnectBackoff: .seconds(2))
        await client.setWebSocketFactoryForTesting { _ in channel }
        let log = FrameLog()
        let frames = await client.rawFrames()
        let collector = Task { for await frame in frames { log.append(frame) } }
        channel.push(connectedFrame())
        try await client.connectWebSocket(serial: "SN1")

        try await waitUntil("pong marker on tap") { log.firstIndex(.inbound, RawFrame.pongMarker) != nil }
        let ping = try XCTUnwrap(log.firstIndex(.outbound, RawFrame.heartbeatMarker))
        let pong = try XCTUnwrap(log.firstIndex(.inbound, RawFrame.pongMarker))
        XCTAssertGreaterThan(pong, ping, "the pong marker follows its ping")
        await client.disconnectWebSocket()
        collector.cancel()
    }

    /// A ping that never completes must surface no pong marker — the tap only
    /// reports round-trips that actually finished.
    func testNoPongMarkerWhenPingHangs() async throws {
        let channel = MockWebSocketChannel()
        channel.pingBehavior = .hang
        let client = makeClient(authBackend())
        await client.setWebSocketTimingForTesting(commandTimeout: .seconds(10),
                                                  heartbeatInterval: .milliseconds(20),
                                                  reconnectBackoff: .seconds(2))
        await client.setWebSocketFactoryForTesting { _ in channel }
        let frames = await client.rawFrames()
        let sawPong = LockedBox(false)
        let collector = Task {
            for await frame in frames where frame.direction == .inbound && frame.text == RawFrame.pongMarker {
                sawPong.set(true)
            }
        }
        channel.push(connectedFrame())
        try await client.connectWebSocket(serial: "SN1")

        try await waitUntil("ping attempted") { channel.pingCount >= 1 }
        try await Task.sleep(for: .milliseconds(50)) // past the pong deadline
        XCTAssertFalse(sawPong.get(), "a hung ping must not report a pong")
        await client.disconnectWebSocket()
        collector.cancel()
    }

    /// The `sendPing` continuation latch: even with many concurrent callbacks
    /// (as Foundation's `sendPing` can fire on connection abort), exactly one
    /// wins — so the underlying continuation is resumed at most once.
    func testResumeOnceClaimsExactlyOnce() async {
        let once = ResumeOnce()
        let winners = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<100 { group.addTask { once.claim() } }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        XCTAssertEqual(winners, 1)
    }

    /// A decoded ``DashboardUpdate`` now re-encodes (Codable), so a diagnostic
    /// tool can serialize the decoded push back to JSON and round-trip it.
    func testDashboardUpdateRoundTripsThroughJSON() throws {
        let json = """
        { "connected": true, "removedWidgets": [{"code":"CMNoWater","index":1}], "commands": [],
          "widgets": [ { "code": "CMMachineStatus", "index": 1,
            "output": { "status": "PoweredOn", "availableModes": ["BrewingMode","StandBy"],
                        "mode": "BrewingMode", "nextStatus": null, "brewingStartTime": null } } ] }
        """
        let decoded = try JSONDecoder.laMarzocco().decode(DashboardUpdate.self, from: Data(json.utf8))
        let reEncoded = try JSONEncoder.laMarzocco().encode(decoded)
        let again = try JSONDecoder.laMarzocco().decode(DashboardUpdate.self, from: reEncoded)
        XCTAssertEqual(decoded, again)
        XCTAssertEqual(again.removedWidgets.first?.code, "CMNoWater")
        XCTAssertEqual(again.widgets.first?.code, "CMMachineStatus")
    }

    // MARK: Two-tier command confirmation

    /// Push a confirmation frame repeatedly (extra frames are dropped) until the
    /// command, which registers its pending wait only after its POST completes,
    /// is resolved — keeping the test deterministic without timing assumptions.
    private func pushUntilResolved(_ channel: MockWebSocketChannel, _ frame: String) async {
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(10))
            channel.push(frame)
        }
    }

    func testCommandConfirmedSuccess() async throws {
        let channel = MockWebSocketChannel()
        let client = try await connect(authBackend(), channel)

        async let result = client.setPower(serial: "SN1", on: true)
        await pushUntilResolved(channel, messageFrame(#"{"commands":[{"id":"cmd1","status":"Success"}]}"#))
        let response = try await result
        XCTAssertEqual(response.status, .success)
    }

    func testCommandRejectedThrows() async throws {
        let channel = MockWebSocketChannel()
        let client = try await connect(authBackend(), channel)

        async let result: CommandResponse = client.setPower(serial: "SN1", on: true)
        await pushUntilResolved(channel, messageFrame(#"{"commands":[{"id":"cmd1","status":"Error","errorCode":"E1"}]}"#))
        do {
            _ = try await result
            XCTFail("expected commandFailed")
        } catch LaMarzoccoError.commandFailed(let status, let code) {
            XCTAssertEqual(status, "Error")
            XCTAssertEqual(code, "E1")
        }
    }

    func testFireAndForgetWhenNotConnected() async throws {
        // No websocket → the command returns its immediate ack without blocking.
        let backend = authBackend()
        let client = LaMarzoccoCloudClient(username: "u", password: "p", installationKey: .generate(),
                                           urlSession: MockURLProtocol.session(backend: backend))
        let response = try await client.setPower(serial: "SN1", on: true)
        XCTAssertEqual(response.status, .pending)
    }

    func testDisconnectFailsPendingCommands() async throws {
        let channel = MockWebSocketChannel()
        let client = try await connect(authBackend(), channel)

        async let result = client.setPower(serial: "SN1", on: true)
        try await Task.sleep(for: .milliseconds(100)) // let the command register its wait
        await client.disconnectWebSocket()
        do {
            _ = try await result
            XCTFail("expected commandTimedOut")
        } catch LaMarzoccoError.commandTimedOut {}
    }

    // MARK: Lifecycle (regression coverage)

    func testReconnectsAfterDrop() async throws {
        let channelA = MockWebSocketChannel()
        let channelB = MockWebSocketChannel()
        let vendor = ChannelVendor([channelA, channelB])
        let client = makeClient(authBackend())
        await client.setWebSocketTimingForTesting(commandTimeout: .seconds(10),
                                                  heartbeatInterval: .seconds(60),
                                                  reconnectBackoff: .milliseconds(10))
        await client.setWebSocketFactoryForTesting { _ in vendor.next() }

        channelA.push(connectedFrame())
        try await client.connectWebSocket(serial: "SN1")
        XCTAssertNotNil(channelA.sentFrame(command: "SUBSCRIBE"))

        // Drop A; the maintenance loop must reconnect with B.
        channelB.push(connectedFrame())
        channelA.close()
        try await waitUntil("B handshake") { channelB.sentFrame(command: "SUBSCRIBE") != nil }
        let connected = await client.isWebSocketConnected
        XCTAssertTrue(connected)
        await client.disconnectWebSocket()
    }

    func testInitialConnectFailureAllowsRetry() async throws {
        // The first attempt fails the handshake; a later connectWebSocket() must
        // not be wedged (regression: maintenanceTask left non-nil).
        let bad = MockWebSocketChannel()
        let good = MockWebSocketChannel()
        let vendor = ChannelVendor([bad, good])
        let client = makeClient(authBackend())
        await client.setWebSocketFactoryForTesting { _ in vendor.next() }

        bad.push(Stomp.encode(.error, headers: [])) // not CONNECTED → handshake throws
        do {
            try await client.connectWebSocket(serial: "SN1")
            XCTFail("expected initial connect to fail")
        } catch {}

        good.push(connectedFrame())
        try await client.connectWebSocket(serial: "SN1") // must succeed, not no-op
        let connected = await client.isWebSocketConnected
        XCTAssertTrue(connected)
        await client.disconnectWebSocket()
    }

    func testCommandTimesOutWhenUnconfirmed() async throws {
        let channel = MockWebSocketChannel()
        let client = try await connect(authBackend(), channel)
        await client.setWebSocketTimingForTesting(commandTimeout: .milliseconds(50),
                                                  heartbeatInterval: .seconds(60),
                                                  reconnectBackoff: .seconds(2))
        do {
            _ = try await client.setPower(serial: "SN1", on: true) // never confirmed
            XCTFail("expected commandTimedOut")
        } catch LaMarzoccoError.commandTimedOut {}
        await client.disconnectWebSocket()
    }

    // MARK: Heartbeat enforcement (zombie-socket recovery)

    /// A heartbeat ping that *fails* must tear the channel down so the
    /// maintenance loop reconnects — a swallowed ping error would leave a dead
    /// socket reported as connected forever (the post-sleep zombie scenario).
    func testPingFailureForcesReconnect() async throws {
        let channelA = MockWebSocketChannel()
        channelA.pingBehavior = .fail(URLError(.networkConnectionLost))
        let channelB = MockWebSocketChannel()
        let vendor = ChannelVendor([channelA, channelB])
        let client = makeClient(authBackend())
        await client.setWebSocketTimingForTesting(commandTimeout: .seconds(10),
                                                  heartbeatInterval: .milliseconds(20),
                                                  reconnectBackoff: .milliseconds(10))
        await client.setWebSocketFactoryForTesting { _ in vendor.next() }

        channelA.push(connectedFrame())
        channelB.push(connectedFrame())
        try await client.connectWebSocket(serial: "SN1")

        try await waitUntil("reconnect after failed ping") { channelB.sentFrame(command: "SUBSCRIBE") != nil }
        await client.disconnectWebSocket()
    }

    /// A ping whose pong never arrives (half-open zombie: the local FD looks
    /// alive but the peer is gone) must be treated as a dead connection after
    /// the pong timeout, tearing the channel down so the loop reconnects.
    func testPingPongTimeoutForcesReconnect() async throws {
        let channelA = MockWebSocketChannel()
        channelA.pingBehavior = .hang
        let channelB = MockWebSocketChannel()
        let vendor = ChannelVendor([channelA, channelB])
        let client = makeClient(authBackend())
        await client.setWebSocketTimingForTesting(commandTimeout: .seconds(10),
                                                  heartbeatInterval: .milliseconds(20),
                                                  reconnectBackoff: .milliseconds(10))
        await client.setWebSocketFactoryForTesting { _ in vendor.next() }

        channelA.push(connectedFrame())
        channelB.push(connectedFrame())
        try await client.connectWebSocket(serial: "SN1")

        try await waitUntil("reconnect after missing pong") { channelB.sentFrame(command: "SUBSCRIBE") != nil }
        await client.disconnectWebSocket()
    }

    func testHeartbeatPings() async throws {
        let channel = MockWebSocketChannel()
        let client = makeClient(authBackend())
        await client.setWebSocketTimingForTesting(commandTimeout: .seconds(10),
                                                  heartbeatInterval: .milliseconds(20),
                                                  reconnectBackoff: .seconds(2))
        await client.setWebSocketFactoryForTesting { _ in channel }
        channel.push(connectedFrame())
        try await client.connectWebSocket(serial: "SN1")
        try await waitUntil("heartbeat ping") { channel.pingCount >= 1 }
        await client.disconnectWebSocket()
    }

    // MARK: Connection events

    /// The connection-event stream reports every transition: `.connected` on the
    /// initial subscribe, `.disconnected` when the socket drops, and `.connected`
    /// again after the automatic reconnect — the signal a consumer needs to
    /// re-fetch state missed during the gap (the feed itself is change-only).
    func testConnectionEventsAcrossDropAndReconnect() async throws {
        let channelA = MockWebSocketChannel()
        let channelB = MockWebSocketChannel()
        let vendor = ChannelVendor([channelA, channelB])
        let client = makeClient(authBackend())
        await client.setWebSocketTimingForTesting(commandTimeout: .seconds(10),
                                                  heartbeatInterval: .seconds(60),
                                                  reconnectBackoff: .milliseconds(10))
        await client.setWebSocketFactoryForTesting { _ in vendor.next() }
        // Register before connecting so the initial transition is observed.
        let events = await client.connectionEvents()
        var iterator = events.makeAsyncIterator()

        channelA.push(connectedFrame())
        try await client.connectWebSocket(serial: "SN1")
        let first = await iterator.next()
        XCTAssertEqual(first, .connected)

        channelB.push(connectedFrame())
        channelA.close()
        let second = await iterator.next()
        XCTAssertEqual(second, .disconnected)
        let third = await iterator.next()
        XCTAssertEqual(third, .connected)

        await client.disconnectWebSocket()
    }

    /// `disconnectWebSocket()` emits a final `.disconnected` and finishes the
    /// event streams, so consumers' iteration loops end cleanly.
    func testConnectionEventStreamFinishesOnDisconnect() async throws {
        let channel = MockWebSocketChannel()
        let client = makeClient(authBackend())
        await client.setWebSocketFactoryForTesting { _ in channel }
        let events = await client.connectionEvents()
        var iterator = events.makeAsyncIterator()

        channel.push(connectedFrame())
        try await client.connectWebSocket(serial: "SN1")
        let first = await iterator.next()
        XCTAssertEqual(first, .connected)

        await client.disconnectWebSocket()
        let second = await iterator.next()
        XCTAssertEqual(second, .disconnected)
        let end = await iterator.next()
        XCTAssertNil(end, "stream must finish after disconnectWebSocket()")
    }

    // MARK: DashboardUpdate + merge

    func testDashboardUpdateDecodesCommands() throws {
        let update = try JSONDecoder.laMarzocco().decode(DashboardUpdate.self, from: Data(
            #"{"connected":true,"commands":[{"id":"c1","status":"Success"}],"widgets":[],"removedWidgets":[{"code":"CMNoWater","index":1}]}"#.utf8))
        XCTAssertEqual(update.commands.first?.id, "c1")
        XCTAssertEqual(update.removedWidgetCodes, ["CMNoWater"])
    }

    func testDashboardApplyingMerge() throws {
        let base = try JSONDecoder.laMarzocco().decode(Dashboard.self, from: try Fixture.data("dashboard_micra"))
        XCTAssertEqual(base.machineStatus?.mode, .standby)
        XCTAssertNotNil(base.backFlush)

        let update = try JSONDecoder.laMarzocco().decode(DashboardUpdate.self, from: Data("""
        { "connected": true, "removedWidgets": [ { "code": "CMBackFlush", "index": 1 } ],
          "widgets": [ { "code": "CMMachineStatus", "index": 1,
            "output": { "status": "PoweredOn", "availableModes": ["BrewingMode"], "mode": "BrewingMode",
                        "nextStatus": null, "brewingStartTime": null } } ] }
        """.utf8))

        let merged = base.applying(update)
        XCTAssertEqual(merged.machineStatus?.mode, .brewing) // replaced
        XCTAssertNil(merged.backFlush)                       // removed
        XCTAssertNotNil(merged.coffeeBoiler)                 // retained
        XCTAssertEqual(merged.machine.serialNumber, "MR123456")
    }
}
