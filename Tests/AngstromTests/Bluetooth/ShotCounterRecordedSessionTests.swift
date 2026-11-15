import XCTest
@testable import Angstrom
import AngstromTestSupport

/// BT-REC-001 (SPEC §9.3.4): the recorded Linea Micra morning of 2026-10-05 (`REC`, copied verbatim to
/// `Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt`) replayed through the real client.
///
/// Synchronisation (no sleeps, no polling): the client handles a notification synchronously on the
/// actor and emits its raw `.notification` frame first. Once the raw tap has recorded the frame of a
/// session's last notification, every handler of that session has at least started, so the following
/// `stopShotCounter()` runs after all of them and its `.unsubscribed` lands after their events.
final class ShotCounterRecordedSessionTests: XCTestCase {
    /// 2026-10-05T00:00:00Z.
    private static let day = Date(timeIntervalSince1970: 1_791_158_400)

    /// Upstream: test_shot_counter_recorded_sessions (tests/test_bluetooth_client.py:912) [C29]
    func testRecordedMorning20261005() async throws {
        let sessions = try ShotCounterRecording.sessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map(\.count), [67, 13], "data lines per session, replay included")
        XCTAssertEqual(sessions.flatMap { $0 }.filter(\.isReplay).count, 2)

        let clock = BluetoothTestClock(Self.day)
        let central = FakeBluetoothCentral()
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        central.enqueueConnect(.success(link))
        let client = LaMarzoccoBluetoothClient(transport: .fake(central, sleeper: ManualBluetoothSleeper(), clock: clock),
                                               peripheral: .fake, token: BluetoothAuthToken("token"))
        let events = Recorder(await client.shotCounterEvents())
        let raw = Recorder(await client.rawFrames())

        var delivered = 0
        for session in sessions {
            let replay = try XCTUnwrap(session.first)
            XCTAssertTrue(replay.isReplay)
            // `clock.now, bleak_client.replay = session.replay`
            clock.set(replay.receivedAt)
            link.replayOnSubscribe = [replay.payload]
            let started = try await client.startShotCounter()
            XCTAssertTrue(started)
            delivered += 1
            for line in session.dropFirst() {
                XCTAssertFalse(line.isReplay)
                clock.set(line.receivedAt)
                link.notify(BluetoothConstants.shotCounterCharacteristic, line.payload, at: line.receivedAt)
                delivered += 1
            }
            // Every handler of this session has run before the stop (see the type comment).
            let count = delivered
            await fulfillment(of: [raw.expectation { $0.filter { $0.kind == .notification }.count >= count }],
                              timeout: 5)
            // The machine went to standby, which stops the shot counter.
            let unsubscribedBefore = events.elements.filter { $0 == .unsubscribed }.count
            await client.stopShotCounter()
            await fulfillment(of: [events.expectation { $0.filter { $0 == .unsubscribed }.count > unsubscribedBefore }],
                              timeout: 5)
        }
        let recorded = events.elements
        await client.disconnect()

        let updates = recorded.compactMap { event -> BluetoothShotCounterUpdate? in
            if case .brewing(let update) = event { return update }
            return nil
        }
        let telemetry = recorded.compactMap { event -> BluetoothMachineTelemetry? in
            if case .telemetry(let value) = event { return value }
            return nil
        }

        // MARK: Upstream assertions 1–6 (normative)

        // 1. Grouped brewing states (33 updates).
        var groups: [(BluetoothBrewingState, Int)] = []
        for update in updates {
            if let last = groups.last, last.0 == update.state {
                groups[groups.count - 1].1 += 1
            } else {
                groups.append((update.state, 1))
            }
        }
        XCTAssertEqual(groups.map(\.0), [.brewing, .flushed, .brewing, .flushed, .brewing, .brewingStopped,
                                         .brewing, .flushed])
        XCTAssertEqual(groups.map(\.1), [3, 1, 3, 1, 13, 1, 10, 1])
        XCTAssertEqual(updates.count, 33)

        // 2. receivedAt of the updates with timerValue == 0.0.
        let starts = updates.filter { $0.timerValue == 0.0 }
        XCTAssertEqual(starts.map { Self.millisecondsText($0.receivedAt) },
                       ["07:50:02.612", "07:50:09.360", "07:57:49.729", "07:59:22.007"])

