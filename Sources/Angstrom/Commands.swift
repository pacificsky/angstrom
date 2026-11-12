import Foundation

// MARK: - Command response

/// The acknowledgement the cloud returns for a command. The final result for a
/// command is delivered later over the websocket (see M3).
public struct CommandResponse: Sendable, Hashable, Codable {
    public let id: String
    public let status: CommandStatus
    public let errorCode: String?
}

/// The status of a dispatched command.
public enum CommandStatus: Sendable, Hashable, Codable {
    case success
    case error
    /// The machine rejected the command (pylamarzocco v2.5.5).
    case failed
    case timeout
    case pending
    case inProgress
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "Success": self = .success
        case "Error": self = .error
        case "Failed": self = .failed
        case "Timeout": self = .timeout
        case "Pending": self = .pending
        case "InProgress": self = .inProgress
        default: self = .other(rawValue)
        }
    }
    public var rawValue: String {
        switch self {
        case .success: "Success"
        case .error: "Error"
        case .failed: "Failed"
        case .timeout: "Timeout"
        case .pending: "Pending"
        case .inProgress: "InProgress"
        case .other(let v): v
        }
    }
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

// MARK: - Firmware update

/// Firmware update status (`GET`/`POST /things/{serial}/update-fw`).
public struct UpdateDetails: Sendable, Hashable, Decodable {
    public let status: UpdateStatus
    public let commandStatus: UpdateStatus?
    public let progressInfo: UpdateProgressInfo?
    public let progressPercentage: Int?
}

/// Firmware update progress phase.
public enum UpdateProgressInfo: Sendable, Hashable, Codable {
    case download
    case rebooting
    case startingProcess
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "download": self = .download
        case "rebooting": self = .rebooting
        case "starting process": self = .startingProcess
        default: self = .other(rawValue)
        }
    }
    public var rawValue: String {
        switch self {
        case .download: "download"
        case .rebooting: "rebooting"
        case .startingProcess: "starting process"
        case .other(let v): v
        }
    }
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

// MARK: - Command bodies (internal)

private struct ModeBody: Encodable, Sendable { let mode: String }
private struct EnabledBody: Encodable, Sendable { let enabled: Bool }
private struct ScheduleBody: Encodable, Sendable { let schedule: String }
private struct IdBody: Encodable, Sendable { let id: String }
private struct BoilerEnabledBody: Encodable, Sendable { let boilerIndex: Int; let enabled: Bool }
private struct BoilerLevelBody: Encodable, Sendable { let boilerIndex: Int; let targetLevel: SteamLevel }
private struct BoilerTemperatureBody: Encodable, Sendable { let boilerIndex: Int; let targetTemperature: Double }
private struct SmartStandbyBody: Encodable, Sendable { let enabled: Bool; let minutes: Int; let after: String }
private struct GroupModeBody: Encodable, Sendable { let groupIndex: Int; let mode: String }
private struct RinseFlushTimeBody: Encodable, Sendable { let timeSeconds: Double }
private struct HotWaterDoseBody: Encodable, Sendable { let doseIndex: String; let dose: Double }
private struct GroupDoseBody: Encodable, Sendable { let groupIndex: Int; let mode: String; let doseIndex: String; let dose: Double }
private struct BrewingPressureBody: Encodable, Sendable { let groupIndex: Int; let pressure: Double }
private struct ContinuousDoseEnabledBody: Encodable, Sendable { let groupIndex: Int; let rinseEnabled: Bool }
private struct ContinuousDoseBody: Encodable, Sendable { let groupIndex: Int; let rinseSeconds: Double }
private struct MirrorGroupBody: Encodable, Sendable { let groupIndex: Int; let enabled: Bool }
private struct GrinderDoseBody: Encodable, Sendable { let mode: String; let doseIndex: String; let dose: Double }
private struct GrinderMoreDoseBody: Encodable, Sendable { let revolutions: Double }
private struct GrinderSpeedBody: Encodable, Sendable { let doseIndex: String; let speedLevel: String }
private struct GrinderAutoSpeedEnabledBody: Encodable, Sendable { let doseIndex: String; let groupIndex: Int; let enabled: Bool }
private struct GrinderAutoStandbyBody: Encodable, Sendable { let standByMinutes: Int }
/// Encodes nil fields as explicit `null`s, matching pylamarzocco's payload.
private struct GrinderAutoSpeedReferenceBody: Encodable, Sendable {
    let doseMode: String
    let extractionSeconds: Double?
    let doseMass: Double?
    let dosePulses: Double?
    let rateLock: Bool

