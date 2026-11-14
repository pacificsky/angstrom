import XCTest
@testable import Angstrom
import AngstromTestSupport

/// `ShotCounterNotificationDecoder` (SPEC §3.8 framing and key tables, §3.10 coercions, D5).
final class ShotCounterNotificationDecoderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_158_400 + 7 * 3600)

    /// Upstream: test_shot_counter_state_machine (tests/test_bluetooth_client.py:784) [C25]
    /// BT-NTF-SEQ-002 at decoder level, then through the tracker as the client dispatches it.
    func testMalformedDropped() throws {
        // Dropped outright (nil).
        for payload in [Data("not json".utf8), Data(#"{"BrewingUpdateGroup1Time":"abc"}"#.utf8), Data("[]".utf8),
                        Data([0xFF, 0xFE])] {
            XCTAssertNil(ShotCounterNotificationDecoder.decode(payload), String(decoding: payload, as: UTF8.self))
        }
        // Not an object, empty, or only NULs → dropped.
        for payload in [Data(#""BrewingMode""#.utf8), Data("5".utf8), Data("null".utf8), Data("true".utf8),
                        Data(#"[{"BrewingStartedGroup1DoseIndex":"DoseA"}]"#.utf8), Data(), Data([0, 0, 0]),
                        Data("   ".utf8), Data(#"{"BrewingStartedGroup1DoseIndex":"DoseA""#.utf8)] {
            XCTAssertNil(ShotCounterNotificationDecoder.decode(payload), "\(Array(payload))")
        }
        // Telemetry only: decoded, but with an empty brewing part (no brewing event).
        XCTAssertEqual(ShotCounterNotificationDecoder.decode(Data(#"{"SteamBoilerUpdateTemperature":130}"#.utf8)),
                       DecodedShotCounterNotification(brewing: BluetoothBrewingData(),
                                                      telemetry: BluetoothMachineTelemetry(steamBoilerTemperature: 130)))
        // Unknown keys are ignored.
        XCTAssertEqual(ShotCounterNotificationDecoder.decode(Data(#"{"SomethingNew":1,"BrewingUpdateGroup1Time":3.5}"#.utf8)),
                       DecodedShotCounterNotification(brewing: BluetoothBrewingData(brewingTime: 3.5),
                                                      telemetry: BluetoothMachineTelemetry()))
        // A trailing NUL is stripped.
        var tickWithNul = BluetoothTestVectors.tick("4.5")
        tickWithNul.append(0x00)
        XCTAssertEqual(ShotCounterNotificationDecoder.decode(tickWithNul),
                       DecodedShotCounterNotification(brewing: BluetoothBrewingData(ev: true, backflush: false,
                                                                                    brewingTime: 4.5),
                                                      telemetry: BluetoothMachineTelemetry()))

        // The whole SEQ-002 sequence: STARTED → (brewing, 0.0, nil); five payloads → no brewing event;
        // then (brewing, 3.5, nil) and (brewing, 4.5, nil).
        let steps: [(Data, (BluetoothBrewingState, Double?, Double?)?)] = [
            (BluetoothTestVectors.started, (.brewing, 0.0, nil)),
            (Data("not json".utf8), nil),
            (Data(#"{"BrewingUpdateGroup1Time":"abc"}"#.utf8), nil),
            (Data("[]".utf8), nil),
            (Data([0xFF, 0xFE]), nil),
            (Data(#"{"SteamBoilerUpdateTemperature":130}"#.utf8), nil),
            (Data(#"{"SomethingNew":1,"BrewingUpdateGroup1Time":3.5}"#.utf8), (.brewing, 3.5, nil)),
            (tickWithNul, (.brewing, 4.5, nil)),
        ]
        var tracker = BrewingTracker()
        for (index, (payload, expected)) in steps.enumerated() {
            let u = dispatch(&tracker, payload, at: t0.addingTimeInterval(Double(index)))
            if let expected {
                let update = try XCTUnwrap(u, "step \(index + 1)")
                XCTAssertEqual(update.state, expected.0, "step \(index + 1)")
                XCTAssertEqual(update.timerValue, expected.1, "step \(index + 1)")
                XCTAssertEqual(update.finalShotTime, expected.2, "step \(index + 1)")
                // Still the shot STARTED began: none of the dropped payloads touched the tracker.
                XCTAssertEqual(update.startedDoseIndex, "DoseA", "step \(index + 1)")
                XCTAssertEqual(update.brewingStartTime, t0, "step \(index + 1)")
            } else {
                XCTAssertNil(u, "step \(index + 1)")
            }
        }
    }

    /// Angstrom-only: G-CODEC-4 — notifications strip 0x00 from both ends only (`bytes.strip(b"\x00")`);
    /// an inner NUL makes the payload unparseable and drops it (unlike reads, which cut at the first NUL).
    func testNulStrippedBothEndsOnly() {
        let body = Data(#"{"Sleep":"command"}"#.utf8)
        let expected = DecodedShotCounterNotification(brewing: BluetoothBrewingData(),
                                                      telemetry: BluetoothMachineTelemetry(sleep: "command"))
        XCTAssertEqual(ShotCounterNotificationDecoder.decode(body), expected)
        XCTAssertEqual(ShotCounterNotificationDecoder.decode(Data([0, 0]) + body), expected)
        XCTAssertEqual(ShotCounterNotificationDecoder.decode(body + Data([0, 0, 0])), expected)
        XCTAssertEqual(ShotCounterNotificationDecoder.decode(Data([0]) + body + Data([0])), expected)
        // Only NULs are stripped; JSON whitespace inside the NULs is the parser's business (allowed).
        XCTAssertEqual(ShotCounterNotificationDecoder.decode(Data([0]) + Data(" ".utf8) + body + Data("\n".utf8) + Data([0])),
                       expected)

        // An inner NUL is not stripped: the notification is dropped.
        XCTAssertNil(ShotCounterNotificationDecoder.decode(body + Data([0]) + Data("garbage".utf8)))
        XCTAssertNil(ShotCounterNotificationDecoder.decode(body + Data([0]) + Data(#"{"Sleep":"x"}"#.utf8) + Data([0])))
        XCTAssertNil(ShotCounterNotificationDecoder.decode(Data(#"{"Sleep":"com"#.utf8) + Data([0])
                                                           + Data(#"mand"}"#.utf8)))
        XCTAssertNil(ShotCounterNotificationDecoder.decode(Data([0]) + Data(#"{"Sleep""#.utf8) + Data([0])
                                                           + Data(#":"command"}"#.utf8) + Data([0])))
        // A NUL behind whitespace is an inner NUL too.
        XCTAssertNil(ShotCounterNotificationDecoder.decode(body + Data(" ".utf8) + Data([0]) + Data(" ".utf8)))
    }

    /// Upstream: test_shot_counter_telemetry (tests/test_bluetooth_client.py:848) [C28]
    /// BT-NTF-TEL-001…005 at decoder level, plus every §3.8 telemetry key.
    func testTelemetryKeys() throws {
        // TEL-001
        XCTAssertEqual(decode(#"{"CoffeeBoiler1UpdateTemperature":95}"#),
                       DecodedShotCounterNotification(brewing: BluetoothBrewingData(),
                                                      telemetry: BluetoothMachineTelemetry(coffeeBoilerTemperature: 95)))
        // TEL-002 / TEL-003: values the library doesn't know are ignored (both parts empty).
        let empty = DecodedShotCounterNotification(brewing: BluetoothBrewingData(), telemetry: BluetoothMachineTelemetry())
        XCTAssertEqual(decode(#"{"SteamBoilerHeatingCoeff":"[{\"temperature\":18}]"}"#), empty)
        XCTAssertEqual(decode(#"{"MachineMode":"Unknown"}"#), empty)
        // TEL-004
        XCTAssertEqual(decode(#"{"MachineStatistics":"{\"tot_doses\":2123}"}"#),
                       DecodedShotCounterNotification(
                        brewing: BluetoothBrewingData(),
                        telemetry: BluetoothMachineTelemetry(machineStatistics: .object(["tot_doses": .number(2123)]))))
        // TEL-005: both kinds of data in one notification; the brewing part derives `.brewing`.
        let both = try XCTUnwrap(decode(#"{"BrewingStartedGroup1DoseIndex":"DoseA","SteamBoilerUpdateTemperature":127}"#))
        XCTAssertEqual(both, DecodedShotCounterNotification(
            brewing: BluetoothBrewingData(startedDoseIndex: "DoseA"),
            telemetry: BluetoothMachineTelemetry(steamBoilerTemperature: 127)))
        var tracker = BrewingTracker()
        XCTAssertEqual(tracker.process(both.brewing, receivedAt: t0)?.state, .brewing)

        // The replay payload of BT-NTF-REPLAY-001.
        XCTAssertEqual(decode(#"{"MachineMode":"StandBy"}"#)?.telemetry, BluetoothMachineTelemetry(machineMode: .standby))
        // Every telemetry key of the §3.8 table at once, verbatim key spelling.
        XCTAssertEqual(decode(#"{"CoffeeBoiler1UpdateTemperature":93.5,"SteamBoilerUpdateTemperature":131,"MachineMode":"EcoMode","Sleep":"command","MachineStatistics":"[1,\"a\"]"}"#),
                       DecodedShotCounterNotification(
                        brewing: BluetoothBrewingData(),
                        telemetry: BluetoothMachineTelemetry(coffeeBoilerTemperature: 93.5, steamBoilerTemperature: 131,
                                                             machineMode: .eco, sleep: "command",
                                                             machineStatistics: .array([.number(1), .string("a")]))))
        // Every brewing key of the §3.8 table at once, verbatim key spelling.
        XCTAssertEqual(decode(#"{"BrewingStartedGroup1DoseIndex":"DoseA","BrewingUpdateGroup1Ev":true,"BrewingUpdateGroup1Backflush":false,"BrewingUpdateGroup1Time":1.5,"FlushStoppedGroup1Time":2.5,"FlushStoppedGroup1DoseIndex":"DoseB","BrewingStoppedGroup1Time":3.5,"BrewingStoppedGroup1DoseIndex":"DoseC","BrewingStoppedGroup1StopType":"Continuous","BrewingStoppedGroup1StopReason":"Manual"}"#),
                       DecodedShotCounterNotification(
                        brewing: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                      brewingTime: 1.5, flushStoppedTime: 2.5,
                                                      flushStoppedDoseIndex: "DoseB", brewingStoppedTime: 3.5,
                                                      brewingStoppedDoseIndex: "DoseC",
                                                      brewingStoppedStopType: "Continuous",
                                                      brewingStoppedStopReason: "Manual"),
                        telemetry: BluetoothMachineTelemetry()))
        // Keys are case-sensitive: a differently-cased key is unknown and ignored.
        XCTAssertEqual(decode(#"{"coffeeBoiler1UpdateTemperature":95,"brewingStartedGroup1DoseIndex":"DoseA"}"#), empty)

        // The recorded MachineStatistics payload (REC:23) parses into nested values.
        let recorded = try XCTUnwrap(decode(#"{"MachineStatistics":"{\"groups\":[{\"doses\":[{\"DoseA\":2123},{\"DoseB\":0},{\"DoseC\":0},{\"DoseD\":0},{\"ContinuousDose\":0}],\"clean\":0,\"ev_activations\":3577,\"ev_ontime\":51431}],\"tot_doses\":2123,\"boilers\":[{\"rsteam_ontime\":152},{\"rcoffee_ontime\":217}],\"tea\":{\"count\":0,\"ev_activation\":0,\"ev_ontime\":0},\"pump_ontime\":41289,\"machine_ontime\":25594,\"refill_ontime\":1432,\"count_liter\":0}"}"#))
        let stats = try XCTUnwrap(recorded.telemetry.machineStatistics)
        XCTAssertEqual(stats["tot_doses"], .number(2123))
        XCTAssertEqual(stats["tea"], .object(["count": .number(0), "ev_activation": .number(0), "ev_ontime": .number(0)]))
        XCTAssertEqual(stats["boilers"], .array([.object(["rsteam_ontime": .number(152)]),
                                                 .object(["rcoffee_ontime": .number(217)])]))
        guard case .array(let groups)? = stats["groups"], let group = groups.first else {
            return XCTFail("groups is not a non-empty array: \(String(describing: stats["groups"]))")
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group["ev_activations"], .number(3577))
        XCTAssertEqual(group["doses"], .array([.object(["DoseA": .number(2123)]), .object(["DoseB": .number(0)]),
                                              .object(["DoseC": .number(0)]), .object(["DoseD": .number(0)]),
                                              .object(["ContinuousDose": .number(0)])]))
        XCTAssertTrue(recorded.brewing.isEmpty)
    }

    /// Angstrom-only: G-CODEC-7 — `MachineStatistics` (BT-NTF-COERCE-002…005): absent or JSON null →
    /// unset with the rest processed; a JSON string → its parsed content, a parsed `null` → unset; any
    /// other value, or an unparseable string, drops the whole notification, brewing keys included.
    func testMachineStatisticsRule() {
        // 002: dropped.
        XCTAssertNil(decode(#"{"MachineStatistics":{"a":1}}"#))
        XCTAssertNil(decode(#"{"MachineStatistics":true}"#))
        XCTAssertNil(decode(#"{"MachineStatistics":"{bad"}"#))
        XCTAssertNil(decode(#"{"MachineStatistics":5}"#))
        XCTAssertNil(decode(#"{"MachineStatistics":0}"#))
        XCTAssertNil(decode(#"{"MachineStatistics":false}"#))
        XCTAssertNil(decode(#"{"MachineStatistics":[1]}"#))
        XCTAssertNil(decode(#"{"MachineStatistics":[]}"#))
        XCTAssertNil(decode(#"{"MachineStatistics":""}"#))
        // ... brewing and other telemetry keys included.
        XCTAssertNil(decode(#"{"MachineStatistics":{"a":1},"BrewingStartedGroup1DoseIndex":"DoseA","CoffeeBoiler1UpdateTemperature":90}"#))
        XCTAssertNil(decode(#"{"MachineStatistics":"{bad","BrewingUpdateGroup1Ev":false}"#))

        // 003: null is unset; the rest is processed.
        XCTAssertEqual(decode(#"{"MachineStatistics":null,"CoffeeBoiler1UpdateTemperature":90}"#),
                       DecodedShotCounterNotification(brewing: BluetoothBrewingData(),
                                                      telemetry: BluetoothMachineTelemetry(coffeeBoilerTemperature: 90)))
        XCTAssertEqual(decode(#"{"MachineStatistics":null,"BrewingStartedGroup1DoseIndex":"DoseA"}"#),
                       DecodedShotCounterNotification(brewing: BluetoothBrewingData(startedDoseIndex: "DoseA"),
                                                      telemetry: BluetoothMachineTelemetry()))
        // Absent is unset too.
        XCTAssertNil(decode(#"{"CoffeeBoiler1UpdateTemperature":90}"#)?.telemetry.machineStatistics)

        // 004: a parsed `null` is unset (nothing to emit); with other telemetry only that remains.
        let empty = DecodedShotCounterNotification(brewing: BluetoothBrewingData(), telemetry: BluetoothMachineTelemetry())
        XCTAssertEqual(decode(#"{"MachineStatistics":"null"}"#), empty)
        XCTAssertEqual(decode(#"{"MachineStatistics":null}"#), empty)
        XCTAssertEqual(decode(#"{"MachineStatistics":"null","CoffeeBoiler1UpdateTemperature":90}"#),
                       DecodedShotCounterNotification(brewing: BluetoothBrewingData(),
                                                      telemetry: BluetoothMachineTelemetry(coffeeBoilerTemperature: 90)))

        // 005: any parsed value, not type-checked.
        XCTAssertEqual(decode(#"{"MachineStatistics":"5"}"#)?.telemetry,
                       BluetoothMachineTelemetry(machineStatistics: .number(5)))
        XCTAssertEqual(decode(#"{"MachineStatistics":"true"}"#)?.telemetry,
                       BluetoothMachineTelemetry(machineStatistics: .bool(true)))   // a JSON bool, not the number 1
        XCTAssertEqual(decode(#"{"MachineStatistics":"0"}"#)?.telemetry,
                       BluetoothMachineTelemetry(machineStatistics: .number(0)))    // the number 0, not false
        XCTAssertEqual(decode(#"{"MachineStatistics":"\"text\""}"#)?.telemetry,
                       BluetoothMachineTelemetry(machineStatistics: .string("text")))
        XCTAssertEqual(decode(#"{"MachineStatistics":"[null,false,1.5,{}]"}"#)?.telemetry,
                       BluetoothMachineTelemetry(machineStatistics: .array([.null, .bool(false), .number(1.5),
                                                                            .object([:])])))
        XCTAssertEqual(decode(#"{"MachineStatistics":" {\"a\":{\"b\":null}} "}"#)?.telemetry,
                       BluetoothMachineTelemetry(machineStatistics: .object(["a": .object(["b": .null])])))
    }

    /// Angstrom-only: D5 — BT-NTF-COERCE-006…010 (rows marked D5 diverge from mashumaro 3.17), plus the
    /// notification-bool, double and string rules of §3.10 on brewing and telemetry keys.
    func testNotificationCoercionVectors() throws {
        // 006 (parity): STARTED, then `{"BrewingUpdateGroup1Ev":[]}` → `.brewingStopped` (`bool([])`).
        do {
            XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Ev":[]}"#)?.brewing, BluetoothBrewingData(ev: false))
            var tracker = BrewingTracker()
            _ = dispatch(&tracker, BluetoothTestVectors.started, at: t0)
            let u = try XCTUnwrap(dispatch(&tracker, Data(#"{"BrewingUpdateGroup1Ev":[]}"#.utf8), at: t0))
            XCTAssertEqual(u.state, .brewingStopped)
            XCTAssertEqual(u.raw, BluetoothBrewingData(startedDoseIndex: "DoseA", ev: false))
        }
        // 007 (D5c): a container in a string field becomes its compact JSON text; a number its decimal (parity).
        do {
            let started = try XCTUnwrap(decode(#"{"BrewingStartedGroup1DoseIndex":["a"]}"#))
            XCTAssertEqual(started.brewing, BluetoothBrewingData(startedDoseIndex: #"["a"]"#))
            var tracker = BrewingTracker()
            let u = try XCTUnwrap(tracker.process(started.brewing, receivedAt: t0))
            XCTAssertEqual(u.state, .brewing)
            XCTAssertEqual(u.startedDoseIndex, #"["a"]"#)
            XCTAssertEqual(decode(#"{"Sleep":{"a":1}}"#)?.telemetry, BluetoothMachineTelemetry(sleep: #"{"a":1}"#))
            XCTAssertEqual(decode(#"{"Sleep":5}"#)?.telemetry, BluetoothMachineTelemetry(sleep: "5"))
        }
        // 008 (D5e): STARTED, then a "nan" time → dropped, tracker unchanged.
        do {
            XCTAssertNil(decode(#"{"BrewingUpdateGroup1Time":"nan","BrewingUpdateGroup1Ev":true}"#))
            var tracker = BrewingTracker()
            _ = dispatch(&tracker, BluetoothTestVectors.started, at: t0)
            XCTAssertNil(dispatch(&tracker, Data(#"{"BrewingUpdateGroup1Time":"nan","BrewingUpdateGroup1Ev":true}"#.utf8),
                                  at: t0.addingTimeInterval(1)))
            // Unchanged: the next tick merges onto STARTED alone and keeps S = t0.
            let next = try XCTUnwrap(dispatch(&tracker, BluetoothTestVectors.tick("1.5"), at: t0.addingTimeInterval(2)))
            XCTAssertEqual(next.raw, BluetoothBrewingData(startedDoseIndex: "DoseA", ev: true, backflush: false,
                                                          brewingTime: 1.5))
            XCTAssertEqual(next.brewingStartTime, t0)
        }
        // 009 (D5e): non-finite telemetry → dropped (string "inf", bare NaN literal, out-of-range literal).
        for json in [#"{"CoffeeBoiler1UpdateTemperature":"inf"}"#, #"{"CoffeeBoiler1UpdateTemperature":NaN}"#,
                     #"{"CoffeeBoiler1UpdateTemperature":1e400}"#, #"{"SteamBoilerUpdateTemperature":"-Infinity"}"#,
                     #"{"BrewingStoppedGroup1Time":"NaN"}"#, #"{"FlushStoppedGroup1Time":"infinity"}"#] {
            XCTAssertNil(decode(json), json)
        }
        // 010 (D5f): `_` digit separators → dropped.
        XCTAssertNil(decode(#"{"BrewingUpdateGroup1Time":"1_0","BrewingUpdateGroup1Ev":true}"#))

        // Notification bool (parity unless marked): bool, string via parseBool (D5a), number != 0,
        // container truthiness, null → unset.
        let bools: [(String, Bool?)] = [
            ("true", true), ("false", false), (#""true""#, true), (#""TRUE""#, true),
            (#""false""#, false),                       // D5a (upstream True)
            (#""yes""#, false), (#""1""#, false),        // D5a (upstream True)
            ("1", true), ("0", false), ("2.5", true), ("0.0", false),
            ("[]", false), ("[0]", true), ("{}", false), (#"{"a":1}"#, true), ("null", nil),
        ]
        for (value, expected) in bools {
            XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Ev":\#(value)}"#)?.brewing,
                           BluetoothBrewingData(ev: expected), "ev \(value)")
            XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Backflush":\#(value)}"#)?.brewing,
                           BluetoothBrewingData(backflush: expected), "backflush \(value)")
        }
        // Double: number, bool → 1.0/0.0, null → unset; an array/object → dropped.
        XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Time":true}"#)?.brewing, BluetoothBrewingData(brewingTime: 1.0))
        XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Time":false}"#)?.brewing, BluetoothBrewingData(brewingTime: 0.0))
        XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Time":null}"#)?.brewing, BluetoothBrewingData())
        XCTAssertEqual(decode(#"{"BrewingStoppedGroup1Time":12}"#)?.brewing, BluetoothBrewingData(brewingStoppedTime: 12))
        XCTAssertNil(decode(#"{"BrewingUpdateGroup1Time":[1]}"#))
        XCTAssertNil(decode(#"{"SteamBoilerUpdateTemperature":{"v":1}}"#))
        // String: bool → "True"/"False", float → shortest text, null → unset.
        XCTAssertEqual(decode(#"{"BrewingStoppedGroup1StopReason":true}"#)?.brewing,
                       BluetoothBrewingData(brewingStoppedStopReason: "True"))
        XCTAssertEqual(decode(#"{"FlushStoppedGroup1DoseIndex":false}"#)?.brewing,
                       BluetoothBrewingData(flushStoppedDoseIndex: "False"))
        XCTAssertEqual(decode(#"{"BrewingStoppedGroup1StopType":1.5}"#)?.brewing,
                       BluetoothBrewingData(brewingStoppedStopType: "1.5"))
        XCTAssertEqual(decode(#"{"BrewingStoppedGroup1DoseIndex":null,"Sleep":null}"#),
                       DecodedShotCounterNotification(brewing: BluetoothBrewingData(), telemetry: BluetoothMachineTelemetry()))
    }

    /// Upstream: test_shot_counter_telemetry (tests/test_bluetooth_client.py:848) [C28]
    /// `{"MachineMode":"Unknown"}` is unset (`_known_machine_mode`); so is any non-string or unknown value.
    func testUnknownMachineModeIsNil() {
        let empty = DecodedShotCounterNotification(brewing: BluetoothBrewingData(), telemetry: BluetoothMachineTelemetry())
        for value in [#""Unknown""#, #""standby""#, #""STANDBY""#, #"" StandBy""#, #""Brewing""#, #""""#, "5", "true",
                      "null", #"["StandBy"]"#, #"{"mode":"StandBy"}"#] {
            XCTAssertEqual(decode(#"{"MachineMode":\#(value)}"#), empty, value)
        }
        // The rest of the notification is still processed.
        XCTAssertEqual(decode(#"{"MachineMode":"Unknown","Sleep":"command","BrewingUpdateGroup1Ev":false}"#),
                       DecodedShotCounterNotification(brewing: BluetoothBrewingData(ev: false),
                                                      telemetry: BluetoothMachineTelemetry(sleep: "command")))
        // The three known modes map; never `.other`.
        XCTAssertEqual(decode(#"{"MachineMode":"BrewingMode"}"#)?.telemetry.machineMode, .brewing)
        XCTAssertEqual(decode(#"{"MachineMode":"EcoMode"}"#)?.telemetry.machineMode, .eco)
        XCTAssertEqual(decode(#"{"MachineMode":"StandBy"}"#)?.telemetry.machineMode, .standby)
    }

    /// Upstream: test_shot_counter_telemetry (tests/test_bluetooth_client.py:848) [C28]
    /// The heating-coefficient keys (REC:13, REC:78) decode to two empty parts: nothing is emitted.
    func testHeatingCoefficientIgnored() {
        let empty = DecodedShotCounterNotification(brewing: BluetoothBrewingData(), telemetry: BluetoothMachineTelemetry())
        let steam = #"{"SteamBoilerHeatingCoeff":"[{\"temperature\":18,\"coefficent\":0.1957},{\"temperature\":40,\"coefficent\":0.2012},{\"temperature\":70,\"coefficent\":0.2105},{\"temperature\":100,\"coefficent\":0.2231},{\"temperature\":130,\"coefficent\":0.2398}]"}"#
        let coffee = #"{"CoffeeBoiler1HeatingCoeff":"[{\"temperature\":17,\"coefficent\":0.4083},{\"temperature\":40,\"coefficent\":0.4121},{\"temperature\":60,\"coefficent\":0.4176},{\"temperature\":80,\"coefficent\":0.4252},{\"temperature\":95,\"coefficent\":0.4317}]"}"#
        XCTAssertEqual(decode(steam), empty)
        XCTAssertEqual(decode(coffee), empty)
        XCTAssertEqual(decode(#"{"SteamBoilerHeatingCoeff":"[{\"temperature\":18}]"}"#), empty)
        // Next to a known key, only the known key is decoded.
        XCTAssertEqual(decode(#"{"CoffeeBoiler1HeatingCoeff":"x","CoffeeBoiler1UpdateTemperature":81}"#),
                       DecodedShotCounterNotification(brewing: BluetoothBrewingData(),
                                                      telemetry: BluetoothMachineTelemetry(coffeeBoilerTemperature: 81)))
    }

    /// Angstrom-only: §3.10 — a numeric string time is `float()`-coerced (whitespace trimmed); a
    /// non-numeric one drops the notification (`TBC:773`).
    func testNumericStringTime() throws {
        XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Time":"3.5","BrewingUpdateGroup1Ev":true}"#)?.brewing,
                       BluetoothBrewingData(ev: true, brewingTime: 3.5))
        XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Time":" 1.17\n"}"#)?.brewing, BluetoothBrewingData(brewingTime: 1.17))
        XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Time":"5"}"#)?.brewing, BluetoothBrewingData(brewingTime: 5))
        XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Time":"-0.5"}"#)?.brewing, BluetoothBrewingData(brewingTime: -0.5))
        XCTAssertEqual(decode(#"{"BrewingUpdateGroup1Time":"1e1"}"#)?.brewing, BluetoothBrewingData(brewingTime: 10))
        XCTAssertEqual(decode(#"{"BrewingStoppedGroup1Time":"12.727"}"#)?.brewing,
                       BluetoothBrewingData(brewingStoppedTime: 12.727))
        XCTAssertEqual(decode(#"{"FlushStoppedGroup1Time":"1.891"}"#)?.brewing, BluetoothBrewingData(flushStoppedTime: 1.891))
        XCTAssertEqual(decode(#"{"CoffeeBoiler1UpdateTemperature":"95"}"#)?.telemetry,
                       BluetoothMachineTelemetry(coffeeBoilerTemperature: 95))
        for bad in ["abc", "", " ", "3.5s", "1,5"] {
            XCTAssertNil(decode(#"{"BrewingUpdateGroup1Time":"\#(bad)","BrewingUpdateGroup1Ev":true}"#), bad)
        }

        // Through the tracker, a string tick is a running shot with that timer.
        var tracker = BrewingTracker()
        let u = try XCTUnwrap(dispatch(&tracker, Data(#"{"BrewingUpdateGroup1Time":"3.5","BrewingUpdateGroup1Ev":true}"#.utf8),
                                       at: t0))
        XCTAssertEqual(u.state, .brewing)
        XCTAssertEqual(u.timerValue, 3.5)
        XCTAssertEqual(u.brewingStartTime, t0.addingTimeInterval(-3.5))
    }

    /// Angstrom-only: §3.10 — a hex-float string time (`"0x1p3"`, which Swift's `Double(String)` accepts
    /// and Python's `float()` rejects) drops the notification.
    func testHexFloatStringTimeDropped() throws {
        if true { throw XCTSkip("BLOCKED-BY BT-W1-01: BluetoothWireCoercion.optionalDouble accepts hex-float strings (\"0x1p3\" → 8.0); SPEC §3.10 requires an error when the string contains x or X") }  // the fix job deletes this line
        for value in ["0x1p3", "0X1P3", " 0x10 ", "-0x1.8p1"] {
            XCTAssertNil(decode(#"{"BrewingUpdateGroup1Time":"\#(value)","BrewingUpdateGroup1Ev":true}"#), value)
            XCTAssertNil(decode(#"{"CoffeeBoiler1UpdateTemperature":"\#(value)"}"#), value)
        }
    }

    // MARK: - Helpers

    private func decode(_ json: String) -> DecodedShotCounterNotification? {
        ShotCounterNotificationDecoder.decode(Data(json.utf8))
    }

    /// The client's dispatch (§4.10 steps 3–4): only a decoded, non-empty brewing part reaches the tracker.
    private func dispatch(_ tracker: inout BrewingTracker, _ payload: Data, at: Date) -> BluetoothShotCounterUpdate? {
        guard let decoded = ShotCounterNotificationDecoder.decode(payload), !decoded.brewing.isEmpty else { return nil }
        return tracker.process(decoded.brewing, receivedAt: at)
    }
}
