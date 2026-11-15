import XCTest
@testable import Angstrom
import AngstromTestSupport

/// Narrow smoke tests of the client shot counter (SPEC §4.9, §4.10, §4.13, D14, D15) over the
/// AngstromTestSupport fakes. The parity suites are ShotCounterLifecycleTests,
/// ShotCounterNotificationTests and ShotCounterReconnectTests.
final class BluetoothClientShotCounterSmokeTests: XCTestCase {
    private let auth = BluetoothConstants.authCharacteristic
    private let shotCounter = BluetoothConstants.shotCounterCharacteristic
    private let tokenWrite = Data("token".utf8)
    private let start = Date(timeIntervalSince1970: 1_000)
    /// `REPLAY` (`tests/test_bluetooth_client.py:811`).
    private let replay = Data(#"{"MachineMode":"StandBy"}"#.utf8)

    /// Angstrom-only: §4.9 — start connects, authenticates and subscribes (replay armed and tracker reset first); a second start is a no-op
    func testStartAuthenticatesThenSubscribes() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        let raw = Recorder(await client.rawFrames())

        // A pending brewing fragment that a missing tracker reset would complete (§4.9: the tracker
        // is replaced on every successful subscribe).
        let seededAt = start
        let seeded = await client.peek { client in
            client.tracker.process(BluetoothBrewingData(brewingTime: 5.0), receivedAt: seededAt)
        }
        XCTAssertNil(seeded, "a lone brewing time derives no state: the fragment is kept")

        // What the client state is while the subscribe is in flight.
        let atSubscribe = Locked<[Bool]>([])
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.beforeOp = { op in
            guard case .subscribe = op else { return }
            let state = await client.peek { [$0.replayPending, $0.shotCounterSubscribed, $0.shotCounterEnabled] }
            atSubscribe.withLock { $0 = state }
        }
        rig.central.enqueueConnect(.success(link))

        let started = try await client.startShotCounter()
        XCTAssertTrue(started)

        XCTAssertEqual(rig.central.connectCount, 1)
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .write(auth, tokenWrite), .read(auth),
                                          .subscribe(shotCounter)])
        XCTAssertEqual(link.requestedTimeouts, [.seconds(20), .seconds(20), .seconds(20), .seconds(20)])
        XCTAssertEqual(atSubscribe.value, [true, false, true],
                       "replayPending is armed before subscribing; subscribed is set after it")

        // The replayed tick (the fake's default replay) is dropped.
        await fulfillment(of: [raw.expectation { frames in
            let texts = frames.map(Self.describe)
            return texts.contains(RawBluetoothFrame.replayDroppedMarker) && texts.contains(RawBluetoothFrame.subscribedMarker)
        }], timeout: 5)
        let state = await client.peek {
            ($0.shotCounterActive, $0.shotCounterEnabled, $0.shotCounterSubscribed, $0.replayPending, $0.idleTask == nil)
        }
        XCTAssertTrue(state.0)
        XCTAssertTrue(state.1)
        XCTAssertTrue(state.2)
        XCTAssertFalse(state.3, "the replay consumed the flag")
        XCTAssertTrue(state.4, "no idle timer while the shot counter runs")
        XCTAssertEqual(rig.sleeper.startedCount(.idleDisconnect), 0)

        let markers = raw.elements.filter { $0.kind == .event }.map(Self.describe)
        XCTAssertEqual(Array(markers.prefix(3)), [RawBluetoothFrame.connectingMarker, RawBluetoothFrame.connectedMarker,
                                                  RawBluetoothFrame.authenticatedMarker])
        XCTAssertEqual(markers.filter { $0 == RawBluetoothFrame.subscribedMarker }.count, 1)
        XCTAssertEqual(markers.filter { $0 == RawBluetoothFrame.replayDroppedMarker }.count, 1)

        // The tracker was reset at subscribe: this completes nothing (with the old fragment it would
        // derive `.brewing`). The telemetry sentinel proves the notification was handled.
        link.notify(shotCounter, Data(#"{"BrewingUpdateGroup1Ev":true}"#.utf8), at: start)
        link.notify(shotCounter, Data(#"{"CoffeeBoiler1UpdateTemperature":93}"#.utf8), at: start)
        await fulfillment(of: [events.expectation { $0.count >= 2 }], timeout: 5)
        XCTAssertEqual(events.elements, [.subscribed, .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 93))])

        // A second start while subscribed: true, no resubscribe, no second `.subscribed`, flags kept.
        let again = try await client.startShotCounter()
        XCTAssertTrue(again)
        XCTAssertEqual(rig.central.connectCount, 1)
        XCTAssertEqual(link.recordedOps.filter { $0 == .subscribe(shotCounter) }.count, 1)
        let replayAfterSecondStart = await client.peek { $0.replayPending }
        XCTAssertFalse(replayAfterSecondStart, "a second start does not re-arm the replay drop")

        // disconnect(): unsubscribe, close, then `.unsubscribed`.
        await client.disconnect()
        XCTAssertEqual(Array(link.recordedOps.suffix(2)), [.unsubscribe(shotCounter), .disconnect])
        await fulfillment(of: [events.expectation { $0.count >= 3 }], timeout: 5)
        XCTAssertEqual(events.elements, [.subscribed, .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 93)),
                                         .unsubscribed])
        await fulfillment(of: [connection.expectation { $0.count >= 2 }], timeout: 5)
        XCTAssertEqual(connection.elements, [.connected, .disconnected])
        let active = await client.shotCounterActive
        XCTAssertFalse(active)
    }

    /// Angstrom-only: §4.10 — the first notification after a subscribe is dropped (during or after the subscribe), the raw tap still sees it
    func testReplayIsDropped() async throws {
        // During subscribe (here with brewing content: the replay is dropped whatever it holds), and
        // after subscribe (proxies may deliver it late).
        for replayDuringSubscribe in [true, false] {
            let context = replayDuringSubscribe ? "during subscribe" : "after subscribe"
            let rig = makeRig()
            let events = Recorder(await rig.client.shotCounterEvents())
            let raw = Recorder(await rig.client.rawFrames())
            let link = FakeBluetoothLink.laMarzocco(token: "token")
            link.replayOnSubscribe = replayDuringSubscribe ? [BluetoothTestVectors.started] : []
            rig.central.enqueueConnect(.success(link))

            let started = try await rig.client.startShotCounter()
            XCTAssertTrue(started, context)
            if !replayDuringSubscribe {
                link.notify(shotCounter, replay, at: start)
            }
            // Only the first notification is dropped.
            link.notify(shotCounter, replay, at: start)

            await fulfillment(of: [events.expectation { $0.count >= 2 }], timeout: 5)
            XCTAssertEqual(events.elements, [.subscribed, .telemetry(BluetoothMachineTelemetry(machineMode: .standby))],
                           context)

            // The raw tap sees both notifications verbatim, the dropped one before its marker.
            await fulfillment(of: [raw.expectation { $0.filter { $0.kind == .notification }.count >= 2 }], timeout: 5)
            let frames = raw.elements.map(Self.describe)
            let first = replayDuringSubscribe ? BluetoothTestVectors.started : replay
            let firstFrame = "notification \(shotCounter.string) \(String(decoding: first, as: UTF8.self))"
            let secondFrame = "notification \(shotCounter.string) \(String(decoding: replay, as: UTF8.self))"
            let dropped = try XCTUnwrap(frames.firstIndex(of: RawBluetoothFrame.replayDroppedMarker), context)
            let firstIndex = try XCTUnwrap(frames.firstIndex(of: firstFrame), context)
            let secondIndex = try XCTUnwrap(frames.lastIndex(of: secondFrame), context)
            XCTAssertEqual(firstIndex + 1, dropped, context)
            XCTAssertGreaterThan(secondIndex, dropped, context)
            XCTAssertEqual(frames.filter { $0 == RawBluetoothFrame.replayDroppedMarker }.count, 1, context)
            XCTAssertEqual(frames.filter { $0.hasPrefix("notification ") }.count, 2, context)

            await rig.client.disconnect()
        }
    }

    /// Angstrom-only: §4.10 — brewing is emitted before the telemetry of the same notification; telemetry-only and unparseable notifications leave the tracker alone
    func testBrewingEmittedBeforeTelemetry() async throws {
        let rig = makeRig()
        let events = Recorder(await rig.client.shotCounterEvents())
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.replayOnSubscribe = []
        rig.central.enqueueConnect(.success(link))
        let started = try await rig.client.startShotCounter()
        XCTAssertTrue(started)
        link.notify(shotCounter, replay, at: start)  // the replay

        // Brewing and telemetry in one notification: brewing first. The update is stamped with the
        // notification's receivedAt, not the client's clock.
        let t1 = start.addingTimeInterval(10)
        link.notify(shotCounter,
                    Data(#"{"BrewingStartedGroup1DoseIndex":"DoseA","SteamBoilerUpdateTemperature":127}"#.utf8), at: t1)
        // Telemetry only: never touches the tracker.
        link.notify(shotCounter, Data(#"{"CoffeeBoiler1UpdateTemperature":95}"#.utf8), at: t1.addingTimeInterval(1))
        // Unparseable, and unknown-only: nothing.
        link.notify(shotCounter, Data("not json".utf8), at: t1.addingTimeInterval(2))
        link.notify(shotCounter, Data(#"{"SomethingNew":1}"#.utf8), at: t1.addingTimeInterval(3))
        // A late tick of the same shot keeps the earliest start and the dose index.
        let t2 = t1.addingTimeInterval(5.07)
        link.notify(shotCounter, BluetoothTestVectors.tick("5"), at: t2)

        await fulfillment(of: [events.expectation { $0.count >= 5 }], timeout: 5)
        let first = BluetoothShotCounterUpdate(state: .brewing, timerValue: 0.0, startedDoseIndex: "DoseA",
                                               receivedAt: t1, raw: BluetoothBrewingData(startedDoseIndex: "DoseA"),
                                               brewingStartTime: t1)
        let tick = BluetoothShotCounterUpdate(state: .brewing, timerValue: 5.0, startedDoseIndex: "DoseA",
                                              receivedAt: t2,
                                              raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                                        brewingTime: 5.0),
                                              brewingStartTime: t1)
        XCTAssertEqual(events.elements, [
            .subscribed,
            .brewing(first),
            .telemetry(BluetoothMachineTelemetry(steamBoilerTemperature: 127)),
            .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 95)),
            .brewing(tick),
        ])
        await rig.client.disconnect()
    }

    /// Angstrom-only: §4.9 — stop unsubscribes, keeps the link, emits `.unsubscribed`, re-arms the idle timer and drops late notifications
    func testStopUnsubscribesAndRearmsIdle() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        let raw = Recorder(await client.rawFrames())
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        rig.central.enqueueConnect(.success(link))

        let started = try await client.startShotCounter()
        XCTAssertTrue(started)
        await fulfillment(of: [raw.expectation { $0.map(Self.describe).contains(RawBluetoothFrame.replayDroppedMarker) }],
                          timeout: 5)
        XCTAssertEqual(rig.sleeper.startedCount(.idleDisconnect), 0, "no idle timer while the shot counter runs")

        await client.stopShotCounter()

        // Unsubscribed, link kept, `.unsubscribed` emitted, idle disconnect re-armed (30 s).
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .write(auth, tokenWrite), .read(auth),
                                          .subscribe(shotCounter), .unsubscribe(shotCounter)])
        let state = await client.peek {
            ($0.isConnected, $0.shotCounterActive, $0.shotCounterEnabled, $0.shotCounterSubscribed, $0.reconnectTask == nil)
        }
        XCTAssertTrue(state.0, "the link stays up")
        XCTAssertFalse(state.1)
        XCTAssertFalse(state.2)
        XCTAssertFalse(state.3)
        XCTAssertTrue(state.4)
        await fulfillment(of: [raw.expectation { $0.map(Self.describe).contains(RawBluetoothFrame.unsubscribedMarker) }],
                          timeout: 5)
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect), [.seconds(30)])

        // A late notification after the stop is dropped silently (handled: its raw frame is tapped).
        let lateFrame = "notification \(shotCounter.string) \(String(decoding: BluetoothTestVectors.started, as: UTF8.self))"
        link.notify(shotCounter, BluetoothTestVectors.started, at: start)
        await fulfillment(of: [raw.expectation { $0.map(Self.describe).contains(lateFrame) }], timeout: 5)

        // The idle timer fires: the link closes and nothing reconnects.
        rig.sleeper.fire(.idleDisconnect)
        await fulfillment(of: [connection.expectation { $0.count >= 2 }], timeout: 5)
        XCTAssertEqual(connection.elements, [.connected, .disconnected])
        await client.drainBackgroundWorkForTesting()
        XCTAssertEqual(link.recordedOps.last, .disconnect)
        XCTAssertEqual(rig.central.connectCount, 1)
        let background = await client.hasBackgroundWorkForTesting
        XCTAssertFalse(background)

        // Restart: the next event is this `.subscribed`, so nothing came from the late notification.
        let restarted = try await client.startShotCounter()
        XCTAssertTrue(restarted)
        XCTAssertEqual(rig.central.connectCount, 2)
        await fulfillment(of: [events.expectation { $0.count >= 3 }], timeout: 5)
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])
        await client.disconnect()
    }

    /// Angstrom-only: §4.13 — a link loss starts the loop: backoff 1, 2, 4 s through two connect failures, resubscribe with a fresh tracker
    func testLossReconnectsAndResubscribes() async throws {
        let rig = makeRig()
        let client = rig.client
        var timing = BluetoothTiming()
        timing.connectAttempts = 1  // one connect per reconnect attempt, like upstream's establish_connection
        await client.setTimingForTesting(timing)
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        let first = FakeBluetoothLink.laMarzocco(token: "token")
        rig.central.enqueueConnect(.success(first))

        let started = try await client.startShotCounter()
        XCTAssertTrue(started)
        // A running shot, which the loss must forget.
        first.notify(shotCounter, BluetoothTestVectors.started, at: start)
        await fulfillment(of: [events.expectation { $0.count >= 2 }], timeout: 5)

        rig.central.enqueueConnect(.failure(.disconnected(code: 7)))
        rig.central.enqueueConnect(.failure(.timedOut("connect")))
        first.drop(.disconnected(code: 6))

        await fulfillment(of: [events.expectation { $0.count >= 4 }], timeout: 5)
        await client.drainBackgroundWorkForTesting()
        XCTAssertEqual(events.elements, [
            .subscribed,
            .brewing(BluetoothShotCounterUpdate(state: .brewing, timerValue: 0.0, startedDoseIndex: "DoseA",
                                                receivedAt: start, raw: BluetoothBrewingData(startedDoseIndex: "DoseA"),
                                                brewingStartTime: start)),
            .unsubscribed,
            .subscribed,
        ])
        // Initial connection + 2 failed reconnects + the successful one; the backoff sleeps before
        // every attempt and doubles after each connection failure.
        XCTAssertEqual(rig.central.connectCount, 4)
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2), .seconds(4)])
        let second = try XCTUnwrap(rig.central.links.last)
        XCTAssertEqual(rig.central.links.count, 2)
        XCTAssertEqual(second.recordedOps, [.discover(refresh: false), .write(auth, tokenWrite), .read(auth),
                                            .subscribe(shotCounter)])
        let state = await client.peek { ($0.shotCounterActive, $0.reconnectTask == nil, $0.link === second) }
        XCTAssertTrue(state.0)
        XCTAssertTrue(state.1, "a successful reconnect clears reconnectTask")
        XCTAssertTrue(state.2)
        await fulfillment(of: [connection.expectation { $0.count >= 3 }], timeout: 5)
        XCTAssertEqual(connection.elements, [.connected, .disconnected, .connected])

        // The new subscription dropped the replay again, and nothing of the old shot is left: with
        // the old tracker this fragment would derive `.brewing` from the earlier START.
        second.notify(shotCounter, Data(#"{"BrewingUpdateGroup1Backflush":false}"#.utf8), at: start)
        second.notify(shotCounter, replay, at: start)
        await fulfillment(of: [events.expectation { $0.count >= 5 }], timeout: 5)
        XCTAssertEqual(Array(events.elements.suffix(1)), [.telemetry(BluetoothMachineTelemetry(machineMode: .standby))])
        XCTAssertEqual(events.elements.count, 5)

        await client.disconnect()
    }

    /// Angstrom-only: D15 — the loop gives up after 3 auth failures (no doubling) or a vanished characteristic, emitting `.gaveUp` once and no second `.unsubscribed`
    func testGiveUpEmitsGaveUp() async throws {
        // Three auth failures (a re-paired machine): delay never doubled, `.gaveUp(auth)`, no second `.unsubscribed`.
        do {
            let rig = makeRig()
            let client = rig.client
            let events = Recorder(await client.shotCounterEvents())
            let connection = Recorder(await client.connectionEvents())
            let first = FakeBluetoothLink.laMarzocco(token: "token")
            rig.central.enqueueConnect(.success(first))
            let started = try await client.startShotCounter()
            XCTAssertTrue(started)

            rig.central.makeLink = { .laMarzocco(token: "other") }
            first.drop(.disconnected(code: 6))

            await fulfillment(of: [events.expectation { $0.count >= 3 }], timeout: 5)
            await client.drainBackgroundWorkForTesting()
            XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .gaveUp(.bluetoothAuthenticationFailed)])
            XCTAssertEqual(rig.central.connectCount, 4, "initial connection + 3 failed reconnects")
            XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(1), .seconds(1)])
            for failed in rig.central.links.dropFirst() {
                XCTAssertEqual(failed.recordedOps.first, .discover(refresh: false))
                XCTAssertEqual(failed.recordedOps.last, .disconnect, "an unauthenticated link is never kept")
                XCTAssertFalse(failed.recordedOps.contains(.subscribe(shotCounter)))
            }
            let state = await client.peek {
                ($0.authenticationFailed, $0.shotCounterActive, $0.shotCounterEnabled, $0.isConnected,
                 $0.reconnectTask == nil, $0.hasBackgroundWorkForTesting)
            }
            XCTAssertTrue(state.0)
            XCTAssertFalse(state.1)
            XCTAssertFalse(state.2)
            XCTAssertFalse(state.3)
            XCTAssertTrue(state.4)
            XCTAssertFalse(state.5, "no background work and no idle timer without a link")
            XCTAssertEqual(rig.sleeper.startedCount(.idleDisconnect), 0)
            await fulfillment(of: [connection.expectation { $0.count >= 2 }], timeout: 5)
            XCTAssertEqual(connection.elements, [.connected, .disconnected])
        }

        // The characteristic vanished: give up with its error; the live link gets its idle timer back.
        do {
            let rig = makeRig()
            let client = rig.client
            let events = Recorder(await client.shotCounterEvents())
            let connection = Recorder(await client.connectionEvents())
            let first = FakeBluetoothLink.laMarzocco(token: "token")
            rig.central.enqueueConnect(.success(first))
            let started = try await client.startShotCounter()
            XCTAssertTrue(started)

            rig.central.makeLink = {
                let link = FakeBluetoothLink.laMarzocco(token: "token")
                link.present = [BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
                                BluetoothConstants.tokenCharacteristic, BluetoothConstants.authCharacteristic]
                return link
            }
            first.drop(nil)

            await fulfillment(of: [events.expectation { $0.count >= 3 }], timeout: 5)
            await client.drainBackgroundWorkForTesting()
            XCTAssertEqual(events.elements, [
                .subscribed, .unsubscribed,
                .gaveUp(.bluetoothConnectionFailed("Could not find characteristic 0e0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")),
            ])
            XCTAssertEqual(rig.central.connectCount, 3, "initial + cached pass + rediscovery pass")
            XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
            let links = rig.central.links
            XCTAssertEqual(links.count, 3)
            XCTAssertEqual(links[1].recordedOps, [.discover(refresh: false), .write(auth, tokenWrite), .read(auth), .disconnect])
            XCTAssertEqual(links[2].recordedOps, [.discover(refresh: true), .write(auth, tokenWrite), .read(auth)])
            let state = await client.peek {
                ($0.isConnected, $0.shotCounterEnabled, $0.reconnectTask == nil, $0.link === links[2])
            }
            XCTAssertTrue(state.0)
            XCTAssertFalse(state.1)
            XCTAssertTrue(state.2)
            XCTAssertTrue(state.3)
            await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
            XCTAssertEqual(rig.sleeper.requested(.idleDisconnect), [.seconds(30)])
            await fulfillment(of: [connection.expectation { $0.count >= 5 }], timeout: 5)
            XCTAssertEqual(connection.elements, [.connected, .disconnected, .connected, .disconnected, .connected])
            await client.disconnect()
        }
    }

    /// Angstrom-only: §4.9 — no characteristic after one rediscovery pass returns false, keeps the link and re-arms the idle timer; a stale cache is rediscovered
    func testUnsupportedReturnsFalse() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        rig.central.makeLink = {
            let link = FakeBluetoothLink.laMarzocco(token: "token")
            link.present = [BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
                            BluetoothConstants.tokenCharacteristic, BluetoothConstants.authCharacteristic]
            return link
        }

        let supported = try await client.startShotCounter()
        XCTAssertFalse(supported)

        // Cached pass, disconnect, rediscovery pass; never subscribed.
        let links = rig.central.links
        XCTAssertEqual(rig.central.connectCount, 2)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].recordedOps, [.discover(refresh: false), .write(auth, tokenWrite), .read(auth), .disconnect])
        XCTAssertEqual(links[1].recordedOps, [.discover(refresh: true), .write(auth, tokenWrite), .read(auth)])
        let state = await client.peek {
            ($0.isConnected, $0.shotCounterActive, $0.shotCounterEnabled, $0.reconnectTask == nil)
        }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertFalse(state.2)
        XCTAssertTrue(state.3)
        await fulfillment(of: [connection.expectation { $0.count >= 3 }], timeout: 5)
        XCTAssertEqual(connection.elements, [.connected, .disconnected, .connected])

        // The idle disconnect runs again.
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect), [.seconds(30)])
        rig.sleeper.fire(.idleDisconnect)
        await fulfillment(of: [connection.expectation { $0.count >= 4 }], timeout: 5)
        await client.drainBackgroundWorkForTesting()
        XCTAssertEqual(links[1].recordedOps.last, .disconnect)
        XCTAssertEqual(rig.central.connectCount, 2, "no reconnect loop")

        // Nothing was emitted: once the machine has the characteristic, the first event is `.subscribed`.
        rig.central.makeLink = { .laMarzocco(token: "token") }
        let supportedNow = try await client.startShotCounter()
        XCTAssertTrue(supportedNow)
        await fulfillment(of: [events.expectation { !$0.isEmpty }], timeout: 5)
        XCTAssertEqual(events.elements, [.subscribed])
        await client.disconnect()

        // Stale cache: the characteristic is found by the rediscovery pass.
        let stale = makeRig()
        let staleEvents = Recorder(await stale.client.shotCounterEvents())
        stale.central.makeLink = {
            let link = FakeBluetoothLink.laMarzocco(token: "token")
            link.present = [BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
                            BluetoothConstants.tokenCharacteristic, BluetoothConstants.authCharacteristic]
            link.presentAfterRefresh = [BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
                                        BluetoothConstants.tokenCharacteristic, BluetoothConstants.authCharacteristic,
                                        BluetoothConstants.shotCounterCharacteristic]
            return link
        }
        let found = try await stale.client.startShotCounter()
        XCTAssertTrue(found)
        XCTAssertEqual(stale.central.connectCount, 2)
        XCTAssertEqual(stale.central.links.last?.recordedOps,
                       [.discover(refresh: true), .write(auth, tokenWrite), .read(auth), .subscribe(shotCounter)])
        let active = await stale.client.shotCounterActive
        XCTAssertTrue(active)
        await stale.client.disconnect()
        await fulfillment(of: [staleEvents.expectation { $0.count >= 2 }], timeout: 5)
        XCTAssertEqual(staleEvents.elements, [.subscribed, .unsubscribed])
    }

    /// Angstrom-only: D14 — Bluetooth returning to `.poweredOn` ends the reconnect backoff early and resets the delay
    func testSmokePoweredOnCutsBackoff() async throws {
        let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
        let client = rig.client
        var timing = BluetoothTiming()
        timing.connectAttempts = 1
        await client.setTimingForTesting(timing)
        let events = Recorder(await client.shotCounterEvents())
        let first = FakeBluetoothLink.laMarzocco(token: "token")
        rig.central.enqueueConnect(.success(first))
        let started = try await client.startShotCounter()
        XCTAssertTrue(started)

        // Attempt 1 fails to connect; attempt 2 (right after the cut) fails discovery (no auth
        // characteristic), and tells the test it started; attempt 3 succeeds.
        rig.central.enqueueConnect(.failure(.timedOut("connect")))
        let secondAttempt = expectation(description: "attempt after the power-on")
        let noAuth = FakeBluetoothLink()
        noAuth.present = [BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
                          BluetoothConstants.shotCounterCharacteristic]
        let release = Latch()
        noAuth.beforeOp = { op in
            guard op == .discover(refresh: false) else { return }
            secondAttempt.fulfill()
            await release.wait()  // held until the test has looked at the sleeper
        }
        rig.central.enqueueConnect(.success(noAuth))
        first.drop(.disconnected(code: 6))

        // The availability stream exists by the first sleep (§4.13).
        await rig.sleeper.waitForPending(.reconnectBackoff, count: 1)
        XCTAssertGreaterThanOrEqual(rig.central.availabilitySubscriberCount, 1)
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
        rig.sleeper.fire(.reconnectBackoff)

        // Attempt 1 failed: the delay doubled.
        await rig.sleeper.waitForPending(.reconnectBackoff, count: 1)
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2)])
        XCTAssertEqual(rig.central.connectCount, 2)

        // Off, then on again: the pending 2 s sleep ends without being fired.
        rig.central.setAvailability(.poweredOff)
        rig.central.setAvailability(.poweredOn)
        await fulfillment(of: [secondAttempt], timeout: 5)
        XCTAssertEqual(rig.sleeper.pendingCount(.reconnectBackoff), 0, "the cut sleep is no longer pending")
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2)], "the 2 s sleep was never fired")
        release.open()

        // Attempt 2 failed after the reset: 1 s doubled to 2 s (without the reset it would be 4 s).
        await rig.sleeper.waitForPending(.reconnectBackoff, count: 1)
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2), .seconds(2)])
        XCTAssertEqual(rig.central.connectCount, 3)
        XCTAssertEqual(noAuth.recordedOps, [.discover(refresh: false), .disconnect])

        rig.sleeper.fire(.reconnectBackoff)
        await fulfillment(of: [events.expectation { $0.count >= 3 }], timeout: 5)
        await client.drainBackgroundWorkForTesting()
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])
        XCTAssertEqual(rig.central.connectCount, 4)
        let active = await client.shotCounterActive
        XCTAssertTrue(active)
        XCTAssertEqual(rig.central.availabilitySubscriberCount, 0, "the loop's availability stream ends with the loop")
        await client.disconnect()
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

    /// A raw frame as text: the marker for `.event`, else `<kind> <characteristic> <UTF-8 data>`.
    private static func describe(_ frame: RawBluetoothFrame) -> String {
        let text = String(decoding: frame.data, as: UTF8.self)
        guard frame.kind != .event else { return text }
        return "\(frame.kind) \(frame.characteristic ?? "-") \(text)"
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

/// A lock-protected value shared with `@Sendable` closures.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

extension LaMarzoccoBluetoothClient {
    /// Runs `body` on the actor: read or set internal state from a test.
    fileprivate func peek<T: Sendable>(_ body: @Sendable (isolated LaMarzoccoBluetoothClient) -> T) -> T {
        body(self)
    }
}