    private enum CodingKeys: String, CodingKey { case doseMode, extractionSeconds, doseMass, dosePulses, rateLock }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(doseMode, forKey: .doseMode)
        for (value, key) in [(extractionSeconds, CodingKeys.extractionSeconds), (doseMass, .doseMass), (dosePulses, .dosePulses)] {
            if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
        }
        try c.encode(rateLock, forKey: .rateLock)
    }
}

private struct PreExtractionTimesBody: Encodable, Sendable {
    struct Seconds: Encodable, Sendable {
        let inSeconds: Double
        let outSeconds: Double
        private enum CodingKeys: String, CodingKey { case inSeconds = "In", outSeconds = "Out" }
    }
    let times: Seconds
    let groupIndex: Int
    let doseIndex: String
}

private struct BrewByWeightDosesBody: Encodable, Sendable {
    struct Doses: Encodable, Sendable {
        let dose1: Double
        let dose2: Double
        private enum CodingKeys: String, CodingKey { case dose1 = "Dose1", dose2 = "Dose2" }
    }
    let doses: Doses
}

/// Round to one decimal place using round-half-to-even, matching Python's
/// `round(x, 1)` (the rounding pylamarzocco applies before sending).
private func round1(_ value: Double) -> Double { (value * 10).rounded(.toNearestOrEven) / 10 }

// MARK: - Commands

extension LaMarzoccoCloudClient {

