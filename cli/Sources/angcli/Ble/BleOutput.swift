import Foundation
import Angstrom

/// Every function returns one JSON line (SPEC §10.3) or nil if encoding fails.
///
/// Keys are sorted, so a line's text is deterministic. Dates inside decoded values use the same
/// ISO 8601 form (UTC, milliseconds) as the `ts` field.
enum BleOutput {
    static func rawLine(_ frame: RawBluetoothFrame, ts: String = Timestamp.now()) -> String? {
        // The only path from frame bytes to output: Redact.bluetoothFrame (SPEC §10.4).
        let shown = Redact.bluetoothFrame(frame)
        return encodeLine(BleRawLine(ts: ts,
                                     dir: frame.direction == .outbound ? ">>" : "<<",
                                     kind: kindName(frame.kind),
                                     char: frame.characteristic,
                                     hex: shown.hex,
                                     text: shown.text))
    }

    static func shotCounterLine(_ event: ShotCounterEvent, ts: String = Timestamp.now()) -> String? {
        switch event {
        case .subscribed:
            return encodeLine(BleEventLine(ts: ts, event: "subscribed", value: BleEmptyValue()))
        case .unsubscribed:
            return encodeLine(BleEventLine(ts: ts, event: "unsubscribed", value: BleEmptyValue()))
        case .brewing(let update):
            return encodeLine(BleEventLine(ts: ts, event: "brewing", value: BleShotCounterUpdateValue(update)))
        case .telemetry(let telemetry):
            return encodeLine(BleEventLine(ts: ts, event: "telemetry", value: BleTelemetryValue(telemetry)))
        case .gaveUp(let error):
            return encodeLine(BleEventLine(ts: ts, event: "gaveUp",
                                           value: BleErrorValue(error: error.errorDescription ?? "\(error)")))
        }
    }

    static func connectionLine(_ event: ConnectionEvent, ts: String = Timestamp.now()) -> String? {
        switch event {
        case .connected:
            return encodeLine(BleEventLine(ts: ts, event: "connected", value: BleEmptyValue()))
        case .disconnected:
            return encodeLine(BleEventLine(ts: ts, event: "disconnected", value: BleEmptyValue()))
        }
    }

    static func peripheralLine(_ peripheral: DiscoveredPeripheral) -> String? {
        encodeLine(BlePeripheralLine(id: peripheral.id.rawValue, name: peripheral.name, rssi: peripheral.rssi))
    }

    static func gattLines(_ services: [BluetoothGATTService]) -> [String] {
        // One line per characteristic (SPEC §10.1), in table order.
        services.flatMap { service in
            service.characteristics.compactMap { characteristic in
                encodeLine(BleGATTLine(service: service.uuid,
                                       characteristic: characteristic.uuid,
                                       properties: characteristic.properties))
            }
        }
    }

    static func readLine<D: Encodable>(setting: BluetoothReadSetting, raw: Data, decoded: D?,
                                       ts: String = Timestamp.now()) -> String? {
        encodeLine(BleReadLine(ts: ts, setting: setting.rawValue,
                               raw: strictUTF8(raw) ?? hexString(raw), decoded: decoded))
    }

    static func commandLine(command: String, status: BluetoothCommandStatus, ts: String = Timestamp.now()) -> String? {
        encodeLine(BleCommandLine(ts: ts, command: command,
                                  status: BleCommandStatusValue(id: status.id, message: status.message,
                                                                status: status.status),
                                  success: status.isSuccess))
    }

    /// {"token":"**REDACTED**","length":n} unless showSecret.
    static func tokenLine(_ token: BluetoothAuthToken, showSecret: Bool) -> String? {
        // `length` counts Unicode scalars, as Python's `len(str)` does.
        encodeLine(BleTokenLine(token: showSecret ? token.rawValue : Redact.placeholder,
                                length: token.rawValue.unicodeScalars.count))
    }

    // MARK: Private helpers

    private static func encodeLine<T: Encodable>(_ value: T) -> String? {
        // A fresh encoder per line keeps this concurrency-safe across printer tasks.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func kindName(_ kind: RawBluetoothFrame.Kind) -> String {
        switch kind {
        case .write: "write"
        case .read: "read"
        case .notification: "notification"
        case .event: "event"
        }
    }

    /// Strict UTF-8 (nothing repaired, nothing stripped); nil if the bytes are not valid UTF-8.
    private static func strictUTF8(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        return Data(text.utf8) == data ? text : nil
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Line shapes (SPEC §10.1, §10.3)

/// `{"ts","dir","kind","char","hex","text"}`: `char` is null for `.event`; `text` is omitted when the
/// bytes are not valid UTF-8.
private struct BleRawLine: Encodable {
    let ts: String
    let dir: String
    let kind: String
    let char: String?
    let hex: String
    let text: String?

    private enum CodingKeys: String, CodingKey { case ts, dir, kind, char, hex, text }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(dir, forKey: .dir)
        try container.encode(kind, forKey: .kind)
        try container.encode(char, forKey: .char)
        try container.encode(hex, forKey: .hex)
        try container.encodeIfPresent(text, forKey: .text)
    }
}

/// `{"ts","event","value"}`.
private struct BleEventLine<Value: Encodable>: Encodable {
    let ts: String
    let event: String
    let value: Value
}

/// `{}`: the value of an event that carries no data.
private struct BleEmptyValue: Encodable {}

/// `{"error"}`: the value of a `gaveUp` event.
private struct BleErrorValue: Encodable {
    let error: String
}

/// `{"id","name","rssi"}`: `name` and `rssi` are null when unknown.
private struct BlePeripheralLine: Encodable {
    let id: String
    let name: String?
    let rssi: Int?