        // 3. Late ticks, like 0.64 s at 07:50:11.215, don't move the start time:
        //    0 ≤ startEventReceivedAt − brewingStartTime < 0.05 s for every update with a start time.
        var startedAt: Date?
        var checkedStarts = 0
        for update in updates {
            if update.timerValue == 0.0 {
                startedAt = update.receivedAt
            }
            if let start = update.brewingStartTime {
                let shotStart = try XCTUnwrap(startedAt, "a start time before any start event")
                let lead = shotStart.timeIntervalSince(start)
                XCTAssertGreaterThanOrEqual(lead, 0, "\(Self.millisecondsText(update.receivedAt))")
                XCTAssertLessThan(lead, 0.05, "\(Self.millisecondsText(update.receivedAt))")
                checkedStarts += 1
            }
        }
        XCTAssertEqual(checkedStarts, 29, "every .brewing update carries a start time")
        XCTAssertEqual(updates.filter { $0.state == .brewing }.count, 29)

        // 4. The single stop.
        let stopped = try XCTUnwrap(updates.first { $0.state == .brewingStopped })
        XCTAssertEqual(Self.millisecondsText(stopped.receivedAt), "07:58:02.461")
        XCTAssertEqual(stopped.finalShotTime, 12.727)
        XCTAssertEqual(stopped.stopReason, "Manual")
        XCTAssertEqual(stopped.startedDoseIndex, "ContinuousDose")

        // 5. Telemetry machine modes, in order.
        XCTAssertEqual(telemetry.compactMap(\.machineMode), [.standby, .standby])

        // 6. Merged telemetry.
        let latest = telemetry.reduce(BluetoothMachineTelemetry()) { $0.merging($1) }
        XCTAssertEqual(latest.coffeeBoilerTemperature, 87)
        XCTAssertEqual(latest.steamBoilerTemperature, 115)
        XCTAssertEqual(latest.sleep, "command")
        let statistics = try XCTUnwrap(latest.machineStatistics)
        XCTAssertEqual(statistics["tot_doses"], .number(2123))

        // MARK: Counts (§9.3.4)

        XCTAssertEqual(telemetry.count, 43)
        XCTAssertEqual(telemetry.filter { $0.steamBoilerTemperature != nil }.count, 31)
        XCTAssertEqual(telemetry.filter { $0.coffeeBoilerTemperature != nil }.count, 7)
        XCTAssertEqual(telemetry.filter { $0.machineMode != nil }.count, 2)
        XCTAssertEqual(telemetry.filter { $0.sleep != nil }.count, 2)
        XCTAssertEqual(telemetry.filter { $0.machineStatistics != nil }.count, 1)
        let frames = raw.elements
        XCTAssertEqual(frames.filter { $0.kind == .notification }.count, 80, "every data line reached the client")
        XCTAssertEqual(frames.filter { $0.kind == .event && $0.data == Data(RawBluetoothFrame.replayDroppedMarker.utf8) }.count,
                       2, "replays dropped")

        // MARK: Event by event (REC line → events), golden start times aside

        let recLines = Self.recLineNumbers(sessions)
        XCTAssertEqual(recLines.flatMap { $0 }, Array(6...85), "REC:6-85 are the data lines")
        // Each expected event with the REC line that produces it (nil for the subscription events).
        var expected: [(event: Expected, line: Int?)] = []
        for lines in recLines {
            expected.append((.subscribed, nil))
            for line in lines.dropFirst() {
                expected.append(contentsOf: (Self.expectedByRECLine[line] ?? []).map { ($0, line) })
            }
            expected.append((.unsubscribed, nil))
        }
        XCTAssertEqual(recorded.count, expected.count, "events: \(recorded)")
        for (index, (got, want)) in zip(recorded, expected).enumerated() {
            Self.assert(got, matches: want.event, context: "event \(index) (REC:\(want.line.map(String.init) ?? "-"))")
        }
        let brewingLines = expected.compactMap { item -> Int? in
            switch item.event {
            case .brewing, .flushed, .stopped: return item.line
            default: return nil
            }
        }
        // Brewing updates carry their notification's receivedAt.
        let receivedAtByLine = Dictionary(uniqueKeysWithValues: zip(recLines.flatMap { $0 },
                                                                    sessions.flatMap { $0 }.map(\.receivedAt)))
        XCTAssertEqual(brewingLines.count, updates.count)
        for (update, line) in zip(updates, brewingLines) {
            XCTAssertEqual(update.receivedAt, receivedAtByLine[line], "REC:\(line)")
        }

        // MARK: Finer golden brewingStartTime (DERIVED, SPEC U22; ≤ 1 ms)

