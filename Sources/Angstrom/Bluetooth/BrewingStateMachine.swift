import Foundation

extension BluetoothBrewingData {
    /// MBT:125-163 (§4.11).
    ///
    /// Derives the brewing state of the (merged) data. The rules are tested in order and the first
    /// match wins: any `BrewingStoppedGroup1*` field or `ev == false` → `.brewingStopped`; any
    /// `FlushStoppedGroup1*` field → `.flushed`; `backflush == true` → `.backflushing`;
    /// `startedDoseIndex` or (`ev == true` and `brewingTime`) → `.brewing`; otherwise nil.
    public func deriveState(receivedAt: Date) -> BluetoothShotCounterUpdate? {
        let state: BluetoothBrewingState
        if brewingStoppedTime != nil
            || brewingStoppedDoseIndex != nil
            || brewingStoppedStopType != nil
            || brewingStoppedStopReason != nil
            || ev == false {
            state = .brewingStopped
        } else if flushStoppedTime != nil || flushStoppedDoseIndex != nil {
            state = .flushed
        } else if backflush == true {
            state = .backflushing
        } else if startedDoseIndex != nil || (ev == true && brewingTime != nil) {
            state = .brewing
        } else {
            return nil
        }

        // `(self.brewing_time or 0.0) if state is BREWING else None` (MBT:151-155).
        let timerValue: Double? = state == .brewing ? (brewingTime ?? 0.0) : nil
        // `__post_init__` (MBT:180-188): receivedAt − timerValue, only for `.brewing`.
        let brewingStartTime: Date? = timerValue.map { receivedAt.addingTimeInterval(-$0) }
        return BluetoothShotCounterUpdate(
            state: state,
            timerValue: timerValue,
            finalShotTime: brewingStoppedTime,
            startedDoseIndex: startedDoseIndex,
            stopReason: brewingStoppedStopReason,
            receivedAt: receivedAt,
            raw: self,
            brewingStartTime: brewingStartTime
        )
    }
}

/// `_BrewingTracker` (BT:77-111, §4.11).
package struct BrewingTracker: Sendable {
    /// The merged brewing data of the current shot (`D` in §4.11).
    private var data = BluetoothBrewingData()
    /// The earliest brewing start seen for the current shot (`S` in §4.11).
    private var start: Date?

    package init() {}

    /// `_BrewingTracker.process` (BT:90-111): merges `message` into the current shot's data and
    /// returns the derived update, if any.
    package mutating func process(_ message: BluetoothBrewingData, receivedAt: Date) -> BluetoothShotCounterUpdate? {
        if message.startedDoseIndex != nil {
            // a new shot or flush started
            reset()
        }
        data = data.merging(message)
        // No state: the data is kept, so fragments accumulate.
        guard var update = data.deriveState(receivedAt: receivedAt) else { return nil }
        if update.state == .flushed || update.state == .brewingStopped {
            reset()
        } else if let estimate = update.brewingStartTime {
            // notifications can only be delayed, so the earliest start is the best
            if start.map({ estimate < $0 }) ?? true {
                start = estimate
            }
            update.brewingStartTime = start
        }
        return update
    }

    /// `_reset` (BT:85-87).
    private mutating func reset() {
        data = BluetoothBrewingData()
        start = nil
    }
}