    /// Set the machine's operating mode directly (the Strada X also accepts
    /// `EcoMode`). Most callers want ``setPower(serial:on:)``.
    @discardableResult
    public func setMode(serial: String, _ mode: MachineMode) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineChangeMode",
                                 body: ModeBody(mode: mode.rawValue))
    }

    /// Turn the machine on (`BrewingMode`) or off (`StandBy`).
    @discardableResult
    public func setPower(serial: String, on: Bool) async throws -> CommandResponse {
        try await setMode(serial: serial, on ? .brewing : .standby)
    }

    /// Turn the steam boiler on or off.
    @discardableResult
    public func setSteam(serial: String, on: Bool, boilerIndex: Int = 1) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingSteamBoilerEnabled",
                                 body: BoilerEnabledBody(boilerIndex: boilerIndex, enabled: on))
    }

    /// Set the steam boiler target level (Linea Micra / Mini R).
    @discardableResult
    public func setSteamTargetLevel(serial: String, _ level: SteamLevel, boilerIndex: Int = 1) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingSteamBoilerTargetLevel",
                                 body: BoilerLevelBody(boilerIndex: boilerIndex, targetLevel: level))
    }

    /// Set the coffee boiler target temperature (°C).
    @discardableResult
    public func setCoffeeTargetTemperature(serial: String, celsius: Double, boilerIndex: Int = 1) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingCoffeeBoilerTargetTemperature",
                                 body: BoilerTemperatureBody(boilerIndex: boilerIndex, targetTemperature: round1(celsius)))
    }

    /// Set the steam boiler target temperature (°C) (GS3 family).
    @discardableResult
    public func setSteamTargetTemperature(serial: String, celsius: Double, boilerIndex: Int = 1) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingSteamBoilerTargetTemperature",
                                 body: BoilerTemperatureBody(boilerIndex: boilerIndex, targetTemperature: round1(celsius)))
    }

    /// Start a backflush cleaning cycle.
    @discardableResult
    public func startBackflush(serial: String) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineBackFlushStartCleaning",
                                 body: EnabledBody(enabled: true))
    }

    /// Change the pre-extraction mode (pre-infusion / pre-brewing / disabled).
    @discardableResult
    public func setPreExtractionMode(serial: String, _ mode: PreExtractionMode) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachinePreBrewingChangeMode",
                                 body: ModeBody(mode: mode.rawValue))
    }

    /// Set the pre-extraction in/out times (seconds).
    @discardableResult
    public func setPreExtractionTimes(
        serial: String, secondsIn: Double, secondsOut: Double,
        groupIndex: Int = 1, doseIndex: PreExtractionDoseIndex = .byGroup
    ) async throws -> CommandResponse {
        let body = PreExtractionTimesBody(
            times: .init(inSeconds: round1(secondsIn), outSeconds: round1(secondsOut)),
            groupIndex: groupIndex, doseIndex: doseIndex.rawValue)
        return try await executeCommand(serial: serial, "CoffeeMachinePreBrewingSettingTimes", body: body)
    }

    /// Configure smart standby.
    @discardableResult
    public func setSmartStandby(serial: String, enabled: Bool, minutes: Int, after: SmartStandbyAfter) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingSmartStandBy",
                                 body: SmartStandbyBody(enabled: enabled, minutes: minutes, after: after.rawValue))
    }

    /// Set the auto-standby mode string (from ``MachineSchedule/autoStandBy``).
    @discardableResult
    public func setAutoStandby(serial: String, mode: String) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingAutoStandBy",
                                 body: ModeBody(mode: mode))
    }

    /// Set the auto on/off schedule string (from ``MachineSchedule/autoOnOff``).
    @discardableResult
    public func setAutoOnOff(serial: String, schedule: String) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingAutoOnOff",
                                 body: ScheduleBody(schedule: schedule))
    }

    /// Create or update a wake-up schedule. Omit ``WakeUpSchedule/id`` to create.
    @discardableResult
    public func setWakeUpSchedule(serial: String, _ schedule: WakeUpSchedule) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingWakeUpSchedule", body: schedule)
    }

    /// Delete a wake-up schedule by id.
    @discardableResult
    public func deleteWakeUpSchedule(serial: String, id: String) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineDeleteWakeUpSchedule", body: IdBody(id: id))
    }

    /// Change the brew-by-weight dose mode (Linea Mini / Mini R).
    @discardableResult
    public func setBrewByWeightMode(serial: String, _ mode: DoseMode) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineBrewByWeightChangeMode",
                                 body: ModeBody(mode: mode.rawValue))
    }

    /// Set the two brew-by-weight doses (grams) (Linea Mini / Mini R).
    @discardableResult
    public func setBrewByWeightDoses(serial: String, dose1: Double, dose2: Double) async throws -> CommandResponse {
        let body = BrewByWeightDosesBody(doses: .init(dose1: round1(dose1), dose2: round1(dose2)))
        return try await executeCommand(serial: serial, "CoffeeMachineBrewByWeightSettingDoses", body: body)
    }

    // MARK: Strada X

    /// Enable or disable automatic group flushing (Strada X).
    @discardableResult
    public func setAutoFlush(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingAutoFlushEnabled",
                                 body: EnabledBody(enabled: on))
    }

    /// Enable or disable automatic steam-wand flushing (Strada X).
    @discardableResult
    public func setSteamFlush(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingSteamFlushEnabled",
                                 body: EnabledBody(enabled: on))
    }

    /// Enable or disable automatic rinse flushing (Strada X).
    @discardableResult
    public func setRinseFlush(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingRinseFlushEnabled",
                                 body: EnabledBody(enabled: on))
    }

    /// Set the duration of the automatic rinse flush (Strada X).
    @discardableResult
    public func setRinseFlushTime(serial: String, seconds: Double) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingRinseFlushTime",
                                 body: RinseFlushTimeBody(timeSeconds: round1(seconds)))
    }

    /// Enable or disable the hot water dose (Strada X).
    @discardableResult
    public func setHotWaterDoseEnabled(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingHotWaterDoseEnabled",
                                 body: EnabledBody(enabled: on))
    }

    /// Set a hot water dose value (Strada X / GS3 AV).
    @discardableResult
    public func setHotWaterDose(serial: String, dose: Double, doseIndex: DoseIndex) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingHotWaterDose",
                                 body: HotWaterDoseBody(doseIndex: doseIndex.rawValue, dose: round1(dose)))
    }

    /// Enable or disable the cup warmer.
    @discardableResult
    public func setCupWarmer(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingCupWarmerEnabled",
                                 body: EnabledBody(enabled: on))
    }

    /// Enable or disable plumb-in mode.
    @discardableResult
    public func setPlumbIn(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingPlumbIn",
                                 body: EnabledBody(enabled: on))
    }

    /// Set the operating mode of a single group (Strada X).
    @discardableResult
    public func setGroupMode(serial: String, _ mode: MachineMode, groupIndex: Int = 1) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineGroupChangeMode",
                                 body: GroupModeBody(groupIndex: groupIndex, mode: mode.rawValue))
    }

    /// Enable or disable the coffee boiler (Strada X).
    @discardableResult
    public func setCoffeeBoilerEnabled(serial: String, on: Bool, boilerIndex: Int = 1) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineSettingCoffeeBoilerEnabled",
                                 body: BoilerEnabledBody(boilerIndex: boilerIndex, enabled: on))
    }

    /// Set the dose mode of a group (Strada X / GS3 AV).
    @discardableResult
    public func setGroupDoseMode(serial: String, _ mode: DoseMode, groupIndex: Int = 1) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineGroupDoseChangeMode",
                                 body: GroupModeBody(groupIndex: groupIndex, mode: mode.rawValue))
    }

    /// Set a group dose value for a given mode and dose index (Strada X / GS3 AV).
    @discardableResult
    public func setGroupDose(
        serial: String, mode: DoseMode, doseIndex: DoseIndex, dose: Double, groupIndex: Int = 1
    ) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineGroupDoseSettingDose",
                                 body: GroupDoseBody(groupIndex: groupIndex, mode: mode.rawValue,
                                                     doseIndex: doseIndex.rawValue, dose: round1(dose)))
    }

    /// Set the brewing pressure of a group (Strada X).
    @discardableResult
    public func setBrewingPressure(serial: String, pressure: Double, groupIndex: Int = 1) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineGroupDoseSettingGroupBrewingPressure",
                                 body: BrewingPressureBody(groupIndex: groupIndex, pressure: round1(pressure)))
    }

    /// Enable or disable the continuous (rinse) dose of a group (Strada X / GS3 AV).
    @discardableResult
    public func setContinuousDoseEnabled(serial: String, on: Bool, groupIndex: Int = 1) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineGroupDoseSettingContinuousDoseEnabled",
                                 body: ContinuousDoseEnabledBody(groupIndex: groupIndex, rinseEnabled: on))
    }

    /// Set the continuous (rinse) dose duration of a group (Strada X / GS3 AV).
    @discardableResult
    public func setContinuousDose(serial: String, seconds: Double, groupIndex: Int = 1) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineGroupDoseSettingContinuousDose",
                                 body: ContinuousDoseBody(groupIndex: groupIndex, rinseSeconds: round1(seconds)))
    }

    /// Make a group mirror group 1's doses (Strada X). `groupIndex` defaults to
    /// 2, since group 1 cannot mirror itself.
    @discardableResult
    public func setMirrorGroup1(serial: String, on: Bool, groupIndex: Int = 2) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineGroupDoseSettingMirrorGroup1",
                                 body: MirrorGroupBody(groupIndex: groupIndex, enabled: on))
    }

    // MARK: Grinder

    /// Set the grinder mode: `GrindingMode` wakes it, `StandBy` puts it to sleep.
    @discardableResult
    public func setGrinderMode(serial: String, _ mode: GrinderMode) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderChangeMode",
                                 body: ModeBody(mode: mode.rawValue))
    }

    /// Enable or disable a grinder's barista light (ignored while in standby).
    @discardableResult
    public func setGrinderBaristaLight(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingBaristaLightEnabled",
                                 body: EnabledBody(enabled: on))
    }

    /// Deprecated: the cloud takes no index for grinder settings
    /// (pylamarzocco v2.5.4 dropped it from every grinder payload).
    @available(*, deprecated, message: "Grinder commands take no index; use setGrinderBaristaLight(serial:on:)")
    @discardableResult
    public func setGrinderBaristaLight(serial: String, on: Bool, index: Int) async throws -> CommandResponse {
        try await setGrinderBaristaLight(serial: serial, on: on)
    }

    /// Set the grind-with mode (Swan).
    @discardableResult
    public func setGrinderGrindWith(serial: String, _ mode: GrinderGrindWithMode) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingGrindWithMode",
                                 body: ModeBody(mode: mode.rawValue))
    }

    /// Set a grinder dose. The speed level is a separate command:
    /// ``setGrinderSpeed(serial:doseIndex:speedLevel:)``.
    @discardableResult
    public func setGrinderDose(
        serial: String, doseIndex: DoseIndex, dose: Double, mode: GrinderDoseMode
    ) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingDose",
                                 body: GrinderDoseBody(mode: mode.rawValue, doseIndex: doseIndex.rawValue, dose: dose))
    }

    /// Deprecated: the speed level now has its own command, as in the official
    /// app (pylamarzocco v2.5.4). With a `speedLevel` this sends
    /// ``setGrinderSpeed(serial:doseIndex:speedLevel:)`` first, then the dose,
    /// and returns the dose command's response.
    @available(*, deprecated, message: "Use setGrinderSpeed(serial:doseIndex:speedLevel:) and setGrinderDose(serial:doseIndex:dose:mode:)")
    @discardableResult
    public func setGrinderDose(
        serial: String, doseIndex: DoseIndex, dose: Double,
        mode: GrinderDoseMode, speedLevel: GrinderSpeedLevel?
    ) async throws -> CommandResponse {
        if let speedLevel {
            try await setGrinderSpeed(serial: serial, doseIndex: doseIndex, speedLevel: speedLevel)
        }
        return try await setGrinderDose(serial: serial, doseIndex: doseIndex, dose: dose, mode: mode)
    }

    /// Set the additional "more dose" revolutions of a grinder (Swan).
    @discardableResult
    public func setGrinderMoreDose(serial: String, revolutions: Double) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingMoreDose",
                                 body: GrinderMoreDoseBody(revolutions: revolutions))
    }

    /// Enable or disable a grinder's single-dose mode.
    @discardableResult
    public func setGrinderSingleDoseMode(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingSingleDoseModeEnabled",
                                 body: EnabledBody(enabled: on))
    }

    /// Enable or disable mirroring a grinder's doses.
    @discardableResult
    public func setGrinderMirrorDoses(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingMirrorDosesEnabled",
                                 body: EnabledBody(enabled: on))
    }

    /// Set the motor speed level of a grinder dose (Swan).
    @discardableResult
    public func setGrinderSpeed(
        serial: String, doseIndex: DoseIndex, speedLevel: GrinderSpeedLevel
    ) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingSpeedForDose",
                                 body: GrinderSpeedBody(doseIndex: doseIndex.rawValue, speedLevel: speedLevel.rawValue))
    }

    /// Enable or disable automatic speed for a grinder dose (Swan). The
    /// automatic speed follows the extraction of `groupIndex` on the coffee
    /// machine in the same coffee station.
    @discardableResult
    public func setGrinderAutoSpeedEnabled(
        serial: String, doseIndex: DoseIndex, enabled: Bool, groupIndex: Int = 1
    ) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingAutoSpeedDoseEnabled",
                                 body: GrinderAutoSpeedEnabledBody(doseIndex: doseIndex.rawValue,
                                                                   groupIndex: groupIndex, enabled: enabled))
    }

    /// Set the reference extraction the automatic grinder speed adapts to
    /// (Swan). `doseMode` is `.mass` (with `doseMass` in grams) or `.pulses`
    /// (with `dosePulses`). `rateLock` keeps the reference flow rate. Nil
    /// values are sent as explicit JSON `null`s, as upstream does.
    @discardableResult
    public func setGrinderAutoSpeedReference(
        serial: String, doseMode: DoseMode, extractionSeconds: Double? = nil,
        doseMass: Double? = nil, dosePulses: Double? = nil, rateLock: Bool = false
    ) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingAutoSpeedDose",
                                 body: GrinderAutoSpeedReferenceBody(
                                     doseMode: doseMode.rawValue, extractionSeconds: extractionSeconds,
                                     doseMass: doseMass, dosePulses: dosePulses, rateLock: rateLock))
    }

    /// Set the minutes of inactivity after which a grinder goes to standby.
    @discardableResult
    public func setGrinderAutoStandby(serial: String, minutes: Int) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingAutoStandBy",
                                 body: GrinderAutoStandbyBody(standByMinutes: minutes))
    }

    // MARK: Firmware

    /// Read firmware update status/progress (`GET /things/{serial}/update-fw`).
    public func firmwareUpdateStatus(serial: String) async throws -> UpdateDetails {
        let data = try await authed(path: "/things/\(serial)/update-fw", method: "GET")
        do {
            return try JSONDecoder.laMarzocco().decode(UpdateDetails.self, from: data)
        } catch {
            throw LaMarzoccoError.decoding("update-fw: \(error)")
        }
    }

    /// Install the available firmware update (`POST /things/{serial}/update-fw`).
    /// Not routed through the command-status machinery.
    @discardableResult
    public func installFirmwareUpdate(serial: String) async throws -> UpdateDetails {
        let data = try await authed(path: "/things/\(serial)/update-fw", method: "POST")
        do {
            return try JSONDecoder.laMarzocco().decode(UpdateDetails.self, from: data)
        } catch {
            throw LaMarzoccoError.decoding("update-fw: \(error)")
        }
    }
}