    private enum CodingKeys: String, CodingKey { case id, name, rssi }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(rssi, forKey: .rssi)
    }
}

/// `{"service","characteristic","properties":[…]}`.
private struct BleGATTLine: Encodable {
    let service: String
    let characteristic: String
    let properties: [String]
}

/// `{"ts","setting","raw","decoded"}`: `decoded` is null when there is no typed value.
private struct BleReadLine<D: Encodable>: Encodable {
    let ts: String
    let setting: String
    let raw: String
    let decoded: D?

    private enum CodingKeys: String, CodingKey { case ts, setting, raw, decoded }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(setting, forKey: .setting)
        try container.encode(raw, forKey: .raw)
        try container.encode(decoded, forKey: .decoded)
    }
}

/// `{"ts","command","status":{id,message,status},"success"}`.
private struct BleCommandLine: Encodable {
    let ts: String
    let command: String
    let status: BleCommandStatusValue
    let success: Bool
}

private struct BleCommandStatusValue: Encodable {
    let id: String
    let message: String
    let status: String
}

/// `{"token","length"}`.
private struct BleTokenLine: Encodable {
    let token: String
    let length: Int
}

// MARK: - CLI-local Encodable mirrors of the shot-counter models

/// ISO 8601, UTC, with milliseconds: the form of the `ts` field.
private func bleISO8601(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

/// Mirror of `BluetoothShotCounterUpdate`. Nil fields are omitted.
private struct BleShotCounterUpdateValue: Encodable {
    let state: String
    let timerValue: Double?
    let finalShotTime: Double?
    let startedDoseIndex: String?
    let stopReason: String?
    let receivedAt: String
    let brewingStartTime: String?
    let raw: BleBrewingDataValue

    init(_ update: BluetoothShotCounterUpdate) {
        state = update.state.rawValue
        timerValue = update.timerValue
        finalShotTime = update.finalShotTime
        startedDoseIndex = update.startedDoseIndex
        stopReason = update.stopReason
        receivedAt = bleISO8601(update.receivedAt)
        brewingStartTime = update.brewingStartTime.map(bleISO8601)
        raw = BleBrewingDataValue(update.raw)
    }
}

/// Mirror of `BluetoothBrewingData`. Nil fields are omitted.
private struct BleBrewingDataValue: Encodable {
    let startedDoseIndex: String?
    let ev: Bool?
    let backflush: Bool?
    let brewingTime: Double?
    let flushStoppedTime: Double?
    let flushStoppedDoseIndex: String?
    let brewingStoppedTime: Double?
    let brewingStoppedDoseIndex: String?
    let brewingStoppedStopType: String?
    let brewingStoppedStopReason: String?

    init(_ data: BluetoothBrewingData) {
        startedDoseIndex = data.startedDoseIndex
        ev = data.ev
        backflush = data.backflush
        brewingTime = data.brewingTime
        flushStoppedTime = data.flushStoppedTime
        flushStoppedDoseIndex = data.flushStoppedDoseIndex
        brewingStoppedTime = data.brewingStoppedTime
        brewingStoppedDoseIndex = data.brewingStoppedDoseIndex
        brewingStoppedStopType = data.brewingStoppedStopType
        brewingStoppedStopReason = data.brewingStoppedStopReason
    }
}

/// Mirror of `BluetoothMachineTelemetry`: only the values present (nil fields are omitted).
private struct BleTelemetryValue: Encodable {
    let coffeeBoilerTemperature: Double?
    let steamBoilerTemperature: Double?
    /// The wire string (e.g. "BrewingMode").
    let machineMode: String?
    let sleep: String?
    let machineStatistics: BleJSONValue?

    init(_ telemetry: BluetoothMachineTelemetry) {
        coffeeBoilerTemperature = telemetry.coffeeBoilerTemperature
        steamBoilerTemperature = telemetry.steamBoilerTemperature
        machineMode = telemetry.machineMode?.rawValue
        sleep = telemetry.sleep
        machineStatistics = telemetry.machineStatistics.map(BleJSONValue.init)
    }
}

/// Mirror of `BluetoothJSONValue`, encoded as the JSON it represents.
private struct BleJSONValue: Encodable {
    let value: BluetoothJSONValue

    init(_ value: BluetoothJSONValue) { self.value = value }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let elements): try container.encode(elements.map(BleJSONValue.init))
        case .object(let members): try container.encode(members.mapValues(BleJSONValue.init))
        }
    }
}