/// §3.8 framing + field rules. nil = drop the notification.
package enum ShotCounterNotificationDecoder {
    package static func decode(_ data: Data) -> DecodedShotCounterNotification? {
        // `bytes(data).strip(b"\x00")`: NULs at both ends only; an inner NUL stays and fails the parse.
        let bytes = [UInt8](data)
        guard let first = bytes.firstIndex(where: { $0 != 0 }),
              let last = bytes.lastIndex(where: { $0 != 0 }) else { return nil }
        let payload = Data(bytes[first...last])
        // `json.loads(...)`, then `from_dict` requires an object.
        guard let parsed = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]),
              let object = parsed as? [String: Any] else { return nil }
        // If either part fails to decode, the whole notification is dropped (BT:451-457).
        guard let brewing = try? brewingData(object),
              let telemetry = try? machineTelemetry(object) else { return nil }
        return DecodedShotCounterNotification(brewing: brewing, telemetry: telemetry)
    }

    // MARK: - Parts (§3.8 key tables, §3.10 rules)

    /// `BluetoothBrewingData.from_dict` (MBT:90-123).
    private static func brewingData(_ object: [String: Any]) throws -> BluetoothBrewingData {
        typealias C = BluetoothWireCoercion
        return BluetoothBrewingData(
            startedDoseIndex: C.optionalString(object["BrewingStartedGroup1DoseIndex"]),
            ev: C.optionalBool(object["BrewingUpdateGroup1Ev"]),
            backflush: C.optionalBool(object["BrewingUpdateGroup1Backflush"]),
            brewingTime: try C.optionalDouble(object["BrewingUpdateGroup1Time"], key: "BrewingUpdateGroup1Time"),
            flushStoppedTime: try C.optionalDouble(object["FlushStoppedGroup1Time"], key: "FlushStoppedGroup1Time"),
            flushStoppedDoseIndex: C.optionalString(object["FlushStoppedGroup1DoseIndex"]),
            brewingStoppedTime: try C.optionalDouble(object["BrewingStoppedGroup1Time"],
                                                     key: "BrewingStoppedGroup1Time"),
            brewingStoppedDoseIndex: C.optionalString(object["BrewingStoppedGroup1DoseIndex"]),
            brewingStoppedStopType: C.optionalString(object["BrewingStoppedGroup1StopType"]),
            brewingStoppedStopReason: C.optionalString(object["BrewingStoppedGroup1StopReason"])
        )
    }

    /// `BluetoothMachineTelemetry.from_dict` (MBT:191-213).
    private static func machineTelemetry(_ object: [String: Any]) throws -> BluetoothMachineTelemetry {
        typealias C = BluetoothWireCoercion
        return BluetoothMachineTelemetry(
            coffeeBoilerTemperature: try C.optionalDouble(object["CoffeeBoiler1UpdateTemperature"],
                                                          key: "CoffeeBoiler1UpdateTemperature"),
            steamBoilerTemperature: try C.optionalDouble(object["SteamBoilerUpdateTemperature"],
                                                         key: "SteamBoilerUpdateTemperature"),
            machineMode: knownMachineMode(object["MachineMode"]),
            sleep: C.optionalString(object["Sleep"]),
            machineStatistics: try machineStatistics(object["MachineStatistics"])
        )
    }

    /// `_known_machine_mode` (MBT:68-70): a string naming a known mode, else nil (never `.other`).
    private static func knownMachineMode(_ value: Any?) -> MachineMode? {
        guard let raw = value as? String else { return nil }
        switch MachineMode(rawValue: raw) {
        case .other: return nil
        case let mode: return mode
        }
    }

    private struct StatisticsFailure: Error {}

    /// `deserialize=json.loads` (MBT:209-213). Absent or JSON null → unset (mashumaro never calls
    /// `deserialize` for `None`). A JSON string → its parsed content, a parsed `null` → unset. Any
    /// other value, or a string that does not parse → throws (drop the notification).
    private static func machineStatistics(_ value: Any?) throws -> BluetoothJSONValue? {
        guard let value, !(value is NSNull) else { return nil }
        // A CFBoolean/NSNumber is never a String, so only a real JSON string gets here.
        guard let text = value as? String,
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        else { throw StatisticsFailure() }
        let json = try jsonValue(parsed)
        if case .null = json { return nil }
        return json
    }

    /// Converts a `JSONSerialization` value, honouring the CFBoolean hazard rule (§3.10).
    private static func jsonValue(_ value: Any) throws -> BluetoothJSONValue {
        if value is NSNull { return .null }
        if BluetoothWireCoercion.isJSONBoolean(value) {
            return .bool((value as? NSNumber)?.boolValue ?? false)
        }
        if let number = value as? NSNumber { return .number(number.doubleValue) }
        if let string = value as? String { return .string(string) }
        if let array = value as? [Any] { return .array(try array.map(jsonValue)) }
        if let object = value as? [String: Any] { return .object(try object.mapValues(jsonValue)) }
        throw StatisticsFailure()
    }
}
