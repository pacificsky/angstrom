import XCTest
@testable import Angstrom
import AngstromTestSupport

/// The brewing state machine (`deriveState`) and `BrewingTracker` (SPEC §4.11), driven at the pure
/// level: every notification goes through `ShotCounterNotificationDecoder` and, like the client's
/// dispatch (§4.10 step 4), reaches the tracker only when its brewing part is non-empty.
final class BrewingStateMachineTests: XCTestCase {
    /// 2026-10-05T07:00:00Z (BT-NTF-START-001).
    private let t0 = Date(timeIntervalSince1970: 1_791_158_400 + 7 * 3600)

    // MARK: - §4.11 rule table and transition table

    /// Angstrom-only: §4.11 — every row of the `deriveState` rule table (in order, first match wins,
    /// with the update fields) and every row of the transition table, with exact updates and the
    /// next phase and `S` proven by a follow-up message.
    func testTransitionTable() throws {
        // --- deriveState: rule 1 (`.brewingStopped`), each disjunct on its own.
        let at = t0
        for data in [
            BluetoothBrewingData(brewingStoppedTime: 27.4),
            BluetoothBrewingData(brewingStoppedDoseIndex: "DoseA"),
            BluetoothBrewingData(brewingStoppedStopType: "X"),
            BluetoothBrewingData(brewingStoppedStopReason: "Manual"),
            BluetoothBrewingData(ev: false),
        ] {
            XCTAssertEqual(data.deriveState(receivedAt: at),
                           update(.brewingStopped, finalShotTime: data.brewingStoppedTime,
                                  stopReason: data.brewingStoppedStopReason, at: at, raw: data), "\(data)")
        }
        // Rule 1 wins over every later rule; `finalShotTime` and `startedDoseIndex` are carried.
        let stopBeatsAll = BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: true,
                                                brewingTime: 3, flushStoppedTime: 1.5,
                                                flushStoppedDoseIndex: "DoseA", brewingStoppedTime: 9.5,
                                                brewingStoppedStopReason: "Manual")
        XCTAssertEqual(stopBeatsAll.deriveState(receivedAt: at),
                       update(.brewingStopped, finalShotTime: 9.5, startedDoseIndex: "DoseA",
                              stopReason: "Manual", at: at, raw: stopBeatsAll))
        let evOffBeatsAll = BluetoothBrewingData(startedDoseIndex: "DoseA", ev: false, backflush: true,
                                                 brewingTime: 3, flushStoppedTime: 1.5)
        XCTAssertEqual(evOffBeatsAll.deriveState(receivedAt: at),
                       update(.brewingStopped, startedDoseIndex: "DoseA", at: at, raw: evOffBeatsAll))

