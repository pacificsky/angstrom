import XCTest
@testable import Angstrom
import AngstromTestSupport

/// BT-W1-02: the ordered command writer, read/auth frames, NUL handling and `ensure_ascii` (SPEC §3.5–§3.9).
///
/// Every expected byte string below is a literal copied from upstream or the SPEC (or, for the
/// `jsonString` table, the output of CPython's `json.dumps`), never computed by the code under test.
final class BluetoothCodecTests: XCTestCase {

    /// Angstrom-only: §9.3.1 — the four command builders produce BT-REQ-001…006 byte for byte.
    ///
    /// Supplementary to C01–C03 (the client-level parity tests are owned by BluetoothRequestTests).
    /// Vectors: BT-REQ-001 from test_ble_set_power (tests/test_bluetooth_client.py:302-306), BT-REQ-003
    /// from test_ble_set_temperature (:317-320), BT-REQ-004 from test_ble_set_smart_standby (:331-334);
    /// BT-REQ-002/005/006 are the SPEC §3.7 derived vectors.
    func testCommandFramesMatchPinnedVectors() {
        // BT-REQ-001
        assertFrame(BluetoothCodec.machineChangeMode(on: true),
                    #"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#)
        // BT-REQ-002
        assertFrame(BluetoothCodec.machineChangeMode(on: false),
                    #"{"name":"MachineChangeMode","parameter":{"mode":"StandBy"}}"#)
        // BT-REQ-003
        assertFrame(BluetoothCodec.settingBoilerTarget(boiler: .steam, celsius: 90),
                    #"{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":90}}"#)
        // BT-REQ-004
        assertFrame(BluetoothCodec.settingSmartStandby(minutes: 42, mode: .powerOn, enabled: true),
                    #"{"name":"SettingSmartStandby","parameter":{"minutes":42,"mode":"PowerOn","enabled":true}}"#)
        // BT-REQ-005
        assertFrame(BluetoothCodec.settingBoilerEnable(steamOn: true),
                    #"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":true}}"#)
        // BT-REQ-006
        assertFrame(BluetoothCodec.settingBoilerTarget(boiler: .coffee, celsius: 96.5),
                    #"{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":96.5}}"#)

        // The generic writer produces the same bytes as the builder (BT-REQ-004 via commandFrame).
        XCTAssertEqual(
            BluetoothCodec.commandFrame(name: "SettingSmartStandby", parameter: [
                ("minutes", .int(42)), ("mode", .string("PowerOn")), ("enabled", .bool(true)),
            ]),
            BluetoothCodec.settingSmartStandby(minutes: 42, mode: .powerOn, enabled: true)
        )

        // The other parameter values of each builder.
        assertFrame(BluetoothCodec.settingSmartStandby(minutes: 10, mode: .lastBrewing, enabled: false),
                    #"{"name":"SettingSmartStandby","parameter":{"minutes":10,"mode":"LastBrewing","enabled":false}}"#)
        assertFrame(BluetoothCodec.settingBoilerTarget(boiler: .other("TeaBoiler"), celsius: 85),
                    #"{"name":"SettingBoilerTarget","parameter":{"identifier":"TeaBoiler","value":85}}"#)
    }

    /// Angstrom-only: G-CODEC-2 — bytes of `setSteam(on:)` and `setPower(on: false)` (BT-REQ-005, BT-REQ-002).
    func testSetSteamAndPowerOffBytes() {
        let steamOn = BluetoothCodec.settingBoilerEnable(steamOn: true)
        XCTAssertEqual(
            steamOn,
            Data(#"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":true}}"#.utf8) + [0x00]
        )
        let steamOff = BluetoothCodec.settingBoilerEnable(steamOn: false)
        XCTAssertEqual(
            steamOff,
            Data(#"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":false}}"#.utf8) + [0x00]
        )
        let powerOff = BluetoothCodec.machineChangeMode(on: false)
        XCTAssertEqual(
            powerOff,
            Data(#"{"name":"MachineChangeMode","parameter":{"mode":"StandBy"}}"#.utf8) + [0x00]
        )
        for frame in [steamOn, steamOff, powerOff] {
            XCTAssertEqual(frame.last, 0x00)
            XCTAssertEqual(frame.filter { $0 == 0x00 }.count, 1, "exactly one NUL, at the end")
        }
    }

    /// Angstrom-only: §9.3.1 — read requests are `UTF8(rawValue) + [0x00]` (BT-READ-REQ-001…006).
    ///
    /// Vectors from tests/test_bluetooth_client.py:347, :370, :399, :415, :429 and :1249.
    func testReadRequestFrames() {
        let expected: [(BluetoothReadSetting, [UInt8])] = [
            (.machineCapabilities, Array("machineCapabilities".utf8) + [0x00]), // BT-READ-REQ-001
            (.boilers, Array("boilers".utf8) + [0x00]),                         // BT-READ-REQ-002
            (.smartStandBy, Array("smartStandBy".utf8) + [0x00]),               // BT-READ-REQ-003
            (.tankStatus, Array("tankStatus".utf8) + [0x00]),                   // BT-READ-REQ-004
            (.machineMode, Array("machineMode".utf8) + [0x00]),                 // BT-READ-REQ-005
            (.isPlumbedIn, Array("isPlumbedIn".utf8) + [0x00]),                 // BT-READ-REQ-006
        ]
        XCTAssertEqual(Set(expected.map(\.0)), Set(BluetoothReadSetting.allCases), "every setting is pinned")
        for (setting, bytes) in expected {
            XCTAssertEqual(Array(BluetoothCodec.readRequestFrame(setting)), bytes, "\(setting)")
        }
        // Spot-check one in raw hex: "smartStandBy" has a capital B (0x42), then one NUL.
        XCTAssertEqual(Array(BluetoothCodec.readRequestFrame(.smartStandBy)),
                       [0x73, 0x6D, 0x61, 0x72, 0x74, 0x53, 0x74, 0x61, 0x6E, 0x64, 0x42, 0x79, 0x00])
    }

    /// Angstrom-only: §9.3.1 — the auth write is `UTF8(token)` with no NUL (BT-AUTH-001).
    ///
    /// Vector from tests/test_bluetooth_client.py:448 (`(AUTH_CHAR, b"token")`).
    func testAuthFrameHasNoTerminator() {
        let frame = BluetoothCodec.authFrame(BluetoothAuthToken("token"))
        XCTAssertEqual(Array(frame), [0x74, 0x6F, 0x6B, 0x65, 0x6E])
        XCTAssertFalse(frame.contains(0x00))

        // `bytes(self._ble_token, "utf-8")`: non-ASCII is UTF-8 encoded, not escaped.
        XCTAssertEqual(Array(BluetoothCodec.authFrame(BluetoothAuthToken("t\u{F6}k"))), [0x74, 0xC3, 0xB6, 0x6B])
        XCTAssertEqual(Array(BluetoothCodec.authFrame(BluetoothAuthToken(""))), [])
    }

    /// Angstrom-only: G-CODEC-4 — reads keep only the bytes before the first NUL (BT-RSP-MODE-002).
    ///
    /// BT-RSP-MODE-002 is the payload of test_read_response_is_nul_terminated
    /// (tests/test_bluetooth_client.py:1227).
    func testResponseTextCutsAtFirstNul() throws {
        // BT-RSP-MODE-002
        let mode = Data(#""BrewingMode""#.utf8) + [0x00, 0x00] + Data("garbage".utf8)
        XCTAssertEqual(Array(try BluetoothCodec.responseText(mode, context: "machineMode").utf8),
                       Array(#""BrewingMode""#.utf8))

        // No NUL at all: the whole payload.
        XCTAssertEqual(Array(try BluetoothCodec.responseText(Data(#"{"a":1}"#.utf8), context: "boilers").utf8),
                       Array(#"{"a":1}"#.utf8))
        // Only the first NUL counts; a later one is part of the discarded tail.
        XCTAssertEqual(try BluetoothCodec.responseText(Data([0x61, 0x00, 0x62, 0x00, 0x63]), context: "x"), "a")
        // A leading NUL leaves nothing; empty input stays empty.
        XCTAssertEqual(try BluetoothCodec.responseText(Data([0x00, 0x61, 0x62]), context: "x"), "")
        XCTAssertEqual(try BluetoothCodec.responseText(Data(), context: "x"), "")
        // The cut happens before decoding: invalid UTF-8 after the NUL is ignored.
        XCTAssertEqual(try BluetoothCodec.responseText(Data([0x6F, 0x6B, 0x00, 0xFF, 0xFE, 0xC3]), context: "command"),
                       "ok")
        // Multi-byte UTF-8 before the NUL is decoded verbatim (scalars compared, not canonical equality).
        let decoded = try BluetoothCodec.responseText(Data([0x65, 0xCC, 0x81, 0xC3, 0xA9, 0x00, 0x7A]), context: "x")
        XCTAssertEqual(decoded.unicodeScalars.map(\.value), [0x65, 0x301, 0xE9])
    }

    /// Angstrom-only: §3.5 — invalid UTF-8 before the first NUL throws `.decoding("bluetooth <context>: invalid UTF-8")`.
    func testResponseTextInvalidUTF8() throws {
        let invalid: [(String, [UInt8])] = [
            ("invalid byte 0xFF", [0x22, 0xFF, 0x22]),
            ("truncated two-byte sequence", [0x41, 0xC3]),
            ("truncated sequence just before the NUL", [0x41, 0xE2, 0x82, 0x00, 0x41]),
            ("overlong '/'", [0xC0, 0xAF]),
            ("overlong three-byte '/'", [0xE0, 0x80, 0xAF]),
            ("UTF-16 surrogate U+D800", [0xED, 0xA0, 0x80]),
            ("above U+10FFFF", [0xF4, 0x90, 0x80, 0x80]),
            ("stray continuation byte", [0x80]),
        ]
        for context in ["machineMode", "command"] {
            for (label, bytes) in invalid {
                XCTAssertThrowsError(try BluetoothCodec.responseText(Data(bytes), context: context), label) { error in
                    XCTAssertEqual(error as? LaMarzoccoError,
                                   .decoding("bluetooth \(context): invalid UTF-8"), label)
                }
            }
        }

        // Python's strict `utf-8` codec keeps a BOM (it is valid UTF-8); so does Angstrom.
        let bom = try BluetoothCodec.responseText(Data([0xEF, 0xBB, 0xBF, 0x41]), context: "x")
        XCTAssertEqual(bom.unicodeScalars.map(\.value), [0xFEFF, 0x41])
        // The largest valid scalar and a 4-byte emoji decode.
        let max = try BluetoothCodec.responseText(Data([0xF4, 0x8F, 0xBF, 0xBF, 0xF0, 0x9F, 0x98, 0x80]), context: "x")
        XCTAssertEqual(max.unicodeScalars.map(\.value), [0x10FFFF, 0x1F600])
    }

    /// Angstrom-only: §3.9 — `jsonString` is CPython `json.dumps(s)` (ensure_ascii=True), quotes included.
    ///
    /// Expected values were produced by CPython's `json.dumps`, then pasted as literals.
    func testJSONStringEnsureASCII() {
        assertJSONString("", #""""#)
        assertJSONString("abc", #""abc""#)
        assertJSONString("a\"b\\c", #""a\"b\\c""#)
        assertJSONString("/", #""/""#)                                  // '/' is not escaped
        assertJSONString("\u{08}\u{0C}\n\r\t", #""\b\f\n\r\t""#)
        assertJSONString("\u{00}\u{01}\u{1F}", #""\u0000\u0001\u001f""#)
        assertJSONString(" ~", #"" ~""#)                                // U+0020 and U+007E pass through
        assertJSONString("\u{7F}", #""\u007f""#)                        // DEL is escaped
        assertJSONString("\u{80}", #""\u0080""#)
        assertJSONString("\u{E9}", #""\u00e9""#)
        assertJSONString("e\u{301}", #""e\u0301""#)                     // scalars, not graphemes; no normalisation
        assertJSONString("\u{FFFF}", #""\uffff""#)
        assertJSONString("\u{ABCD}", #""\uabcd""#)                      // lowercase hex
        assertJSONString("\u{1F600}", #""\ud83d\ude00""#)               // surrogate pair
        assertJSONString("\u{10000}", #""\ud800\udc00""#)
        assertJSONString("\u{10FFFF}", #""\udbff\udfff""#)
        assertJSONString("\r\n", #""\r\n""#)                            // one Character, two scalars
        assertJSONString("caf\u{E9} \u{2615}", #""caf\u00e9 \u2615""#)

        // Every ASCII code point, U+0000…U+007F, as CPython writes `json.dumps("".join(map(chr, range(128))))`.
        let allASCII = String(String.UnicodeScalarView((0...0x7F).map { Unicode.Scalar(UInt8($0)) }))
        assertJSONString(
            allASCII,
            ##""\u0000\u0001\u0002\u0003\u0004\u0005\u0006\u0007\b\t\n\u000b\f\r\u000e\u000f\u0010\u0011\u0012\u0013\u0014\u0015\u0016\u0017\u0018\u0019\u001a\u001b\u001c\u001d\u001e\u001f !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\u007f""##
        )

        // commandFrame applies the same escaping to the name, keys and string values:
        // json.dumps({"name":"a\"b/<U+E9>","parameter":{"k<U+E9>y":"v\n/<U+1F600>","z":1,"a":True}}, separators=(",",":"))
        assertFrame(
            BluetoothCodec.commandFrame(name: "a\"b/\u{E9}", parameter: [
                ("k\u{E9}y", .string("v\n/\u{1F600}")), ("z", .int(1)), ("a", .bool(true)),
            ]),
            #"{"name":"a\"b/\u00e9","parameter":{"k\u00e9y":"v\n/\ud83d\ude00","z":1,"a":true}}"#
        )
    }

    /// Angstrom-only: D6 — a finite integral double with `abs < 1e15` is written as an integer, anything else as `String(describing:)`.
    func testIntegralDoubleRule() {
        let cases: [(Double, String)] = [
            (90, "90"),
            (93.0, "93"),                                   // Python would send 93.0 (D6)
            (128, "128"),
            (0, "0"),
            (-0.0, "0"),                                    // integral, so the integer form of zero
            (-5, "-5"),
            (999_999_999_999_999, "999999999999999"),       // largest integral value below the 1e15 bound
            (-999_999_999_999_999, "-999999999999999"),
            (1e15, "1000000000000000.0"),                   // at the bound: String(describing:) (= Python repr)
            (-1e15, "-1000000000000000.0"),
            (1e16, "1e+16"),                                // Swift and Python both switch to exponent form
            (96.5, "96.5"),
            (93.25, "93.25"),
            (0.1, "0.1"),
            (-0.5, "-0.5"),
            (999_999_999_999_999.5, "999999999999999.5"),  // non-integral below the bound
        ]
        for (value, text) in cases {
            assertFrame(BluetoothCodec.commandFrame(name: "T", parameter: [("v", .double(value))]),
                        #"{"name":"T","parameter":{"v":"# + text + "}}",
                        "double \(value)")
        }

        // Int scalars are always plain decimal.
        assertFrame(BluetoothCodec.commandFrame(name: "T", parameter: [("a", .int(42)), ("b", .int(-7)), ("c", .int(0))]),
                    #"{"name":"T","parameter":{"a":42,"b":-7,"c":0}}"#)

        // Through the builder: no rounding on the BLE leg, integral values lose the fraction.
        assertFrame(BluetoothCodec.settingBoilerTarget(boiler: .coffee, celsius: 93.0),
                    #"{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":93}}"#)
        assertFrame(BluetoothCodec.settingBoilerTarget(boiler: .steam, celsius: 130.5),
                    #"{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":130.5}}"#)
        assertFrame(BluetoothCodec.settingBoilerTarget(boiler: .coffee, celsius: 93.25),
                    #"{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":93.25}}"#)
    }

    /// Angstrom-only: §3.9 — parameter keys are written in the caller's order, never sorted.
    func testKeyOrderIsNotSorted() {
        assertFrame(
            BluetoothCodec.commandFrame(name: "N", parameter: [("z", .int(1)), ("a", .int(2)), ("m", .bool(false))]),
            #"{"name":"N","parameter":{"z":1,"a":2,"m":false}}"#
        )
        assertFrame(
            BluetoothCodec.commandFrame(name: "N", parameter: [("a", .int(2)), ("z", .int(1)), ("m", .bool(false))]),
            #"{"name":"N","parameter":{"a":2,"z":1,"m":false}}"#
        )
        // `json.dumps({"name": "N", "parameter": {}}, separators=(",", ":"))`
        assertFrame(BluetoothCodec.commandFrame(name: "N", parameter: []), #"{"name":"N","parameter":{}}"#)

        // BT-REQ-004 is minutes, mode, enabled; a sorted writer would emit enabled, minutes, mode.
        let smartStandby = BluetoothCodec.settingSmartStandby(minutes: 42, mode: .powerOn, enabled: true)
        XCTAssertNotEqual(
            smartStandby,
            Data(#"{"name":"SettingSmartStandby","parameter":{"enabled":true,"minutes":42,"mode":"PowerOn"}}"#.utf8) + [0x00]
        )
        // SettingBoilerEnable / SettingBoilerTarget: identifier first, then state / value.
        assertFrame(BluetoothCodec.settingBoilerEnable(steamOn: false),
                    #"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":false}}"#)
        assertFrame(BluetoothCodec.settingBoilerTarget(boiler: .steam, celsius: 126),
                    #"{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":126}}"#)
    }

    // MARK: - Helpers

    /// `frame` must equal `UTF8(json) + [0x00]` exactly (one trailing NUL, nothing else).
    private func assertFrame(_ frame: Data, _ json: String, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(frame), Array(json.utf8) + [0x00], message, file: file, line: line)
        XCTAssertEqual(frame.filter { $0 == 0x00 }.count, 1, "exactly one NUL \(message)", file: file, line: line)
        XCTAssertTrue(frame.allSatisfy { $0 < 0x80 }, "pure ASCII \(message)", file: file, line: line)
    }

    /// Byte-exact comparison (String `==` uses canonical equivalence, so compare the UTF-8 bytes).
    private func assertJSONString(_ input: String, _ expected: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let output = BluetoothCodec.jsonString(input)
        XCTAssertEqual(Array(output.utf8), Array(expected.utf8),
                       "jsonString(\(input.unicodeScalars.map { String($0.value, radix: 16) }))", file: file, line: line)
        XCTAssertTrue(output.utf8.allSatisfy { $0 < 0x80 }, "ensure_ascii output", file: file, line: line)
    }
}
