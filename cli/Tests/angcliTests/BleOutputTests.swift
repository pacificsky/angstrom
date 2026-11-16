import XCTest
import Angstrom
@testable import angcli

/// `BleOutput` line shapes (SPEC §10.1, §10.3) and BLE redaction (SPEC §10.4). Pure: no CoreBluetooth.
final class BleOutputTests: XCTestCase {
    private let readUUID = "0a0b7847-e12b-09a8-b04b-8e0922a9abab"
    private let writeUUID = "0b0b7847-e12b-09a8-b04b-8e0922a9abab"
    private let tokenUUID = "0c0b7847-e12b-09a8-b04b-8e0922a9abab"
    private let authUUID = "0d0b7847-e12b-09a8-b04b-8e0922a9abab"
    private let shotCounterUUID = "0e0b7847-e12b-09a8-b04b-8e0922a9abab"

    private func frame(_ direction: RawBluetoothFrame.Direction, _ kind: RawBluetoothFrame.Kind,
                       _ characteristic: String?, _ data: Data, secret: Bool = false) -> RawBluetoothFrame {
        RawBluetoothFrame(timestamp: Date(timeIntervalSince1970: 0), direction: direction, kind: kind,
                          characteristic: characteristic, data: data, isSecret: secret)
    }

    /// Angstrom-only: §10.3 — `{"ts","dir","kind","char","hex","text"}` for every kind and direction.
    func testRawLineShape() {
        let write = frame(.outbound, .write, writeUUID, Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(BleOutput.rawLine(write, ts: "T"),
                       #"{"char":"0b0b7847-e12b-09a8-b04b-8e0922a9abab","dir":">>","hex":"7b2261223a317d","kind":"write","text":"{\"a\":1}","ts":"T"}"#)

        let read = frame(.inbound, .read, readUUID, Data("OK".utf8))
        XCTAssertEqual(BleOutput.rawLine(read, ts: "T"),
                       #"{"char":"0a0b7847-e12b-09a8-b04b-8e0922a9abab","dir":"<<","hex":"4f4b","kind":"read","text":"OK","ts":"T"}"#)

        let notification = frame(.inbound, .notification, shotCounterUUID, Data([0x41, 0x5a]))
        XCTAssertEqual(BleOutput.rawLine(notification, ts: "2026-11-14T10:00:00.000Z"),
                       #"{"char":"0e0b7847-e12b-09a8-b04b-8e0922a9abab","dir":"<<","hex":"415a","kind":"notification","text":"AZ","ts":"2026-11-14T10:00:00.000Z"}"#)

        // `.event`: no characteristic (null), and `text` is the marker.
        let event = frame(.inbound, .event, nil, Data(RawBluetoothFrame.connectedMarker.utf8))
        XCTAssertEqual(BleOutput.rawLine(event, ts: "T"),
                       #"{"char":null,"dir":"<<","hex":"5b636f6e6e65637465645d","kind":"event","text":"[connected]","ts":"T"}"#)

        // Upper-case hex digits never appear.
        let highBytes = frame(.outbound, .write, writeUUID, Data("é".utf8))
        XCTAssertEqual(BleOutput.rawLine(highBytes, ts: "T"),
                       #"{"char":"0b0b7847-e12b-09a8-b04b-8e0922a9abab","dir":">>","hex":"c3a9","kind":"write","text":"é","ts":"T"}"#)
    }

    /// Angstrom-only: §10.4 — an `isSecret` frame shows `**REDACTED**` for both hex and text, whatever its characteristic.
    func testSecretFrameRedacted() {
        let secret = Data("SECRETTOKEN".utf8)
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()

        let write = frame(.outbound, .write, writeUUID, secret, secret: true)
        let writeLine = BleOutput.rawLine(write, ts: "T")
        XCTAssertEqual(writeLine,
                       #"{"char":"0b0b7847-e12b-09a8-b04b-8e0922a9abab","dir":">>","hex":"**REDACTED**","kind":"write","text":"**REDACTED**","ts":"T"}"#)

        let read = frame(.inbound, .read, readUUID, secret, secret: true)
        XCTAssertEqual(BleOutput.rawLine(read, ts: "T"),
                       #"{"char":"0a0b7847-e12b-09a8-b04b-8e0922a9abab","dir":"<<","hex":"**REDACTED**","kind":"read","text":"**REDACTED**","ts":"T"}"#)

        // Non-UTF-8 secret bytes still get a (redacted) text, so nothing hints at the value.
        let binary = frame(.inbound, .notification, shotCounterUUID, Data([0xff, 0xfe]), secret: true)
        XCTAssertEqual(BleOutput.rawLine(binary, ts: "T"),
                       #"{"char":"0e0b7847-e12b-09a8-b04b-8e0922a9abab","dir":"<<","hex":"**REDACTED**","kind":"notification","text":"**REDACTED**","ts":"T"}"#)

        for line in [writeLine, BleOutput.rawLine(read, ts: "T")] {
            let text = line ?? ""
            XCTAssertFalse(text.contains("SECRETTOKEN"), text)
            XCTAssertFalse(text.contains(secretHex), text)
        }
    }

    /// Angstrom-only: §10.4 — any write to the auth characteristic is redacted even when `isSecret` is false.
    func testAuthWriteRedactedByUUID() {
        let token = Data("abcdef0123".utf8)
        XCTAssertEqual(BleOutput.rawLine(frame(.outbound, .write, authUUID, token), ts: "T"),
                       #"{"char":"0d0b7847-e12b-09a8-b04b-8e0922a9abab","dir":">>","hex":"**REDACTED**","kind":"write","text":"**REDACTED**","ts":"T"}"#)

        // The UUID comparison is case-insensitive; `char` is printed as given.
        let upper = authUUID.uppercased()
        XCTAssertEqual(BleOutput.rawLine(frame(.outbound, .write, upper, token), ts: "T"),
                       #"{"char":"0D0B7847-E12B-09A8-B04B-8E0922A9ABAB","dir":">>","hex":"**REDACTED**","kind":"write","text":"**REDACTED**","ts":"T"}"#)

        // The rule is about writes: the auth result read back (0x01) carries no secret and is shown.
        XCTAssertEqual(BleOutput.rawLine(frame(.inbound, .read, authUUID, Data([0x01])), ts: "T"),
                       #"{"char":"0d0b7847-e12b-09a8-b04b-8e0922a9abab","dir":"<<","hex":"01","kind":"read","text":"\u0001","ts":"T"}"#)
    }

    /// Angstrom-only: §10.4 — any read of the token characteristic is redacted even when `isSecret` is false.
    func testTokenReadRedactedByUUID() {
        let token = Data("abcdef0123".utf8)
        XCTAssertEqual(BleOutput.rawLine(frame(.inbound, .read, tokenUUID, token), ts: "T"),
                       #"{"char":"0c0b7847-e12b-09a8-b04b-8e0922a9abab","dir":"<<","hex":"**REDACTED**","kind":"read","text":"**REDACTED**","ts":"T"}"#)

        let upper = tokenUUID.uppercased()
        XCTAssertEqual(BleOutput.rawLine(frame(.inbound, .read, upper, token), ts: "T"),
                       #"{"char":"0C0B7847-E12B-09A8-B04B-8E0922A9ABAB","dir":"<<","hex":"**REDACTED**","kind":"read","text":"**REDACTED**","ts":"T"}"#)

        // The rule is about reads: other kinds on that characteristic are shown.
        XCTAssertEqual(BleOutput.rawLine(frame(.outbound, .write, tokenUUID, Data("x".utf8)), ts: "T"),
                       #"{"char":"0c0b7847-e12b-09a8-b04b-8e0922a9abab","dir":">>","hex":"78","kind":"write","text":"x","ts":"T"}"#)
    }

    /// Angstrom-only: §10.3 — bytes that are not valid UTF-8 print hex only: the raw line omits `text`, a read line's `raw` is hex.
    func testNonUTF8RawHasNoText() {
        let bytes = Data([0xff, 0x00, 0xab])
        XCTAssertEqual(BleOutput.rawLine(frame(.inbound, .notification, shotCounterUUID, bytes), ts: "T"),
                       #"{"char":"0e0b7847-e12b-09a8-b04b-8e0922a9abab","dir":"<<","hex":"ff00ab","kind":"notification","ts":"T"}"#)

        // A truncated multi-byte sequence is not UTF-8 either.
        XCTAssertEqual(BleOutput.rawLine(frame(.inbound, .read, readUUID, Data([0x7b, 0xc3])), ts: "T"),
                       #"{"char":"0a0b7847-e12b-09a8-b04b-8e0922a9abab","dir":"<<","hex":"7bc3","kind":"read","ts":"T"}"#)

        XCTAssertEqual(BleOutput.readLine(setting: .boilers, raw: bytes, decoded: nil as Int?, ts: "T"),
                       #"{"decoded":null,"raw":"ff00ab","setting":"boilers","ts":"T"}"#)
        // Valid UTF-8 prints as text, verbatim: a NUL is kept, not cut.
        XCTAssertEqual(BleOutput.readLine(setting: .machineMode, raw: Data("\"BrewingMode\"".utf8),
                                          decoded: "BrewingMode", ts: "T"),
                       #"{"decoded":"BrewingMode","raw":"\"BrewingMode\"","setting":"machineMode","ts":"T"}"#)
        XCTAssertEqual(BleOutput.readLine(setting: .isPlumbedIn, raw: Data([0x74, 0x72, 0x75, 0x65, 0x00]),
                                          decoded: true, ts: "T"),
                       #"{"decoded":true,"raw":"true\u0000","setting":"isPlumbedIn","ts":"T"}"#)
    }

    /// Angstrom-only: §10.3 — decoded lines are `{"ts","event","value"}`; scan, gatt, read and cmd lines match §10.1.
    func testDecodedLineShapes() throws {
        XCTAssertEqual(BleOutput.connectionLine(.connected, ts: "T"), #"{"event":"connected","ts":"T","value":{}}"#)
        XCTAssertEqual(BleOutput.connectionLine(.disconnected, ts: "T"), #"{"event":"disconnected","ts":"T","value":{}}"#)
        XCTAssertEqual(BleOutput.shotCounterLine(.subscribed, ts: "T"), #"{"event":"subscribed","ts":"T","value":{}}"#)
        XCTAssertEqual(BleOutput.shotCounterLine(.unsubscribed, ts: "T"), #"{"event":"unsubscribed","ts":"T","value":{}}"#)

        // 1_700_000_000 s = 2023-11-14T22:13:20Z; the start defaults to receivedAt − timerValue.
        let update = BluetoothShotCounterUpdate(
            state: .brewing, timerValue: 12.5, startedDoseIndex: "DoseA",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
            raw: BluetoothBrewingData(startedDoseIndex: "DoseA", ev: false, brewingTime: 12.5))
        XCTAssertEqual(BleOutput.shotCounterLine(.brewing(update), ts: "T"),
                       #"{"event":"brewing","ts":"T","value":{"brewingStartTime":"2023-11-14T22:13:07.750Z","raw":{"brewingTime":12.5,"ev":false,"startedDoseIndex":"DoseA"},"receivedAt":"2023-11-14T22:13:20.250Z","startedDoseIndex":"DoseA","state":"Brewing","timerValue":12.5}}"#)

        let stopped = BluetoothShotCounterUpdate(
            state: .brewingStopped, finalShotTime: 27.25, stopReason: "Manual",
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            raw: BluetoothBrewingData(brewingStoppedTime: 27.25, brewingStoppedStopReason: "Manual"))
        XCTAssertEqual(BleOutput.shotCounterLine(.brewing(stopped), ts: "T"),
                       #"{"event":"brewing","ts":"T","value":{"finalShotTime":27.25,"raw":{"brewingStoppedStopReason":"Manual","brewingStoppedTime":27.25},"receivedAt":"2023-11-14T22:13:20.000Z","state":"BrewingStopped","stopReason":"Manual"}}"#)

        // Telemetry carries only the values present; MachineStatistics is the JSON it parsed to.
        let telemetry = BluetoothMachineTelemetry(
            coffeeBoilerTemperature: 93.5, steamBoilerTemperature: 124, machineMode: .brewing,
            machineStatistics: .object(["shots": .number(42), "list": .array([.bool(true), .null, .string("x")])]))
        XCTAssertEqual(BleOutput.shotCounterLine(.telemetry(telemetry), ts: "T"),
                       #"{"event":"telemetry","ts":"T","value":{"coffeeBoilerTemperature":93.5,"machineMode":"BrewingMode","machineStatistics":{"list":[true,null,"x"],"shots":42},"steamBoilerTemperature":124}}"#)
        XCTAssertEqual(BleOutput.shotCounterLine(.telemetry(BluetoothMachineTelemetry(machineMode: .other("Weird"), sleep: "0")), ts: "T"),
                       #"{"event":"telemetry","ts":"T","value":{"machineMode":"Weird","sleep":"0"}}"#)

        XCTAssertEqual(BleOutput.shotCounterLine(.gaveUp(.bluetoothAuthenticationFailed), ts: "T"),
                       #"{"event":"gaveUp","ts":"T","value":{"error":"Bluetooth authentication failed. The Bluetooth token is likely wrong."}}"#)

        // `ble scan`: {"id","name","rssi"}; name and rssi may be null.
        let id = BluetoothPeripheralID(rawValue: "1B6B3B2C-6F0E-4C55-9E1A-2D3C4B5A6978")
        XCTAssertEqual(BleOutput.peripheralLine(DiscoveredPeripheral(id: id, name: "MICRA_123456", rssi: -61)),
                       #"{"id":"1B6B3B2C-6F0E-4C55-9E1A-2D3C4B5A6978","name":"MICRA_123456","rssi":-61}"#)
        XCTAssertEqual(BleOutput.peripheralLine(DiscoveredPeripheral(id: id, name: nil, rssi: nil)),
                       #"{"id":"1B6B3B2C-6F0E-4C55-9E1A-2D3C4B5A6978","name":null,"rssi":null}"#)

        // `ble gatt`: one line per characteristic, in table order; a service with none prints nothing.
        let table = [
            BluetoothGATTService(uuid: "180a", characteristics: []),
            BluetoothGATTService(uuid: "0a0b7847-e12b-09a8-b04b-8e0922a9abab", characteristics: [
                BluetoothGATTCharacteristic(uuid: readUUID, properties: ["read", "write"]),
                BluetoothGATTCharacteristic(uuid: shotCounterUUID, properties: ["notify"]),
            ]),
            BluetoothGATTService(uuid: "1801", characteristics: [
                BluetoothGATTCharacteristic(uuid: "2a05", properties: []),
            ]),
        ]
        XCTAssertEqual(BleOutput.gattLines(table), [
            #"{"characteristic":"0a0b7847-e12b-09a8-b04b-8e0922a9abab","properties":["read","write"],"service":"0a0b7847-e12b-09a8-b04b-8e0922a9abab"}"#,
            #"{"characteristic":"0e0b7847-e12b-09a8-b04b-8e0922a9abab","properties":["notify"],"service":"0a0b7847-e12b-09a8-b04b-8e0922a9abab"}"#,
            #"{"characteristic":"2a05","properties":[],"service":"1801"}"#,
        ])
        XCTAssertEqual(BleOutput.gattLines([]), [])

        // `ble read`: {"ts","setting","raw","decoded"} with an Encodable decoded value.
        let boilers = #"[{"id":"CoffeeBoiler1","isEnabled":true,"target":93,"current":92}]"#
        XCTAssertEqual(BleOutput.readLine(setting: .boilers, raw: Data(boilers.utf8),
                                          decoded: ["CoffeeBoiler1": 93.5], ts: "T"),
                       #"{"decoded":{"CoffeeBoiler1":93.5},"raw":"[{\"id\":\"CoffeeBoiler1\",\"isEnabled\":true,\"target\":93,\"current\":92}]","setting":"boilers","ts":"T"}"#)

        // `ble cmd`: {"ts","command","status":{id,message,status},"success"}; success is case-insensitive "success".
        XCTAssertEqual(BleOutput.commandLine(command: "power on",
                                             status: BluetoothCommandStatus(id: "MachineChangeMode", message: "OK", status: "Success"),
                                             ts: "T"),
                       #"{"command":"power on","status":{"id":"MachineChangeMode","message":"OK","status":"Success"},"success":true,"ts":"T"}"#)
        XCTAssertEqual(BleOutput.commandLine(command: "steam off",
                                             status: BluetoothCommandStatus(id: "SettingBoilerEnable", message: "Busy", status: "error"),
                                             ts: "T"),
                       #"{"command":"steam off","status":{"id":"SettingBoilerEnable","message":"Busy","status":"error"},"success":false,"ts":"T"}"#)

        // The default `ts` is the shared Timestamp format (ISO 8601, UTC, milliseconds).
        let stamped = try XCTUnwrap(BleOutput.connectionLine(.connected))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stamped.utf8)) as? [String: Any])
        let ts = try XCTUnwrap(object["ts"] as? String)
        XCTAssertNotNil(ts.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression), ts)
    }

    /// Angstrom-only: §10.4 — the token line is `{"token":"**REDACTED**","length":n}` unless showSecret.
    func testTokenLineMaskedByDefault() {
        let token = BluetoothAuthToken("abc123XYZ")
        let masked = BleOutput.tokenLine(token, showSecret: false)
        XCTAssertEqual(masked, #"{"length":9,"token":"**REDACTED**"}"#)
        XCTAssertFalse(masked?.contains("abc123XYZ") ?? true)

        XCTAssertEqual(BleOutput.tokenLine(token, showSecret: true), #"{"length":9,"token":"abc123XYZ"}"#)

        // `length` counts Unicode scalars, like Python's len(str): "tök" is 3 (4 UTF-8 bytes),
        // "e" + COMBINING ACUTE is 2 (one Character).
        XCTAssertEqual(BleOutput.tokenLine(BluetoothAuthToken("t\u{00F6}k"), showSecret: false),
                       #"{"length":3,"token":"**REDACTED**"}"#)
        XCTAssertEqual(BleOutput.tokenLine(BluetoothAuthToken("e\u{0301}"), showSecret: false),
                       #"{"length":2,"token":"**REDACTED**"}"#)
        XCTAssertEqual(BleOutput.tokenLine(BluetoothAuthToken(""), showSecret: false),
                       #"{"length":0,"token":"**REDACTED**"}"#)
    }

    /// Angstrom-only: §10.4 — `Redact.secrets(in:)` is unchanged: it masks `bleAuthToken` and the STOMP bearer only.
    func testExistingRedactSecretsUnchanged() {
        XCTAssertEqual(Redact.placeholder, "**REDACTED**")
        XCTAssertEqual(Redact.secrets(in: #"{"bleAuthToken":"SECRET","serialNumber":"MR1"}"#),
                       #"{"bleAuthToken":"**REDACTED**","serialNumber":"MR1"}"#)
        XCTAssertEqual(Redact.secrets(in: #"{"bleAuthToken" : "a\"b","x":{"bleAuthToken":"S2"}}"#),
                       #"{"bleAuthToken" : "**REDACTED**","x":{"bleAuthToken":"**REDACTED**"}}"#)
        XCTAssertEqual(Redact.secrets(in: "CONNECT\nhost:h\nAuthorization:Bearer eyJ.SECRET.sig\n\n\u{0}"),
                       "CONNECT\nhost:h\nAuthorization:Bearer **REDACTED**\n\n\u{0}")
        // Untouched: empty and null tokens, other frames, and BLE-looking text (no new rules).
        XCTAssertEqual(Redact.secrets(in: #"{"bleAuthToken":""}"#), #"{"bleAuthToken":""}"#)
        XCTAssertEqual(Redact.secrets(in: #"{"bleAuthToken":null}"#), #"{"bleAuthToken":null}"#)
        XCTAssertEqual(Redact.secrets(in: "SUBSCRIBE\ndestination:/ws/sn/MR1/dashboard\n\n\u{0}"),
                       "SUBSCRIBE\ndestination:/ws/sn/MR1/dashboard\n\n\u{0}")
        XCTAssertEqual(Redact.secrets(in: "0d0b7847-e12b-09a8-b04b-8e0922a9abab abcdef"),
                       "0d0b7847-e12b-09a8-b04b-8e0922a9abab abcdef")
    }
}
