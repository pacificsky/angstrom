import Foundation

// MARK: - Settings (GET /things/{serial}/settings)

/// A machine's settings: connectivity, plumb-in, firmware, and auto-update.
public struct MachineSettings: Sendable, Hashable, Codable {
    /// Device identity carried at the top of the settings payload.
    public let machine: Machine
    public let wifiSSID: String?
    public let wifiRSSI: Int?
    public let isPlumbedIn: Bool
    public let plumbInSupported: Bool
    public let autoUpdate: Bool
    public let autoUpdateSupported: Bool
    /// Cropster (roast-logging integration) capability/state.
    public let cropsterSupported: Bool
    public let cropsterActive: Bool
    /// Hemro (grinder integration) capability/state.
    public let hemroSupported: Bool
    public let hemroActive: Bool
    /// Whether the machine exposes a factory-reset action.
    public let factoryResetSupported: Bool
    public let firmware: [FirmwareInfo]

    public var machineFirmware: FirmwareInfo? { firmware.first { $0.type == .machine } }
    public var gatewayFirmware: FirmwareInfo? { firmware.first { $0.type == .gateway } }

    private enum CodingKeys: String, CodingKey {
        case wifiSsid, wifiRssi, isPlumbedIn, plumbInSupported, autoUpdate, autoUpdateSupported
        case cropsterSupported, cropsterActive, hemroSupported, hemroActive, factoryResetSupported
        case actualFirmwares
    }

