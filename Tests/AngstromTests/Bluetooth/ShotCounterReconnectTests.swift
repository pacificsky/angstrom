import XCTest
@testable import Angstrom
import AngstromTestSupport

/// Parity suite for the shot-counter reconnect loop (SPEC §4.13, D14, D15): upstream C32–C35 plus the
/// reconnect gaps G-RC-1/2/3/5 and G-SC-7. Unlike upstream, which patches `RECONNECT_INITIAL_DELAY` to 0,
/// every backoff duration is asserted from `ManualBluetoothSleeper.requested(.reconnectBackoff)` (§9.2).
final class ShotCounterReconnectTests: XCTestCase {
    private let auth = BluetoothConstants.authCharacteristic
    private let shotCounter = BluetoothConstants.shotCounterCharacteristic
    private let tokenWrite = Data("token".utf8)
    private let start = Date(timeIntervalSince1970: 1_000)
    /// `REPLAY` (`tests/test_bluetooth_client.py:811`): a telemetry-only notification, used as a sentinel
    /// that proves every notification before it was handled.
    private let replay = Data(#"{"MachineMode":"StandBy"}"#.utf8)
    /// The `0e0b…` give-up error of §4.13, verbatim.
    private let shotCounterMissing = LaMarzoccoError.bluetoothConnectionFailed(
        "Could not find characteristic 0e0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")

    // MARK: - Upstream parity (C32–C35)

    /// Upstream: test_shot_counter_reconnects_after_disconnect (tests/test_bluetooth_client.py:1022) [C32, BT-NTF-RESET-001]
    func testReconnectsAndResetsTrackerAfterLinkLoss() async throws {
        let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        let first = try await startCounter(rig)

        // The running shot must be forgotten on disconnect.
        first.notify(shotCounter, BluetoothTestVectors.started, at: start)
        guard await fulfilled([events.expectation { $0.count >= 2 }], "the shot started") else {
            await client.disconnect()
            return
        }
        let probeAt = start
        let beforeLoss = await client.inspect { client in
            var copy = client.tracker
            return copy.process(BluetoothBrewingData(backflush: false), receivedAt: probeAt)?.state
        }
        XCTAssertEqual(beforeLoss, .brewing, "premise: the probe fragment completes the running shot")

        first.drop(.disconnected(code: 7))

        // The loop is in its first backoff sleep: the loss has been handled.
        guard await reachedPending(rig, .reconnectBackoff, "first reconnect backoff") else {
            await client.disconnect()
            return
        }
        guard await fulfilled([events.expectation { $0.count >= 3 }], "loss reported") else {
            await client.disconnect()
            return
        }
        XCTAssertEqual(events.elements, [.subscribed, .brewing(startedUpdate(at: start)), .unsubscribed])
        let lost = await client.inspect { client in
            var copy = client.tracker
            return (client.shotCounterActive, client.isConnected, client.shotCounterEnabled,
                    copy.process(BluetoothBrewingData(backflush: false), receivedAt: probeAt)?.state)
        }
        XCTAssertFalse(lost.0, "not active after the loss")
        XCTAssertFalse(lost.1)
        XCTAssertTrue(lost.2, "still enabled: it reconnects")
        XCTAssertNil(lost.3, "the tracker was replaced at loss time")
        XCTAssertEqual(rig.central.connectCount, 1)
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
        guard await fulfilled([connection.expectation { $0.count >= 2 }], "connection lost reported") else {
            await client.disconnect()
            return
        }
        XCTAssertEqual(connection.elements, [.connected, .disconnected])

        rig.sleeper.fire(.reconnectBackoff)
        guard await fulfilled([events.expectation { $0.count >= 4 }], "resubscribed") else {
            await client.disconnect()
            return
        }
        await client.drainBackgroundWorkForTesting()

        XCTAssertEqual(events.elements, [.subscribed, .brewing(startedUpdate(at: start)), .unsubscribed, .subscribed])
        // establish_connection and start_notify were each awaited twice.
        XCTAssertEqual(rig.central.connectCount, 2)
        let links = rig.central.links
        XCTAssertEqual(links.count, 2)
        let second = try XCTUnwrap(links.last)
        XCTAssertEqual(first.recordedOps.filter { $0 == .subscribe(shotCounter) }.count, 1)
        XCTAssertEqual(second.recordedOps, [.discover(refresh: false), .write(auth, tokenWrite), .read(auth),
                                            .subscribe(shotCounter)])
        let active = await client.inspect { ($0.shotCounterActive, $0.reconnectTask == nil, $0.link === second) }
        XCTAssertTrue(active.0)
        XCTAssertTrue(active.1, "a successful reconnect clears reconnectTask")
        XCTAssertTrue(active.2)
        guard await fulfilled([connection.expectation { $0.count >= 3 }], "reconnected reported") else {
            await client.disconnect()
            return
        }
        XCTAssertEqual(connection.elements, [.connected, .disconnected, .connected])

        // BT-NTF-RESET-001: the new subscription dropped the replay (the fake's default tick, which would
        // emit `.brewing`) and nothing of the shot is left (with the old tracker this fragment derives
        // `.brewing` from the earlier START). The telemetry sentinel proves the fragment was handled.
        second.notify(shotCounter, Data(#"{"BrewingUpdateGroup1Backflush":false}"#.utf8), at: start)
        second.notify(shotCounter, replay, at: start)
        guard await fulfilled([events.expectation { $0.count >= 5 }], "sentinel delivered") else {
            await client.disconnect()
            return
        }
        XCTAssertEqual(events.elements, [.subscribed, .brewing(startedUpdate(at: start)), .unsubscribed, .subscribed,
                                         .telemetry(BluetoothMachineTelemetry(machineMode: .standby))])

        await client.disconnect()
    }

    /// Upstream: test_shot_counter_reconnect_retries_failed_connections (tests/test_bluetooth_client.py:1053) [C33]
    ///
    /// Restated counts (SPEC §9.4): upstream mocks `establish_connection` (3 attempts inside) as one call; here
    /// `central.connect` is one attempt, so failing a whole reconnect attempt takes 3 failures (§4.2 step 4).
    /// Initial 1 + attempt 1 (3 × `.disconnected`) + attempt 2 (3 × `.timedOut`) + the successful 1 = 8.
    func testReconnectRetriesThroughConnectErrors() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        let first = try await startCounter(rig)

        for _ in 0..<3 { rig.central.enqueueConnect(.failure(.disconnected(code: 7))) }
        for _ in 0..<3 { rig.central.enqueueConnect(.failure(.timedOut("connect"))) }
        first.drop(.disconnected(code: 7))

        guard await fulfilled([events.expectation { $0.count >= 3 }], "resubscribed") else {
            await client.disconnect()  // cancels a loop that never ends, so the test cannot hang
            return
        }
        await client.drainBackgroundWorkForTesting()

        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])
        XCTAssertEqual(rig.central.connectCount, 8)
        XCTAssertEqual(rig.central.links.count, 2, "only the initial and the successful attempt made a link")
        // Sleeps before every attempt; doubles after each connection failure.
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2), .seconds(4)])
        // Inside each failed ensureConnected: 0.1 s after a non-timeout failure, 0.25 s after a timeout.
        XCTAssertEqual(rig.sleeper.requested(.connectBackoff),
                       [.milliseconds(100), .milliseconds(100), .milliseconds(250), .milliseconds(250)])
        let state = await client.inspect { ($0.shotCounterActive, $0.reconnectTask == nil) }
        XCTAssertTrue(state.0)
        XCTAssertTrue(state.1)
        guard await fulfilled([connection.expectation { $0.count >= 3 }], "connection events") else {
            await client.disconnect()
            return
        }
        XCTAssertEqual(connection.elements, [.connected, .disconnected, .connected])
        await client.disconnect()
    }

    /// Upstream: test_shot_counter_gives_up_after_auth_failures (tests/test_bluetooth_client.py:1072) [C34]
    func testGivesUpAfterThreeAuthFailures() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        let first = try await startCounter(rig)

        // The machine was paired again with another token.
        rig.central.makeLink = { .laMarzocco(token: "other") }
        first.drop(.disconnected(code: 7))

        guard await fulfilled([events.expectation { $0.count >= 3 }], "gave up") else {
            await client.disconnect()  // cancels a loop that never gives up, so the test cannot hang
            return
        }
        await client.drainBackgroundWorkForTesting()

        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .gaveUp(.bluetoothAuthenticationFailed)])
        // Initial connection + 3 failed reconnects: auth failures are not retried inside a connect.
        XCTAssertEqual(rig.central.connectCount, 4)
        // Auth failures never double the delay.
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(1), .seconds(1)])
        // Each failed login polls 10 reads with 9 sleeps of 50 ms.
        XCTAssertEqual(rig.sleeper.requested(.authPoll), Array(repeating: .milliseconds(50), count: 27))
        for failed in rig.central.links.dropFirst() {
            XCTAssertEqual(failed.recordedOps, authFailedOps, "an unauthenticated link is never kept")
        }
        let state = await client.inspect {
            ($0.authenticationFailed, $0.shotCounterActive, $0.isConnected, $0.shotCounterEnabled,
             $0.hasBackgroundWorkForTesting)
        }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertFalse(state.2)
        XCTAssertFalse(state.3)
        XCTAssertFalse(state.4, "no background tasks")
        guard await fulfilled([connection.expectation { $0.count >= 2 }], "connection events") else { return }
        XCTAssertEqual(connection.elements, [.connected, .disconnected], "a failed login is never reported connected")
    }

    /// Upstream: test_shot_counter_no_reconnect_after_disconnect (tests/test_bluetooth_client.py:1094) [C35]
    func testUserDisconnectDoesNotReconnect() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let first = try await startCounter(rig)

        // The fake reports the user disconnect as `.disconnected` too, like bleak (§9.2).
        await client.disconnect()
        await client.drainBackgroundWorkForTesting()

        XCTAssertEqual(rig.central.connectCount, 1, "establish_connection awaited once")
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [], "no reconnect loop ran")
        XCTAssertEqual(Array(first.recordedOps.suffix(2)), [.unsubscribe(shotCounter), .disconnect])
        let state = await client.inspect {
            ($0.isConnected, $0.shotCounterEnabled, $0.reconnectTask == nil, $0.hasBackgroundWorkForTesting)
        }
        XCTAssertFalse(state.0)
        XCTAssertFalse(state.1)
        XCTAssertTrue(state.2)
        XCTAssertFalse(state.3)
        guard await fulfilled([events.expectation { $0.count >= 2 }], "unsubscribed") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed])
    }

    // MARK: - Angstrom-only (gaps and divergences)

    /// Angstrom-only: G-RC-1 — the backoff is 1, 2, 4, 8, 16, 32, 60, 60 s and doubles only after connection-class failures
    func testBackoffSequence() async throws {
        // Every reconnect attempt fails to connect: the delay doubles up to the 60 s cap.
        do {
            let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
            let client = rig.client
            let events = Recorder(await client.shotCounterEvents())
            let first = try await startCounter(rig)
            rig.central.connectFailure = .disconnected(code: 7)
            first.drop(.disconnected(code: 7))

            let expected: [Duration] = [1, 2, 4, 8, 16, 32, 60, 60].map { .seconds($0) }
            for index in expected.indices {
                guard await reachedPending(rig, .reconnectBackoff, "backoff sleep \(index + 1)") else {
                    await client.disconnect()
                    return
                }
                XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), Array(expected.prefix(index + 1)))
                XCTAssertEqual(rig.central.connectCount, 1 + 3 * index, "3 connect attempts per failed reconnect")
                if index == expected.count - 1 {
                    rig.central.connectFailure = nil  // the 8th attempt succeeds
                }
                rig.sleeper.fire(.reconnectBackoff)
            }
            guard await fulfilled([events.expectation { $0.count >= 3 }], "resubscribed") else {
                await client.disconnect()
                return
            }
            await client.drainBackgroundWorkForTesting()
            XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])
            XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), expected, "no sleep after the success")
            XCTAssertEqual(rig.central.connectCount, 1 + 3 * 7 + 1)
            XCTAssertEqual(rig.sleeper.requested(.connectBackoff), Array(repeating: .milliseconds(100), count: 14))
            await client.disconnect()
        }

        // Connection failure, auth failure, connection failure, success: the auth failure keeps the delay.
        do {
            let rig = makeRig()
            let client = rig.client
            let events = Recorder(await client.shotCounterEvents())
            let first = try await startCounter(rig)
            for _ in 0..<3 { rig.central.enqueueConnect(.failure(.disconnected(code: 7))) }
            rig.central.enqueueConnect(.success(.laMarzocco(token: "other")))
            for _ in 0..<3 { rig.central.enqueueConnect(.failure(.timedOut("connect"))) }
            first.drop(.disconnected(code: 7))

            guard await fulfilled([events.expectation { $0.count >= 3 }], "resubscribed") else {
                await client.disconnect()
                return
            }
            await client.drainBackgroundWorkForTesting()
            XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])
            XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2), .seconds(2), .seconds(4)])
            XCTAssertEqual(rig.central.connectCount, 1 + 3 + 1 + 3 + 1)
            let state = await client.inspect { ($0.shotCounterActive, $0.authenticationFailed) }
            XCTAssertTrue(state.0)
            XCTAssertFalse(state.1, "the successful login cleared the flag")
            await client.disconnect()
        }
    }

    /// Angstrom-only: G-RC-2 — auth failures are counted per loop run, not in a row (D15): auth, connection error, auth, auth gives up
    func testAuthFailuresAreCumulative() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let first = try await startCounter(rig)

        rig.central.enqueueConnect(.success(.laMarzocco(token: "other")))
        for _ in 0..<3 { rig.central.enqueueConnect(.failure(.disconnected(code: 7))) }
        rig.central.enqueueConnect(.success(.laMarzocco(token: "other")))
        rig.central.enqueueConnect(.success(.laMarzocco(token: "other")))
        // A fifth attempt (only reached with "in a row" counting) would get the default, accepting machine.
        first.drop(.disconnected(code: 7))

        guard await fulfilled([events.expectation { $0.count >= 3 }], "gave up") else {
            await client.disconnect()
            return
        }
        await client.drainBackgroundWorkForTesting()

        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .gaveUp(.bluetoothAuthenticationFailed)])
        XCTAssertEqual(rig.central.connectCount, 1 + 1 + 3 + 1 + 1, "no fifth attempt")
        // 1 s first; an auth failure keeps it; the connection error doubles it; the next auth failure keeps it.
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(1), .seconds(2), .seconds(2)])
        let links = rig.central.links
        XCTAssertEqual(links.count, 4)
        for failed in links.dropFirst() {
            XCTAssertEqual(failed.recordedOps, authFailedOps)
        }
        let state = await client.inspect {
            ($0.authenticationFailed, $0.shotCounterActive, $0.shotCounterEnabled, $0.isConnected,
             $0.hasBackgroundWorkForTesting)
        }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertFalse(state.2)
        XCTAssertFalse(state.3)
        XCTAssertFalse(state.4)
    }

    /// Angstrom-only: G-RC-3 — the characteristic disappears during a reconnect: give up, the idle timer is re-armed, no second `.unsubscribed`
    func testCharacteristicGoneGivesUp() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        let first = try await startCounter(rig)

        rig.central.makeLink = { Self.linkWithoutShotCounter() }
        first.drop(nil)

        guard await fulfilled([events.expectation { $0.count >= 3 }], "gave up") else {
            await client.disconnect()
            return
        }
        await client.drainBackgroundWorkForTesting()

        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .gaveUp(shotCounterMissing)])
        // One reconnect attempt: the cached pass, a disconnect, then the rediscovery pass.
        XCTAssertEqual(rig.central.connectCount, 3)
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
        let links = rig.central.links
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[1].recordedOps, [.discover(refresh: false), .write(auth, tokenWrite), .read(auth), .disconnect])
        XCTAssertEqual(links[2].recordedOps, [.discover(refresh: true), .write(auth, tokenWrite), .read(auth)])
        let state = await client.inspect {
            ($0.isConnected, $0.shotCounterEnabled, $0.shotCounterActive, $0.reconnectTask == nil, $0.link === links[2])
        }
        XCTAssertTrue(state.0, "the link of the rediscovery pass stays up")
        XCTAssertFalse(state.1)
        XCTAssertFalse(state.2)
        XCTAssertTrue(state.3)
        XCTAssertTrue(state.4)

        // The idle timer was re-armed (none ran while the counter was enabled) and closes the link.
        guard await reachedPending(rig, .idleDisconnect, "idle timer re-armed") else {
            await client.disconnect()
            return
        }
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect), [.seconds(30)])
        rig.sleeper.fire(.idleDisconnect)
        guard await fulfilled([connection.expectation { $0.count >= 6 }], "idle disconnect") else {
            await client.disconnect()
            return
        }
        await client.drainBackgroundWorkForTesting()
        XCTAssertEqual(connection.elements, [.connected, .disconnected, .connected, .disconnected, .connected, .disconnected])
        XCTAssertEqual(links[2].recordedOps.last, .disconnect)
        XCTAssertEqual(rig.central.connectCount, 3, "the idle drop starts no loop: the counter is disabled")
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .gaveUp(shotCounterMissing)],
                       "no second .unsubscribed")
    }

    /// Angstrom-only: G-RC-5 — an idle drop or an error-path drop while the counter is enabled starts the reconnect loop
    func testIdleOrErrorDropWhileEnabledReconnects() async throws {
        // Idle path: the idle timer's drop holds the connection gate when the counter is started. The
        // drop sees the counter enabled, so it starts the loop; the queued start subscribes on a new
        // link, and the loop then finds it subscribed.
        do {
            let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
            let client = rig.client
            let events = Recorder(await client.shotCounterEvents())
            let connection = Recorder(await client.connectionEvents())
            let first = FakeBluetoothLink.laMarzocco(token: "token",
                                                     settingResponses: [.machineMode: Data(#""BrewingMode""#.utf8)])
            let dropHeld = expectation(description: "the idle drop is disconnecting")
            let release = Latch()
            first.beforeOp = { op in
                guard op == .disconnect else { return }
                dropHeld.fulfill()
                await release.wait()
            }
            rig.central.enqueueConnect(.success(first))

            // A plain request connects and arms the idle timer.
            let mode = try await client.machineMode()
            XCTAssertEqual(mode, .brewing)
            guard await reachedPending(rig, .idleDisconnect, "idle timer armed") else {
                release.open()
                await client.disconnect()
                return
            }
            rig.sleeper.fire(.idleDisconnect)
            guard await fulfilled([dropHeld], "the idle drop reached the disconnect") else {
                release.open()
                await client.disconnect()
                return
            }

            let queued = expectation(description: "start enabled the counter")
            let starting = Task { try await client.startShotCounterSignalling { queued.fulfill() } }
            guard await fulfilled([queued], "start entered") else {
                release.open()
                await client.disconnect()
                return
            }
            let premise = await client.inspect { ($0.shotCounterEnabled, $0.link == nil, $0.reconnectTask == nil) }
            XCTAssertTrue(premise.0, "premise: enabled while the idle drop runs")
            XCTAssertTrue(premise.1)
            XCTAssertTrue(premise.2, "premise: no loop yet")
            release.open()

            let started = try await starting.value
            XCTAssertTrue(started)
            guard await reachedPending(rig, .reconnectBackoff, "the idle drop started the loop") else {
                await client.disconnect()
                return
            }
            XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
            XCTAssertEqual(rig.central.connectCount, 2)
            rig.sleeper.fire(.reconnectBackoff)
            await client.drainBackgroundWorkForTesting()

            XCTAssertEqual(rig.central.connectCount, 2, "the loop found the counter subscribed: no new connection")
            XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
            let links = rig.central.links
            XCTAssertEqual(links.count, 2)
            XCTAssertEqual(first.recordedOps.last, .disconnect)
            XCTAssertEqual(links[1].recordedOps.filter { $0 == .subscribe(shotCounter) }.count, 1)
            let state = await client.inspect { ($0.shotCounterActive, $0.reconnectTask == nil, $0.link === links[1]) }
            XCTAssertTrue(state.0)
            XCTAssertTrue(state.1)
            XCTAssertTrue(state.2)
            guard await fulfilled([events.expectation { !$0.isEmpty },
                                   connection.expectation { $0.count >= 3 }], "events") else {
                await client.disconnect()
                return
            }
            XCTAssertEqual(events.elements, [.subscribed], "not subscribed at drop time: no .unsubscribed, one .subscribed")
            XCTAssertEqual(connection.elements, [.connected, .disconnected, .connected])
            await client.disconnect()
        }

        // Error path: a request for a characteristic the machine lacks drops the link even while the
        // counter runs (§4.5 step 4); the drop sees the counter enabled and reconnects.
        do {
            let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
            let client = rig.client
            let events = Recorder(await client.shotCounterEvents())
            let first = FakeBluetoothLink.laMarzocco(token: "token")
            first.present = [BluetoothConstants.writeCharacteristic, BluetoothConstants.tokenCharacteristic,
                             BluetoothConstants.authCharacteristic, BluetoothConstants.shotCounterCharacteristic]
            rig.central.enqueueConnect(.success(first))
            let started = try await client.startShotCounter()
            XCTAssertTrue(started)

            do {
                _ = try await client.machineMode()
                XCTFail("expected the missing read characteristic to fail the request")
            } catch {
                XCTAssertEqual(error as? LaMarzoccoError, .bluetoothConnectionFailed(
                    "Could not find characteristic 0a0b7847-e12b-09a8-b04b-8e0922a9abab on machine."))
            }
            guard await reachedPending(rig, .reconnectBackoff, "the error drop started the loop") else {
                await client.disconnect()
                return
            }
            XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
            XCTAssertEqual(first.recordedOps, [.discover(refresh: false), .write(auth, tokenWrite), .read(auth),
                                               .subscribe(shotCounter), .discover(refresh: true), .disconnect])
            guard await fulfilled([events.expectation { $0.count >= 2 }], "unsubscribed") else {
                await client.disconnect()
                return
            }
            XCTAssertEqual(events.elements, [.subscribed, .unsubscribed])

            rig.sleeper.fire(.reconnectBackoff)
            guard await fulfilled([events.expectation { $0.count >= 3 }], "resubscribed") else {
                await client.disconnect()
                return
            }
            await client.drainBackgroundWorkForTesting()
            XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])
            XCTAssertEqual(rig.central.connectCount, 2)
            let active = await client.shotCounterActive
            XCTAssertTrue(active)
            await client.disconnect()
        }
    }

    /// Angstrom-only: G-SC-7 — the loop sleeps the initial 1 s before its first attempt
    func testFirstAttemptWaitsInitialDelay() async throws {
        let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let first = try await startCounter(rig)
        first.drop(.disconnected(code: 7))

        guard await reachedPending(rig, .reconnectBackoff, "first backoff sleep") else {
            await client.disconnect()
            return
        }
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
        XCTAssertEqual(rig.central.connectCount, 1, "no attempt before the first sleep")
        let waiting = await client.inspect { ($0.reconnectTask != nil, $0.isConnected) }
        XCTAssertTrue(waiting.0)
        XCTAssertFalse(waiting.1)

        rig.sleeper.fire(.reconnectBackoff)
        guard await fulfilled([events.expectation { $0.count >= 3 }], "resubscribed") else {
            await client.disconnect()
            return
        }
        await client.drainBackgroundWorkForTesting()
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])
        XCTAssertEqual(rig.central.connectCount, 2)
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
        await client.disconnect()
    }

    /// Angstrom-only: D14 — Bluetooth returning to `.poweredOn` ends the pending backoff early and resets the delay to 1 s
    func testPoweredOnCutsBackoffShort() async throws {
        let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let first = try await startCounter(rig)
        rig.central.connectFailure = .disconnected(code: 7)
        first.drop(.disconnected(code: 7))

        guard await reachedPending(rig, .reconnectBackoff, "first backoff sleep") else {
            await client.disconnect()
            return
        }
        // The loop's availability stream exists by its first sleep (§4.13).
        XCTAssertGreaterThanOrEqual(rig.central.availabilitySubscriberCount, 1)
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
        rig.sleeper.fire(.reconnectBackoff)
        guard await reachedPending(rig, .reconnectBackoff, "second backoff sleep") else {
            await client.disconnect()
            return
        }
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2)])
        rig.sleeper.fire(.reconnectBackoff)
        guard await reachedPending(rig, .reconnectBackoff, "third backoff sleep") else {
            await client.disconnect()
            return
        }
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2), .seconds(4)])
        XCTAssertEqual(rig.central.connectCount, 7)

        // The attempt after the cut is held at its discovery so the sleeper can be inspected while it
        // runs; it then fails (no auth characteristic), a connection-class failure.
        let attemptStarted = expectation(description: "attempt after the power-on")
        let release = Latch()
        let noAuth = FakeBluetoothLink()
        noAuth.present = [BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
                          BluetoothConstants.shotCounterCharacteristic]
        noAuth.beforeOp = { op in
            guard op == .discover(refresh: false) else { return }
            attemptStarted.fulfill()
            await release.wait()
        }
        rig.central.enqueueConnect(.success(noAuth))

        rig.central.setAvailability(.poweredOff)
        rig.central.setAvailability(.poweredOn)
        guard await fulfilled([attemptStarted], "the power-on cut the 4 s backoff short") else {
            release.open()
            await client.disconnect()  // cancels the loop's manual sleep, so the test ends
            return
        }
        XCTAssertEqual(rig.sleeper.pendingCount(.reconnectBackoff), 0, "the cut sleep is no longer pending")
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2), .seconds(4)],
                       "the 4 s sleep was never fired")
        XCTAssertEqual(rig.central.connectCount, 8)
        release.open()

        // Reset to 1 s, then doubled by the failed attempt: 2 s (without the reset it would be 8 s).
        guard await reachedPending(rig, .reconnectBackoff, "backoff after the reset") else {
            await client.disconnect()
            return
        }
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2), .seconds(4), .seconds(2)])
        XCTAssertEqual(noAuth.recordedOps, [.discover(refresh: false), .disconnect])

        rig.central.connectFailure = nil
        rig.sleeper.fire(.reconnectBackoff)
        guard await fulfilled([events.expectation { $0.count >= 3 }], "resubscribed") else {
            await client.disconnect()
            return
        }
        await client.drainBackgroundWorkForTesting()
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])
        XCTAssertEqual(rig.central.connectCount, 9)
        let active = await client.shotCounterActive
        XCTAssertTrue(active)
        await client.disconnect()
    }

    /// Angstrom-only: D15 — `.gaveUp` carries the last error of the loop run and is emitted only when the loop gives up by itself
    func testGaveUpCarriesLastError() async throws {
        // Auth failure, then a connection error, then the characteristic is gone: the earlier errors are
        // replaced by the last one.
        do {
            let rig = makeRig()
            let client = rig.client
            let events = Recorder(await client.shotCounterEvents())
            let first = try await startCounter(rig)
            rig.central.enqueueConnect(.success(.laMarzocco(token: "other")))
            for _ in 0..<3 { rig.central.enqueueConnect(.failure(.timedOut("connect"))) }
            rig.central.makeLink = { Self.linkWithoutShotCounter() }
            first.drop(.disconnected(code: 7))

            guard await fulfilled([events.expectation { $0.count >= 3 }], "gave up") else {
                await client.disconnect()
                return
            }
            await client.drainBackgroundWorkForTesting()
            XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .gaveUp(shotCounterMissing)])
            XCTAssertEqual(rig.central.connectCount, 1 + 1 + 3 + 2)
            XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(1), .seconds(2)])
            let state = await client.inspect { ($0.authenticationFailed, $0.shotCounterEnabled, $0.reconnectTask == nil) }
            XCTAssertFalse(state.0, "the last login succeeded")
            XCTAssertFalse(state.1)
            XCTAssertTrue(state.2)
            await client.disconnect()
            XCTAssertEqual(events.elements.count, 3, "nothing after .gaveUp")
        }

        // A stop while the loop waits (after an auth failure set its last error): no `.gaveUp`, and no
        // second `.unsubscribed`.
        do {
            let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
            let client = rig.client
            let events = Recorder(await client.shotCounterEvents())
            let first = try await startCounter(rig)
            rig.central.enqueueConnect(.success(.laMarzocco(token: "other")))
            first.drop(.disconnected(code: 7))

            guard await reachedPending(rig, .reconnectBackoff, "first backoff sleep") else {
                await client.disconnect()
                return
            }
            rig.sleeper.fire(.reconnectBackoff)
            guard await reachedPending(rig, .reconnectBackoff, "backoff after the auth failure") else {
                await client.disconnect()
                return
            }
            XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(1)])
            XCTAssertEqual(rig.central.connectCount, 2)
            let pendingLoop = await client.inspect { $0.reconnectTask }
            let loop = try XCTUnwrap(pendingLoop)

            await client.stopShotCounter()
            await loop.value  // the cancelled loop has ended
            await client.drainBackgroundWorkForTesting()

            XCTAssertEqual(rig.sleeper.pendingCount(.reconnectBackoff), 0, "the sleep was cancelled")
            XCTAssertEqual(rig.central.connectCount, 2, "no attempt after the stop")
            XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(1)])
            let state = await client.inspect { ($0.shotCounterEnabled, $0.reconnectTask == nil, $0.authenticationFailed) }
            XCTAssertFalse(state.0)
            XCTAssertTrue(state.1)
            XCTAssertTrue(state.2)
            guard await fulfilled([events.expectation { $0.count >= 2 }], "events") else { return }
            XCTAssertEqual(events.elements, [.subscribed, .unsubscribed], "no .gaveUp after a stop")
        }
    }

    // MARK: - Helpers

    private struct Rig {
        let central: FakeBluetoothCentral
        let sleeper: ManualBluetoothSleeper
        let client: LaMarzoccoBluetoothClient
    }

    private func makeRig(manual: Set<SleepPurpose> = [.idleDisconnect]) -> Rig {
        let central = FakeBluetoothCentral()
        let sleeper = ManualBluetoothSleeper(manual: manual)
        let clock = BluetoothTestClock(start)
        let client = LaMarzoccoBluetoothClient(transport: .fake(central, sleeper: sleeper, clock: clock),
                                               peripheral: .fake, token: BluetoothAuthToken("token"))
        return Rig(central: central, sleeper: sleeper, client: client)
    }

    /// Starts the shot counter on a fresh accepting machine (the fake's default replay is dropped) and
    /// returns its link.
    private func startCounter(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async throws -> FakeBluetoothLink {
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        rig.central.enqueueConnect(.success(link))
        let started = try await rig.client.startShotCounter()
        XCTAssertTrue(started, "premise: the shot counter started", file: file, line: line)
        XCTAssertEqual(rig.central.connectCount, 1, file: file, line: line)
        return link
    }

    /// The ops of a link whose login the machine rejects: 10 auth reads, then the link is dropped.
    private var authFailedOps: [FakeOp] {
        [.discover(refresh: false), .write(auth, tokenWrite)]
            + Array(repeating: FakeOp.read(auth), count: 10)
            + [.disconnect]
    }

    /// The update for `STARTED` on a fresh tracker.
    private func startedUpdate(at receivedAt: Date) -> BluetoothShotCounterUpdate {
        BluetoothShotCounterUpdate(state: .brewing, timerValue: 0.0, startedDoseIndex: "DoseA", receivedAt: receivedAt,
                                   raw: BluetoothBrewingData(startedDoseIndex: "DoseA"), brewingStartTime: receivedAt)
    }

    /// An accepting machine whose service table has no shot-counter characteristic, also after a refresh.
    private static func linkWithoutShotCounter() -> FakeBluetoothLink {
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.present = [BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
                        BluetoothConstants.tokenCharacteristic, BluetoothConstants.authCharacteristic]
        return link
    }

    /// `fulfillment(of:timeout:)` that also reports whether everything was fulfilled, so a test can stop
    /// (cancelling its background work) instead of hanging in a later unbounded wait.
    private func fulfilled(_ expectations: [XCTestExpectation], _ message: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let result = await XCTWaiter().fulfillment(of: expectations, timeout: timeout)
        guard result == .completed else {
            XCTFail("\(message): \(result)", file: file, line: line)
            return false
        }
        return true
    }

    /// `sleeper.waitForPending(purpose, count: 1)` with a 5 s hang guard (no polling).
    private func reachedPending(_ rig: Rig, _ purpose: SleepPurpose, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let reached = XCTestExpectation(description: message)
        let sleeper = rig.sleeper
        let waiter = Task {
            await sleeper.waitForPending(purpose, count: 1)
            if !Task.isCancelled { reached.fulfill() }
        }
        let ok = await fulfilled([reached], message, file: file, line: line)
        if !ok { waiter.cancel() }
        return ok
    }
}

