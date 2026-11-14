import XCTest
@testable import Angstrom
import AngstromTestSupport

/// SPEC §3.10 value coercion rules (G-CODEC-3, D5). Inputs are parsed from JSON text with
/// `JSONSerialization` (`.fragmentsAllowed`), exactly as the decoders see them; `nil` means "absent".
final class BluetoothWireCoercionTests: XCTestCase {

    private typealias C = BluetoothWireCoercion

    /// Parses one JSON value (fragments allowed).
    private func json(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        } catch {
            XCTFail("invalid JSON fixture \(text): \(error)", file: file, line: line)
            throw error
        }
    }

    /// Asserts `body` throws a `BluetoothWireCoercion.Failure`.
    private func assertFails<T>(_ body: @autoclosure () throws -> T, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), message, file: file, line: line) { error in
            XCTAssertTrue(error is BluetoothWireCoercion.Failure,
                          "\(message): unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - parseBool (`_parse_bool`, BT:62-64)

    /// Angstrom-only: G-CODEC-3 — `parseBool` is `str(v).lower() == "true"`: JSON true or a "true" string ignoring case, anything else false.
    func testParseBool() throws {
        XCTAssertTrue(C.parseBool(try json("true")))
        XCTAssertFalse(C.parseBool(try json("false")))
        for text in [#""true""#, #""TRUE""#, #""True""#, #""tRuE""#] {
            XCTAssertTrue(C.parseBool(try json(text)), text)
        }
        // Strings other than "true" (no trimming: str(" true").lower() != "true").
        for text in [#""false""#, #""False""#, #""yes""#, #""1""#, #""""#, #"" true""#, #""true ""#, #""None""#] {
            XCTAssertFalse(C.parseBool(try json(text)), text)
        }
        // Numbers, null, arrays, objects: str() of them is never "true".
        for text in ["1", "0", "1.0", "2", "null", "[]", "[true]", #"["true"]"#, "{}", #"{"a":true}"#] {
            XCTAssertFalse(C.parseBool(try json(text)), text)
        }
        XCTAssertFalse(C.parseBool(nil))   // absent
    }

    // MARK: - Wire and notification bools (D5a)

    /// Angstrom-only: D5 — `"false"` is false for both wire (required) and notification (optional) bools (upstream `bool("false")` is True; G-CODEC-3).
    func testRequiredBoolStringFalseIsFalse() throws {
        // Strings go through parseBool for both rules.
        let strings: [(String, Bool)] = [
            (#""false""#, false), (#""False""#, false), (#""FALSE""#, false),
            (#""true""#, true), (#""True""#, true),
            (#""yes""#, false), (#""1""#, false), (#""""#, false),
        ]
        for (text, expected) in strings {
            XCTAssertEqual(try C.requiredBool(try json(text), key: "enabled"), expected, text)
            XCTAssertEqual(C.optionalBool(try json(text)), expected, text)
        }
        // JSON bools are themselves.
        XCTAssertEqual(try C.requiredBool(try json("true"), key: "enabled"), true)
        XCTAssertEqual(try C.requiredBool(try json("false"), key: "enabled"), false)
        XCTAssertEqual(C.optionalBool(try json("true")), true)
        XCTAssertEqual(C.optionalBool(try json("false")), false)
        // Numbers: != 0.
        for (text, expected) in [("0", false), ("1", true), ("2", true), ("-1", true), ("0.0", false), ("0.5", true)] {
            XCTAssertEqual(try C.requiredBool(try json(text), key: "enabled"), expected, text)
            XCTAssertEqual(C.optionalBool(try json(text)), expected, text)
        }
        // null: wire bool false (bool(None)); notification bool unset.
        XCTAssertEqual(try C.requiredBool(try json("null"), key: "enabled"), false)
        XCTAssertNil(C.optionalBool(try json("null")))
        // Absent: wire bool throws (MissingField); notification bool unset.
        assertFails(try C.requiredBool(nil, key: "enabled"), "absent required bool")
        XCTAssertNil(C.optionalBool(nil))
    }

    /// Angstrom-only: G-CODEC-3 — a value is a JSON boolean only when it is a CFBoolean; the numbers 1/0 are numbers for every rule.
    func testCFBooleanHazard() throws {
        let jsonTrue = try json("true"), jsonFalse = try json("false")
        let one = try json("1"), zero = try json("0"), oneFloat = try json("1.0")
        // The hazard itself: `as? Bool` matches the numbers too.
        XCTAssertEqual(one as? Bool, true)
        XCTAssertEqual(zero as? Bool, false)

        XCTAssertTrue(C.isJSONBoolean(jsonTrue))
        XCTAssertTrue(C.isJSONBoolean(jsonFalse))
        XCTAssertTrue(C.isJSONBoolean(NSNumber(value: true)))
        XCTAssertFalse(C.isJSONBoolean(one))
        XCTAssertFalse(C.isJSONBoolean(zero))
        XCTAssertFalse(C.isJSONBoolean(oneFloat))
        XCTAssertFalse(C.isJSONBoolean(NSNumber(value: 1)))
        XCTAssertFalse(C.isJSONBoolean("true"))
        XCTAssertFalse(C.isJSONBoolean(NSNull()))

        // parseBool: JSON true → true, number 1 → false (str(1) == "1").
        XCTAssertTrue(C.parseBool(jsonTrue))
        XCTAssertFalse(C.parseBool(one))
        // str(): bool → "True"/"False", number → digits.
        XCTAssertEqual(C.optionalString(jsonTrue), "True")
        XCTAssertEqual(C.optionalString(jsonFalse), "False")
        XCTAssertEqual(C.optionalString(one), "1")
        XCTAssertEqual(C.optionalString(zero), "0")
        XCTAssertEqual(try C.requiredString(jsonTrue, key: "message"), "True")
        XCTAssertEqual(try C.requiredString(one, key: "message"), "1")
        // int()/float() of a bool are 1/0 and 1.0/0.0, the same values as the numbers.
        XCTAssertEqual(try C.requiredInt(jsonTrue, key: "minutes"), 1)
        XCTAssertEqual(try C.requiredInt(jsonFalse, key: "minutes"), 0)
        XCTAssertEqual(try C.requiredDouble(jsonTrue, key: "target"), 1.0)
        XCTAssertEqual(try C.requiredDouble(jsonFalse, key: "target"), 0.0)
        // Inside a container, booleans stay booleans in the compact JSON text.
        XCTAssertEqual(C.optionalString(try json("[true,1,false,0]")), "[true,1,false,0]")
    }

    // MARK: - float()

    /// Angstrom-only: §3.10 — the double rule: numbers, bools, trimmed numeric strings; "abc", containers and missing required values fail.
    func testDoubleRule() throws {
        let accepted: [(String, Double)] = [
            ("93", 93), ("93.5", 93.5), ("-1.25", -1.25), ("0", 0), ("1e2", 100), ("1e300", 1e300),
            ("true", 1.0), ("false", 0.0),
            (#""93.5""#, 93.5), (#"" 93.5 ""#, 93.5), (#""\n7\t""#, 7), (#""1e2""#, 100),
            (#""-3""#, -3), (#""+2.5""#, 2.5), (#"".5""#, 0.5), (#""127""#, 127),
        ]
        for (text, expected) in accepted {
            XCTAssertEqual(try C.optionalDouble(try json(text), key: "target"), expected, text)
            XCTAssertEqual(try C.requiredDouble(try json(text), key: "target"), expected, text)
        }
        // An integer literal beyond UInt64 (an NSDecimalNumber) is float()'d to the nearest double.
        let huge = try C.requiredDouble(try json("123456789012345678901234567890"), key: "target")
        XCTAssertEqual(huge, 1.2345678901234568e29, accuracy: 1e14)

        // float("abc") raises; so do other non-numeric strings.
        for text in [#""abc""#, #""""#, #""   ""#, #""1.2.3""#, #""12abc""#, #""True""#] {
            assertFails(try C.optionalDouble(try json(text), key: "target"), text)
            assertFails(try C.requiredDouble(try json(text), key: "target"), text)
        }
        // Arrays and objects are errors.
        for text in ["[]", "[1]", "{}", #"{"a":1}"#] {
            assertFails(try C.optionalDouble(try json(text), key: "target"), text)
            assertFails(try C.requiredDouble(try json(text), key: "target"), text)
        }
        // null/absent: optional → nil, required → error.
        XCTAssertNil(try C.optionalDouble(try json("null"), key: "target"))
        XCTAssertNil(try C.optionalDouble(nil, key: "target"))
        assertFails(try C.requiredDouble(try json("null"), key: "target"), "null required double")
        assertFails(try C.requiredDouble(nil, key: "target"), "absent required double")
    }

    /// Angstrom-only: D5e, D5f — "nan"/"inf" strings and "_" digit separators are errors for float(); non-finite literals never parse.
    func testDoubleRejectsNonFiniteAndUnderscoreStrings() throws {
        for text in [#""nan""#, #""NaN""#, #""inf""#, #""-inf""#, #""+inf""#, #""Infinity""#, #""infinity""#, #""-Infinity""#] {
            assertFails(try C.optionalDouble(try json(text), key: "target"), text)
            assertFails(try C.requiredDouble(try json(text), key: "target"), text)
        }
        for text in [#""1_0""#, #""1_000.5""#, #""1_0e2""#] {
            assertFails(try C.optionalDouble(try json(text), key: "target"), text)
            assertFails(try C.requiredDouble(try json(text), key: "target"), text)
            assertFails(try C.requiredInt(try json(text), key: "minutes"), text)
        }
        // Non-JSON callers handing in a non-finite NSNumber are rejected too.
        for value in [Double.nan, .infinity, -.infinity] {
            assertFails(try C.optionalDouble(NSNumber(value: value), key: "target"), "\(value)")
        }
        // The premise of D5e: JSONSerialization rejects NaN/Infinity literals and out-of-range numbers.
        for text in ["NaN", "Infinity", "-Infinity", "1e400"] {
            XCTAssertThrowsError(try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed), text)
        }
    }

    /// Angstrom-only: §3.10 amendment — a string containing x/X (a hex float such as "0x1p3") is a float() error.
    func testDoubleRejectsHexFloatString() throws {
        // The premise: Swift's Double(String) accepts hex floats, Python's float() raises on them.
        XCTAssertEqual(Double("0x1p3"), 8.0)
        for text in [#""0x1p3""#, #""0X1P3""#, #"" 0x1p3 ""#, #""0x10""#, #""-0x1.8p1""#, #""0x1""#] {
            assertFails(try C.optionalDouble(try json(text), key: "target"), text)
            assertFails(try C.requiredDouble(try json(text), key: "target"), text)
        }
        // Decimal exponents are still accepted.
        XCTAssertEqual(try C.requiredDouble(try json(#""1e3""#), key: "target"), 1000)
        XCTAssertEqual(try C.requiredDouble(try json(#""1E3""#), key: "target"), 1000)
    }

    // MARK: - int()

    /// Angstrom-only: §3.10 — int() truncates floats toward zero (93.5 → 93) but rejects fractional strings ("93.5").
    func testIntRuleTruncates() throws {
        let accepted: [(String, Int)] = [
            ("93.5", 93), ("-93.5", -93), ("42.7", 42), ("0.9999", 0), ("-0.5", 0), ("1e2", 100),
            ("42", 42), ("-7", -7), ("0", 0), ("9007199254740993", 9_007_199_254_740_993),
            ("true", 1), ("false", 0),
            (#""42""#, 42), (#"" 42 ""#, 42), (#""+42""#, 42), (#""-7""#, -7), (#""\t5\n""#, 5), (#""007""#, 7),
        ]
        for (text, expected) in accepted {
            XCTAssertEqual(try C.requiredInt(try json(text), key: "minutes"), expected, text)
        }
        for text in [#""93.5""#, #""1.0""#, #""abc""#, #""""#, #""1e2""#, #""4 2""#, #""0x10""#, #""--1""#,
                     "[]", "[1]", "{}", #"{"a":1}"#, "null"] {
            assertFails(try C.requiredInt(try json(text), key: "minutes"), text)
        }
        assertFails(try C.requiredInt(nil, key: "minutes"), "absent int")
    }

    /// Angstrom-only: D5d — int() of a value outside Int range, or of a non-finite value, is an error and never traps.
    func testIntRejectsOutOfRangeAndNonFinite() throws {
        for text in ["1e300", "-1e300", "12345678901234567890", "9223372036854775808",
                     "9223372036854775807.0", "18446744073709551616", "123456789012345678901234567890",
                     "-123456789012345678901234567890", #""99999999999999999999""#, #""9223372036854775808""#] {
            assertFails(try C.requiredInt(try json(text), key: "minutes"), text)
        }
        for value in [Double.nan, .infinity, -.infinity, 9.3e18, -9.3e18] {
            assertFails(try C.requiredInt(NSNumber(value: value), key: "minutes"), "\(value)")
        }
        // The largest in-range float values still convert (Python: int(-2.0**63) == -2**63).
        XCTAssertEqual(try C.requiredInt(try json("-9223372036854775808.0"), key: "minutes"), Int.min)
        XCTAssertEqual(try C.requiredInt(NSNumber(value: 9_223_372_036_854_774_784.0), key: "minutes"), 9_223_372_036_854_774_784)
    }

    /// Angstrom-only: §3.10 amendment — integer literals at Int.max and Int.min decode exactly via the exact path.
    func testIntExactAtIntBounds() throws {
        XCTAssertEqual(try C.requiredInt(try json("9223372036854775807"), key: "minutes"), Int.max)
        XCTAssertEqual(try C.requiredInt(try json("-9223372036854775808"), key: "minutes"), Int.min)
        XCTAssertEqual(try C.requiredInt(try json("9223372036854775806"), key: "minutes"), Int.max - 1)
        XCTAssertEqual(try C.requiredInt(try json("-9223372036854775807"), key: "minutes"), Int.min + 1)
        XCTAssertEqual(try C.requiredInt(NSNumber(value: Int.max), key: "minutes"), Int.max)
        XCTAssertEqual(try C.requiredInt(NSNumber(value: Int.min), key: "minutes"), Int.min)
        XCTAssertEqual(try C.requiredInt(try json(#""9223372036854775807""#), key: "minutes"), Int.max)
        XCTAssertEqual(try C.requiredInt(try json(#""-9223372036854775808""#), key: "minutes"), Int.min)
        // One past Int.max is out of range.
        assertFails(try C.requiredInt(try json("9223372036854775808"), key: "minutes"), "Int.max + 1")
    }

    // MARK: - str()

    /// Angstrom-only: §3.10 — str(): strings verbatim, integers as digits, floats as shortest text, bools "True"/"False", null/absent per field kind.
    func testStringRule() throws {
        let cases: [(String, String)] = [
            (#""abc""#, "abc"), (#""""#, ""), (#"" padded ""#, " padded "), (#""None""#, "None"),
            ("5", "5"), ("-5", "-5"), ("0", "0"),
            ("12345678901234567890", "12345678901234567890"),   // UInt64 range: exact digits
            ("9223372036854775807", "9223372036854775807"),
            ("-9223372036854775808", "-9223372036854775808"),
            ("93.5", "93.5"), ("0.1", "0.1"), ("100.0", "100.0"), ("1e2", "100.0"), ("1e300", "1e+300"),
            ("-1.25", "-1.25"),
            ("true", "True"), ("false", "False"),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(C.optionalString(try json(text)), expected, text)
            XCTAssertEqual(try C.requiredString(try json(text), key: "message"), expected, text)
        }
        // Optional: null/absent → nil.
        XCTAssertNil(C.optionalString(try json("null")))
        XCTAssertNil(C.optionalString(nil))
        // Required: null → "None", absent → error.
        XCTAssertEqual(try C.requiredString(try json("null"), key: "message"), "None")
        assertFails(try C.requiredString(nil, key: "message"), "absent required string")
    }

    /// Angstrom-only: §3.10 amendment — an integer literal too large for UInt64 (a non-fractional NSDecimalNumber) renders as its digits.
    func testStringFromHugeIntegerIsDigits() throws {
        // The premise: these arrive as NSDecimalNumber.
        XCTAssertTrue(try json("123456789012345678901234567890") is NSDecimalNumber)
        let digits = ["123456789012345678901234567890", "18446744073709551616", "-18446744073709551617",
                      "-9223372036854775809", "100000000000000000000000000000000000000"]
        for text in digits {
            XCTAssertEqual(C.optionalString(try json(text)), text, text)
            XCTAssertEqual(try C.requiredString(try json(text), key: "id"), text, text)
        }
        // Fractional values that arrive as NSDecimalNumber are float()'d first, as in Python.
        XCTAssertEqual(C.optionalString(try json("3.14159265358979323846264338327950288")), "3.141592653589793")
        XCTAssertEqual(C.optionalString(try json("100000000000000000000.5")), "1e+20")
    }

    /// Angstrom-only: G-CODEC-3 — container truthiness for both bool rules: [] and {} are false, non-empty containers true.
    func testBoolContainerTruthiness() throws {
        let cases: [(String, Bool)] = [
            ("[]", false), ("{}", false), ("[1]", true), (#"{"a":1}"#, true),
            ("[false]", true), ("[null]", true), ("[[]]", true), (#"{"a":false}"#, true),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(try C.requiredBool(try json(text), key: "isEnabled"), expected, text)
            XCTAssertEqual(C.optionalBool(try json(text)), expected, text)
            XCTAssertFalse(C.parseBool(try json(text)), text)   // _parse_bool: str(container) is never "true"
        }
        // As a notification field: {"BrewingUpdateGroup1Ev":[]} is ev == false (parity: bool([])).
        let notification = try XCTUnwrap(try json(#"{"BrewingUpdateGroup1Ev":[]}"#) as? [String: Any])
        XCTAssertEqual(C.optionalBool(notification["BrewingUpdateGroup1Ev"]), false)
        XCTAssertNil(C.optionalBool(notification["BrewingUpdateGroup1Backflush"]))
    }

    /// Angstrom-only: G-CODEC-3 — a required string that is null is "None" (str(None)); absent throws; an optional null string is nil.
    func testRequiredStringNullIsNone() throws {
        let payload = try XCTUnwrap(try json(#"{"id":"a","message":null,"status":"success"}"#) as? [String: Any])
        XCTAssertEqual(try C.requiredString(payload["message"], key: "message"), "None")
        XCTAssertEqual(try C.requiredString(payload["id"], key: "id"), "a")
        assertFails(try C.requiredString(payload["missing"], key: "missing"), "absent required string")
        XCTAssertNil(C.optionalString(payload["message"]))
        XCTAssertNil(C.optionalString(payload["missing"]))
        XCTAssertEqual(try C.requiredString(NSNull(), key: "message"), "None")
    }

    /// Angstrom-only: D5c — an array/object in a string field becomes its compact, sorted-keys JSON text (Python gives its repr).
    func testStringFromContainerIsCompactJSON() throws {
        let cases: [(String, String)] = [
            (#"["a"]"#, #"["a"]"#),
            ("[1]", "[1]"),
            ("[ 1 , 2 ]", "[1,2]"),
            ("[]", "[]"),
            ("{}", "{}"),
            (#"{ "b" : 1 , "a" : [ true , null ] }"#, #"{"a":[true,null],"b":1}"#),
            (#"{"u":"a/b"}"#, #"{"u":"a/b"}"#),
            (#"{"z":{"y":2,"x":1}}"#, #"{"z":{"x":1,"y":2}}"#),
            ("[1.5]", "[1.5]"),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(C.optionalString(try json(text)), expected, text)
            XCTAssertEqual(try C.requiredString(try json(text), key: "startedDoseIndex"), expected, text)
        }
    }
}
