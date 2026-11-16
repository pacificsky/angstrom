import XCTest
@testable import Angstrom
import AngstromTestSupport

/// Leaf value types of the Bluetooth port: SPEC §4.11 (merge), §4.12, §6.2, §6.4, §6.6, §6.9, §6.10.
final class BluetoothModelsTests: XCTestCase {

    // MARK: - Fixtures

    /// Every brewing field set to a non-falsy value.
    private let fullBrewing = BluetoothBrewingData(
        startedDoseIndex: "DoseA", ev: true, backflush: true, brewingTime: 12.5,
        flushStoppedTime: 3.5, flushStoppedDoseIndex: "DoseB", brewingStoppedTime: 27.25,
        brewingStoppedDoseIndex: "DoseC", brewingStoppedStopType: "Volumetric",
        brewingStoppedStopReason: "Reached")

    /// Every brewing field set to its "falsy" value: false, 0, "". All of them count as set.
    private let falsyBrewing = BluetoothBrewingData(
        startedDoseIndex: "", ev: false, backflush: false, brewingTime: 0,
        flushStoppedTime: 0, flushStoppedDoseIndex: "", brewingStoppedTime: 0,
        brewingStoppedDoseIndex: "", brewingStoppedStopType: "", brewingStoppedStopReason: "")

    /// One setter per brewing field, each writing that field's falsy value.
    private let brewingFalsySetters: [(name: String, set: (inout BluetoothBrewingData) -> Void)] = [
        ("startedDoseIndex", { $0.startedDoseIndex = "" }),
        ("ev", { $0.ev = false }),
        ("backflush", { $0.backflush = false }),
        ("brewingTime", { $0.brewingTime = 0 }),
        ("flushStoppedTime", { $0.flushStoppedTime = 0 }),
        ("flushStoppedDoseIndex", { $0.flushStoppedDoseIndex = "" }),
        ("brewingStoppedTime", { $0.brewingStoppedTime = 0 }),
        ("brewingStoppedDoseIndex", { $0.brewingStoppedDoseIndex = "" }),
        ("brewingStoppedStopType", { $0.brewingStoppedStopType = "" }),
        ("brewingStoppedStopReason", { $0.brewingStoppedStopReason = "" }),
    ]

    private let fullTelemetry = BluetoothMachineTelemetry(
        coffeeBoilerTemperature: 93.5, steamBoilerTemperature: 128.25, machineMode: .brewing,
        sleep: "Off", machineStatistics: .object(["shots": .number(42)]))

    private let falsyTelemetry = BluetoothMachineTelemetry(
        coffeeBoilerTemperature: 0, steamBoilerTemperature: 0, machineMode: .standby,
        sleep: "", machineStatistics: .bool(false))

    private let telemetrySetters: [(name: String, set: (inout BluetoothMachineTelemetry) -> Void)] = [
        ("coffeeBoilerTemperature", { $0.coffeeBoilerTemperature = 0 }),
        ("steamBoilerTemperature", { $0.steamBoilerTemperature = 0 }),
        ("machineMode", { $0.machineMode = .eco }),
        ("sleep", { $0.sleep = "" }),
        ("machineStatistics", { $0.machineStatistics = .number(0) }),
    ]

    // MARK: - Brewing data (§4.11, MBT:73-87)

    /// Angstrom-only: §4.11 — `merging` overwrites with every non-nil field of `other` (false/0/"" count as set) and never clears a field.
    func testBrewingMergeNeverClears() {
        let empty = BluetoothBrewingData()
        // Merging an empty partial changes nothing.
        XCTAssertEqual(fullBrewing.merging(empty), fullBrewing)
        XCTAssertEqual(falsyBrewing.merging(empty), falsyBrewing)
        // Every set field of `other` wins, including falsy values.
        XCTAssertEqual(fullBrewing.merging(falsyBrewing), falsyBrewing)
        XCTAssertEqual(falsyBrewing.merging(fullBrewing), fullBrewing)
        XCTAssertEqual(empty.merging(fullBrewing), fullBrewing)
        XCTAssertEqual(empty.merging(falsyBrewing), falsyBrewing)

        // Field by field: only that field changes; the other nine keep their values.
        for setter in brewingFalsySetters {
            var partial = BluetoothBrewingData()
            setter.set(&partial)
            var expected = fullBrewing
            setter.set(&expected)
            XCTAssertNotEqual(expected, fullBrewing, setter.name)
            XCTAssertEqual(fullBrewing.merging(partial), expected, setter.name)
            // And merging into empty yields exactly the partial.
            XCTAssertEqual(empty.merging(partial), partial, setter.name)
        }

        // `merging` is non-mutating.
        var original = fullBrewing
        _ = original.merging(falsyBrewing)
        XCTAssertEqual(original, fullBrewing)
        original.ev = nil
        XCTAssertEqual(original.merging(BluetoothBrewingData(ev: nil)).ev, nil)
    }

