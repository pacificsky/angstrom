import XCTest
@testable import Angstrom
@testable import AngstromUI

/// Drives the observable device layer through the core client + mock transport:
/// refresh populates state, a pushed update merges into the dashboard, commands
/// apply optimistically, model gating throws, and snapshots round-trip.
@MainActor
final class LaMarzoccoMachineTests: XCTestCase {

    private let serial = "MR123456" // matches dashboard_micra / settings_micra

    /// A backend serving the Micra fixtures for reads and acking commands.
    private func fixtureBackend() throws -> MockBackend {
        let dashboard = try Fixture.data("dashboard_micra")
        let settings = try Fixture.data("settings_micra")
        let schedule = try Fixture.data("schedule")
        let stats = try Fixture.data("statistics")
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.hasSuffix("/dashboard") { return MockBackend.Reply(status: 200, body: dashboard) }
            if path.hasSuffix("/settings") { return MockBackend.Reply(status: 200, body: settings) }
            if path.hasSuffix("/scheduling") { return MockBackend.Reply(status: 200, body: schedule) }
            if path.hasSuffix("/stats") { return MockBackend.Reply(status: 200, body: stats) }
            if path.contains("/command/") { return .jsonArray([["id": "cmd1", "status": "Pending"]]) }
            return MockBackend.Reply(status: 404)
        }
        return backend
    }

    /// A backend serving an arbitrary dashboard fixture for reads + acking commands.
    private func backend(dashboardFixture: String) throws -> MockBackend {
        let dashboard = try Fixture.data(dashboardFixture)
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.hasSuffix("/dashboard") { return MockBackend.Reply(status: 200, body: dashboard) }
            if path.contains("/command/") { return .jsonArray([["id": "cmd1", "status": "Pending"]]) }
            return MockBackend.Reply(status: 404)
        }
        return backend
    }

    private func machine(dashboardFixture: String, serial: String) throws -> LaMarzoccoMachine {
        LaMarzoccoMachine(serialNumber: serial, client: makeClient(try backend(dashboardFixture: dashboardFixture)))
    }

    private func decodeDashboard(_ name: String) throws -> Dashboard {
        try JSONDecoder.laMarzocco().decode(Dashboard.self, from: Fixture.data(name))
    }

    private func makeClient(_ backend: MockBackend) -> LaMarzoccoCloudClient {
        LaMarzoccoCloudClient(username: "u", password: "p", installationKey: .generate(),
                              urlSession: MockURLProtocol.session(backend: backend))
    }

    private func makeMachine(_ backend: MockBackend, snapshot: MachineSnapshot? = nil) -> LaMarzoccoMachine {
        LaMarzoccoMachine(serialNumber: serial, client: makeClient(backend), snapshot: snapshot)
    }

    private func messageFrame(_ json: String) -> String {
        Stomp.encode(.message, headers: [("destination", "/ws/sn/\(serial)/dashboard")], body: json)
    }

    private func connectedFrame() -> String { Stomp.encode(.connected, headers: [("version", "1.2")]) }

    /// Vends a fixed sequence of channels (then fresh ones), for reconnect tests.
    private final class ChannelVendor: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [MockWebSocketChannel]
        init(_ channels: [MockWebSocketChannel]) { queue = channels }
        func next() -> MockWebSocketChannel {
            lock.withLock { queue.isEmpty ? MockWebSocketChannel() : queue.removeFirst() }
        }
    }

    /// A brewing machine-status push, used to make local state diverge from the
    /// standby REST fixture.
    private var brewingPush: String {
        messageFrame("""
        { "connected": true, "removedWidgets": [], "commands": [],
          "widgets": [ { "code": "CMMachineStatus", "index": 1,
            "output": { "status": "PoweredOn", "availableModes": ["BrewingMode","StandBy"],
                        "mode": "BrewingMode", "nextStatus": null, "brewingStartTime": null } } ] }
        """)
    }

    // MARK: - Strada X / Swan (upstream v2.4.2)

    /// The Strada X reports `CMMachineGroupStatus` instead of `CMMachineStatus`;
    /// `powerState` must derive from it, and `setPower`'s optimistic update must
    /// flip it.
    func testStradaXPowerStateFromGroupStatus() async throws {
        let machine = try machine(dashboardFixture: "dashboard_stradax", serial: "SR123456")
        try await machine.refreshDashboard()
        XCTAssertEqual(machine.model, .stradaX)
        XCTAssertNil(machine.dashboard?.machineStatus)
        XCTAssertEqual(machine.powerState, .off) // group status mode: StandBy

        try await machine.setPower(on: true)
        XCTAssertEqual(machine.dashboard?.machineGroupStatus?.mode, .brewing)
        XCTAssertEqual(machine.powerState, .on)
    }

    func testStradaXCommandsGateAndUpdateOptimistically() async throws {
        let machine = try machine(dashboardFixture: "dashboard_stradax", serial: "SR123456")
        try await machine.refreshDashboard()

        try await machine.setMode(.eco)
        XCTAssertEqual(machine.dashboard?.machineGroupStatus?.mode, .eco)

        try await machine.setAutoFlush(on: false)
        XCTAssertEqual(machine.dashboard?.autoFlush?.enabled, false)
        try await machine.setSteamFlush(on: false)
        XCTAssertEqual(machine.dashboard?.steamFlush?.enabled, false)
        try await machine.setRinseFlush(on: false)
        XCTAssertEqual(machine.dashboard?.rinseFlush?.enabled, false)
        try await machine.setRinseFlushTime(seconds: 2.5)
        XCTAssertEqual(machine.dashboard?.rinseFlush?.timeSeconds, 2.5)
        try await machine.setCoffeeBoilerEnabled(on: false)
        XCTAssertEqual(machine.dashboard?.coffeeBoiler?.enabled, false)
        try await machine.setHotWaterDoseEnabled(on: false)
        XCTAssertEqual(machine.dashboard?.hotWaterDose?.enabled, false)
        try await machine.setHotWaterDose(dose: 9.9, doseIndex: .doseA)
        XCTAssertEqual(machine.dashboard?.hotWaterDose?.doses.first?.dose, 9.9)
        try await machine.setGroupDose(mode: .manual, doseIndex: .doseA, dose: 20)
        try await machine.setGroupMode(.brewing)
        XCTAssertEqual(machine.dashboard?.machineGroupStatus?.mode, .brewing)
        // Steam temperature is now Strada X-supported (was GS3-only).
        try await machine.setSteamTargetTemperature(celsius: 126)
        XCTAssertEqual(machine.dashboard?.steamBoilerTemperature?.targetTemperature, 126)
    }

    /// Strada X-only commands throw ``LaMarzoccoError/unsupportedModel`` on
    /// other machines.
    func testStradaXCommandsThrowOnMicra() async throws {
        let machine = makeMachine(try fixtureBackend())
        try await machine.refreshDashboard()
        do {
            _ = try await machine.setAutoFlush(on: true)
            XCTFail("expected unsupportedModel")
        } catch LaMarzoccoError.unsupportedModel {}
        do {
            _ = try await machine.setMode(.eco)
            XCTFail("expected unsupportedModel")
        } catch LaMarzoccoError.unsupportedModel {}
    }

    /// Brewing pressure requires the group's dose mode to support it — the
    /// stradax fixture reports `brewingPressureSupported: false`, so the
    /// command must throw ``LaMarzoccoError/operationNotAvailable`` without
    /// hitting the network (upstream `OperationNotAvailable` parity).
    func testBrewingPressureUnavailableThrows() async throws {
        let backend = try backend(dashboardFixture: "dashboard_stradax")
        let machine = LaMarzoccoMachine(serialNumber: "SR123456", client: makeClient(backend))
        try await machine.refreshDashboard()
        do {
            _ = try await machine.setBrewingPressure(pressure: 9)
            XCTFail("expected operationNotAvailable")
        } catch LaMarzoccoError.operationNotAvailable {}
        XCTAssertEqual(backend.count(pathSuffix: "/command/CoffeeMachineGroupDoseSettingGroupBrewingPressure"), 0)
    }

    func testSwanGrinderCommands() async throws {
        let machine = try machine(dashboardFixture: "dashboard_swan", serial: "SG123456")
        try await machine.refreshDashboard()
        XCTAssertEqual(machine.model, .swan)
        XCTAssertEqual(machine.powerState, .on) // GrindingMode

        try await machine.setGrinderPower(on: false)
        XCTAssertEqual(machine.dashboard?.grinderStatus?.mode, .standby)
        XCTAssertEqual(machine.powerState, .off)

        // Mode defaults to the dashboard's current dose mode (RevType).
        try await machine.setGrinderDose(doseIndex: .doseA, dose: 12.0, speedLevel: .low)
        XCTAssertEqual(machine.dashboard?.grinderDoses?.doses.revType.first?.dose, 12.0)
        XCTAssertEqual(machine.dashboard?.grinderSpeed?.doses["DoseA"]?.level, .low)

        try await machine.setGrinderMoreDose(revolutions: 2.0)
        XCTAssertEqual(machine.dashboard?.grinderMoreDose?.revolutions, 2.0)

        try await machine.setGrinderGrindWith(.portafilter)
        XCTAssertEqual(machine.dashboard?.grinderGrindWith?.mode, .portafilter)
    }

    /// Swan-only grinder commands throw on the Pico.
    func testSwanCommandsThrowOnPico() async throws {
        let machine = try machine(dashboardFixture: "dashboard_pico", serial: "GR123456")
        try await machine.refreshDashboard()
        do {
            _ = try await machine.setGrinderGrindWith(.portafilter)
            XCTFail("expected unsupportedModel")
        } catch LaMarzoccoError.unsupportedModel {}
        do {
            _ = try await machine.setGrinderMoreDose(revolutions: 1)
            XCTFail("expected unsupportedModel")
        } catch LaMarzoccoError.unsupportedModel {}
    }

    // MARK: - Refresh

    func testRefreshAllPopulatesState() async throws {
        let machine = makeMachine(try fixtureBackend())
        XCTAssertNil(machine.dashboard)

        try await machine.refreshAll()

        XCTAssertEqual(machine.dashboard?.machine.serialNumber, serial)
        XCTAssertEqual(machine.model, .lineaMicra)
        XCTAssertEqual(machine.powerState, .off) // Micra fixture is in standby
        XCTAssertNotNil(machine.settings)
        XCTAssertNotNil(machine.schedule)
        XCTAssertNil(machine.lastError)
    }

    func testRefreshDashboardRecordsError() async throws {
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            return MockBackend.Reply(status: 500) // dashboard fails
        }
        let machine = makeMachine(backend)
        do {
            _ = try await machine.refreshDashboard()
            XCTFail("expected throw")
        } catch {
            XCTAssertNotNil(machine.lastError)
        }
    }

    // MARK: - Live updates

    func testPushedUpdateMergesIntoDashboard() async throws {
        let backend = try fixtureBackend()
        let machine = makeMachine(backend)
        try await machine.refreshDashboard()
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .standby)

        let channel = MockWebSocketChannel()
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in channel }
        channel.push(Stomp.encode(.connected, headers: [("version", "1.2")]))
        try await machine.start()
        XCTAssertTrue(machine.isLive)

        channel.push(messageFrame("""
        { "connected": true, "removedWidgets": [], "commands": [],
          "widgets": [ { "code": "CMMachineStatus", "index": 1,
            "output": { "status": "PoweredOn", "availableModes": ["BrewingMode","StandBy"],
                        "mode": "BrewingMode", "nextStatus": null, "brewingStartTime": null } } ] }
        """))

        try await waitUntil("dashboard merges push") { machine.dashboard?.machineStatus?.mode == .brewing }
        await machine.stop()
        XCTAssertFalse(machine.isLive)
    }

    /// The push feed is change-only, so a state transition that happens while
    /// the socket is down is never re-pushed. After every automatic reconnect
    /// the machine must re-fetch the dashboard snapshot so state missed during
    /// the gap is reconciled (the stale "heating up for hours" bug).
    func testReconnectRefreshesDashboard() async throws {
        let backend = try fixtureBackend()
        let machine = makeMachine(backend)
        try await machine.refreshDashboard() // fixture: standby
        let channelA = MockWebSocketChannel()
        let channelB = MockWebSocketChannel()
        let vendor = ChannelVendor([channelA, channelB])
        await machine.clientForTesting.setWebSocketTimingForTesting(commandTimeout: .seconds(10),
                                                                    heartbeatInterval: .seconds(60),
                                                                    reconnectBackoff: .milliseconds(10))
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in vendor.next() }
        channelA.push(connectedFrame())
        try await machine.start()
        let fetchesBeforeDrop = backend.count(pathSuffix: "/dashboard")

        // Diverge local state from the REST fixture, as a missed transition would.
        channelA.push(brewingPush)
        try await waitUntil("push merged") { machine.dashboard?.machineStatus?.mode == .brewing }

        // Drop the socket; the reconnect must trigger a REST re-fetch that
        // replaces the stale merged state with the fixture snapshot.
        channelB.push(connectedFrame())
        channelA.close()
        try await waitUntil("dashboard re-fetched on reconnect") {
            machine.dashboard?.machineStatus?.mode == .standby
        }
        XCTAssertGreaterThan(backend.count(pathSuffix: "/dashboard"), fetchesBeforeDrop)
        await machine.stop()
    }

    /// ``isConnected`` reflects actual socket health across silent drops, while
    /// ``isLive`` keeps reporting subscription intent — so UIs can distinguish
    /// "live" from "subscribed but stale".
    func testIsConnectedTracksSocketState() async throws {
        let machine = makeMachine(try fixtureBackend())
        try await machine.refreshDashboard()
        XCTAssertFalse(machine.isConnected)

        let channelA = MockWebSocketChannel()
        let vendor = ChannelVendor([channelA]) // reconnect attempts get fresh, never-completing channels
        await machine.clientForTesting.setWebSocketTimingForTesting(commandTimeout: .seconds(10),
                                                                    heartbeatInterval: .seconds(60),
                                                                    reconnectBackoff: .milliseconds(10))
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in vendor.next() }
        channelA.push(connectedFrame())
        try await machine.start()
        try await waitUntil("connected") { machine.isConnected }
        XCTAssertTrue(machine.isLive)

        // Drop the socket; the replacement channel never completes its
        // handshake, so the machine must report disconnected while still live.
        channelA.close()
        try await waitUntil("disconnect observed") { !machine.isConnected }
        XCTAssertTrue(machine.isLive, "isLive tracks the subscription, not the socket")

        await machine.stop()
        XCTAssertFalse(machine.isConnected)
        XCTAssertFalse(machine.isLive)
    }

    /// ``isMachineConnected`` reports whether the *machine* is reachable from
    /// La Marzocco's cloud (distinct from ``isConnected``, our own socket):
    /// `nil` until a dashboard exists, then tracks the `connected` flag through
    /// REST refreshes and websocket pushes — while ``powerState`` keeps
    /// reporting the frozen last-known mode, which UIs must gate on the flag.
    func testIsMachineConnectedTracksCloudReachability() async throws {
        let machine = makeMachine(try fixtureBackend())
        XCTAssertNil(machine.isMachineConnected, "nil until the first dashboard")
        XCTAssertNil(machine.machineLastConnectionDate)

        try await machine.refreshDashboard()
        XCTAssertEqual(machine.isMachineConnected, true) // micra fixture: connected

        let channel = MockWebSocketChannel()
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in channel }
        channel.push(connectedFrame())
        try await machine.start()

        // The machine drops off the cloud: a husk push (one frozen
        // CMMachineStatus, as the REST husk serves) flips the flag and
        // replaces the widget set, while the frozen status widget keeps
        // reporting the stale mode.
        channel.push(messageFrame("""
        { "connected": false, "connectionDate": 1783565955166, "removedWidgets": [], "commands": [],
          "widgets": [ { "code": "CMMachineStatus", "index": 1,
            "output": { "status": "Off", "availableModes": ["BrewingMode","StandBy"], "mode": "StandBy",
                        "nextStatus": null, "brewingStartTime": null } } ] }
        """))
        try await waitUntil("offline push applied") { machine.isMachineConnected == false }
        XCTAssertEqual(machine.machineLastConnectionDate, Date(timeIntervalSince1970: 1_783_565_955.166))
        XCTAssertEqual(machine.dashboard?.widgets.count, 1, "the husk snapshot replaces the widget set")
        XCTAssertEqual(machine.powerState, .off, "powerState still derives from the frozen widget")

        channel.push(brewingPush) // routine push: carries connected:true
        try await waitUntil("online push applied") { machine.isMachineConnected == true }
        await machine.stop()
    }

    /// ``lastUpdateAt`` stamps every applied dashboard state — REST refreshes and
    /// merged pushes — so UIs can honestly show "last update Nm ago".
    func testLastUpdateAtStampsRefreshAndPush() async throws {
        let machine = makeMachine(try fixtureBackend())
        XCTAssertNil(machine.lastUpdateAt)

        try await machine.refreshDashboard()
        let afterRefresh = try XCTUnwrap(machine.lastUpdateAt)

        let channel = MockWebSocketChannel()
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in channel }
        channel.push(connectedFrame())
        try await machine.start()
        channel.push(brewingPush)
        try await waitUntil("push merged") { machine.dashboard?.machineStatus?.mode == .brewing }
        let afterPush = try XCTUnwrap(machine.lastUpdateAt)
        XCTAssertGreaterThanOrEqual(afterPush, afterRefresh)
        await machine.stop()
    }

    // MARK: - Optimistic command updates

    func testSetPowerUpdatesDashboardOptimistically() async throws {
        let machine = makeMachine(try fixtureBackend())
        try await machine.refreshDashboard()
        XCTAssertEqual(machine.powerState, .off)

        try await machine.setPower(on: true)
        XCTAssertEqual(machine.powerState, .on) // reflected without a websocket push
    }

    func testSetSteamLevelUpdatesDashboardOptimistically() async throws {
        let machine = makeMachine(try fixtureBackend())
        try await machine.refreshDashboard()

        try await machine.setSteamTargetLevel(.level1)
        XCTAssertEqual(machine.dashboard?.steamBoilerLevel?.targetLevel, .level1)
    }

    // MARK: - Model gating

    func testUnsupportedCommandThrows() async throws {
        let machine = makeMachine(try fixtureBackend())
        try await machine.refreshDashboard() // model = Micra

        // Micra supports steam *level*, not steam *temperature* (GS3 family).
        await XCTAssertThrowsErrorAsync(try await machine.setSteamTargetTemperature(celsius: 130)) { error in
            guard case LaMarzoccoError.unsupportedModel = error else {
                return XCTFail("expected unsupportedModel, got \(error)")
            }
        }
        // The supported command does not throw.
        try await machine.setSteamTargetLevel(.level2)
    }

    func testGatingThrowsBeforeModelKnown() async throws {
        let machine = makeMachine(try fixtureBackend()) // no refresh → model unknown
        await XCTAssertThrowsErrorAsync(try await machine.setBrewByWeightMode(.dose1)) { error in
            guard case LaMarzoccoError.unsupportedModel = error else {
                return XCTFail("expected unsupportedModel, got \(error)")
            }
        }
    }

    // MARK: - Snapshot

    func testSnapshotRoundTripsAndSeedsMachine() async throws {
        let machine = makeMachine(try fixtureBackend())
        try await machine.refreshAll()
        let snapshot = machine.snapshot

        let data = try snapshot.encoded()
        let restored = try MachineSnapshot(data: data)
        XCTAssertEqual(restored.serialNumber, serial)
        XCTAssertEqual(restored.dashboard?.machineStatus?.mode, machine.dashboard?.machineStatus?.mode)
        XCTAssertEqual(restored.dashboard?.coffeeBoiler?.targetTemperature,
                       machine.dashboard?.coffeeBoiler?.targetTemperature)
        XCTAssertEqual(restored.dashboard?.unknownWidgetCodes, machine.dashboard?.unknownWidgetCodes)
        XCTAssertEqual(restored.settings?.machine.serialNumber, serial)

        // A fresh machine seeded with the snapshot shows stale state immediately.
        let seeded = LaMarzoccoMachine(serialNumber: serial, client: makeClient(try fixtureBackend()),
                                       snapshot: restored)
        XCTAssertEqual(seeded.model, .lineaMicra)
        XCTAssertEqual(seeded.dashboard?.coffeeBoiler?.targetTemperature,
                       machine.dashboard?.coffeeBoiler?.targetTemperature)
    }

    func testSnapshotIgnoredWhenSerialMismatch() throws {
        let snapshot = MachineSnapshot(serialNumber: "OTHER", dashboard: nil)
        let backend = try fixtureBackend()
        let machine = LaMarzoccoMachine(serialNumber: serial, client: makeClient(backend), snapshot: snapshot)
        XCTAssertNil(machine.dashboard)
    }

    // MARK: - setSteam dual-widget optimistic (both boiler kinds)

    func testSetSteamTogglesLevelBoiler() async throws {
        let machine = makeMachine(try fixtureBackend()) // Micra → steam level
        try await machine.refreshDashboard()
        try await machine.setSteam(on: false)
        XCTAssertEqual(machine.dashboard?.steamBoilerLevel?.enabled, false)
    }

    func testSetSteamTogglesTemperatureBoiler() async throws {
        let machine = try machine(dashboardFixture: "dashboard_gs3av", serial: "GS123456") // GS3 → steam temp
        try await machine.refreshDashboard()
        try await machine.setSteam(on: false)
        XCTAssertEqual(machine.dashboard?.steamBoilerTemperature?.enabled, false)
    }

    // MARK: - Gating matrix (positive on supported models + negatives)

    func testGatedCommandsSucceedOnSupportedModels() async throws {
        // Steam temperature on a GS3 family machine.
        let gs3 = try machine(dashboardFixture: "dashboard_gs3av", serial: "GS123456")
        try await gs3.refreshDashboard()
        try await gs3.setSteamTargetTemperature(celsius: 130)
        XCTAssertEqual(gs3.dashboard?.steamBoilerTemperature?.targetTemperature, 130)

        // Brew-by-weight on a Linea Mini.
        let mini = try machine(dashboardFixture: "dashboard_mini", serial: "LM123456")
        try await mini.refreshDashboard()
        try await mini.setBrewByWeightMode(.dose1)
        XCTAssertEqual(mini.dashboard?.brewByWeightDoses?.mode, .dose1)
        try await mini.setBrewByWeightDoses(dose1: 18, dose2: 36)
        XCTAssertEqual(mini.dashboard?.brewByWeightDoses?.doses.dose1.dose, 18)
        XCTAssertEqual(mini.dashboard?.brewByWeightDoses?.doses.dose2.dose, 36)

        // Steam level on a Mini R.
        let minir = try machine(dashboardFixture: "dashboard_minir", serial: "MI123456")
        try await minir.refreshDashboard()
        try await minir.setSteamTargetLevel(.level2)
        XCTAssertEqual(minir.dashboard?.steamBoilerLevel?.targetLevel, .level2)
    }

    func testGatedCommandsThrowOnUnsupportedModels() async throws {
        // Steam level is unsupported on a GS3 (temperature-based).
        let gs3 = try machine(dashboardFixture: "dashboard_gs3av", serial: "GS123456")
        try await gs3.refreshDashboard()
        await XCTAssertThrowsErrorAsync(try await gs3.setSteamTargetLevel(.level1)) {
            guard case LaMarzoccoError.unsupportedModel = $0 else { return XCTFail("got \($0)") }
        }
        // Brew-by-weight is unsupported on a GS3.
        await XCTAssertThrowsErrorAsync(try await gs3.setBrewByWeightMode(.dose1)) {
            guard case LaMarzoccoError.unsupportedModel = $0 else { return XCTFail("got \($0)") }
        }
    }

    func testGatingFailureIsRecordedInLastError() async throws {
        let machine = makeMachine(try fixtureBackend())
        try await machine.refreshDashboard() // Micra
        _ = try? await machine.setSteamTargetTemperature(celsius: 130) // unsupported on Micra
        XCTAssertNotNil(machine.lastError)
    }

    // MARK: - lastError lifecycle

    func testLastErrorClearedOnSubsequentSuccess() async throws {
        let dashboard = try Fixture.data("dashboard_micra")
        let failFirst = MockBackend()
        failFirst.onRequest { [failFirst] req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.hasSuffix("/dashboard") {
                // The first dashboard read fails; the second (and later) succeed.
                return failFirst.count(pathSuffix: "/dashboard") == 0
                    ? MockBackend.Reply(status: 500)
                    : MockBackend.Reply(status: 200, body: dashboard)
            }
            return MockBackend.Reply(status: 404)
        }
        let machine = makeMachine(failFirst)
        _ = try? await machine.refreshDashboard()
        XCTAssertNotNil(machine.lastError)
        try await machine.refreshDashboard()
        XCTAssertNil(machine.lastError, "a subsequent success should clear the error")
    }

    // MARK: - refreshAll partial failure

    func testRefreshAllPartialFailureLeavesStateUntouched() async throws {
        let dashboard = try Fixture.data("dashboard_micra")
        let schedule = try Fixture.data("schedule")
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.hasSuffix("/dashboard") { return MockBackend.Reply(status: 200, body: dashboard) }
            if path.hasSuffix("/scheduling") { return MockBackend.Reply(status: 200, body: schedule) }
            if path.hasSuffix("/settings") { return MockBackend.Reply(status: 500) } // settings fails
            return MockBackend.Reply(status: 404)
        }
        // Seed prior state via a snapshot so we can prove it isn't clobbered.
        let seed = MachineSnapshot(serialNumber: serial,
                                   dashboard: try decodeDashboard("dashboard_gs3av"))
        let machine = LaMarzoccoMachine(serialNumber: serial, client: makeClient(backend), snapshot: nil)
        let seeded = LaMarzoccoMachine(serialNumber: serial, client: makeClient(backend), snapshot: seed)

        await XCTAssertThrowsErrorAsync(try await machine.refreshAll())
        XCTAssertNil(machine.dashboard, "no property is assigned when any endpoint fails")
        XCTAssertNotNil(machine.lastError)

        await XCTAssertThrowsErrorAsync(try await seeded.refreshAll())
        XCTAssertEqual(seeded.dashboard?.machine.model, .gs3AV, "prior snapshot state survives a failed refreshAll")
    }

    // MARK: - Live lifecycle

    func testPushIgnoredWhenDashboardNil() async throws {
        let machine = makeMachine(try fixtureBackend()) // no refresh → dashboard nil
        let channel = MockWebSocketChannel()
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in channel }
        channel.push(Stomp.encode(.connected, headers: [("version", "1.2")]))
        try await machine.start()
        channel.push(messageFrame("""
        { "connected": true, "removedWidgets": [], "commands": [],
          "widgets": [ { "code": "CMMachineStatus", "index": 1,
            "output": { "status": "PoweredOn", "availableModes": ["BrewingMode","StandBy"],
                        "mode": "BrewingMode", "nextStatus": null, "brewingStartTime": null } } ] }
        """))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(machine.dashboard, "a push with no base dashboard is dropped")
        await machine.stop()
    }

    func testStartIdempotentAndStopThenRestart() async throws {
        let machine = makeMachine(try fixtureBackend())
        try await machine.refreshDashboard()
        let channel = MockWebSocketChannel()
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in channel }
        channel.push(Stomp.encode(.connected, headers: [("version", "1.2")]))

        try await machine.start()
        try await machine.start() // idempotent: no crash, still one session
        XCTAssertTrue(machine.isLive)

        await machine.stop()
        XCTAssertFalse(machine.isLive)

        // A push after stop must not mutate the dashboard.
        let before = machine.dashboard
        channel.push(messageFrame("""
        { "connected": true, "removedWidgets": [], "commands": [],
          "widgets": [ { "code": "CMMachineStatus", "index": 1,
            "output": { "status": "PoweredOn", "availableModes": ["BrewingMode","StandBy"],
                        "mode": "BrewingMode", "nextStatus": null, "brewingStartTime": null } } ] }
        """))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(machine.dashboard, before, "no merge after stop()")

        // Restart succeeds (updateTask was cleared).
        let channel2 = MockWebSocketChannel()
        await machine.clientForTesting.setWebSocketFactoryForTesting { _ in channel2 }
        channel2.push(Stomp.encode(.connected, headers: [("version", "1.2")]))
        try await machine.start()
        XCTAssertTrue(machine.isLive)
        await machine.stop()
    }

    // MARK: - Grinder

    func testGrinderPowerStateAndBaristaLight() async throws {
        let machine = try machine(dashboardFixture: "dashboard_pico", serial: "GR123456")
        try await machine.refreshDashboard()
        XCTAssertEqual(machine.model, .pico)
        XCTAssertEqual(machine.powerState, .off) // grinder in StandBy
        XCTAssertEqual(machine.dashboard?.grinderBaristaLight?.enabled, true)

        try await machine.setGrinderBaristaLight(on: false)
        XCTAssertEqual(machine.dashboard?.grinderBaristaLight?.enabled, false) // optimistic
    }

    // MARK: - Smart standby dispatch (auto-standby branch)

    private func commandBody(_ backend: MockBackend, _ command: String) throws -> [String: Any]? {
        guard let data = backend.body(pathSuffix: "/command/\(command)") else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testSmartStandbyUsesAutoStandbyWhenSupported() async throws {
        // The Micra schedule fixture reports autoStandBySupported = true, so the
        // device layer must dispatch the auto-standby command with an HH:MM string
        // (matching pylamarzocco's set_smart_standby), not CoffeeMachineSettingSmartStandBy.
        let backend = try fixtureBackend()
        let machine = makeMachine(backend)
        try await machine.refreshSchedule()
        XCTAssertEqual(machine.schedule?.autoStandBySupported, true)

        try await machine.setSmartStandby(enabled: true, minutes: 90, after: .powerOn)
        XCTAssertEqual(try commandBody(backend, "CoffeeMachineSettingAutoStandBy")?["mode"] as? String, "01:30")
        XCTAssertEqual(backend.count(pathSuffix: "/command/CoffeeMachineSettingSmartStandBy"), 0)

        // Disabling sends the "Off" sentinel.
        try await machine.setSmartStandby(enabled: false, minutes: 90, after: .powerOn)
        XCTAssertEqual(try commandBody(backend, "CoffeeMachineSettingAutoStandBy")?["mode"] as? String, "Off")
    }

    func testSmartStandbyFallsBackToSmartStandbyCommand() async throws {
        // With no schedule loaded (autoStandBySupported unknown), the legacy
        // smart-standby command is used.
        let backend = try fixtureBackend()
        let machine = makeMachine(backend)
        try await machine.setSmartStandby(enabled: true, minutes: 10, after: .powerOn)
        let b = try XCTUnwrap(try commandBody(backend, "CoffeeMachineSettingSmartStandBy"))
        XCTAssertEqual(b["minutes"] as? Int, 10)
        XCTAssertEqual(backend.count(pathSuffix: "/command/CoffeeMachineSettingAutoStandBy"), 0)
    }

    // MARK: - Statistics

    func testRefreshStatistics() async throws {
        let machine = makeMachine(try fixtureBackend())
        try await machine.refreshStatistics()
        XCTAssertEqual(machine.statistics?.coffeeAndFlushCounter?.totalCoffee, 1620)
        XCTAssertEqual(machine.statistics?.coffeeAndFlushTrend?.coffees.count, 7)
    }

    // MARK: - Snapshot fidelity across models

    func testSnapshotRoundTripsAllRecognizedFixtures() throws {
        for name in ["dashboard_gs3av", "dashboard_mini", "dashboard_minir", "dashboard_pico"] {
            let d = try decodeDashboard(name)
            XCTAssertEqual(d.unknownWidgetCodes, [], "\(name) should fully decode")
            let restored = try XCTUnwrap(MachineSnapshot(data: MachineSnapshot(serialNumber: d.machine.serialNumber, dashboard: d).encoded()).dashboard)
            XCTAssertEqual(restored, d, "\(name) must round-trip losslessly through a snapshot")
        }
    }

    func testSnapshotPreservesUnknownWidgetCodeButDropsPayload() throws {
        let json = """
        { "serialNumber": "SN9", "modelName": "Linea Micra",
          "widgets": [
            { "code": "CMMachineStatus", "index": 1,
              "output": { "status": "StandBy", "availableModes": ["StandBy"], "mode": "StandBy", "nextStatus": null, "brewingStartTime": null } },
            { "code": "CMFutureGizmo", "index": 2, "output": { "wat": true } }
          ] }
        """
        let d = try JSONDecoder.laMarzocco().decode(Dashboard.self, from: Data(json.utf8))
        XCTAssertEqual(d.unknownWidgetCodes, ["CMFutureGizmo"])

        let restored = try XCTUnwrap(MachineSnapshot(data: MachineSnapshot(serialNumber: "SN9", dashboard: d).encoded()).dashboard)
        XCTAssertEqual(restored.unknownWidgetCodes, ["CMFutureGizmo"], "unknown code + index preserved")
        XCTAssertNotNil(restored.machineStatus, "recognized widgets still round-trip")
        XCTAssertEqual(restored.widgets.count, 2)
    }

    // MARK: - Helpers

    private func waitUntil(_ message: String = "condition", _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(message)")
    }
}

/// Async variant of `XCTAssertThrowsError`.
@MainActor
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "expected an error to be thrown" : message, file: file, line: line)
    } catch {
        handler(error)
    }
}
