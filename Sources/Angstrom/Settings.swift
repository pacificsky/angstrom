import Foundation

// MARK: - Settings (GET /things/{serial}/settings)

/// A machine's settings: connectivity, plumb-in, firmware, and auto-update.
public struct MachineSettings: Sendable, Hashable, Decodable {
    /// Device identity carried at the top of the settings payload.
    public let machine: Machine
    public let wifiSSID: String?
    public let wifiRSSI: Int?
    public let isPlumbedIn: Bool
    public let plumbInSupported: Bool
    public let autoUpdate: Bool
    public let autoUpdateSupported: Bool
    public let firmware: [FirmwareInfo]

    public var machineFirmware: FirmwareInfo? { firmware.first { $0.type == .machine } }
    public var gatewayFirmware: FirmwareInfo? { firmware.first { $0.type == .gateway } }

    private enum CodingKeys: String, CodingKey {
        case wifiSsid, wifiRssi, isPlumbedIn, plumbInSupported, autoUpdate, autoUpdateSupported, actualFirmwares
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
        // Decode firmware entries individually so one malformed entry doesn't
        // discard the rest (matching the per-widget resilience elsewhere).
        let firmwareEntries = (try? c.decode([Lenient<FirmwareInfo>].self, forKey: .actualFirmwares)) ?? []
        firmware = firmwareEntries.compactMap(\.value)
    }
}

public struct FirmwareInfo: Sendable, Hashable, Decodable {
    public let type: FirmwareType
    public let buildVersion: String
    public let changeLog: String?
    public let thingModelCode: String
    public let status: UpdateStatus
    public let availableUpdate: FirmwareVersion?
}

public struct FirmwareVersion: Sendable, Hashable, Decodable {
    public let type: FirmwareType
    public let buildVersion: String
    public let changeLog: String?
    public let thingModelCode: String
}

// MARK: - Scheduling (GET /things/{serial}/scheduling)

/// A machine's scheduling configuration: smart standby, wake-up schedules, and
/// auto on/off times.
public struct MachineSchedule: Sendable, Hashable, Decodable {
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
    public let autoOnOff: String?
    public let autoOnOffSupported: Bool

    /// The configured wake-up schedules.
    public var wakeUpSchedules: [WakeUpSchedule] { smartWakeUpSleep.schedules }

    private enum CodingKeys: String, CodingKey {
        case smartWakeUpSleep, smartWakeUpSleepSupported, smartStandBy, smartStandBySupported
        case autoStandBy, autoStandBySupported, autoOnOff, autoOnOffSupported
    }

    public init(from decoder: Decoder) throws {
        machine = try Machine(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smartWakeUpSleep = (try? c.decode(SmartWakeUpSleep.self, forKey: .smartWakeUpSleep)) ?? SmartWakeUpSleep()
        smartWakeUpSleepSupported = (try? c.decode(Bool.self, forKey: .smartWakeUpSleepSupported)) ?? false
        smartStandby = (try? c.decodeIfPresent(SmartStandby.self, forKey: .smartStandBy)) ?? nil
        smartStandbySupported = (try? c.decode(Bool.self, forKey: .smartStandBySupported)) ?? false
        autoStandBy = (try? c.decodeIfPresent(String.self, forKey: .autoStandBy)) ?? nil
        autoStandBySupported = (try? c.decode(Bool.self, forKey: .autoStandBySupported)) ?? false
        autoOnOff = (try? c.decodeIfPresent(String.self, forKey: .autoOnOff)) ?? nil
        autoOnOffSupported = (try? c.decode(Bool.self, forKey: .autoOnOffSupported)) ?? false
    }
}

public struct SmartWakeUpSleep: Sendable, Hashable, Decodable {
    public let smartStandbyEnabled: Bool
    public let smartStandbyMinutes: Int
    public let smartStandbyAfter: SmartStandbyAfter
    public let schedules: [WakeUpSchedule]

    private enum CodingKeys: String, CodingKey {
        case smartStandbyEnabled = "smartStandByEnabled"
        case smartStandbyMinutes = "smartStandByMinutes"
        case smartStandbyAfter = "smartStandByAfter"
        case schedules
    }

    public init(
        smartStandbyEnabled: Bool = false,
        smartStandbyMinutes: Int = 0,
        smartStandbyAfter: SmartStandbyAfter = .powerOn,
        schedules: [WakeUpSchedule] = []
    ) {
        self.smartStandbyEnabled = smartStandbyEnabled
        self.smartStandbyMinutes = smartStandbyMinutes
        self.smartStandbyAfter = smartStandbyAfter
        self.schedules = schedules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smartStandbyEnabled = (try? c.decode(Bool.self, forKey: .smartStandbyEnabled)) ?? false
        smartStandbyMinutes = (try? c.decode(Int.self, forKey: .smartStandbyMinutes)) ?? 0
        smartStandbyAfter = (try? c.decode(SmartStandbyAfter.self, forKey: .smartStandbyAfter)) ?? .powerOn
        // Decode schedules individually so one malformed entry doesn't wipe the list.
        let entries = (try? c.decode([Lenient<WakeUpSchedule>].self, forKey: .schedules)) ?? []
        schedules = entries.compactMap(\.value)
    }
}

public struct SmartStandby: Sendable, Hashable, Decodable {
    public let enabled: Bool
    public let minutes: Int
    public let after: SmartStandbyAfter

    private enum CodingKeys: String, CodingKey { case enabled, minutes, after }

    public init(enabled: Bool, minutes: Int, after: SmartStandbyAfter) {
        self.enabled = enabled
        self.minutes = minutes
        self.after = after
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 0
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