    /// Angstrom-only: §4.11 — `isEmpty` is true only when every field is nil; a falsy value counts as set (brewing and telemetry).
    func testIsEmpty() {
        XCTAssertTrue(BluetoothBrewingData().isEmpty)
        XCTAssertFalse(fullBrewing.isEmpty)
        XCTAssertFalse(falsyBrewing.isEmpty)
        for setter in brewingFalsySetters {
            var data = BluetoothBrewingData()
            setter.set(&data)
            XCTAssertFalse(data.isEmpty, setter.name)
        }

        XCTAssertTrue(BluetoothMachineTelemetry().isEmpty)
        XCTAssertFalse(fullTelemetry.isEmpty)
        XCTAssertFalse(falsyTelemetry.isEmpty)
        for setter in telemetrySetters {
            var telemetry = BluetoothMachineTelemetry()
            setter.set(&telemetry)
            XCTAssertFalse(telemetry.isEmpty, setter.name)
        }
        // A JSON null statistics value is a set (non-nil) field at the model level.
        XCTAssertFalse(BluetoothMachineTelemetry(machineStatistics: .null).isEmpty)
    }

    /// Angstrom-only: §4.12 — telemetry `merging` has the brewing-merge semantics: non-nil fields of `other` win, nothing is cleared.
    func testTelemetryMerge() {
        let empty = BluetoothMachineTelemetry()
        XCTAssertEqual(fullTelemetry.merging(empty), fullTelemetry)
        XCTAssertEqual(empty.merging(fullTelemetry), fullTelemetry)
        XCTAssertEqual(fullTelemetry.merging(falsyTelemetry), falsyTelemetry)
        XCTAssertEqual(falsyTelemetry.merging(fullTelemetry), fullTelemetry)

        for setter in telemetrySetters {
            var partial = BluetoothMachineTelemetry()
            setter.set(&partial)
            var expected = fullTelemetry
            setter.set(&expected)
            XCTAssertNotEqual(expected, fullTelemetry, setter.name)
            XCTAssertEqual(fullTelemetry.merging(partial), expected, setter.name)
            XCTAssertEqual(empty.merging(partial), partial, setter.name)
        }

        // Typical stream: one value per notification accumulates.
        let merged = BluetoothMachineTelemetry(coffeeBoilerTemperature: 90)
            .merging(BluetoothMachineTelemetry(steamBoilerTemperature: 120))
            .merging(BluetoothMachineTelemetry(machineMode: .standby))
            .merging(BluetoothMachineTelemetry(coffeeBoilerTemperature: 91))
        XCTAssertEqual(merged, BluetoothMachineTelemetry(coffeeBoilerTemperature: 91, steamBoilerTemperature: 120,
                                                         machineMode: .standby))
    }

    // MARK: - Shot-counter update (MBT:166-188)

    /// Angstrom-only: §6.9 — `brewingStartTime` defaults to `receivedAt − timerValue` only for `.brewing` with a timer and no explicit start (`__post_init__`).
    func testUpdateDefaultStartTime() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let raw = BluetoothBrewingData(ev: true, brewingTime: 5)

        let defaulted = BluetoothShotCounterUpdate(state: .brewing, timerValue: 5, receivedAt: t, raw: raw)
        XCTAssertEqual(defaulted.brewingStartTime, Date(timeIntervalSince1970: 999_995))
        let fractional = BluetoothShotCounterUpdate(state: .brewing, timerValue: 2.5, receivedAt: t, raw: raw)
        XCTAssertEqual(fractional.brewingStartTime, Date(timeIntervalSince1970: 999_997.5))
        let zero = BluetoothShotCounterUpdate(state: .brewing, timerValue: 0, receivedAt: t, raw: raw)
        XCTAssertEqual(zero.brewingStartTime, t)

        // An explicit start is kept.
        let explicit = Date(timeIntervalSince1970: 999_000)
        let kept = BluetoothShotCounterUpdate(state: .brewing, timerValue: 5, receivedAt: t, raw: raw,
                                              brewingStartTime: explicit)
        XCTAssertEqual(kept.brewingStartTime, explicit)

