import Foundation

/// Decoders for read/command responses (§3.6, §3.10). Input is the NUL-truncated UTF-8 text.
/// Every failure throws `LaMarzoccoError.decoding("bluetooth <setting|command>: <detail>")`.
package enum BluetoothResponseDecoder {
    /// `MachineMode(value)` (`_bluetooth.py:555-560`): only the three known modes are accepted; any
    /// other value (an unknown string or a non-string) is a `ValueError` upstream, `.decoding` here.
    package static func machineMode(_ text: String) throws -> MachineMode {
        let context = BluetoothReadSetting.machineMode.rawValue
        let value = try parse(text, context: context)
        guard let raw = value as? String else {
            throw failure(context, "expected a JSON string, got \(describe(value))")
        }
        let mode = MachineMode(rawValue: raw)
        if case .other = mode {
            throw failure(context, "\(raw) is not a valid MachineMode")
        }
        return mode
    }

    /// `BluetoothMachineCapabilities.from_dict(capabilities[0])` (`_bluetooth.py:562-568`,
    /// `models/_bluetooth.py:22-39`).
    package static func capabilities(_ text: String) throws -> BluetoothMachineCapabilities {
        let context = BluetoothReadSetting.machineCapabilities.rawValue
        let value = try parse(text, context: context)
        guard let array = value as? [Any] else {
            throw failure(context, "expected a JSON array, got \(describe(value))")
        }
        guard let first = array.first else {
            throw failure(context, "empty array (no element [0])")
        }
        guard let object = first as? [String: Any] else {
            throw failure(context, "element [0] is not a JSON object")
        }
        return try coerce(context) {
            // `ModelName.from_string` (const.py:198-218) is the field's deserializer: it calls
            // `name.upper()`, so a non-string (or null) family fails the read.
            guard let familyValue = object["family"] else {
                throw BluetoothWireCoercion.Failure(detail: "missing family")
            }
            guard let rawFamily = familyValue as? String else {
                throw BluetoothWireCoercion.Failure(
                    detail: "family is not a string: \(describe(familyValue))")
            }
            guard let family = Model(bluetoothFamily: rawFamily) else {
                // Verbatim `ValueError(f"Invalid model name: {name}")` (const.py:216-217).
                throw BluetoothWireCoercion.Failure(detail: "Invalid model name: \(rawFamily)")
            }
            return BluetoothMachineCapabilities(
                family: family,
                rawFamily: rawFamily,
                groupsNumber: try BluetoothWireCoercion.requiredInt(
                    object["groupsNumber"], key: "groupsNumber"),
                coffeeBoilersNumber: try BluetoothWireCoercion.requiredInt(
                    object["coffeeBoilersNumber"], key: "coffeeBoilersNumber"),
                hasCupWarmer: try BluetoothWireCoercion.requiredBool(
                    object["hasCupWarmer"], key: "hasCupWarmer"),
                steamBoilersNumber: try BluetoothWireCoercion.requiredInt(
                    object["steamBoilersNumber"], key: "steamBoilersNumber"),
                teaDosesNumber: try BluetoothWireCoercion.requiredInt(
                    object["teaDosesNumber"], key: "teaDosesNumber"),
                machineModes: try machineModes(object["machineModes"]),
                schedulingType: try BluetoothWireCoercion.requiredString(
                    object["schedulingType"], key: "schedulingType"))
        }
    }

    /// `parseBool` on the decoded JSON value.
    package static func bool(_ text: String, setting: BluetoothReadSetting) throws -> Bool {
        BluetoothWireCoercion.parseBool(try parse(text, context: setting.rawValue))
    }

    /// `[BluetoothBoilerDetails.from_dict(b) for b in boilers]` (`_bluetooth.py:584-588`), in wire
    /// order. `target`/`current` are `Double` (D9); an unknown `id` is `.other` (D5).
    package static func boilers(_ text: String) throws -> [BluetoothBoilerDetails] {
        let context = BluetoothReadSetting.boilers.rawValue
        let value = try parse(text, context: context)
        guard let array = value as? [Any] else {
            throw failure(context, "expected a JSON array, got \(describe(value))")
        }
        var result: [BluetoothBoilerDetails] = []
        result.reserveCapacity(array.count)
        for (index, element) in array.enumerated() {
            guard let object = element as? [String: Any] else {
                throw failure(context, "element [\(index)] is not a JSON object")
            }
            let boiler = try coerce(context, prefix: "element [\(index)]: ") {
                guard let idValue = object["id"] else {
                    throw BluetoothWireCoercion.Failure(detail: "missing id")
                }
                guard let rawID = idValue as? String else {
                    throw BluetoothWireCoercion.Failure(detail: "id is not a string: \(describe(idValue))")
                }
                return BluetoothBoilerDetails(
                    id: BluetoothBoilerType(rawValue: rawID),
                    isEnabled: try BluetoothWireCoercion.requiredBool(object["isEnabled"], key: "isEnabled"),
                    target: try BluetoothWireCoercion.requiredDouble(object["target"], key: "target"),
                    current: try BluetoothWireCoercion.requiredDouble(object["current"], key: "current"))
            }
            result.append(boiler)
        }
        return result
    }

    /// `BluetoothSmartStandbyDetails.from_dict(data)` (`_bluetooth.py:590-594`,
    /// `models/_bluetooth.py:51-57`).
    package static func smartStandby(_ text: String) throws -> BluetoothSmartStandbyDetails {
        let context = BluetoothReadSetting.smartStandBy.rawValue
        let value = try parse(text, context: context)
        guard let object = value as? [String: Any] else {
            throw failure(context, "expected a JSON object, got \(describe(value))")
        }
        return try coerce(context) {
            guard let modeValue = object["mode"] else {
                throw BluetoothWireCoercion.Failure(detail: "missing mode")
            }
            guard let rawMode = modeValue as? String, let mode = SmartStandbyAfter(rawValue: rawMode) else {
                throw BluetoothWireCoercion.Failure(
                    detail: "mode is not a valid SmartStandByType: \(describe(modeValue))")
            }
            return BluetoothSmartStandbyDetails(
                mode: mode,
                minutes: try BluetoothWireCoercion.requiredInt(object["minutes"], key: "minutes"),
                enabled: try BluetoothWireCoercion.requiredBool(object["enabled"], key: "enabled"))
        }
    }

    /// `BluetoothCommandStatus.from_json(result)` (`_bluetooth.py:702-710`,
    /// `models/_bluetooth.py:59-65`): three required keys, each with the required-string rule.
    package static func commandStatus(_ text: String) throws -> BluetoothCommandStatus {
        let context = "command"
        let value = try parse(text, context: context)
        guard let object = value as? [String: Any] else {
            throw failure(context, "expected a JSON object, got \(describe(value))")
        }
        return try coerce(context) {
            BluetoothCommandStatus(
                id: try BluetoothWireCoercion.requiredString(object["id"], key: "id"),
                message: try BluetoothWireCoercion.requiredString(object["message"], key: "message"),
                status: try BluetoothWireCoercion.requiredString(object["status"], key: "status"))
        }
    }

    // MARK: - Helpers

    /// `machineModes`: an array of strings; each entry keeps `.other` for unknown values (D5b).
    private static func machineModes(_ value: Any?) throws -> [MachineMode] {
        guard let value else {
            throw BluetoothWireCoercion.Failure(detail: "missing machineModes")
        }
        guard let array = value as? [Any] else {
            throw BluetoothWireCoercion.Failure(detail: "machineModes is not an array: \(describe(value))")
        }
        return try array.enumerated().map { index, element in
            guard let raw = element as? String else {
                throw BluetoothWireCoercion.Failure(
                    detail: "machineModes[\(index)] is not a string: \(describe(element))")
            }
            return MachineMode(rawValue: raw)
        }
    }

    /// Parses the response text as JSON with fragments allowed.
    private static func parse(_ text: String, context: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        } catch {
            throw failure(context, "not valid JSON: \(text.debugDescription)")
        }
    }

    /// Runs `body`, mapping a coercion failure to `.decoding("bluetooth <context>: <prefix><detail>")`.
    private static func coerce<T>(_ context: String, prefix: String = "",
                                  _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as BluetoothWireCoercion.Failure {
            throw failure(context, prefix + error.detail)
        }
    }

    private static func failure(_ context: String, _ detail: String) -> LaMarzoccoError {
        .decoding("bluetooth \(context): \(detail)")
    }

    /// A short description of a JSON value's kind, for error details.
    private static func describe(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if BluetoothWireCoercion.isJSONBoolean(value) { return "a boolean" }
        if value is NSNumber { return "a number" }
        if let s = value as? String { return "the string \(s.debugDescription)" }
        if value is [Any] { return "an array" }
        if value is [String: Any] { return "an object" }
        return "an unsupported value"
    }
}
