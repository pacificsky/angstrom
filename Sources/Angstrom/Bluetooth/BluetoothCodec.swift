import Foundation

/// A JSON scalar for the ordered command writer (§3.9).
package enum BluetoothJSONScalar: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)     // integral → "90"; otherwise shortest round-trip; caller guarantees finite
}

/// Builds every BLE request frame and extracts response text (§3.5–§3.9).
///
/// Command bytes are produced by a hand-written ordered writer, never by a Foundation JSON encoder:
/// that encoder guarantees no key order, and sorting keys would break the pinned `SettingSmartStandby`
/// frame (BT-REQ-004). The output is byte-identical to upstream's
/// `json.dumps({"name": name, "parameter": parameter}, separators=(",", ":"))` (`_bluetooth.py:702-710`),
/// except for integral doubles (D6).
package enum BluetoothCodec {
    /// `json.dumps({"name": name, "parameter": {…}}, separators=(",", ":"))` + NUL, keys in the given order.
    package static func commandFrame(name: String, parameter: [(String, BluetoothJSONScalar)]) -> Data {
        var json = "{\"name\":" + jsonString(name) + ",\"parameter\":{"
        for (index, member) in parameter.enumerated() {
            if index > 0 { json += "," }
            json += jsonString(member.0) + ":" + encodeScalar(member.1)
        }
        json += "}}"
        // `__write_bluetooth_message` appends exactly one trailing NUL (`_bluetooth.py:689-690`).
        return Data(json.utf8) + [0x00]
    }

    /// `UTF8(setting.rawValue) + [0x00]`.
    package static func readRequestFrame(_ setting: BluetoothReadSetting) -> Data {
        Data(setting.rawValue.utf8) + [0x00]
    }

    /// `UTF8(token.rawValue)` — no NUL.
    package static func authFrame(_ token: BluetoothAuthToken) -> Data {
        Data(token.rawValue.utf8)
    }

    /// Bytes before the first 0x00, strict UTF-8; throws `.decoding("bluetooth \(context): invalid UTF-8")`.
    ///
    /// Mirrors `bytes(result).split(b"\x00", 1)[0].decode()` (`_bluetooth.py:671`): the cut happens
    /// before decoding, so anything after the first NUL is ignored even when it is not valid UTF-8.
    /// Decoding is strict (overlong forms, surrogates, code points above U+10FFFF and truncated
    /// sequences all fail) and, like Python's `utf-8` codec, keeps a leading U+FEFF.
    package static func responseText(_ data: Data, context: String) throws -> String {
        let payload = data.prefix { $0 != 0x00 }
        var scalars = String.UnicodeScalarView()
        var iterator = payload.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                scalars.append(scalar)
            case .emptyInput:
                return String(scalars)
            case .error:
                throw LaMarzoccoError.decoding("bluetooth \(context): invalid UTF-8")
            }
        }
    }

    /// Python `json.dumps` string escaping with ensure_ascii (§3.9), including the quotes.
    ///
    /// Works on Unicode scalars, not grapheme clusters, so `"\r\n"` and combining sequences are
    /// escaped scalar by scalar, as Python does.
    package static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x20...0x7E:
                // Python's ESCAPE_ASCII is `[^\ -~]`: only U+0020…U+007E pass through ('/' included).
                out.unicodeScalars.append(scalar)
            case 0x10000...:
                let offset = scalar.value - 0x10000
                out += unicodeEscape(0xD800 + (offset >> 10))
                out += unicodeEscape(0xDC00 + (offset & 0x3FF))
            default:
                // < U+0020 without a short form, U+007F, and U+0080…U+FFFF.
                out += unicodeEscape(scalar.value)
            }
        }
        out += "\""
        return out
    }

    // Command frames (§3.7) — the only producers of command bytes.
    /// BT-REQ-001/002 (`_bluetooth.py:596-600`).
    package static func machineChangeMode(on: Bool) -> Data {
        commandFrame(name: "MachineChangeMode", parameter: [
            ("mode", .string(on ? "BrewingMode" : "StandBy")),
        ])
    }

    /// BT-REQ-005 (`_bluetooth.py:602-608`).
    package static func settingBoilerEnable(steamOn: Bool) -> Data {
        commandFrame(name: "SettingBoilerEnable", parameter: [
            ("identifier", .string(BluetoothBoilerType.steam.rawValue)),
            ("state", .bool(steamOn)),
        ])
    }

    /// BT-REQ-004 (`_bluetooth.py:610-618`): keys `minutes`, `mode`, `enabled`, in that order.
    package static func settingSmartStandby(minutes: Int, mode: SmartStandbyAfter, enabled: Bool) -> Data {
        commandFrame(name: "SettingSmartStandby", parameter: [
            ("minutes", .int(minutes)),
            ("mode", .string(mode.rawValue)),
            ("enabled", .bool(enabled)),
        ])
    }

    /// BT-REQ-003/006 (`_bluetooth.py:620-626`). No rounding; the caller guarantees `celsius` is finite.
    package static func settingBoilerTarget(boiler: BluetoothBoilerType, celsius: Double) -> Data {
        commandFrame(name: "SettingBoilerTarget", parameter: [
            ("identifier", .string(boiler.rawValue)),
            ("value", .double(celsius)),
        ])
    }

    // MARK: - Private

    private static func encodeScalar(_ value: BluetoothJSONScalar) -> String {
        switch value {
        case .string(let string):
            return jsonString(string)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .int(let int):
            return String(int)
        case .double(let double):
            return encodeDouble(double)
        }
    }

    /// §3.9 / D6: a finite integral value with `abs < 1e15` is written in integer form (`90`);
    /// anything else as Swift's shortest round-trip description (`96.5`).
    private static func encodeDouble(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(.towardZero), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(describing: value)
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    /// `\uxxxx` with four lowercase hex digits; `value` must be ≤ 0xFFFF.
    private static func unicodeEscape(_ value: UInt32) -> String {
        var out = "\\u"
        for shift in stride(from: 12, through: 0, by: -4) {
            out.append(hexDigits[Int((value >> UInt32(shift)) & 0xF)])
        }
        return out
    }
}
