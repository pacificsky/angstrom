import Foundation

/// Python-constructor-compatible coercions (§3.10). Operates on `JSONSerialization` values.
///
/// Upstream decodes BLE payloads with mashumaro, which coerces with Python's `bool()`, `int()`,
/// `float()` and `str()`. These helpers reproduce those results, except for the documented
/// divergences of D5. Inputs are what `JSONSerialization` (`.fragmentsAllowed`) produces: `String`,
/// `NSNumber` (numbers **and** booleans), `NSNull`, `NSArray`, `NSDictionary`; `nil` means the key
/// was absent.
///
/// **Hazard:** `JSONSerialization` returns JSON `true`/`false` as `NSNumber`, and `as? Bool` also
/// matches the numbers `0` and `1`. A value is a JSON boolean only when its CF type is `CFBoolean`
/// (``isJSONBoolean(_:)``); integer vs float is decided with `CFNumberIsFloatType`.
package enum BluetoothWireCoercion {
    package struct Failure: Error, Sendable, Equatable { package let detail: String }

    /// `_parse_bool`: JSON true, or a string equal to "true" ignoring case.
    ///
    /// Anything else (a number, null, an array, an object, an absent key) is `false`.
    package static func parseBool(_ value: Any?) -> Bool {
        switch classify(value) {
        case .bool(let b): return b
        case .string(let s): return s.lowercased() == "true"
        case .absent, .null, .number, .array, .object, .unsupported: return false
        }
    }

    /// True iff `value` is a JSON boolean (CFBoolean), not the numbers 0/1.
    package static func isJSONBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// Wire bool for required fields: bool → itself; string → parseBool; number → != 0; null → false;
    /// array/object → !isEmpty; absent → throws.
    package static func requiredBool(_ value: Any?, key: String) throws -> Bool {
        switch classify(value) {
        case .absent: throw Failure(detail: "missing \(key)")
        case .null: return false
        case .bool(let b): return b
        case .string(let s): return s.lowercased() == "true"
        case .number(let n): return n.doubleValue != 0
        case .array(let a): return a.count != 0
        case .object(let o): return o.count != 0
        case .unsupported: throw Failure(detail: "\(key) is not a JSON value")
        }
    }

    /// Notification bool: nil for absent/null; array/object → !isEmpty; otherwise as requiredBool.
    package static func optionalBool(_ value: Any?) -> Bool? {
        switch classify(value) {
        case .absent, .null, .unsupported: return nil
        case .bool(let b): return b
        case .string(let s): return s.lowercased() == "true"
        case .number(let n): return n.doubleValue != 0
        case .array(let a): return a.count != 0
        case .object(let o): return o.count != 0
        }
    }

    /// float(): number, bool (1/0), numeric string with a finite result; nil for absent/null;
    /// throws otherwise (incl. "nan"/"inf").
    package static func optionalDouble(_ value: Any?, key: String) throws -> Double? {
        switch classify(value) {
        case .absent, .null:
            return nil
        case .bool(let b):
            return b ? 1.0 : 0.0
        case .number(let n):
            // A JSON number literal is always finite (JSONSerialization rejects NaN/Infinity/1e400);
            // the guard only protects against non-JSON callers (D5e).
            let d = n.doubleValue
            guard d.isFinite else { throw Failure(detail: "\(key) is not finite") }
            return d
        case .string(let s):
            // Swift's Double(String) accepts hex floats ("0x1p3"); Python's float() does not.
            guard !s.contains(where: { $0 == "x" || $0 == "X" }),
                  let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw Failure(detail: "\(key) is not a number: \(s)")
            }
            guard d.isFinite else { throw Failure(detail: "\(key) is not finite: \(s)") }
            return d
        case .array, .object, .unsupported:
            throw Failure(detail: "\(key) is not a number")
        }
    }

    /// `float()` on a required key: as ``optionalDouble(_:key:)``, but null or absent throws.
    package static func requiredDouble(_ value: Any?, key: String) throws -> Double {
        guard let d = try optionalDouble(value, key: key) else {
            throw Failure(detail: value == nil ? "missing \(key)" : "\(key) is null")
        }
        return d
    }

    /// int(): finite number within Int range (truncated), bool (1/0), integer-literal string;
    /// throws otherwise or when absent. Never traps.
    package static func requiredInt(_ value: Any?, key: String) throws -> Int {
        switch classify(value) {
        case .absent:
            throw Failure(detail: "missing \(key)")
        case .null:
            throw Failure(detail: "\(key) is null")
        case .bool(let b):
            return b ? 1 : 0
        case .number(let n):
            // Exact path first: every integer literal in Int range, including Int.max and Int.min
            // (whose Double images round to ±2^63 and would fail the range check below).
            if !CFNumberIsFloatType(n as CFNumber), let exact = Int(n.stringValue) {
                return exact
            }
            // A literal outside the 64-bit integer range (or with more digits than a double holds)
            // arrives as an NSDecimalNumber. Decide with its Decimal value: its doubleValue would
            // round -9223372036854775809 to -2^63, which then passes the range check as Int.min.
            if let decimal = n as? NSDecimalNumber {
                return try truncatedInt(decimal, key: key)
            }
            let d = n.doubleValue
            let t = d.rounded(.towardZero)
            // Never call Int(_: Double) outside this range: it traps.
            guard d.isFinite, -9223372036854775808.0 <= t, t < 9223372036854775808.0 else {
                throw Failure(detail: "\(key) is out of range: \(n)")
            }
            return Int(t)
        case .string(let s):
            guard let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw Failure(detail: "\(key) is not an integer: \(s)")
            }
            return i
        case .array, .object, .unsupported:
            throw Failure(detail: "\(key) is not an integer")
        }
    }

    /// str(): string, integer/float numbers, bool → "True"/"False", array/object → compact JSON text;
    /// nil for absent/null.
    package static func optionalString(_ value: Any?) -> String? {
        switch classify(value) {
        case .absent, .null, .unsupported:
            return nil
        case .string(let s):
            return s
        case .bool(let b):
            return b ? "True" : "False"
        case .number(let n):
            // An integer literal too large for UInt64 arrives as a non-fractional NSDecimalNumber:
            // Python's str(int) gives its digits, never float text.
            if let decimal = n as? NSDecimalNumber, isIntegral(decimal) {
                return decimal.stringValue
            }
            if CFNumberIsFloatType(n as CFNumber) {
                return String(describing: n.doubleValue)
            }
            return n.stringValue
        case .array(let a):
            return compactJSON(a)
        case .object(let o):
            return compactJSON(o)
        }
    }

    /// As optionalString, but null → "None" and absent → throws.
    package static func requiredString(_ value: Any?, key: String) throws -> String {
        switch classify(value) {
        case .absent:
            throw Failure(detail: "missing \(key)")
        case .null:
            return "None"
        default:
            guard let s = optionalString(value) else {
                throw Failure(detail: "\(key) is not a JSON value")
            }
            return s
        }
    }

    // MARK: - Classification

    private enum JSONKind {
        case absent
        case null
        case bool(Bool)
        case number(NSNumber)
        case string(String)
        case array(NSArray)
        case object(NSDictionary)
        case unsupported
    }

    /// Classifies a `JSONSerialization` value, honouring the CFBoolean hazard rule.
    private static func classify(_ value: Any?) -> JSONKind {
        guard let value else { return .absent }
        if value is NSNull { return .null }
        if isJSONBoolean(value) {
            // A CFBoolean is always an NSNumber; `boolValue` is exact for it.
            return .bool((value as? NSNumber)?.boolValue ?? false)
        }
        if let n = value as? NSNumber { return .number(n) }
        if let s = value as? String { return .string(s) }
        if let a = value as? NSArray { return .array(a) }
        if let o = value as? NSDictionary { return .object(o) }
        return .unsupported
    }

    /// True when `decimal` is a finite value with no fractional part.
    private static func isIntegral(_ decimal: NSDecimalNumber) -> Bool {
        var value = decimal.decimalValue
        guard !value.isNaN else { return false }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .down)
        return rounded == value
    }

    /// int() of an `NSDecimalNumber` (§3.10 int rule): truncate toward zero at scale 0, error unless
    /// the result lies in `Decimal(Int.min)...Decimal(Int.max)`, else convert exactly. Never uses
    /// `doubleValue`.
    private static func truncatedInt(_ decimal: NSDecimalNumber, key: String) throws -> Int {
        var value = decimal.decimalValue
        guard !value.isNaN else { throw Failure(detail: "\(key) is not finite: \(decimal)") }
        var truncated = Decimal()
        NSDecimalRound(&truncated, &value, 0, value >= 0 ? .down : .up)
        guard Decimal(Int.min) <= truncated, truncated <= Decimal(Int.max),
              let exact = Int("\(truncated)") else {
            throw Failure(detail: "\(key) is out of range: \(decimal)")
        }
        return exact
    }

    /// `[.sortedKeys, .withoutEscapingSlashes]` compact JSON text of an array/object (D5c).
    private static func compactJSON(_ container: Any) -> String {
        guard JSONSerialization.isValidJSONObject(container),
              let data = try? JSONSerialization.data(withJSONObject: container,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return String(describing: container) }
        return String(decoding: data, as: UTF8.self)
    }
}