    public init(from decoder: Decoder) throws {
        machine = try Machine(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wifiSSID = (try? c.decodeIfPresent(String.self, forKey: .wifiSsid)) ?? nil
        wifiRSSI = (try? c.decodeIfPresent(Int.self, forKey: .wifiRssi)) ?? nil
        isPlumbedIn = (try? c.decode(Bool.self, forKey: .isPlumbedIn)) ?? false
        plumbInSupported = (try? c.decode(Bool.self, forKey: .plumbInSupported)) ?? false
        autoUpdate = (try? c.decode(Bool.self, forKey: .autoUpdate)) ?? false
        autoUpdateSupported = (try? c.decode(Bool.self, forKey: .autoUpdateSupported)) ?? false
        cropsterSupported = (try? c.decode(Bool.self, forKey: .cropsterSupported)) ?? false
        cropsterActive = (try? c.decode(Bool.self, forKey: .cropsterActive)) ?? false
        hemroSupported = (try? c.decode(Bool.self, forKey: .hemroSupported)) ?? false
        hemroActive = (try? c.decode(Bool.self, forKey: .hemroActive)) ?? false
        factoryResetSupported = (try? c.decode(Bool.self, forKey: .factoryResetSupported)) ?? false
        // Decode firmware entries individually so one malformed entry doesn't
        // discard the rest (matching the per-widget resilience elsewhere).
        let firmwareEntries = (try? c.decode([Lenient<FirmwareInfo>].self, forKey: .actualFirmwares)) ?? []
        firmware = firmwareEntries.compactMap(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        try machine.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(wifiSSID, forKey: .wifiSsid)
        try c.encodeIfPresent(wifiRSSI, forKey: .wifiRssi)
        try c.encode(isPlumbedIn, forKey: .isPlumbedIn)
        try c.encode(plumbInSupported, forKey: .plumbInSupported)
        try c.encode(autoUpdate, forKey: .autoUpdate)
        try c.encode(autoUpdateSupported, forKey: .autoUpdateSupported)
        try c.encode(cropsterSupported, forKey: .cropsterSupported)
        try c.encode(cropsterActive, forKey: .cropsterActive)
        try c.encode(hemroSupported, forKey: .hemroSupported)
        try c.encode(hemroActive, forKey: .hemroActive)
        try c.encode(factoryResetSupported, forKey: .factoryResetSupported)
        try c.encode(firmware, forKey: .actualFirmwares)
    }
}

public struct FirmwareInfo: Sendable, Hashable, Codable {
    public let type: FirmwareType
    public let buildVersion: String
    public let changeLog: String?
    public let thingModelCode: String
    public let status: UpdateStatus
    public let availableUpdate: FirmwareVersion?
}

public struct FirmwareVersion: Sendable, Hashable, Codable {
    public let type: FirmwareType
    public let buildVersion: String
    public let changeLog: String?
    public let thingModelCode: String
}

// MARK: - Scheduling (GET /things/{serial}/scheduling)

/// A machine's scheduling configuration: smart standby, wake-up schedules, and
/// auto on/off times.
public struct MachineSchedule: Sendable, Hashable, Codable {
    /// Device identity carried at the top of the scheduling payload.
    public let machine: Machine
    public let smartWakeUpSleep: SmartWakeUpSleep
    public let smartWakeUpSleepSupported: Bool
    /// Top-level smart-standby block (often absent; the live standby state also
    /// lives in ``smartWakeUpSleep``).
    public let smartStandby: SmartStandby?
    public let smartStandbySupported: Bool
    public let autoStandBy: String?
    public let autoStandBySupported: Bool
    /// Auto on/off configuration. Most machines send a mode string
    /// (`"HH:MM"`/`"Off"`); the Strada X sends a settings object — mirroring
    /// pylamarzocco's `str | AutoOnOff | None` union.
    public let autoOnOff: AutoOnOff?
    public let autoOnOffSupported: Bool
    /// Eco-mode configuration (Strada X).
    public let ecoMode: EcoMode?
    public let ecoModeSupported: Bool

    /// The configured wake-up schedules.
    public var wakeUpSchedules: [WakeUpSchedule] { smartWakeUpSleep.schedules }

    private enum CodingKeys: String, CodingKey {
        case smartWakeUpSleep, smartWakeUpSleepSupported, smartStandBy, smartStandBySupported
        case autoStandBy, autoStandBySupported, autoOnOff, autoOnOffSupported
        case ecoMode, ecoModeSupported
    }

    public init(from decoder: Decoder) throws {
        machine = try Machine(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smartWakeUpSleep = (try? c.decode(SmartWakeUpSleep.self, forKey: .smartWakeUpSleep)) ?? SmartWakeUpSleep()
        // Defaults to `true` when the key is absent, matching pylamarzocco's
        // `ThingSchedulingSettings.smart_wake_up_sleep_supported` default — the
        // feature is assumed present unless the cloud explicitly says otherwise.
        smartWakeUpSleepSupported = (try? c.decode(Bool.self, forKey: .smartWakeUpSleepSupported)) ?? true
        smartStandby = (try? c.decodeIfPresent(SmartStandby.self, forKey: .smartStandBy)) ?? nil
        smartStandbySupported = (try? c.decode(Bool.self, forKey: .smartStandBySupported)) ?? false
        autoStandBy = (try? c.decodeIfPresent(String.self, forKey: .autoStandBy)) ?? nil
        autoStandBySupported = (try? c.decode(Bool.self, forKey: .autoStandBySupported)) ?? false
        autoOnOff = (try? c.decodeIfPresent(AutoOnOff.self, forKey: .autoOnOff)) ?? nil
        autoOnOffSupported = (try? c.decode(Bool.self, forKey: .autoOnOffSupported)) ?? false
        ecoMode = (try? c.decodeIfPresent(EcoMode.self, forKey: .ecoMode)) ?? nil
        ecoModeSupported = (try? c.decode(Bool.self, forKey: .ecoModeSupported)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        try machine.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(smartWakeUpSleep, forKey: .smartWakeUpSleep)
        try c.encode(smartWakeUpSleepSupported, forKey: .smartWakeUpSleepSupported)
        try c.encodeIfPresent(smartStandby, forKey: .smartStandBy)
        try c.encode(smartStandbySupported, forKey: .smartStandBySupported)
        try c.encodeIfPresent(autoStandBy, forKey: .autoStandBy)
        try c.encode(autoStandBySupported, forKey: .autoStandBySupported)
        try c.encodeIfPresent(autoOnOff, forKey: .autoOnOff)
        try c.encode(autoOnOffSupported, forKey: .autoOnOffSupported)
        try c.encodeIfPresent(ecoMode, forKey: .ecoMode)
        try c.encode(ecoModeSupported, forKey: .ecoModeSupported)
    }
}

/// Auto on/off, which the cloud sends in two shapes: a plain `"HH:MM"`/`"Off"`
/// mode string on most machines, or a full ``AutoOnOffSettings`` object on the
/// Strada X. Mirrors pylamarzocco's `str | AutoOnOff | None` union.
public enum AutoOnOff: Sendable, Hashable, Codable {
    case mode(String)
    case settings(AutoOnOffSettings)

    /// The mode string, when the machine sent the string form.
    public var modeString: String? {
        if case .mode(let value) = self { return value }
        return nil
    }

    /// The settings object, when the machine sent the object form (Strada X).
    public var settings: AutoOnOffSettings? {
        if case .settings(let value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let string = try? c.decode(String.self) {
            self = .mode(string)
        } else {
            self = .settings(try c.decode(AutoOnOffSettings.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .mode(let value): try c.encode(value)
        case .settings(let value): try c.encode(value)
        }
    }
}

/// Auto on/off settings, as sent by the Strada X.
public struct AutoOnOffSettings: Sendable, Hashable, Codable {
    public let enabled: Bool
    public let onTimeMinutes: Int
    public let offTimeMinutes: Int
    public let closeDay: String?
    public let ecoModeSupported: Bool
    public let ecoMode: EcoMode?

    private enum CodingKeys: String, CodingKey {
        case enabled, onTimeMinutes, offTimeMinutes, closeDay, ecoModeSupported, ecoMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        onTimeMinutes = (try? c.decode(Int.self, forKey: .onTimeMinutes)) ?? 0
        offTimeMinutes = (try? c.decode(Int.self, forKey: .offTimeMinutes)) ?? 0
        closeDay = (try? c.decodeIfPresent(String.self, forKey: .closeDay)) ?? nil
        ecoModeSupported = (try? c.decode(Bool.self, forKey: .ecoModeSupported)) ?? false
        ecoMode = (try? c.decodeIfPresent(EcoMode.self, forKey: .ecoMode)) ?? nil
    }
}

/// Eco-mode settings (Strada X).
public struct EcoMode: Sendable, Hashable, Codable {
    public let enabled: Bool
    public let offset: Int
    public let offsetMin: Int
    public let offsetMax: Int
    public let offsetStep: Int
    public let timeoutMinutes: Int
    public let timeoutMinutesMin: Int
    public let timeoutMinutesMax: Int
    public let timeoutMinutesStep: Int

    private enum CodingKeys: String, CodingKey {
        case enabled, offset, offsetMin, offsetMax, offsetStep
        case timeoutMinutes, timeoutMinutesMin, timeoutMinutesMax, timeoutMinutesStep
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        offset = (try? c.decode(Int.self, forKey: .offset)) ?? 0
        offsetMin = (try? c.decode(Int.self, forKey: .offsetMin)) ?? 0
        offsetMax = (try? c.decode(Int.self, forKey: .offsetMax)) ?? 0
        offsetStep = (try? c.decode(Int.self, forKey: .offsetStep)) ?? 0
        timeoutMinutes = (try? c.decode(Int.self, forKey: .timeoutMinutes)) ?? 0
        timeoutMinutesMin = (try? c.decode(Int.self, forKey: .timeoutMinutesMin)) ?? 0
        timeoutMinutesMax = (try? c.decode(Int.self, forKey: .timeoutMinutesMax)) ?? 0
        timeoutMinutesStep = (try? c.decode(Int.self, forKey: .timeoutMinutesStep)) ?? 0
    }
}

public struct SmartWakeUpSleep: Sendable, Hashable, Codable {
    public let smartStandbyEnabled: Bool
    public let smartStandbyMinutes: Int
    /// Allowed range/granularity for ``smartStandbyMinutes`` (UI sliders).
    public let smartStandbyMinutesMin: Int
    public let smartStandbyMinutesMax: Int
    public let smartStandbyMinutesStep: Int
    public let smartStandbyAfter: SmartStandbyAfter
    public let schedules: [WakeUpSchedule]

    private enum CodingKeys: String, CodingKey {
        case smartStandbyEnabled = "smartStandByEnabled"
        case smartStandbyMinutes = "smartStandByMinutes"
        case smartStandbyMinutesMin = "smartStandByMinutesMin"
        case smartStandbyMinutesMax = "smartStandByMinutesMax"
        case smartStandbyMinutesStep = "smartStandByMinutesStep"
        case smartStandbyAfter = "smartStandByAfter"
        case schedules
    }

    public init(
        smartStandbyEnabled: Bool = false,
        smartStandbyMinutes: Int = 0,
        smartStandbyMinutesMin: Int = 0,
        smartStandbyMinutesMax: Int = 0,
        smartStandbyMinutesStep: Int = 0,
        smartStandbyAfter: SmartStandbyAfter = .powerOn,
        schedules: [WakeUpSchedule] = []
    ) {
        self.smartStandbyEnabled = smartStandbyEnabled
        self.smartStandbyMinutes = smartStandbyMinutes
        self.smartStandbyMinutesMin = smartStandbyMinutesMin
        self.smartStandbyMinutesMax = smartStandbyMinutesMax
        self.smartStandbyMinutesStep = smartStandbyMinutesStep
        self.smartStandbyAfter = smartStandbyAfter
        self.schedules = schedules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smartStandbyEnabled = (try? c.decode(Bool.self, forKey: .smartStandbyEnabled)) ?? false
        smartStandbyMinutes = (try? c.decode(Int.self, forKey: .smartStandbyMinutes)) ?? 0
        smartStandbyMinutesMin = (try? c.decode(Int.self, forKey: .smartStandbyMinutesMin)) ?? 0
        smartStandbyMinutesMax = (try? c.decode(Int.self, forKey: .smartStandbyMinutesMax)) ?? 0
        smartStandbyMinutesStep = (try? c.decode(Int.self, forKey: .smartStandbyMinutesStep)) ?? 0
        smartStandbyAfter = (try? c.decode(SmartStandbyAfter.self, forKey: .smartStandbyAfter)) ?? .powerOn
        // Decode schedules individually so one malformed entry doesn't wipe the list.
        let entries = (try? c.decode([Lenient<WakeUpSchedule>].self, forKey: .schedules)) ?? []
        schedules = entries.compactMap(\.value)
    }
}

public struct SmartStandby: Sendable, Hashable, Codable {
    public let enabled: Bool
    public let minutes: Int
    /// Allowed range/granularity for ``minutes`` (UI sliders).
    public let minutesMin: Int
    public let minutesMax: Int
    public let minutesStep: Int
    public let after: SmartStandbyAfter

    private enum CodingKeys: String, CodingKey {
        case enabled, minutes, minutesMin, minutesMax, minutesStep, after
    }

    public init(enabled: Bool, minutes: Int, minutesMin: Int = 0, minutesMax: Int = 0, minutesStep: Int = 0, after: SmartStandbyAfter) {
        self.enabled = enabled
        self.minutes = minutes
        self.minutesMin = minutesMin
        self.minutesMax = minutesMax
        self.minutesStep = minutesStep
        self.after = after
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 0
        minutesMin = (try? c.decode(Int.self, forKey: .minutesMin)) ?? 0
        minutesMax = (try? c.decode(Int.self, forKey: .minutesMax)) ?? 0
        minutesStep = (try? c.decode(Int.self, forKey: .minutesStep)) ?? 0
        after = (try? c.decode(SmartStandbyAfter.self, forKey: .after)) ?? .powerOn
    }
}

/// A single wake-up schedule. `Codable` because it is also sent to the machine
/// (the `id` is omitted when creating a new schedule).
public struct WakeUpSchedule: Sendable, Hashable, Codable {
    public let id: String?
    public let enabled: Bool
    public let onTimeMinutes: Int
    public let offTimeMinutes: Int
    public let steamBoiler: Bool
    public let days: [Weekday]

    private enum CodingKeys: String, CodingKey {
        case id, enabled, onTimeMinutes, offTimeMinutes, steamBoiler, days
    }

    public init(
        id: String? = nil,
        enabled: Bool,
        onTimeMinutes: Int,
        offTimeMinutes: Int,
        steamBoiler: Bool,
        days: [Weekday]
    ) {
        self.id = id
        self.enabled = enabled
        self.onTimeMinutes = onTimeMinutes
        self.offTimeMinutes = offTimeMinutes
        self.steamBoiler = steamBoiler
        self.days = days
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        onTimeMinutes = try c.decode(Int.self, forKey: .onTimeMinutes)
        offTimeMinutes = try c.decode(Int.self, forKey: .offTimeMinutes)
        steamBoiler = try c.decode(Bool.self, forKey: .steamBoiler)
        days = (try? c.decode([Weekday].self, forKey: .days)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id) // omit `id` when creating a schedule
        try c.encode(enabled, forKey: .enabled)
        try c.encode(onTimeMinutes, forKey: .onTimeMinutes)
        try c.encode(offTimeMinutes, forKey: .offTimeMinutes)
        try c.encode(steamBoiler, forKey: .steamBoiler)
        try c.encode(days, forKey: .days)
    }
}
