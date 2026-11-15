import XCTest
@testable import Angstrom
import AngstromTestSupport

/// Parity suite for shot-counter notifications through the real client (SPEC §3.8, §4.10–§4.12,
/// vectors §9.3.3). Every notification goes through `FakeBluetoothLink.notify(_:_:at:)` on a started
/// `LaMarzoccoBluetoothClient`, and the assertions are on `shotCounterEvents()`.
///
/// Synchronisation (no sleeps, no polling): the client handles a notification synchronously on the
/// actor, emitting its raw `.notification` frame first. Once the raw tap has recorded the frame of the
/// last delivered notification, every handler has at least started, so a following actor call
/// (`disconnect()` / `stopShotCounter()`) runs after all of them. Its `.unsubscribed` therefore lands
/// on the event stream after every event those notifications produced, and comparing the complete
/// event list also proves that nothing else was emitted.
final class ShotCounterNotificationTests: XCTestCase {
    /// `REPLAY` (`tests/test_bluetooth_client.py:811`).
    private static let replay = Data(#"{"MachineMode":"StandBy"}"#.utf8)
    /// `{"BrewingUpdateGroup1Ev":false}` (`tests/test_bluetooth_client.py:756`).
    private static let evOff = Data(#"{"BrewingUpdateGroup1Ev":false}"#.utf8)
    /// An arbitrary epoch for the tests that do not pin a clock.
    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - C24 / C25 test_shot_counter_state_machine

    /// Upstream: test_shot_counter_state_machine (tests/test_bluetooth_client.py:784) [C24]
    func testSequence() async throws {
        let h = await Harness(start: Self.t0)
        try await h.start()
        let t = (0...10).map { Self.t0.addingTimeInterval(Double($0)) }
        let stop = Data(#"{"BrewingStoppedGroup1Time":27.4,"BrewingStoppedGroup1DoseIndex":"DoseA","BrewingStoppedGroup1StopType":"X","BrewingStoppedGroup1StopReason":"Manual"}"#.utf8)

        h.notify(BluetoothTestVectors.started, at: t[1])
        h.notify(BluetoothTestVectors.tick("0.1"), at: t[2])
        h.notify(BluetoothTestVectors.tick("1.17"), at: t[3])
        h.notify(Self.evOff, at: t[4])
        h.notify(stop, at: t[5])
        h.notify(Data(#"{"FlushStoppedGroup1Time":3.1}"#.utf8), at: t[6])
        h.notify(BluetoothTestVectors.started, at: t[7])
        h.notify(BluetoothTestVectors.tick("0.1", backflush: true), at: t[8])
        h.notify(Self.evOff, at: t[9])
        // Without a start event, e.g. when subscribing during a shot.
        h.notify(BluetoothTestVectors.tick("5.2"), at: t[10])

        let events = await h.finish()

        // Upstream's (state, timerValue, finalShotTime) for each step (BT-NTF-SEQ-001).
        let triples = events.compactMap(Self.triple)
        XCTAssertEqual(triples.map(\.0), [.brewing, .brewing, .brewing, .brewingStopped, .brewingStopped, .flushed,
                                          .brewing, .backflushing, .brewingStopped, .brewing])
        XCTAssertEqual(triples.map(\.1), [0.0, 0.1, 1.17, nil, nil, nil, 0.0, nil, nil, 5.2])
        XCTAssertEqual(triples.map(\.2), [nil, nil, nil, nil, 27.4, nil, nil, nil, nil, nil])

        // The complete updates (§4.11 field rules and tracker).
        let doseA = BluetoothBrewingData(startedDoseIndex: "DoseA")
        let running = BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false)
        assertEvents(events, [
            .subscribed,
            .brewing(update(.brewing, timer: 0.0, dose: "DoseA", at: t[1], raw: doseA, start: t[1])),
            .brewing(update(.brewing, timer: 0.1, dose: "DoseA", at: t[2], raw: with(running, time: 0.1), start: t[1])),
            .brewing(update(.brewing, timer: 1.17, dose: "DoseA", at: t[3], raw: with(running, time: 1.17), start: t[1])),
            .brewing(update(.brewingStopped, dose: "DoseA", at: t[4],
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: false, backflush: false,
                                                      brewingTime: 1.17))),
            // The tracker was reset by the previous stop: no dose index, only this message's data.
            .brewing(update(.brewingStopped, final: 27.4, reason: "Manual", at: t[5],
                            raw: BluetoothBrewingData(brewingStoppedTime: 27.4, brewingStoppedDoseIndex: "DoseA",
                                                      brewingStoppedStopType: "X", brewingStoppedStopReason: "Manual"))),
            .brewing(update(.flushed, at: t[6], raw: BluetoothBrewingData(flushStoppedTime: 3.1))),
            .brewing(update(.brewing, timer: 0.0, dose: "DoseA", at: t[7], raw: doseA, start: t[7])),
            .brewing(update(.backflushing, dose: "DoseA", at: t[8],
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: true,
                                                      brewingTime: 0.1))),
            .brewing(update(.brewingStopped, dose: "DoseA", at: t[9],
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: false, backflush: true,
                                                      brewingTime: 0.1))),
            .brewing(update(.brewing, timer: 5.2, at: t[10],
                            raw: BluetoothBrewingData(ev: true, backflush: false, brewingTime: 5.2),
                            start: t[10].addingTimeInterval(-5.2))),
            .unsubscribed,
        ])
    }

    /// Upstream: test_shot_counter_state_machine (tests/test_bluetooth_client.py:784) [C25]
    func testMalformedPayloadsAreDropped() async throws {
        let h = await Harness(start: Self.t0)
        try await h.start()
        let t = (0...8).map { Self.t0.addingTimeInterval(Double($0)) }

        h.notify(BluetoothTestVectors.started, at: t[1])
        h.notify(Data("not json".utf8), at: t[2])
        h.notify(Data(#"{"BrewingUpdateGroup1Time":"abc"}"#.utf8), at: t[3])
        h.notify(Data("[]".utf8), at: t[4])
        h.notify(Data([0xFF, 0xFE]), at: t[5])
        // No brewing event; its telemetry is emitted (upstream's test registers no telemetry callback).
        h.notify(Data(#"{"SteamBoilerUpdateTemperature":130}"#.utf8), at: t[6])
        h.notify(Data(#"{"SomethingNew":1,"BrewingUpdateGroup1Time":3.5}"#.utf8), at: t[7])
        h.notify(BluetoothTestVectors.tick("4.5") + Data([0x00]), at: t[8])

        let events = await h.finish()

        // Upstream's (state, timerValue, finalShotTime) for the steps that produce an update (BT-NTF-SEQ-002).
        let triples = events.compactMap(Self.triple)
        XCTAssertEqual(triples.map(\.0), [.brewing, .brewing, .brewing])
        XCTAssertEqual(triples.map(\.1), [0.0, 3.5, 4.5])
        XCTAssertEqual(triples.map(\.2), [nil, nil, nil])

        // The dropped payloads left the tracker untouched: the shot keeps its dose index and start.
        assertEvents(events, [
            .subscribed,
            .brewing(update(.brewing, timer: 0.0, dose: "DoseA", at: t[1],
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA"), start: t[1])),
            .telemetry(BluetoothMachineTelemetry(steamBoilerTemperature: 130)),
            .brewing(update(.brewing, timer: 3.5, dose: "DoseA", at: t[7],
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA", brewingTime: 3.5), start: t[1])),
            .brewing(update(.brewing, timer: 4.5, dose: "DoseA", at: t[8],
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                      brewingTime: 4.5), start: t[1])),
            .unsubscribed,
        ])
    }

    // MARK: - C26 / C27 test_shot_counter_discards_replay

    /// Upstream: test_shot_counter_discards_replay (tests/test_bluetooth_client.py:822) [C26]
    func testReplayDuringSubscribeIsDropped() async throws {
        // Upstream's fake: the replay is handed over inside `subscribe` (`start_notify`).
        try await assertReplayDropped(duringSubscribe: true)
        // Deterministically before the subscribe acknowledgement: the client has handled the replay
        // while `subscribe` is still in flight, so the flag must be armed before subscribing (§3.8).
        try await assertReplayDropped(duringSubscribe: true, handledBeforeAcknowledgement: true)
    }

    /// Upstream: test_shot_counter_discards_replay (tests/test_bluetooth_client.py:822) [C27]
    func testReplayAfterSubscribeIsDropped() async throws {
        // Proxies may deliver the replay after subscribing.
        try await assertReplayDropped(duringSubscribe: false)
    }

    private func assertReplayDropped(duringSubscribe: Bool, handledBeforeAcknowledgement: Bool = false,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        // Upstream: `bleak_client.replay = REPLAY if replay_during_subscribe else None`.
        let h = await Harness(start: Self.t0,
                              replay: duringSubscribe && !handledBeforeAcknowledgement ? [Self.replay] : [])
        if handledBeforeAcknowledgement {
            // Hold the subscribe op until the client has handled the replay: its raw frame is emitted
            // by the (synchronous) handler, which then finishes before `subscribe` can resume.
            let link = h.link
            let raw = h.raw
            let replay = Self.replay
            let at = Self.t0
            link.beforeOp = { op in
                guard op == .subscribe(BluetoothConstants.shotCounterCharacteristic) else { return }
                link.notify(BluetoothConstants.shotCounterCharacteristic, replay, at: at)
                let handled = raw.expectation { $0.contains { $0.kind == .notification } }
                await XCTWaiter().fulfillment(of: [handled], timeout: 5)
            }
        }
        try await h.start(file: file, line: line)
        if handledBeforeAcknowledgement {
            h.countDelivered()
            let preAckFrames = h.raw.elements
            XCTAssertEqual(preAckFrames.filter { $0.kind == .notification }.count, 1, file: file, line: line)
        }
        if !duringSubscribe {
            h.notify(Self.replay, at: Self.t0.addingTimeInterval(1))
        }
        // Only the first notification is dropped.
        h.notify(Self.replay, at: Self.t0.addingTimeInterval(2))

        let events = await h.finish()
        assertEvents(events, [
            .subscribed,
            .telemetry(BluetoothMachineTelemetry(machineMode: .standby)),
            .unsubscribed,
        ], file: file, line: line)

        // Which one was dropped: the raw tap (one ordered stream) shows the drop marker right after the
        // first notification, and the second notification after it. Exactly one drop.
        let frames = h.raw.elements
        let notifications = frames.indices.filter { frames[$0].kind == .notification }
        let drops = frames.indices.filter { Self.isMarker(frames[$0], RawBluetoothFrame.replayDroppedMarker) }
        XCTAssertEqual(notifications.count, 2, file: file, line: line)
        XCTAssertEqual(drops.count, 1, file: file, line: line)
        if notifications.count == 2, drops.count == 1 {
            XCTAssertEqual(drops[0], notifications[0] + 1, file: file, line: line)
            XCTAssertGreaterThan(notifications[1], drops[0], file: file, line: line)
        }
    }

    // MARK: - C28 test_shot_counter_telemetry

    /// Upstream: test_shot_counter_telemetry (tests/test_bluetooth_client.py:848) [C28]
    func testTelemetryRoutingAndParsing() async throws {
        let h = await Harness(start: Self.t0)
        try await h.start()
        let both = Self.t0.addingTimeInterval(5)

        // BT-NTF-TEL-001
        h.notify(Data(#"{"CoffeeBoiler1UpdateTemperature":95}"#.utf8), at: Self.t0.addingTimeInterval(1))
        // BT-NTF-TEL-002/003: values the library doesn't know are ignored.
        h.notify(Data(#"{"SteamBoilerHeatingCoeff":"[{\"temperature\":18}]"}"#.utf8), at: Self.t0.addingTimeInterval(2))
        h.notify(Data(#"{"MachineMode":"Unknown"}"#.utf8), at: Self.t0.addingTimeInterval(3))
        // BT-NTF-TEL-004
        h.notify(Data(#"{"MachineStatistics":"{\"tot_doses\":2123}"}"#.utf8), at: Self.t0.addingTimeInterval(4))
        // BT-NTF-TEL-005: a notification with both kinds of data — brewing first, then telemetry.
        h.notify(Data(#"{"BrewingStartedGroup1DoseIndex":"DoseA","SteamBoilerUpdateTemperature":127}"#.utf8), at: both)

        let events = await h.finish()
        assertEvents(events, [
            .subscribed,
            .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 95)),
            .telemetry(BluetoothMachineTelemetry(machineStatistics: .object(["tot_doses": .number(2123)]))),
            .brewing(update(.brewing, timer: 0.0, dose: "DoseA", at: both,
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA"), start: both)),
            // Partial telemetry: only this notification's field, not merged with the earlier coffee/statistics.
            .telemetry(BluetoothMachineTelemetry(steamBoilerTemperature: 127)),
            .unsubscribed,
        ])
    }

    // MARK: - C30 test_shot_counter_brewing_start_time

    /// Upstream: test_shot_counter_brewing_start_time (tests/test_bluetooth_client.py:980) [C30]
    func testBrewingStartTimeIsEarliestEstimate() async throws {
        // `FakeClock`: 2026-10-05T07:00:00Z (`tests/test_bluetooth_client.py:89-90`).
        let clock = BluetoothTestClock(Date(timeIntervalSince1970: 1_791_183_600))
        let h = await Harness(clock: clock)
        try await h.start()

        let startedAt = clock.now()
        h.notify(BluetoothTestVectors.started, at: clock.now())

        // A late tick doesn't move the start.
        clock.advance(by: 5.07)
        let lateAt = clock.now()
        h.notify(BluetoothTestVectors.tick("5"), at: lateAt)

        // An earlier estimate does.
        clock.advance(by: 1)
        let earlyAt = clock.now()
        h.notify(BluetoothTestVectors.tick("6.1"), at: earlyAt)

        let events = await h.finish()
        let updates = events.compactMap(Self.brewingUpdate)
        XCTAssertEqual(updates.count, 3)
        guard updates.count == 3 else { return }
        XCTAssertEqual(updates[0].brewingStartTime, startedAt)

        XCTAssertEqual(updates[1].timerValue, 5)
        XCTAssertEqual(updates[1].brewingStartTime, startedAt)
        XCTAssertEqual(updates[1].startedDoseIndex, "DoseA")

        let early = try XCTUnwrap(updates[2].brewingStartTime)
        XCTAssertEqual(early.timeIntervalSince1970, earlyAt.addingTimeInterval(-6.1).timeIntervalSince1970,
                       accuracy: 1e-6)
        // 07:00:06.07 − 6.1 s = 06:59:59.97, i.e. 0.03 s before the START notification (BT-NTF-START-001).
        XCTAssertEqual(early.timeIntervalSince(startedAt), -0.03, accuracy: 1e-6)

        assertEvents(events, [
            .subscribed,
            .brewing(update(.brewing, timer: 0.0, dose: "DoseA", at: startedAt,
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA"), start: startedAt)),
            .brewing(update(.brewing, timer: 5, dose: "DoseA", at: lateAt,
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                      brewingTime: 5), start: startedAt)),
            .brewing(update(.brewing, timer: 6.1, dose: "DoseA", at: earlyAt,
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                      brewingTime: 6.1), start: earlyAt.addingTimeInterval(-6.1))),
            .unsubscribed,
        ])
    }

    // MARK: - C31 test_shot_counter_callback_exception_is_caught (restated, D4)

    /// Upstream: test_shot_counter_callback_exception_is_caught (tests/test_bluetooth_client.py:1009) [C31]
    ///
    /// Restated (D4: streams instead of callbacks, so there is no user exception to catch): a consumer
    /// that stops iterating — one breaks out of its loop, one is cancelled while waiting — neither stops
    /// delivery to the other listeners nor breaks the client.
    func testCancelledConsumerDoesNotAffectClient() async throws {
        let h = await Harness(start: Self.t0)

        // Consumer 1 breaks out of its loop after its first event.
        let breaking = await h.client.shotCounterEvents()
        let breaker = Task { () -> [ShotCounterEvent] in
            var seen: [ShotCounterEvent] = []
            for await event in breaking {
                seen.append(event)
                break
            }
            return seen
        }
        // Consumer 2 records its first event, then is cancelled while it waits for the next.
        let cancelling = await h.client.shotCounterEvents()
        let gotFirst = XCTestExpectation(description: "consumer 2 received its first event")
        let cancelled = Task { () -> [ShotCounterEvent] in
            var seen: [ShotCounterEvent] = []
            for await event in cancelling {
                seen.append(event)
                gotFirst.fulfill()
            }
            return seen
        }

        try await h.start()
        let broke = await breaker.value
        XCTAssertEqual(broke, [.subscribed])
        await fulfillment(of: [gotFirst], timeout: 5)
        cancelled.cancel()
        let cancelledSeen = await cancelled.value
        XCTAssertEqual(cancelledSeen, [.subscribed])

        // The client keeps processing notifications for the remaining listener.
        let t1 = Self.t0.addingTimeInterval(1)
        let t2 = Self.t0.addingTimeInterval(3)
        h.notify(BluetoothTestVectors.started, at: t1)
        h.notify(BluetoothTestVectors.tick("1.5"), at: t2)
        h.notify(Data(#"{"CoffeeBoiler1UpdateTemperature":93}"#.utf8), at: t2)
        await h.settle()
        let state = await h.client.peek { ($0.shotCounterActive, $0.isConnected, $0.shotCounterEnabled) }
        XCTAssertTrue(state.0, "shot counter still active")
        XCTAssertTrue(state.1, "still connected")
        XCTAssertTrue(state.2, "shot counter still enabled")

        // And it still serves requests on the same link.
        let mode = try await h.client.machineMode()
        XCTAssertEqual(mode, .brewing)
        XCTAssertEqual(h.central.connectCount, 1)

        let events = await h.finish()
        assertEvents(events, [
            .subscribed,
            .brewing(update(.brewing, timer: 0.0, dose: "DoseA", at: t1,
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA"), start: t1)),
            .brewing(update(.brewing, timer: 1.5, dose: "DoseA", at: t2,
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                      brewingTime: 1.5), start: t1)),
            .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 93)),
            .unsubscribed,
        ])
    }

    // MARK: - Angstrom-only

    /// Angstrom-only: G-SC-3 — the tracker resets on every successful subscribe (the first start and a restart)
    func testTrackerResetOnResubscribe() async throws {
        let h = await Harness(start: Self.t0)

        // Before the first subscribe: a pending fragment that a later brewing time would complete.
        let seededAt = Self.t0
        let seeded = await h.client.peek { client in
            client.tracker.process(BluetoothBrewingData(ev: true), receivedAt: seededAt)
        }
        XCTAssertNil(seeded, "a lone ev is a fragment: kept, no state")
        try await h.start()
        // Without the reset this completes the seeded fragment (ev true + time → brewing 2.0).
        h.notify(Data(#"{"BrewingUpdateGroup1Time":2.0}"#.utf8), at: Self.t0.addingTimeInterval(1))
        await h.settle()

        // Stop (the stop resets the tracker too), then seed a running shot right before the restart,
        // so only the subscribe can clear it.
        await h.client.stopShotCounter()
        let shotAt = Self.t0.addingTimeInterval(2)
        let shot = await h.client.peek { client in
            client.tracker.process(BluetoothBrewingData(startedDoseIndex: "DoseA"), receivedAt: shotAt)
        }
        XCTAssertEqual(shot?.state, .brewing, "seeded a running shot started at t0 + 2 s")
        try await h.start()   // the same link; its default replay tick("3.34") is dropped again
        let tickAt = Self.t0.addingTimeInterval(20)
        h.notify(BluetoothTestVectors.tick("1"), at: tickAt)

        let events = await h.finish()
        XCTAssertEqual(h.central.connectCount, 1, "the restart reuses the link")
        XCTAssertEqual(h.link.recordedOps.filter { $0 == .subscribe(BluetoothConstants.shotCounterCharacteristic) }.count, 2)
        assertEvents(events, [
            .subscribed,
            // Nothing for the brewing time after the first subscribe (the fragment is gone).
            .unsubscribed,
            .subscribed,
            // A fresh shot: no dose index of the seeded START, and its own start estimate, not t0 + 2 s.
            .brewing(update(.brewing, timer: 1, at: tickAt,
                            raw: BluetoothBrewingData(ev: true, backflush: false, brewingTime: 1),
                            start: tickAt.addingTimeInterval(-1))),
            .unsubscribed,
        ])
    }

    /// Angstrom-only: D5 — BT-NTF-COERCE-001: `"BrewingUpdateGroup1Ev":"false"` is false at client level, so the update is `.brewingStopped` (upstream `.brewing(1.0)`)
    func testEvFalseStringStopsAtClientLevel() async throws {
        let h = await Harness(start: Self.t0)
        try await h.start()   // a fresh tracker
        let t1 = Self.t0.addingTimeInterval(1)
        h.notify(Data(#"{"BrewingUpdateGroup1Ev":"false","BrewingUpdateGroup1Time":1}"#.utf8), at: t1)
        // The stop reset the tracker: a lone brewing time is only a fragment again.
        h.notify(Data(#"{"BrewingUpdateGroup1Time":2}"#.utf8), at: Self.t0.addingTimeInterval(2))

        let events = await h.finish()
        assertEvents(events, [
            .subscribed,
            .brewing(update(.brewingStopped, at: t1, raw: BluetoothBrewingData(ev: false, brewingTime: 1))),
            .unsubscribed,
        ])
    }

    /// Angstrom-only: §3.8 — BT-NTF-COERCE-002: a `MachineStatistics` object, bool or unparseable string drops the whole notification
    func testStatisticsObjectDropped() async throws {
        let h = await Harness(start: Self.t0)
        try await h.start()
        let t = (0...8).map { Self.t0.addingTimeInterval(Double($0)) }

        // The vectors verbatim.
        h.notify(Data(#"{"MachineStatistics":{"a":1}}"#.utf8), at: t[1])
        h.notify(Data(#"{"MachineStatistics":true}"#.utf8), at: t[2])
        h.notify(Data(#"{"MachineStatistics":"{bad"}"#.utf8), at: t[3])
        // The whole notification goes: valid telemetry and brewing keys beside it are dropped too.
        h.notify(Data(#"{"MachineStatistics":{"a":1},"CoffeeBoiler1UpdateTemperature":90}"#.utf8), at: t[4])
        h.notify(Data(#"{"MachineStatistics":true,"BrewingStartedGroup1DoseIndex":"DoseA"}"#.utf8), at: t[5])
        h.notify(Data(#"{"MachineStatistics":"{bad","SteamBoilerUpdateTemperature":120,"BrewingStartedGroup1DoseIndex":"DoseA"}"#.utf8), at: t[6])
        // The dropped brewing keys never reached the tracker: a lone brewing time stays a fragment.
        h.notify(Data(#"{"BrewingUpdateGroup1Time":2}"#.utf8), at: t[7])
        // The client still processes the next valid notification.
        h.notify(Data(#"{"CoffeeBoiler1UpdateTemperature":91}"#.utf8), at: t[8])

        let events = await h.finish()
        assertEvents(events, [
            .subscribed,
            .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 91)),
            .unsubscribed,
        ])
    }

    /// Angstrom-only: §3.8 — BT-NTF-COERCE-003/004: `MachineStatistics` null, or a string parsing to null, is unset and the rest of the notification is processed
    func testStatisticsNullIsUnset() async throws {
        let h = await Harness(start: Self.t0)
        try await h.start()
        let t5 = Self.t0.addingTimeInterval(5)

        // 003: JSON null is unset; the rest of the notification is processed.
        h.notify(Data(#"{"MachineStatistics":null,"CoffeeBoiler1UpdateTemperature":90}"#.utf8), at: Self.t0.addingTimeInterval(1))
        // 004: a string parsing to null is unset; alone, the notification is empty, so nothing is emitted.
        h.notify(Data(#"{"MachineStatistics":"null"}"#.utf8), at: Self.t0.addingTimeInterval(2))
        h.notify(Data(#"{"MachineStatistics":"null","CoffeeBoiler1UpdateTemperature":90}"#.utf8), at: Self.t0.addingTimeInterval(3))
        // JSON null alone: also empty (§3.8: absent or null → unset).
        h.notify(Data(#"{"MachineStatistics":null}"#.utf8), at: Self.t0.addingTimeInterval(4))
        // Brewing keys beside a null statistics value are processed too.
        h.notify(Data(#"{"MachineStatistics":null,"BrewingStartedGroup1DoseIndex":"DoseA"}"#.utf8), at: t5)

        let events = await h.finish()
        assertEvents(events, [
            .subscribed,
            .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 90)),
            .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 90)),
            .brewing(update(.brewing, timer: 0.0, dose: "DoseA", at: t5,
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA"), start: t5)),
            .unsubscribed,
        ])
        // `machineStatistics == nil` in both telemetry events (BT-NTF-COERCE-003/004).
        let telemetry = events.compactMap { event -> BluetoothMachineTelemetry? in
            if case .telemetry(let value) = event { return value }
            return nil
        }
        XCTAssertEqual(telemetry.map(\.machineStatistics), [nil, nil])
    }

    /// Angstrom-only: §4.11 — BT-NTF-LATE-001 (Q9): a late tick after a stop re-enters `.brewing` (no guard, parity)
    func testLateTickReentersBrewing() async throws {
        let h = await Harness(start: Self.t0)
        try await h.start()
        let t = (0...6).map { Self.t0.addingTimeInterval(Double($0) * 10) }
        let bstop = Data(#"{"BrewingStoppedGroup1Time":10.0}"#.utf8)

        // The vector: BSTOP(10.0) then tick("10.2").
        h.notify(bstop, at: t[1])
        h.notify(BluetoothTestVectors.tick("10.2"), at: t[2])
        // The same after a started shot: the stop forgot the shot's dose index and start estimate.
        h.notify(Data(#"{"BrewingStoppedGroup1Time":0.5}"#.utf8), at: t[3])   // ends the re-entered shot
        h.notify(BluetoothTestVectors.started, at: t[4])
        h.notify(bstop, at: t[5])
        h.notify(BluetoothTestVectors.tick("10.2"), at: t[6])

        let events = await h.finish()
        let late = BluetoothBrewingData(ev: true, backflush: false, brewingTime: 10.2)
        assertEvents(events, [
            .subscribed,
            .brewing(update(.brewingStopped, final: 10.0, at: t[1], raw: BluetoothBrewingData(brewingStoppedTime: 10.0))),
            .brewing(update(.brewing, timer: 10.2, at: t[2], raw: late, start: t[2].addingTimeInterval(-10.2))),
            .brewing(update(.brewingStopped, final: 0.5, at: t[3],
                            raw: BluetoothBrewingData(ev: true, backflush: false, brewingTime: 10.2,
                                                      brewingStoppedTime: 0.5))),
            .brewing(update(.brewing, timer: 0.0, dose: "DoseA", at: t[4],
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA"), start: t[4])),
            .brewing(update(.brewingStopped, final: 10.0, dose: "DoseA", at: t[5],
                            raw: BluetoothBrewingData(startedDoseIndex: "DoseA", brewingStoppedTime: 10.0))),
            .brewing(update(.brewing, timer: 10.2, at: t[6], raw: late, start: t[6].addingTimeInterval(-10.2))),
            .unsubscribed,
        ])
    }

    /// Angstrom-only: §4.11 — BT-NTF-FRAG-001: a brewing fragment matching no rule is kept and completed by the next one
    func testFragmentsAccumulate() async throws {
        let h = await Harness(start: Self.t0)
        try await h.start()
        let t2 = Self.t0.addingTimeInterval(2)
        h.notify(Data(#"{"BrewingUpdateGroup1Ev":true}"#.utf8), at: Self.t0.addingTimeInterval(1))
        h.notify(Data(#"{"BrewingUpdateGroup1Time":2.0}"#.utf8), at: t2)

        let events = await h.finish()
        assertEvents(events, [
            .subscribed,
            .brewing(update(.brewing, timer: 2.0, at: t2, raw: BluetoothBrewingData(ev: true, brewingTime: 2.0),
                            start: t2.addingTimeInterval(-2))),
            .unsubscribed,
        ])
    }

    // MARK: - Helpers

    private static func triple(_ event: ShotCounterEvent) -> (BluetoothBrewingState, Double?, Double?)? {
        guard case .brewing(let update) = event else { return nil }
        return (update.state, update.timerValue, update.finalShotTime)
    }

    private static func brewingUpdate(_ event: ShotCounterEvent) -> BluetoothShotCounterUpdate? {
        guard case .brewing(let update) = event else { return nil }
        return update
    }

    private static func isMarker(_ frame: RawBluetoothFrame, _ marker: String) -> Bool {
        frame.kind == .event && frame.data == Data(marker.utf8)
    }

    /// An expected update. `start` is passed explicitly, so a `.brewing` update without one has a nil
    /// start only if the caller says so — the initialiser's `receivedAt − timerValue` default never fills it.
    private func update(_ state: BluetoothBrewingState, timer: Double? = nil, final: Double? = nil,
                        dose: String? = nil, reason: String? = nil, at receivedAt: Date,
                        raw: BluetoothBrewingData, start: Date? = nil) -> BluetoothShotCounterUpdate {
        var update = BluetoothShotCounterUpdate(state: state, timerValue: timer, finalShotTime: final,
                                                startedDoseIndex: dose, stopReason: reason,
                                                receivedAt: receivedAt, raw: raw, brewingStartTime: start)
        update.brewingStartTime = start
        return update
    }

    private func with(_ data: BluetoothBrewingData, time: Double) -> BluetoothBrewingData {
        var data = data
        data.brewingTime = time
        return data
    }

    /// Compares the complete event lists. Updates compare field by field: everything exactly except the
    /// two dates, which allow 1 µs for the `Date` arithmetic of `receivedAt − timerValue`.
    private func assertEvents(_ actual: [ShotCounterEvent], _ expected: [ShotCounterEvent],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "event count; got \(actual)", file: file, line: line)
        for (index, (got, want)) in zip(actual, expected).enumerated() {
            switch (got, want) {
            case (.brewing(let g), .brewing(let w)):
                let context = "event \(index): \(g)"
                XCTAssertEqual(g.state, w.state, context, file: file, line: line)
                XCTAssertEqual(g.timerValue, w.timerValue, context, file: file, line: line)
                XCTAssertEqual(g.finalShotTime, w.finalShotTime, context, file: file, line: line)
                XCTAssertEqual(g.startedDoseIndex, w.startedDoseIndex, context, file: file, line: line)
                XCTAssertEqual(g.stopReason, w.stopReason, context, file: file, line: line)
                XCTAssertEqual(g.raw, w.raw, context, file: file, line: line)
                XCTAssertEqual(g.receivedAt.timeIntervalSince1970, w.receivedAt.timeIntervalSince1970,
                               accuracy: 1e-6, context, file: file, line: line)
                switch (g.brewingStartTime, w.brewingStartTime) {
                case (nil, nil):
                    break
                case (let gs?, let ws?):
                    XCTAssertEqual(gs.timeIntervalSince1970, ws.timeIntervalSince1970, accuracy: 1e-6, context,
                                   file: file, line: line)
                default:
                    XCTFail("brewingStartTime \(String(describing: g.brewingStartTime)) != "
                            + "\(String(describing: w.brewingStartTime)); \(context)", file: file, line: line)
                }
            default:
                XCTAssertEqual(got, want, "event \(index)", file: file, line: line)
            }
        }
    }
}

// MARK: - Private test harness

/// A client over a fake central with one `FakeBluetoothLink.laMarzocco(token: "token")`, plus
/// recorders on its shot-counter events and raw frames, registered before anything starts.
private final class Harness {
    let central = FakeBluetoothCentral()
    let sleeper = ManualBluetoothSleeper()
    let clock: BluetoothTestClock
    let link: FakeBluetoothLink
    let client: LaMarzoccoBluetoothClient
    let events: Recorder<ShotCounterEvent>
    let raw: Recorder<RawBluetoothFrame>
    /// Notifications put on the link so far, replays included.
    private var delivered = 0

    /// `replay == nil` keeps the fake's default replay, `tick("3.34")` (upstream's fake, TBC:176).
    convenience init(start: Date, replay: [Data]? = nil) async {
        await self.init(clock: BluetoothTestClock(start), replay: replay)
    }

    init(clock: BluetoothTestClock, replay: [Data]? = nil) async {
        self.clock = clock
        link = FakeBluetoothLink.laMarzocco(token: "token",
                                            settingResponses: [.machineMode: Data(#""BrewingMode""#.utf8)])
        if let replay {
            link.replayOnSubscribe = replay
        }
        central.enqueueConnect(.success(link))
        client = LaMarzoccoBluetoothClient(transport: .fake(central, sleeper: sleeper, clock: clock),
                                           peripheral: .fake, token: BluetoothAuthToken("token"))
        events = Recorder(await client.shotCounterEvents())
        raw = Recorder(await client.rawFrames())
    }

    func start(file: StaticString = #filePath, line: UInt = #line) async throws {
        let replays = link.replayOnSubscribe.count
        let started = try await client.startShotCounter()
        XCTAssertTrue(started, "startShotCounter()", file: file, line: line)
        delivered += replays
    }

    func notify(_ payload: Data, at receivedAt: Date) {
        link.notify(BluetoothConstants.shotCounterCharacteristic, payload, at: receivedAt)
        delivered += 1
    }

    /// Counts a notification the test put on the link itself (e.g. from a `beforeOp` hook).
    func countDelivered() {
        delivered += 1
    }

    /// Returns once the client has started handling every notification delivered so far: their raw
    /// frames are recorded, and each handler is synchronous, so the next actor call runs after them.
    func settle() async {
        let count = delivered
        let expectation = raw.expectation { frames in frames.filter { $0.kind == .notification }.count >= count }
        await XCTWaiter().fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(raw.elements.filter { $0.kind == .notification }.count, count, "raw notifications")
    }

    /// Settles, disconnects (upstream ends every test with `client.disconnect()`), waits for the
    /// resulting `.unsubscribed`, and returns every event recorded.
    func finish() async -> [ShotCounterEvent] {
        await settle()
        let unsubscribedBefore = events.elements.filter { $0 == .unsubscribed }.count
        await client.disconnect()
        let expectation = events.expectation { events in
            events.filter { $0 == .unsubscribed }.count > unsubscribedBefore
        }
        await XCTWaiter().fulfillment(of: [expectation], timeout: 5)
        return events.elements
    }
}

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

extension LaMarzoccoBluetoothClient {
    /// Runs `body` on the actor: read or set internal state from a test.
    fileprivate func peek<T: Sendable>(_ body: @Sendable (isolated LaMarzoccoBluetoothClient) -> T) -> T {
        body(self)
    }
}
