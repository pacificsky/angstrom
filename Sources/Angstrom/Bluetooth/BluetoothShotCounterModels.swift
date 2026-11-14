import Foundation

/// Arbitrary JSON (used for `MachineStatistics`, whose meaning upstream marks unverified).
public enum BluetoothJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BluetoothJSONValue])
    case object([String: BluetoothJSONValue])

    /// The member named `key` when this is an object, else nil.
    public subscript(key: String) -> BluetoothJSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }
}

/// Brewing part of a notification; all fields optional (MBT:90-123).
public struct BluetoothBrewingData: Sendable, Hashable {
    /// `BrewingStartedGroup1DoseIndex`.
    public var startedDoseIndex: String?
    /// `BrewingUpdateGroup1Ev`.
    public var ev: Bool?
    /// `BrewingUpdateGroup1Backflush`.
    public var backflush: Bool?
    /// `BrewingUpdateGroup1Time` (seconds).
    public var brewingTime: Double?
    /// `FlushStoppedGroup1Time` (seconds).
    public var flushStoppedTime: Double?
    /// `FlushStoppedGroup1DoseIndex`.
    public var flushStoppedDoseIndex: String?
    /// `BrewingStoppedGroup1Time` (seconds).
    public var brewingStoppedTime: Double?
    /// `BrewingStoppedGroup1DoseIndex`.
    public var brewingStoppedDoseIndex: String?
    /// `BrewingStoppedGroup1StopType`.
    public var brewingStoppedStopType: String?
    /// `BrewingStoppedGroup1StopReason`.
    public var brewingStoppedStopReason: String?

    public init(startedDoseIndex: String? = nil, ev: Bool? = nil, backflush: Bool? = nil,
                brewingTime: Double? = nil, flushStoppedTime: Double? = nil,
                flushStoppedDoseIndex: String? = nil, brewingStoppedTime: Double? = nil,
                brewingStoppedDoseIndex: String? = nil, brewingStoppedStopType: String? = nil,
                brewingStoppedStopReason: String? = nil) {
        self.startedDoseIndex = startedDoseIndex
        self.ev = ev
        self.backflush = backflush
        self.brewingTime = brewingTime
        self.flushStoppedTime = flushStoppedTime
        self.flushStoppedDoseIndex = flushStoppedDoseIndex
        self.brewingStoppedTime = brewingStoppedTime
        self.brewingStoppedDoseIndex = brewingStoppedDoseIndex
        self.brewingStoppedStopType = brewingStoppedStopType
        self.brewingStoppedStopReason = brewingStoppedStopReason
    }

    /// Every field is nil (`_PartialNotification.is_empty`, MBT:79-82).
    public var isEmpty: Bool {
        startedDoseIndex == nil && ev == nil && backflush == nil && brewingTime == nil
            && flushStoppedTime == nil && flushStoppedDoseIndex == nil && brewingStoppedTime == nil
            && brewingStoppedDoseIndex == nil && brewingStoppedStopType == nil
            && brewingStoppedStopReason == nil
    }

    /// Copy of self overridden by every non-nil field of `other` (MBT:85-87).
    ///
    /// `false`, `0` and `""` count as set; a merge never clears a field (§4.11).
    public func merging(_ other: BluetoothBrewingData) -> BluetoothBrewingData {
        BluetoothBrewingData(
            startedDoseIndex: other.startedDoseIndex ?? startedDoseIndex,
            ev: other.ev ?? ev,
            backflush: other.backflush ?? backflush,
            brewingTime: other.brewingTime ?? brewingTime,
            flushStoppedTime: other.flushStoppedTime ?? flushStoppedTime,
            flushStoppedDoseIndex: other.flushStoppedDoseIndex ?? flushStoppedDoseIndex,
            brewingStoppedTime: other.brewingStoppedTime ?? brewingStoppedTime,
            brewingStoppedDoseIndex: other.brewingStoppedDoseIndex ?? brewingStoppedDoseIndex,
            brewingStoppedStopType: other.brewingStoppedStopType ?? brewingStoppedStopType,
            brewingStoppedStopReason: other.brewingStoppedStopReason ?? brewingStoppedStopReason
        )
    }
    // `deriveState(receivedAt:)` is declared in BrewingStateMachine.swift.
}

