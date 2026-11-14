import Foundation

/// A JSON scalar for the ordered command writer (§3.9).
package enum BluetoothJSONScalar: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)     // integral → "90"; otherwise shortest round-trip; caller guarantees finite
}

/// Builds every BLE request frame and extracts response text (§3.5–§3.9).
package enum BluetoothCodec {
    /// `json.dumps({"name": name, "parameter": {…}}, separators=(",", ":"))` + NUL, keys in the given order.
    package static func commandFrame(name: String, parameter: [(String, BluetoothJSONScalar)]) -> Data {
        fatalError("unimplemented: BT-W1-02")
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
    package static func responseText(_ data: Data, context: String) throws -> String {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-02")
    }

    /// Python `json.dumps` string escaping with ensure_ascii (§3.9), including the quotes.
    package static func jsonString(_ s: String) -> String {
        fatalError("unimplemented: BT-W1-02")
    }

    // Command frames (§3.7) — the only producers of command bytes.
    package static func machineChangeMode(on: Bool) -> Data {
        fatalError("unimplemented: BT-W1-02")
    }

    package static func settingBoilerEnable(steamOn: Bool) -> Data {
        fatalError("unimplemented: BT-W1-02")
    }

    package static func settingSmartStandby(minutes: Int, mode: SmartStandbyAfter, enabled: Bool) -> Data {
        fatalError("unimplemented: BT-W1-02")
    }

    package static func settingBoilerTarget(boiler: BluetoothBoilerType, celsius: Double) -> Data {
        fatalError("unimplemented: BT-W1-02")
    }
}