        XCTAssertEqual(brewingLines.count, 33)
        let goldenByLine = Self.goldenStartByRECLine
        for (update, line) in zip(updates, brewingLines) {
            if let golden = goldenByLine[line] {
                let start = try XCTUnwrap(update.brewingStartTime, "REC:\(line)")
                XCTAssertEqual(start.timeIntervalSince1970, Self.utc(golden).timeIntervalSince1970, accuracy: 0.001,
                               "REC:\(line): \(Self.millisecondsText(start)) vs golden \(golden)")
            } else {
                XCTAssertNil(update.brewingStartTime, "REC:\(line) (\(update.state))")
            }
        }
        XCTAssertEqual(Set(brewingLines.filter { goldenByLine[$0] != nil }), Set(goldenByLine.keys))
    }

    // MARK: - Expected events per REC line

    private enum Expected {
        case subscribed, unsubscribed
        case steam(Double), coffee(Double), standby, sleep(String), statistics
        case brewing(timer: Double), flushed, stopped(final: Double)
    }

    /// The events each REC data line produces (hand-copied from the fixture). Lines not listed — the
    /// replays (6, 73) and the heating coefficients (13, 78) — produce none.
    private static let expectedByRECLine: [Int: [Expected]] = {
        var map: [Int: [Expected]] = [:]
        let steam: [Int: Double] = [
            7: 112, 8: 115, 9: 118, 10: 121, 11: 124, 12: 127, 14: 130,
            24: 133, 25: 130, 27: 133, 28: 130, 29: 133, 30: 130, 31: 133, 32: 130, 33: 133, 34: 130, 35: 133,
            36: 130, 37: 133,
            52: 130, 53: 133, 54: 130, 55: 127, 56: 124, 57: 127, 58: 130,
            74: 106, 76: 109, 80: 112, 85: 115,
        ]
        let coffee: [Int: Double] = [26: 95, 70: 92, 75: 75, 77: 78, 79: 81, 81: 84, 84: 87]
        let brewing: [Int: Double] = [
            15: 0.0, 16: 0.089, 17: 1.159,
            19: 0.0, 20: 0.107, 21: 1.177,
            38: 0.0, 39: 0.108, 40: 1.178, 41: 2.251, 42: 3.324, 43: 4.394, 44: 5.479, 45: 6.556, 46: 7.631,
            47: 8.703, 48: 9.773, 49: 10.846, 50: 11.897,
            59: 0.0, 60: 0.118, 61: 1.189, 62: 2.259, 63: 3.343, 64: 4.423, 65: 5.485, 66: 6.557, 67: 7.639,
            68: 8.716,
        ]
        for (line, value) in steam { map[line] = [.steam(value)] }
        for (line, value) in coffee { map[line] = [.coffee(value)] }
        for (line, value) in brewing { map[line] = [.brewing(timer: value)] }
        for line in [18, 22, 69] { map[line] = [.flushed] }
        map[51] = [.stopped(final: 12.727)]
        map[23] = [.statistics]
        for line in [71, 82] { map[line] = [.standby] }
        for line in [72, 83] { map[line] = [.sleep("command")] }
        return map
    }()

    /// SPEC §9.3.4 finer golden, per REC line (UTC, 2026-10-05).
    private static let goldenStartByRECLine: [Int: String] = {
        var map: [Int: String] = [15: "07:50:02.612", 16: "07:50:02.593", 17: "07:50:02.583",
                                  38: "07:57:49.729", 39: "07:57:49.723"]
        for line in 19...21 { map[line] = "07:50:09.360" }
        for line in 40...43 { map[line] = "07:57:49.716" }
        for line in 44...50 { map[line] = "07:57:49.713" }
        for line in 59...63 { map[line] = "07:59:22.007" }
        for line in 64...68 { map[line] = "07:59:22.005" }
        return map
    }()

    /// `MachineStatistics` of REC:23, parsed.
    private static let recordedStatistics: BluetoothJSONValue = .object([
        "groups": .array([.object([
            "doses": .array([
                .object(["DoseA": .number(2123)]), .object(["DoseB": .number(0)]), .object(["DoseC": .number(0)]),
                .object(["DoseD": .number(0)]), .object(["ContinuousDose": .number(0)]),
            ]),
            "clean": .number(0), "ev_activations": .number(3577), "ev_ontime": .number(51431),
        ])]),
        "tot_doses": .number(2123),
        "boilers": .array([.object(["rsteam_ontime": .number(152)]), .object(["rcoffee_ontime": .number(217)])]),
        "tea": .object(["count": .number(0), "ev_activation": .number(0), "ev_ontime": .number(0)]),
        "pump_ontime": .number(41289), "machine_ontime": .number(25594), "refill_ontime": .number(1432),
        "count_liter": .number(0),
    ])

    private static func assert(_ event: ShotCounterEvent, matches expected: Expected, context: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch (event, expected) {
        case (.subscribed, .subscribed), (.unsubscribed, .unsubscribed):
            return
        case (.telemetry(let t), .steam(let value)):
            XCTAssertEqual(t, BluetoothMachineTelemetry(steamBoilerTemperature: value), context, file: file, line: line)
        case (.telemetry(let t), .coffee(let value)):
            XCTAssertEqual(t, BluetoothMachineTelemetry(coffeeBoilerTemperature: value), context, file: file, line: line)
        case (.telemetry(let t), .standby):
            XCTAssertEqual(t, BluetoothMachineTelemetry(machineMode: .standby), context, file: file, line: line)
        case (.telemetry(let t), .sleep(let value)):
            XCTAssertEqual(t, BluetoothMachineTelemetry(sleep: value), context, file: file, line: line)
        case (.telemetry(let t), .statistics):
            XCTAssertEqual(t, BluetoothMachineTelemetry(machineStatistics: recordedStatistics), context,
                           file: file, line: line)
        case (.brewing(let u), .brewing(let timer)):
            XCTAssertEqual(u.state, .brewing, context, file: file, line: line)
            XCTAssertEqual(u.timerValue, timer, context, file: file, line: line)
            XCTAssertNil(u.finalShotTime, context, file: file, line: line)
            XCTAssertEqual(u.startedDoseIndex, "ContinuousDose", context, file: file, line: line)
            XCTAssertNil(u.stopReason, context, file: file, line: line)
        case (.brewing(let u), .flushed):
            XCTAssertEqual(u.state, .flushed, context, file: file, line: line)
            XCTAssertNil(u.timerValue, context, file: file, line: line)
            XCTAssertNil(u.finalShotTime, context, file: file, line: line)
            XCTAssertEqual(u.startedDoseIndex, "ContinuousDose", context, file: file, line: line)
            XCTAssertNil(u.stopReason, context, file: file, line: line)
            XCTAssertEqual(u.raw.flushStoppedDoseIndex, "ContinuousDose", context, file: file, line: line)
            XCTAssertNotNil(u.raw.flushStoppedTime, context, file: file, line: line)
        case (.brewing(let u), .stopped(let final)):
            XCTAssertEqual(u.state, .brewingStopped, context, file: file, line: line)
            XCTAssertNil(u.timerValue, context, file: file, line: line)
            XCTAssertEqual(u.finalShotTime, final, context, file: file, line: line)
            XCTAssertEqual(u.startedDoseIndex, "ContinuousDose", context, file: file, line: line)
            XCTAssertEqual(u.stopReason, "Manual", context, file: file, line: line)
            XCTAssertEqual(u.raw.brewingStoppedStopType, "Continuous", context, file: file, line: line)
            XCTAssertEqual(u.raw.brewingStoppedDoseIndex, "ContinuousDose", context, file: file, line: line)
        default:
            XCTFail("\(context): got \(event), expected \(expected)", file: file, line: line)
        }
    }

    // MARK: - Helpers

    /// The REC line number of every data line, per session. REC:1-5 are file comments and every other
    /// line is a data line, so the n-th data line (0-based) is REC line 6 + n.
    private static func recLineNumbers(_ sessions: [[ShotCounterRecording.Line]]) -> [[Int]] {
        var next = 6
        return sessions.map { session in
            session.map { _ in
                defer { next += 1 }
                return next
            }
        }
    }

    /// `HH:MM:SS.mmm` in UTC, milliseconds truncated (upstream: `f"{t:%H:%M:%S.%f}"[:-3]`). Rounds to
    /// the microsecond first, as a Python `datetime` holds microseconds.
    private static func millisecondsText(_ date: Date) -> String {
        let micros = Int((date.timeIntervalSince(day) * 1_000_000).rounded())
        let millis = micros / 1_000
        return String(format: "%02d:%02d:%02d.%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1_000 % 60,
                      millis % 1_000)
    }

    /// `HH:MM:SS.mmm` on 2026-10-05, UTC.
    private static func utc(_ text: String) -> Date {
        let parts = text.split(separator: ":")
        let hours = Double(parts[0])!, minutes = Double(parts[1])!, seconds = Double(parts[2])!
        return day.addingTimeInterval(hours * 3600 + minutes * 60 + seconds)
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