        // --- Rule 2 (`.flushed`), each disjunct; it wins over rules 3 and 4. The flush time is NOT
        // surfaced as `finalShotTime`.
        for data in [BluetoothBrewingData(flushStoppedTime: 3.1),
                     BluetoothBrewingData(flushStoppedDoseIndex: "ContinuousDose")] {
            XCTAssertEqual(data.deriveState(receivedAt: at), update(.flushed, at: at, raw: data), "\(data)")
        }
        let flushBeatsBrewing = BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: true,
                                                     brewingTime: 3, flushStoppedTime: 3.1)
        XCTAssertEqual(flushBeatsBrewing.deriveState(receivedAt: at),
                       update(.flushed, startedDoseIndex: "DoseA", at: at, raw: flushBeatsBrewing))

        // --- Rule 3 (`.backflushing`) wins over rule 4; no timer, no start time.
        let backflush = BluetoothBrewingData(backflush: true)
        XCTAssertEqual(backflush.deriveState(receivedAt: at), update(.backflushing, at: at, raw: backflush))
        let backflushBeatsBrewing = BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: true,
                                                         brewingTime: 3)
        XCTAssertEqual(backflushBeatsBrewing.deriveState(receivedAt: at),
                       update(.backflushing, startedDoseIndex: "DoseA", at: at, raw: backflushBeatsBrewing))

        // --- Rule 4 (`.brewing`): a start (timer defaults to 0.0) or ev true with a time.
        let started = BluetoothBrewingData(startedDoseIndex: "DoseA")
        XCTAssertEqual(started.deriveState(receivedAt: at),
                       update(.brewing, timer: 0.0, startedDoseIndex: "DoseA", at: at, raw: started, start: at))
        let ticking = BluetoothBrewingData(ev: true, backflush: false, brewingTime: 1.17)
        XCTAssertEqual(ticking.deriveState(receivedAt: at),
                       update(.brewing, timer: 1.17, at: at, raw: ticking, start: at.addingTimeInterval(-1.17)))
        let startedAndTicking = BluetoothBrewingData(startedDoseIndex: "DoseB", brewingTime: 4.25)
        XCTAssertEqual(startedAndTicking.deriveState(receivedAt: at),
                       update(.brewing, timer: 4.25, startedDoseIndex: "DoseB", at: at, raw: startedAndTicking,
                              start: at.addingTimeInterval(-4.25)))
        let zeroTime = BluetoothBrewingData(ev: true, brewingTime: 0)
        XCTAssertEqual(zeroTime.deriveState(receivedAt: at),
                       update(.brewing, timer: 0.0, at: at, raw: zeroTime, start: at))

        // --- Rule 5: otherwise nil.
        for data in [BluetoothBrewingData(),
                     BluetoothBrewingData(ev: true),
                     BluetoothBrewingData(brewingTime: 2.0),
                     BluetoothBrewingData(backflush: false),
                     BluetoothBrewingData(ev: true, backflush: false),
                     BluetoothBrewingData(backflush: false, brewingTime: 2.0)] {
            XCTAssertNil(data.deriveState(receivedAt: at), "\(data)")
        }

        // --- Transition table. Each phase is reached through the tracker:
        // IDLE = fresh; PENDING = after FRAG; BREWING = after START or TICK; BACKFLUSH = after TICK_BF.
        let frag = BluetoothBrewingData(ev: true)
        let startD = BluetoothBrewingData(startedDoseIndex: "DoseA")
        let pendingFrag = Data(#"{"BrewingUpdateGroup1Ev":true}"#.utf8)

        // Row 1: any → START(i): `.brewing`, 0.0, nil, t_r; BREWING with S = t_r (the old S and the
        // old data are discarded).
        for phase in Phase.allCases {
            var tracker = BrewingTracker()
            let setup = try phase.enter(&tracker, at: t0)
            let tr = t0.addingTimeInterval(20)
            let u = feed(&tracker, BluetoothTestVectors.started, at: tr)
            XCTAssertEqual(u, update(.brewing, timer: 0.0, startedDoseIndex: "DoseA", at: tr, raw: startD, start: tr),
                           "\(phase)")
            // S = t_r: a later estimate keeps it, and the previous shot's data is gone.
            let next = try XCTUnwrap(feed(&tracker, BluetoothTestVectors.tick("1.5"), at: tr.addingTimeInterval(2)))
            XCTAssertEqual(next.brewingStartTime, tr, "\(phase)")
            XCTAssertEqual(next.raw, BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                          brewingTime: 1.5), "\(phase) (setup \(setup))")
        }

        // Row 2: IDLE/PENDING → TICK(t): `.brewing`, t, nil, t_r − t; BREWING with S = t_r − t.
        for phase in [Phase.idle, .pending] {
            var tracker = BrewingTracker()
            try phase.enter(&tracker, at: t0)
            let tr = t0.addingTimeInterval(10)
            let u = feed(&tracker, BluetoothTestVectors.tick("3.5"), at: tr)
            XCTAssertEqual(u, update(.brewing, timer: 3.5, at: tr,
                                     raw: BluetoothBrewingData(ev: true, backflush: false, brewingTime: 3.5),
                                     start: tr.addingTimeInterval(-3.5)), "\(phase)")
            let s = tr.addingTimeInterval(-3.5)
            // S = t_r − t: a later estimate (+0.25 s) does not move it.
            let next = try XCTUnwrap(feed(&tracker, BluetoothTestVectors.tick("4.5"), at: tr.addingTimeInterval(1.25)))
            XCTAssertEqual(next.brewingStartTime, s, "\(phase)")
        }

        // Row 3: BREWING → TICK(t): `.brewing`, t, nil, min(S, t_r − t).
        do {
            var tracker = BrewingTracker()
            _ = feed(&tracker, BluetoothTestVectors.started, at: t0)                 // S = t0
            let later = t0.addingTimeInterval(2.5)                                         // estimate t0 + 0.5
            let u1 = feed(&tracker, BluetoothTestVectors.tick("2"), at: later)
            XCTAssertEqual(u1, update(.brewing, timer: 2, startedDoseIndex: "DoseA", at: later,
                                      raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                                brewingTime: 2),
                                      start: t0))
            let earlier = t0.addingTimeInterval(3)                                         // estimate t0 − 0.1
            let u2 = feed(&tracker, BluetoothTestVectors.tick("3.1"), at: earlier)
            let s = earlier.addingTimeInterval(-3.1)
            XCTAssertEqual(u2, update(.brewing, timer: 3.1, startedDoseIndex: "DoseA", at: earlier,
                                      raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                                brewingTime: 3.1),
                                      start: s))
            // S = min(…): the earlier estimate is now kept against a later one.
            let u3 = try XCTUnwrap(feed(&tracker, BluetoothTestVectors.tick("4"), at: t0.addingTimeInterval(4.2)))
            XCTAssertEqual(u3.brewingStartTime, s)
        }

        // Row 4: IDLE/PENDING/BREWING → TICK_BF(t): `.backflushing`, nil, nil, nil; S unchanged.
        for phase in [Phase.idle, .pending, .brewing] {
            var tracker = BrewingTracker()
            let setup = try phase.enter(&tracker, at: t0)
            let tr = t0.addingTimeInterval(5)
            let u = feed(&tracker, BluetoothTestVectors.tick("0.1", backflush: true), at: tr)
            XCTAssertEqual(u, update(.backflushing, startedDoseIndex: setup.raw.startedDoseIndex, at: tr,
                                     raw: setup.raw.merging(BluetoothBrewingData(ev: true, backflush: true,
                                                                                 brewingTime: 0.1))),
                           "\(phase)")
            // S unchanged: BREWING keeps its S (t0) against a later estimate; IDLE/PENDING still have none.
            let tr2 = t0.addingTimeInterval(8)
            let next = try XCTUnwrap(feed(&tracker, BluetoothTestVectors.tick("2"), at: tr2), "\(phase)")
            XCTAssertEqual(next.state, .brewing, "\(phase)")
            XCTAssertEqual(next.brewingStartTime, phase == .brewing ? setup.start : tr2.addingTimeInterval(-2),
                           "\(phase)")
        }

        // Row 5: BACKFLUSH → TICK(t): `.brewing`, t, nil, min(S, t_r − t), or t_r − t when S is nil.
        do {
            // S nil (BACKFLUSH entered from IDLE).
            var tracker = BrewingTracker()
            _ = feed(&tracker, BluetoothTestVectors.tick("0.1", backflush: true), at: t0)
            let tr = t0.addingTimeInterval(4)
            let u = feed(&tracker, BluetoothTestVectors.tick("3"), at: tr)
            XCTAssertEqual(u, update(.brewing, timer: 3, at: tr,
                                     raw: BluetoothBrewingData(ev: true, backflush: false, brewingTime: 3),
                                     start: tr.addingTimeInterval(-3)))
        }
        do {
            // S set (START at t0, then TICK_BF): a later estimate keeps S, an earlier one replaces it.
            var tracker = BrewingTracker()
            _ = feed(&tracker, BluetoothTestVectors.started, at: t0)
            _ = feed(&tracker, BluetoothTestVectors.tick("0.5", backflush: true), at: t0.addingTimeInterval(1))
            let later = t0.addingTimeInterval(6)
            let u1 = feed(&tracker, BluetoothTestVectors.tick("5.5"), at: later)       // estimate t0 + 0.5
            XCTAssertEqual(u1, update(.brewing, timer: 5.5, startedDoseIndex: "DoseA", at: later,
                                      raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                                brewingTime: 5.5),
                                      start: t0))
            var tracker2 = BrewingTracker()
            _ = feed(&tracker2, BluetoothTestVectors.started, at: t0)
            _ = feed(&tracker2, BluetoothTestVectors.tick("0.5", backflush: true), at: t0.addingTimeInterval(1))
            let earlier = t0.addingTimeInterval(6)
            let u2 = feed(&tracker2, BluetoothTestVectors.tick("6.75"), at: earlier)   // estimate t0 − 0.75
            XCTAssertEqual(u2?.brewingStartTime, earlier.addingTimeInterval(-6.75))
            XCTAssertEqual(u2?.timerValue, 6.75)
        }

        // Row 6: any → EV_OFF: `.brewingStopped`, nil, D.brewingStoppedTime (nil), nil; IDLE (reset).
        let evOff = Data(#"{"BrewingUpdateGroup1Ev":false}"#.utf8)
        for phase in Phase.allCases {
            var tracker = BrewingTracker()
            let setup = try phase.enter(&tracker, at: t0)
            let tr = t0.addingTimeInterval(7)
            let u = feed(&tracker, evOff, at: tr)
            XCTAssertEqual(u, update(.brewingStopped, startedDoseIndex: setup.raw.startedDoseIndex, at: tr,
                                     raw: setup.raw.merging(BluetoothBrewingData(ev: false))), "\(phase)")
            assertIdle(&tracker, at: tr.addingTimeInterval(1), "EV_OFF from \(phase)")
        }

        // Row 7: any → BSTOP(t,…): `.brewingStopped`, nil, t, nil; stopReason set; startedDoseIndex is
        // the preceding START's index, if any; IDLE (reset).
        let bstop = Data(#"{"BrewingStoppedGroup1Time":27.4,"BrewingStoppedGroup1DoseIndex":"DoseA","BrewingStoppedGroup1StopType":"X","BrewingStoppedGroup1StopReason":"Manual"}"#.utf8)
        let bstopD = BluetoothBrewingData(brewingStoppedTime: 27.4, brewingStoppedDoseIndex: "DoseA",
                                          brewingStoppedStopType: "X", brewingStoppedStopReason: "Manual")
        for phase in Phase.allCases {
            var tracker = BrewingTracker()
            let setup = try phase.enter(&tracker, at: t0)
            let tr = t0.addingTimeInterval(30)
            let u = feed(&tracker, bstop, at: tr)
            XCTAssertEqual(u, update(.brewingStopped, finalShotTime: 27.4, startedDoseIndex: setup.raw.startedDoseIndex,
                                     stopReason: "Manual", at: tr, raw: setup.raw.merging(bstopD)), "\(phase)")
            assertIdle(&tracker, at: tr.addingTimeInterval(1), "BSTOP from \(phase)")
        }
        // Any single `BrewingStoppedGroup1*` key is a BSTOP.
        for (json, expected) in [
            (#"{"BrewingStoppedGroup1Time":12.727}"#, BluetoothBrewingData(brewingStoppedTime: 12.727)),
            (#"{"BrewingStoppedGroup1DoseIndex":"DoseA"}"#, BluetoothBrewingData(brewingStoppedDoseIndex: "DoseA")),
            (#"{"BrewingStoppedGroup1StopType":"Continuous"}"#, BluetoothBrewingData(brewingStoppedStopType: "Continuous")),
            (#"{"BrewingStoppedGroup1StopReason":"Manual"}"#, BluetoothBrewingData(brewingStoppedStopReason: "Manual")),
        ] {
            var tracker = BrewingTracker()
            _ = feed(&tracker, BluetoothTestVectors.started, at: t0)
            let u = feed(&tracker, Data(json.utf8), at: t0.addingTimeInterval(9))
            XCTAssertEqual(u, update(.brewingStopped, finalShotTime: expected.brewingStoppedTime,
                                     startedDoseIndex: "DoseA", stopReason: expected.brewingStoppedStopReason,
                                     at: t0.addingTimeInterval(9), raw: startD.merging(expected)), json)
            assertIdle(&tracker, at: t0.addingTimeInterval(10), json)
        }

        // Row 8: any → FSTOP(t,i): `.flushed`, nil, nil, nil (`raw.flushStoppedTime = t`); IDLE (reset).
        let fstop = Data(#"{"FlushStoppedGroup1DoseIndex":"ContinuousDose","FlushStoppedGroup1Time":1.891}"#.utf8)
        let fstopD = BluetoothBrewingData(flushStoppedTime: 1.891, flushStoppedDoseIndex: "ContinuousDose")
        for phase in Phase.allCases {
            var tracker = BrewingTracker()
            let setup = try phase.enter(&tracker, at: t0)
            let tr = t0.addingTimeInterval(2)
            let u = feed(&tracker, fstop, at: tr)
            XCTAssertEqual(u, update(.flushed, startedDoseIndex: setup.raw.startedDoseIndex, at: tr,
                                     raw: setup.raw.merging(fstopD)), "\(phase)")
            XCTAssertEqual(u?.raw.flushStoppedTime, 1.891)
            XCTAssertNil(u?.finalShotTime)
            assertIdle(&tracker, at: tr.addingTimeInterval(1), "FSTOP from \(phase)")
        }
        for (json, expected) in [
            (#"{"FlushStoppedGroup1Time":3.1}"#, BluetoothBrewingData(flushStoppedTime: 3.1)),
            (#"{"FlushStoppedGroup1DoseIndex":"DoseA"}"#, BluetoothBrewingData(flushStoppedDoseIndex: "DoseA")),
        ] {
            var tracker = BrewingTracker()
            _ = feed(&tracker, BluetoothTestVectors.started, at: t0)
            let u = feed(&tracker, Data(json.utf8), at: t0)
            XCTAssertEqual(u, update(.flushed, startedDoseIndex: "DoseA", at: t0, raw: startD.merging(expected)), json)
            assertIdle(&tracker, at: t0.addingTimeInterval(1), json)
        }

        // Row 9: IDLE/PENDING → FRAG: nothing; PENDING (the fragment is kept).
        do {
            var tracker = BrewingTracker()
            XCTAssertNil(feed(&tracker, pendingFrag, at: t0))                          // IDLE → PENDING
            XCTAssertNil(feed(&tracker, Data(#"{"BrewingUpdateGroup1Backflush":false}"#.utf8), at: t0))
            // Kept: a time alone now completes `ev == true ∧ brewingTime`.
            let tr = t0.addingTimeInterval(1)
            let u = feed(&tracker, Data(#"{"BrewingUpdateGroup1Time":2.0}"#.utf8), at: tr)
            XCTAssertEqual(u, update(.brewing, timer: 2.0, at: tr,
                                     raw: frag.merging(BluetoothBrewingData(backflush: false, brewingTime: 2.0)),
                                     start: tr.addingTimeInterval(-2.0)))
        }

        // Row 10: any → unparseable or telemetry-only: nothing; tracker untouched.
        for phase in Phase.allCases {
            var tracker = BrewingTracker()
            let setup = try phase.enter(&tracker, at: t0)
            for payload in [Data("not json".utf8), Data([0xFF, 0xFE]), Data(#"{"SteamBoilerUpdateTemperature":130}"#.utf8),
                            Data(#"{"BrewingUpdateGroup1Time":"abc"}"#.utf8), Data(#"{"SomethingNew":1}"#.utf8)] {
                XCTAssertNil(feed(&tracker, payload, at: t0.addingTimeInterval(1)), "\(phase)")
            }
            // Untouched: the next message derives from the setup data and the setup S.
            let tr = t0.addingTimeInterval(3)
            let u = feed(&tracker, Data(#"{"BrewingUpdateGroup1Time":1.0}"#.utf8), at: tr)
            let merged = setup.raw.merging(BluetoothBrewingData(brewingTime: 1.0))
            let expected = merged.deriveState(receivedAt: tr)
            switch phase {
            case .idle:
                XCTAssertNil(u, "a time alone from IDLE stays pending")
            case .pending:
                XCTAssertEqual(u, update(.brewing, timer: 1.0, at: tr, raw: merged, start: tr.addingTimeInterval(-1.0)))
            case .brewing:
                XCTAssertEqual(u, update(.brewing, timer: 1.0, startedDoseIndex: "DoseA", at: tr, raw: merged,
                                         start: setup.start))
            case .backflush:
                XCTAssertEqual(u, update(.backflushing, at: tr, raw: merged))
            }
            XCTAssertEqual(u?.state, expected?.state, "\(phase)")
        }
    }

    // MARK: - §9.3.3 sequences

    /// Upstream: test_shot_counter_state_machine (tests/test_bluetooth_client.py:784) [C24]
    /// BT-NTF-SEQ-001 at tracker level (supplementary to C24, which the client suite owns).
    func testSequenceAtTrackerLevel() throws {
        let steps: [(Data, BluetoothBrewingState, Double?, Double?)] = [
            (BluetoothTestVectors.started, .brewing, 0.0, nil),
            (BluetoothTestVectors.tick("0.1"), .brewing, 0.1, nil),
            (BluetoothTestVectors.tick("1.17"), .brewing, 1.17, nil),
            (Data(#"{"BrewingUpdateGroup1Ev":false}"#.utf8), .brewingStopped, nil, nil),
            (Data(#"{"BrewingStoppedGroup1Time":27.4,"BrewingStoppedGroup1DoseIndex":"DoseA","BrewingStoppedGroup1StopType":"X","BrewingStoppedGroup1StopReason":"Manual"}"#.utf8),
             .brewingStopped, nil, 27.4),
            (Data(#"{"FlushStoppedGroup1Time":3.1}"#.utf8), .flushed, nil, nil),
            (BluetoothTestVectors.started, .brewing, 0.0, nil),
            (BluetoothTestVectors.tick("0.1", backflush: true), .backflushing, nil, nil),
            (Data(#"{"BrewingUpdateGroup1Ev":false}"#.utf8), .brewingStopped, nil, nil),
            // without a start event, e.g. when subscribing during a shot
            (BluetoothTestVectors.tick("5.2"), .brewing, 5.2, nil),
        ]
        var tracker = BrewingTracker()
        for (index, (payload, state, timer, final)) in steps.enumerated() {
            let at = t0.addingTimeInterval(Double(index))
            let u = try XCTUnwrap(feed(&tracker, payload, at: at), "step \(index + 1)")
            XCTAssertEqual(u.state, state, "step \(index + 1)")
            XCTAssertEqual(u.timerValue, timer, "step \(index + 1)")
            XCTAssertEqual(u.finalShotTime, final, "step \(index + 1)")
            XCTAssertEqual(u.receivedAt, at, "step \(index + 1)")
        }
        // The stop at step 5 carries the stop reason and the BSTOP dose index only (the EV_OFF at
        // step 4 reset the tracker, so the START's index is gone).
        var t = BrewingTracker()
        for (payload, _, _, _) in steps.prefix(4) { _ = feed(&t, payload, at: t0) }
        let stop = try XCTUnwrap(feed(&t, steps[4].0, at: t0))
        XCTAssertEqual(stop.stopReason, "Manual")
        XCTAssertNil(stop.startedDoseIndex)
        XCTAssertEqual(stop.raw.brewingStoppedDoseIndex, "DoseA")
    }

    /// Upstream: test_shot_counter_brewing_start_time (tests/test_bluetooth_client.py:980) [C30]
    /// BT-NTF-START-001 at tracker level.
    func testEarliestStartTime() throws {
        let clock = BluetoothTestClock(t0)
        var tracker = BrewingTracker()

        let started = try XCTUnwrap(feed(&tracker, BluetoothTestVectors.started, at: clock.now()))
        XCTAssertEqual(started.brewingStartTime, t0)

        // a late tick doesn't move the start
        clock.advance(by: 5.07)
        let late = try XCTUnwrap(feed(&tracker, BluetoothTestVectors.tick("5"), at: clock.now()))
        XCTAssertEqual(late.timerValue, 5)
        XCTAssertEqual(late.brewingStartTime, t0)
        XCTAssertEqual(late.startedDoseIndex, "DoseA")
        XCTAssertEqual(late.receivedAt, t0.addingTimeInterval(5.07))

        // an earlier estimate does
        clock.advance(by: 1)
        let now = clock.now()
        let earlier = try XCTUnwrap(feed(&tracker, BluetoothTestVectors.tick("6.1"), at: now))
        XCTAssertEqual(earlier.brewingStartTime, now.addingTimeInterval(-6.1))
        let bst = try XCTUnwrap(earlier.brewingStartTime)
        XCTAssertEqual(bst.timeIntervalSince(t0), -0.03, accuracy: 1e-6)   // Date resolution near 2026 is ~1e-7 s
        XCTAssertEqual(earlier.timerValue, 6.1)
    }

    /// Angstrom-only: §4.11 — BT-NTF-LATE-001: a late tick after a stop re-enters `.brewing` (no guard,
    /// parity; Q9), with no start index and a fresh start estimate.
    func testLateTickAfterStopReentersBrewing() throws {
        var tracker = BrewingTracker()
        _ = feed(&tracker, BluetoothTestVectors.started, at: t0)
        let stopAt = t0.addingTimeInterval(10.5)
        let stop = feed(&tracker, Data(#"{"BrewingStoppedGroup1Time":10.0}"#.utf8), at: stopAt)
        XCTAssertEqual(stop, update(.brewingStopped, finalShotTime: 10.0, startedDoseIndex: "DoseA", at: stopAt,
                                    raw: BluetoothBrewingData(startedDoseIndex: "DoseA", brewingStoppedTime: 10.0)))

        let tickAt = t0.addingTimeInterval(10.7)
        let tick = feed(&tracker, BluetoothTestVectors.tick("10.2"), at: tickAt)
        XCTAssertEqual(tick, update(.brewing, timer: 10.2, at: tickAt,
                                    raw: BluetoothBrewingData(ev: true, backflush: false, brewingTime: 10.2),
                                    start: tickAt.addingTimeInterval(-10.2)))
    }

    /// Angstrom-only: §4.11 — BT-NTF-FRAG-001: a fragment with no state is kept and completed by the
    /// next one.
    func testFragmentAccumulates() throws {
        var tracker = BrewingTracker()
        XCTAssertNil(feed(&tracker, Data(#"{"BrewingUpdateGroup1Ev":true}"#.utf8), at: t0))
        let tr = t0.addingTimeInterval(2.5)
        let u = feed(&tracker, Data(#"{"BrewingUpdateGroup1Time":2.0}"#.utf8), at: tr)
        XCTAssertEqual(u, update(.brewing, timer: 2.0, at: tr, raw: BluetoothBrewingData(ev: true, brewingTime: 2.0),
                                 start: tr.addingTimeInterval(-2)))

        // The other order, through more than one fragment.
        var other = BrewingTracker()
        XCTAssertNil(feed(&other, Data(#"{"BrewingUpdateGroup1Time":4.0}"#.utf8), at: t0))
        XCTAssertNil(feed(&other, Data(#"{"BrewingUpdateGroup1Backflush":false}"#.utf8), at: t0))
        let u2 = feed(&other, Data(#"{"BrewingUpdateGroup1Ev":true}"#.utf8), at: tr)
        XCTAssertEqual(u2, update(.brewing, timer: 4.0, at: tr,
                                  raw: BluetoothBrewingData(ev: true, backflush: false, brewingTime: 4.0),
                                  start: tr.addingTimeInterval(-4)))
    }

    /// Angstrom-only: D5 — BT-NTF-COERCE-001: a string `"false"` ev stops a shot (upstream `bool("false")`
    /// would make it `.brewing(1.0)`).
    func testEvFalseStringIsStop() throws {
        var tracker = BrewingTracker()
        let payload = Data(#"{"BrewingUpdateGroup1Ev":"false","BrewingUpdateGroup1Time":1}"#.utf8)
        let u = feed(&tracker, payload, at: t0)
        XCTAssertEqual(u, update(.brewingStopped, at: t0, raw: BluetoothBrewingData(ev: false, brewingTime: 1)))
        assertIdle(&tracker, at: t0.addingTimeInterval(1), "after the D5 stop")

        // The same payload with a string "true" (any case) is a running shot.
        for text in ["true", "TRUE", "True"] {
            var t = BrewingTracker()
            let p = Data(#"{"BrewingUpdateGroup1Ev":"\#(text)","BrewingUpdateGroup1Time":1}"#.utf8)
            XCTAssertEqual(feed(&t, p, at: t0),
                           update(.brewing, timer: 1, at: t0, raw: BluetoothBrewingData(ev: true, brewingTime: 1),
                                  start: t0.addingTimeInterval(-1)), text)
        }
    }

    // MARK: - §9.3.4 recorded session

    /// Upstream: test_shot_counter_recorded_sessions (tests/test_bluetooth_client.py:912) [C29]
    /// Pure BT-REC-001 (supplementary to C29): every REC notification through decoder + tracker (a fresh
    /// tracker per session, replays skipped), SPEC §9.3.4 assertions 1–6, the counts and the finer golden.
    func testRecordedMorningPureGolden() throws {
        let sessions = try ShotCounterRecording.sessions()
        XCTAssertEqual(sessions.count, 2)

        var updates: [BluetoothShotCounterUpdate] = []
        var telemetry: [BluetoothMachineTelemetry] = []
        var replays = 0, dataLines = 0, ignored = 0, dropped = 0
        for session in sessions {
            var tracker = BrewingTracker()                 // replaced on every successful subscribe
            for line in session {
                dataLines += 1
                if line.isReplay { replays += 1; continue }
                guard let decoded = ShotCounterNotificationDecoder.decode(line.payload) else {
                    dropped += 1
                    continue
                }
                if decoded.brewing.isEmpty && decoded.telemetry.isEmpty { ignored += 1 }
                if !decoded.brewing.isEmpty, let u = tracker.process(decoded.brewing, receivedAt: line.receivedAt) {
                    updates.append(u)
                }
                if !decoded.telemetry.isEmpty { telemetry.append(decoded.telemetry) }
            }
        }

        // 1. Grouped brewing states (33 updates).
        var groups: [(BluetoothBrewingState, Int)] = []
        for u in updates {
            if let last = groups.last, last.0 == u.state {
                groups[groups.count - 1].1 += 1
            } else {
                groups.append((u.state, 1))
            }
        }
        XCTAssertEqual(groups.map { "\($0.0.rawValue)×\($0.1)" },
                       ["Brewing×3", "Flushed×1", "Brewing×3", "Flushed×1", "Brewing×13", "BrewingStopped×1",
                        "Brewing×10", "Flushed×1"])
        XCTAssertEqual(updates.count, 33)

        // 2. receivedAt of the updates with timerValue == 0.0.
        XCTAssertEqual(updates.filter { $0.timerValue == 0.0 }.map(\.receivedAt),
                       [rec("07:50:02.612"), rec("07:50:09.360"), rec("07:57:49.729"), rec("07:59:22.007")])

        // 3. For every .brewing update: 0 ≤ startEventReceivedAt − brewingStartTime < 0.05 s.
        var startedAt: Date?
        var checked = 0
        for u in updates {
            if u.timerValue == 0.0 { startedAt = u.receivedAt }
            if let bst = u.brewingStartTime {
                let s = try XCTUnwrap(startedAt)
                let lag = s.timeIntervalSince(bst)
                XCTAssertGreaterThanOrEqual(lag, 0, "\(u.receivedAt)")
                XCTAssertLessThan(lag, 0.05, "\(u.receivedAt)")
                checked += 1
            }
        }
        XCTAssertEqual(checked, updates.filter { $0.state == .brewing }.count)
        XCTAssertEqual(checked, 29)

        // 4. The single stop.
        let stops = updates.filter { $0.state == .brewingStopped }
        XCTAssertEqual(stops.count, 1)
        let stop = try XCTUnwrap(stops.first)
        XCTAssertEqual(stop.receivedAt, rec("07:58:02.461"))
        XCTAssertEqual(stop.finalShotTime, 12.727)
        XCTAssertEqual(stop.stopReason, "Manual")
        XCTAssertEqual(stop.startedDoseIndex, "ContinuousDose")

        // 5. Telemetry machine modes, in order.
        XCTAssertEqual(telemetry.compactMap(\.machineMode), [.standby, .standby])

        // 6. Merged telemetry.
        let merged = telemetry.reduce(BluetoothMachineTelemetry()) { $0.merging($1) }
        XCTAssertEqual(merged.coffeeBoilerTemperature, 87)
        XCTAssertEqual(merged.steamBoilerTemperature, 115)
        XCTAssertEqual(merged.sleep, "command")
        XCTAssertEqual(merged.machineStatistics?["tot_doses"], .number(2123))

        // Counts: 43 telemetry events (31 steam, 7 coffee, 2 mode, 2 sleep, 1 statistics), 2 replays,
        // 2 heating-coefficient lines ignored; 33 + 43 + 2 + 2 = 80 data lines; nothing dropped.
        XCTAssertEqual(telemetry.count, 43)
        XCTAssertEqual(telemetry.filter { $0.steamBoilerTemperature != nil }.count, 31)
        XCTAssertEqual(telemetry.filter { $0.coffeeBoilerTemperature != nil }.count, 7)
        XCTAssertEqual(telemetry.filter { $0.machineMode != nil }.count, 2)
        XCTAssertEqual(telemetry.filter { $0.sleep != nil }.count, 2)
        XCTAssertEqual(telemetry.filter { $0.machineStatistics != nil }.count, 1)
        XCTAssertEqual(replays, 2)
        XCTAssertEqual(ignored, 2)
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(dataLines, 80)

        // Finer golden (SPEC §9.3.4, U22): per update in order, (REC receivedAt, state, brewingStartTime).
        let golden: [(String, BluetoothBrewingState, String?)] = [
            ("07:50:02.612", .brewing, "07:50:02.612"),         // REC 15
            ("07:50:02.682", .brewing, "07:50:02.593"),         // 16
            ("07:50:03.742", .brewing, "07:50:02.583"),         // 17
            ("07:50:04.525", .flushed, nil),                    // 18
            ("07:50:09.360", .brewing, "07:50:09.360"),         // 19
            ("07:50:09.507", .brewing, "07:50:09.360"),         // 20
            ("07:50:11.215", .brewing, "07:50:09.360"),         // 21 (late tick)
            ("07:50:11.218", .flushed, nil),                    // 22
            ("07:57:49.729", .brewing, "07:57:49.729"),         // 38
            ("07:57:49.831", .brewing, "07:57:49.723"),         // 39
            ("07:57:50.894", .brewing, "07:57:49.716"),         // 40
            ("07:57:51.983", .brewing, "07:57:49.716"),         // 41
            ("07:57:53.054", .brewing, "07:57:49.716"),         // 42
            ("07:57:54.132", .brewing, "07:57:49.716"),         // 43
            ("07:57:55.192", .brewing, "07:57:49.713"),         // 44
            ("07:57:56.282", .brewing, "07:57:49.713"),         // 45
            ("07:57:57.352", .brewing, "07:57:49.713"),         // 46
            ("07:57:58.433", .brewing, "07:57:49.713"),         // 47
            ("07:57:59.493", .brewing, "07:57:49.713"),         // 48
            ("07:58:00.583", .brewing, "07:57:49.713"),         // 49
            ("07:58:01.659", .brewing, "07:57:49.713"),         // 50
            ("07:58:02.461", .brewingStopped, nil),             // 51 (final 12.727)
            ("07:59:22.007", .brewing, "07:59:22.007"),         // 59
            ("07:59:22.140", .brewing, "07:59:22.007"),         // 60
            ("07:59:23.219", .brewing, "07:59:22.007"),         // 61
            ("07:59:24.267", .brewing, "07:59:22.007"),         // 62
            ("07:59:25.392", .brewing, "07:59:22.007"),         // 63
            ("07:59:26.428", .brewing, "07:59:22.005"),         // 64
            ("07:59:27.520", .brewing, "07:59:22.005"),         // 65
            ("07:59:28.592", .brewing, "07:59:22.005"),         // 66
            ("07:59:29.798", .brewing, "07:59:22.005"),         // 67
            ("07:59:30.726", .brewing, "07:59:22.005"),         // 68
            ("07:59:31.412", .flushed, nil),                    // 69
        ]
        XCTAssertEqual(updates.count, golden.count)
        for (u, (received, state, start)) in zip(updates, golden) {
            XCTAssertEqual(u.receivedAt, rec(received), received)
            XCTAssertEqual(u.state, state, received)
            if let start {
                let bst = try XCTUnwrap(u.brewingStartTime, received)
                XCTAssertEqual(bst.timeIntervalSince(rec(start)), 0, accuracy: 0.001, received)
            } else {
                XCTAssertNil(u.brewingStartTime, received)
            }
        }
    }

    // MARK: - Helpers

    /// The tracker phases of §4.11.
    private enum Phase: CaseIterable, CustomStringConvertible {
        case idle, pending, brewing, backflush

        var description: String {
            switch self {
            case .idle: "IDLE"
            case .pending: "PENDING"
            case .brewing: "BREWING"
            case .backflush: "BACKFLUSH"
            }
        }

        /// Puts a fresh tracker into this phase at `at` and returns the tracker's data `D` and `S`.
        /// IDLE: nothing. PENDING: `{"BrewingUpdateGroup1Ev":true}`. BREWING: START("DoseA"), so S = at.
        /// BACKFLUSH: TICK_BF(0.1) from IDLE, so S is nil.
        @discardableResult
        func enter(_ tracker: inout BrewingTracker, at: Date) throws -> (raw: BluetoothBrewingData, start: Date?) {
            switch self {
            case .idle:
                return (BluetoothBrewingData(), nil)
            case .pending:
                let u = BrewingStateMachineTests.feed(&tracker, Data(#"{"BrewingUpdateGroup1Ev":true}"#.utf8), at: at)
                XCTAssertNil(u)
                return (BluetoothBrewingData(ev: true), nil)
            case .brewing:
                let u = try XCTUnwrap(BrewingStateMachineTests.feed(&tracker, BluetoothTestVectors.started, at: at))
                XCTAssertEqual(u.state, .brewing)
                XCTAssertEqual(u.brewingStartTime, at)
                return (BluetoothBrewingData(startedDoseIndex: "DoseA"), at)
            case .backflush:
                let u = try XCTUnwrap(BrewingStateMachineTests.feed(&tracker,
                                                                        BluetoothTestVectors.tick("0.1", backflush: true),
                                                                        at: at))
                XCTAssertEqual(u.state, .backflushing)
                return (BluetoothBrewingData(ev: true, backflush: true, brewingTime: 0.1), nil)
            }
        }
    }

    /// The client's dispatch (§4.10 steps 3–4): decode, then run the brewing part through the tracker
    /// only when it is non-empty. A dropped or brewing-less payload returns nil and never reaches the
    /// tracker.
    private static func feed(_ tracker: inout BrewingTracker, _ payload: Data, at: Date) -> BluetoothShotCounterUpdate? {
        guard let decoded = ShotCounterNotificationDecoder.decode(payload), !decoded.brewing.isEmpty else { return nil }
        return tracker.process(decoded.brewing, receivedAt: at)
    }

    private func feed(_ tracker: inout BrewingTracker, _ payload: Data, at: Date) -> BluetoothShotCounterUpdate? {
        Self.feed(&tracker, payload, at: at)
    }

    /// Proves the tracker is IDLE (D empty, S nil): a lone time fragment derives nothing (a kept
    /// `ev`/start/backflush/stop would derive a state), and the completing `ev` yields a start that is
    /// its own estimate (a kept S from before `at` would win the min).
    private func assertIdle(_ tracker: inout BrewingTracker, at: Date, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(feed(&tracker, Data(#"{"BrewingUpdateGroup1Time":2.0}"#.utf8), at: at), context,
                     file: file, line: line)
        let u = feed(&tracker, Data(#"{"BrewingUpdateGroup1Ev":true}"#.utf8), at: at.addingTimeInterval(0.5))
        XCTAssertEqual(u, update(.brewing, timer: 2.0, at: at.addingTimeInterval(0.5),
                                 raw: BluetoothBrewingData(ev: true, brewingTime: 2.0),
                                 start: at.addingTimeInterval(0.5).addingTimeInterval(-2.0)), context,
                       file: file, line: line)
    }

    private func update(_ state: BluetoothBrewingState, timer: Double? = nil, finalShotTime: Double? = nil,
                        startedDoseIndex: String? = nil, stopReason: String? = nil, at: Date,
                        raw: BluetoothBrewingData, start: Date? = nil) -> BluetoothShotCounterUpdate {
        BluetoothShotCounterUpdate(state: state, timerValue: timer, finalShotTime: finalShotTime,
                                   startedDoseIndex: startedDoseIndex, stopReason: stopReason, receivedAt: at,
                                   raw: raw, brewingStartTime: start)
    }

    /// `HH:MM:SS.mmm` on 2026-10-05 UTC, computed exactly as `ShotCounterRecording` does.
    private func rec(_ time: String) -> Date {
        let parts = time.split(separator: ":")
        let secondParts = parts[2].split(separator: ".")
        let h = Int(parts[0])!, m = Int(parts[1])!, s = Int(secondParts[0])!, ms = Int(secondParts[1])!
        let micros = ((h * 60 + m) * 60 + s) * 1_000_000 + ms * 1_000
        return Date(timeIntervalSince1970: 1_791_158_400).addingTimeInterval(Double(micros) / 1_000_000)
    }
}