/// A brewing state update (MBT:166-188).
public struct BluetoothShotCounterUpdate: Sendable, Hashable {
    public let state: BluetoothBrewingState
    /// Seconds into the running shot; non-nil only for `.brewing`.
    public let timerValue: Double?
    /// `BrewingStoppedGroup1Time` of the merged data, in any state.
    public let finalShotTime: Double?
    public let startedDoseIndex: String?
    public let stopReason: String?
    public let receivedAt: Date
    /// The merged data the state was derived from.
    public let raw: BluetoothBrewingData
    /// Earliest estimate of the running shot's start; non-nil only for `.brewing`.
    public var brewingStartTime: Date?

    /// When `brewingStartTime` is nil, `state == .brewing` and `timerValue` is non-nil, it
    /// defaults to `receivedAt - timerValue`.
    public init(state: BluetoothBrewingState, timerValue: Double? = nil, finalShotTime: Double? = nil,
                startedDoseIndex: String? = nil, stopReason: String? = nil, receivedAt: Date,
                raw: BluetoothBrewingData, brewingStartTime: Date? = nil) {
        self.state = state
        self.timerValue = timerValue
        self.finalShotTime = finalShotTime
        self.startedDoseIndex = startedDoseIndex
        self.stopReason = stopReason
        self.receivedAt = receivedAt
        self.raw = raw
        // `__post_init__` (MBT:180-188).
        if brewingStartTime == nil, state == .brewing, let timerValue {
            self.brewingStartTime = receivedAt.addingTimeInterval(-timerValue)
        } else {
            self.brewingStartTime = brewingStartTime
        }
    }
}

/// Live machine values carried by shot-counter notifications (MBT:191-213).
public struct BluetoothMachineTelemetry: Sendable, Hashable {
    /// `CoffeeBoiler1UpdateTemperature` (°C).
    public var coffeeBoilerTemperature: Double?
    /// `SteamBoilerUpdateTemperature` (°C).
    public var steamBoilerTemperature: Double?
    /// Never `.other`: unknown modes decode as nil.
    public var machineMode: MachineMode?
    /// `Sleep`.
    public var sleep: String?
    /// `MachineStatistics`, parsed from its JSON-encoded string.
    public var machineStatistics: BluetoothJSONValue?

    public init(coffeeBoilerTemperature: Double? = nil, steamBoilerTemperature: Double? = nil,
                machineMode: MachineMode? = nil, sleep: String? = nil,
                machineStatistics: BluetoothJSONValue? = nil) {
        self.coffeeBoilerTemperature = coffeeBoilerTemperature
        self.steamBoilerTemperature = steamBoilerTemperature
        self.machineMode = machineMode
        self.sleep = sleep
        self.machineStatistics = machineStatistics
    }

    /// Every field is nil (`_PartialNotification.is_empty`, MBT:79-82).
    public var isEmpty: Bool {
        coffeeBoilerTemperature == nil && steamBoilerTemperature == nil && machineMode == nil
            && sleep == nil && machineStatistics == nil
    }

    /// Copy of self overridden by every non-nil field of `other` (MBT:85-87). Never clears a field.
    public func merging(_ other: BluetoothMachineTelemetry) -> BluetoothMachineTelemetry {
        BluetoothMachineTelemetry(
            coffeeBoilerTemperature: other.coffeeBoilerTemperature ?? coffeeBoilerTemperature,
            steamBoilerTemperature: other.steamBoilerTemperature ?? steamBoilerTemperature,
            machineMode: other.machineMode ?? machineMode,
            sleep: other.sleep ?? sleep,
            machineStatistics: other.machineStatistics ?? machineStatistics
        )
    }
}

/// What the client's shot-counter stream delivers.
public enum ShotCounterEvent: Sendable, Equatable {   // not Hashable: LaMarzoccoError is only Equatable
    /// Subscribed (upstream `connection_callback(True)`).
    case subscribed
    /// Subscription lost or stopped (upstream `connection_callback(False)`).
    case unsubscribed
    case brewing(BluetoothShotCounterUpdate)
    /// Only the values present in that notification.
    case telemetry(BluetoothMachineTelemetry)
    /// Angstrom-only: the reconnect loop gave up (3 auth failures, or the characteristic vanished).
    case gaveUp(LaMarzoccoError)
}

/// Parsed notification (§3.8).
package struct DecodedShotCounterNotification: Sendable, Hashable {
    package let brewing: BluetoothBrewingData
    package let telemetry: BluetoothMachineTelemetry
    package init(brewing: BluetoothBrewingData, telemetry: BluetoothMachineTelemetry) {
        self.brewing = brewing
        self.telemetry = telemetry
    }
}