        // No timer → no default.
        XCTAssertNil(BluetoothShotCounterUpdate(state: .brewing, receivedAt: t, raw: raw).brewingStartTime)

        // Other states never default, even with a timer value.
        for state in [BluetoothBrewingState.brewingStopped, .flushed, .backflushing] {
            let update = BluetoothShotCounterUpdate(state: state, timerValue: 5, receivedAt: t, raw: raw)
            XCTAssertNil(update.brewingStartTime, state.rawValue)
        }

        // The initializer stores every other field verbatim.
        let full = BluetoothShotCounterUpdate(state: .brewingStopped, timerValue: nil, finalShotTime: 27.5,
                                              startedDoseIndex: "DoseA", stopReason: "Reached",
                                              receivedAt: t, raw: fullBrewing)
        XCTAssertEqual(full.state, .brewingStopped)
        XCTAssertNil(full.timerValue)
        XCTAssertEqual(full.finalShotTime, 27.5)
        XCTAssertEqual(full.startedDoseIndex, "DoseA")
        XCTAssertEqual(full.stopReason, "Reached")
        XCTAssertEqual(full.receivedAt, t)
        XCTAssertEqual(full.raw, fullBrewing)
        XCTAssertNil(full.brewingStartTime)
    }

    // MARK: - Command status (MBT:59-65, MACH:1023)

    /// Angstrom-only: §6.6 — `isSuccess` is `status.lower() == "success"`: case-insensitive, no trimming.
    func testCommandStatusIsSuccessCaseInsensitive() {
        for status in ["success", "SUCCESS", "Success", "sUcCeSs"] {
            XCTAssertTrue(BluetoothCommandStatus(id: "ble", message: "Success", status: status).isSuccess, status)
        }
        for status in ["error", "failed", "", " success", "success ", "successful", "succes", "None"] {
            XCTAssertFalse(BluetoothCommandStatus(id: "ble", message: "Success", status: status).isSuccess, status)
        }
        // Only `status` matters, not `message`.
        XCTAssertFalse(BluetoothCommandStatus(id: "ble", message: "success", status: "error").isSuccess)
        let status = BluetoothCommandStatus(id: "test-id", message: "Success", status: "success")
        XCTAssertEqual(status.id, "test-id")
        XCTAssertEqual(status.message, "Success")
        XCTAssertEqual(status.status, "success")
    }

    // MARK: - BluetoothJSONValue (§6.9)

    /// Angstrom-only: §6.9 — the `BluetoothJSONValue` subscript returns an object member, else nil.
    func testJSONValueSubscript() {
        let value = BluetoothJSONValue.object([
            "a": .number(1),
            "n": .null,
            "s": .string("x"),
            "nested": .object(["b": .bool(true)]),
            "list": .array([.number(2)]),
        ])
        XCTAssertEqual(value["a"], .number(1))
        XCTAssertEqual(value["n"], .some(.null))
        XCTAssertEqual(value["s"], .string("x"))
        XCTAssertEqual(value["nested"]?["b"], .bool(true))
        XCTAssertEqual(value["list"], .array([.number(2)]))
        XCTAssertNil(value["missing"])
        XCTAssertNil(value["A"])
        XCTAssertNil(value["nested"]?["missing"])
        XCTAssertNil(value["list"]?["0"])

        // Non-objects have no members.
        for other in [BluetoothJSONValue.null, .bool(true), .number(1), .string("a"),
                      .array([.object(["a": .number(1)])])] {
            XCTAssertNil(other["a"], "\(other)")
        }
        XCTAssertNil(BluetoothJSONValue.object([:])["a"])
    }

    // MARK: - Diagnostics (§6.10)

    /// Angstrom-only: §6.10 — `RawBluetoothFrame` event marker texts are exact, `mtuMarker` renders "[mtu <n>]", and the init stores its fields.
    func testRawFrameMarkers() {
        XCTAssertEqual(RawBluetoothFrame.connectingMarker, "[connecting]")
        XCTAssertEqual(RawBluetoothFrame.connectedMarker, "[connected]")
        XCTAssertEqual(RawBluetoothFrame.authenticatedMarker, "[authenticated]")
        XCTAssertEqual(RawBluetoothFrame.disconnectedMarker, "[disconnected]")
        XCTAssertEqual(RawBluetoothFrame.subscribedMarker, "[subscribed]")
        XCTAssertEqual(RawBluetoothFrame.unsubscribedMarker, "[unsubscribed]")
        XCTAssertEqual(RawBluetoothFrame.replayDroppedMarker, "[replay dropped]")
        XCTAssertEqual(RawBluetoothFrame.servicesInvalidatedMarker, "[services invalidated]")
        XCTAssertEqual(RawBluetoothFrame.mtuMarker(185), "[mtu 185]")
        XCTAssertEqual(RawBluetoothFrame.mtuMarker(23), "[mtu 23]")
        XCTAssertEqual(RawBluetoothFrame.mtuMarker(517), "[mtu 517]")

        let t = Date(timeIntervalSince1970: 42)
        let frame = RawBluetoothFrame(timestamp: t, direction: .outbound, kind: .write,
                                      characteristic: "0d0b7847-e12b-09a8-b04b-8e0922a9abab",
                                      data: Data("token".utf8), isSecret: true)
        XCTAssertEqual(frame.timestamp, t)
        XCTAssertEqual(frame.direction, .outbound)
        XCTAssertEqual(frame.kind, .write)
        XCTAssertEqual(frame.characteristic, "0d0b7847-e12b-09a8-b04b-8e0922a9abab")
        XCTAssertEqual(frame.data, Data("token".utf8))
        XCTAssertTrue(frame.isSecret)

        let event = RawBluetoothFrame(timestamp: t, direction: .inbound, kind: .event, characteristic: nil,
                                      data: Data(RawBluetoothFrame.connectedMarker.utf8), isSecret: false)
        XCTAssertNil(event.characteristic)
        XCTAssertEqual(String(decoding: event.data, as: UTF8.self), "[connected]")
        XCTAssertFalse(event.isSecret)
    }

    // MARK: - Errors (§6.4)

    /// Every availability state, so tables below cover them all.
    private let allAvailabilities: [BluetoothAvailability] = [
        .unknown, .resetting, .unsupported,
        .unauthorized(.notDetermined), .unauthorized(.restricted), .unauthorized(.denied),
        .unauthorized(.allowedAlways), .poweredOff, .poweredOn,
    ]

    /// Angstrom-only: §6.4 — every Bluetooth `errorDescription` is verbatim from the SPEC table (and `EXC:34`).
    func testErrorDescriptionsVerbatim() {
        XCTAssertEqual(LaMarzoccoError.bluetoothConnectionFailed("boom").errorDescription,
                       "Bluetooth connection failed: boom")
        XCTAssertEqual(LaMarzoccoError.bluetoothConnectionFailed("").errorDescription,
                       "Bluetooth connection failed: ")
        XCTAssertEqual(LaMarzoccoError.bluetoothAuthenticationFailed.errorDescription,
                       "Bluetooth authentication failed. The Bluetooth token is likely wrong.")
        XCTAssertEqual(LaMarzoccoError.bluetoothTimedOut("read 0a0b").errorDescription,
                       "The machine did not answer over Bluetooth in time (read 0a0b).")
        XCTAssertEqual(LaMarzoccoError.cloudOnlyFunctionality.errorDescription,
                       "Functionality is cloud only, but cloud client not initialized.")

        for availability in allAvailabilities {
            let expected: String
            switch availability {
            case .poweredOff: expected = "Bluetooth is turned off."
            case .unauthorized: expected = "Bluetooth access is not allowed. Check Privacy & Security settings."
            case .unsupported: expected = "Bluetooth Low Energy is not supported on this device."
            case .unknown, .resetting, .poweredOn: expected = "Bluetooth is not ready."
            }
            XCTAssertEqual(LaMarzoccoError.bluetoothUnavailable(availability).errorDescription, expected,
                           "\(availability)")
        }
        // Spot-check the literal strings independent of the switch above.
        XCTAssertEqual(LaMarzoccoError.bluetoothUnavailable(.unauthorized(.denied)).errorDescription,
                       "Bluetooth access is not allowed. Check Privacy & Security settings.")
        XCTAssertEqual(LaMarzoccoError.bluetoothUnavailable(.resetting).errorDescription, "Bluetooth is not ready.")
        // Surfaces through `localizedDescription` (LocalizedError).
        XCTAssertEqual((LaMarzoccoError.bluetoothAuthenticationFailed as Error).localizedDescription,
                       "Bluetooth authentication failed. The Bluetooth token is likely wrong.")
    }

    /// Angstrom-only: D10 — `isBluetoothConnectionFailure` is true exactly for connection failed, authentication failed and unavailable.
    func testIsBluetoothConnectionFailure() {
        var cases: [(LaMarzoccoError, Bool)] = [
            (.authenticationFailed, false),
            (.policyAcceptanceRequired, false),
            (.invalidInstallationKey, false),
            (.requestFailed(status: 500, body: ""), false),
            (.network("x"), false),
            (.decoding("bluetooth command: x"), false),
            (.noMachines, false),
            (.webSocket("x"), false),
            (.commandTimedOut, false),
            (.commandFailed(status: "error", errorCode: nil), false),
            (.unsupportedModel("x"), false),
            (.operationNotAvailable("x"), false),
            (.bluetoothConnectionFailed("x"), true),
            (.bluetoothAuthenticationFailed, true),
            (.bluetoothTimedOut("x"), false),
            (.cloudOnlyFunctionality, false),
        ]
        cases += allAvailabilities.map { (.bluetoothUnavailable($0), true) }
        for (error, expected) in cases {
            XCTAssertEqual(error.isBluetoothConnectionFailure, expected, "\(error)")
        }
        // The table above names every case of the enum (checked by the exhaustive switch).
        XCTAssertEqual(Set(cases.map { Self.caseName($0.0) }).count, Self.errorCaseCount)
    }

    /// Exhaustive over `LaMarzoccoError`: adding a case fails to compile until the tables above cover it.
    private static func caseName(_ error: LaMarzoccoError) -> String {
        switch error {
        case .authenticationFailed: "authenticationFailed"
        case .policyAcceptanceRequired: "policyAcceptanceRequired"
        case .invalidInstallationKey: "invalidInstallationKey"
        case .requestFailed: "requestFailed"
        case .network: "network"
        case .decoding: "decoding"
        case .noMachines: "noMachines"
        case .webSocket: "webSocket"
        case .commandTimedOut: "commandTimedOut"
        case .commandFailed: "commandFailed"
        case .unsupportedModel: "unsupportedModel"
        case .operationNotAvailable: "operationNotAvailable"
        case .bluetoothConnectionFailed: "bluetoothConnectionFailed"
        case .bluetoothAuthenticationFailed: "bluetoothAuthenticationFailed"
        case .bluetoothUnavailable: "bluetoothUnavailable"
        case .bluetoothTimedOut: "bluetoothTimedOut"
        case .cloudOnlyFunctionality: "cloudOnlyFunctionality"
        }
    }
    private static let errorCaseCount = 17

    // MARK: - Transport errors (§6.2)

    /// Angstrom-only: §6.2 — `BluetoothTransportError.description` is non-empty (and distinct) for every case.
    func testTransportErrorDescriptions() {
        var errors: [BluetoothTransportError] = [
            .unknownPeripheral(BluetoothPeripheralID(rawValue: "6F1E0C2A-0000-0000-0000-000000000001")),
            .timedOut("connect"),
            .notConnected,
            .characteristicNotFound(BluetoothConstants.shotCounterCharacteristic),
            .valueTooLong(600, max: 512),
            .disconnected(code: nil),
            .disconnected(code: 7),
            .gatt(domain: "CBATTErrorDomain", code: 5),
        ]
        errors += allAvailabilities.map { .unavailable($0) }
        var names = Set<String>()
        for error in errors {
            XCTAssertFalse(error.description.isEmpty, "\(Self.caseName(error))")
            XCTAssertFalse(error.description.trimmingCharacters(in: .whitespaces).isEmpty)
            names.insert(Self.caseName(error))
        }
        XCTAssertEqual(names.count, 8, "every BluetoothTransportError case is covered")
        XCTAssertEqual(Set(errors.map(\.description)).count, errors.count, "descriptions are distinct")
        // String interpolation uses the description.
        XCTAssertEqual("\(BluetoothTransportError.notConnected)", BluetoothTransportError.notConnected.description)
    }

    /// Exhaustive over `BluetoothTransportError`.
    private static func caseName(_ error: BluetoothTransportError) -> String {
        switch error {
        case .unavailable: "unavailable"
        case .unknownPeripheral: "unknownPeripheral"
        case .timedOut: "timedOut"
        case .notConnected: "notConnected"
        case .characteristicNotFound: "characteristicNotFound"
        case .valueTooLong: "valueTooLong"
        case .disconnected: "disconnected"
        case .gatt: "gatt"
        }
    }
}