// MARK: - Private test doubles

/// Records every element of a stream from creation on; expectations fire once a predicate over
/// everything recorded so far holds (immediately, if it already does). No polling.
private final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    private var waiters: [(predicate: ([Element]) -> Bool, expectation: XCTestExpectation)] = []
    private var reader: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        reader = Task { [self] in
            for await element in stream {
                append(element)
            }
        }
    }

    deinit { reader?.cancel() }

    var elements: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func expectation(where predicate: @escaping ([Element]) -> Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "recorded elements")
        lock.lock()
        let satisfied = predicate(items)
        if !satisfied {
            waiters.append((predicate, expectation))
        }
        lock.unlock()
        if satisfied { expectation.fulfill() }
        return expectation
    }

    private func append(_ element: Element) {
        lock.lock()
        items.append(element)
        let snapshot = items
        var ready: [XCTestExpectation] = []
        waiters.removeAll { waiter in
            guard waiter.predicate(snapshot) else { return false }
            ready.append(waiter.expectation)
            return true
        }
        lock.unlock()
        for expectation in ready { expectation.fulfill() }
    }
}

/// One-shot gate: `wait()` suspends until `open()`; afterwards it returns at once.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

extension LaMarzoccoBluetoothClient {
    /// Runs `body` on the actor: read internal state from a test.
    fileprivate func inspect<T: Sendable>(_ body: @Sendable (isolated LaMarzoccoBluetoothClient) -> T) -> T {
        body(self)
    }

    /// Calls `entered` on the actor, then `startShotCounter()`, which enables the counter and reaches its
    /// connection-gate wait without suspending in between: once `entered` has run, any later actor job
    /// sees the counter enabled and the start queued on the gate.
    fileprivate func startShotCounterSignalling(_ entered: @Sendable () -> Void) async throws -> Bool {
        entered()
        return try await startShotCounter()
    }
}
