import Foundation

// MARK: - Command response

/// The acknowledgement the cloud returns for a command. The final result for a
/// command is delivered later over the websocket (see M3).
public struct CommandResponse: Sendable, Hashable, Decodable {
    public let id: String
    public let status: CommandStatus
    public let errorCode: String?
}

/// The status of a dispatched command.
public enum CommandStatus: Sendable, Hashable, Codable {
    case success
    case error
    case timeout
    case pending
    case inProgress
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "Success": self = .success
        case "Error": self = .error
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
private struct GrinderLightBody: Encodable, Sendable { let index: Int; let enabled: Bool }

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

    /// Turn the machine on (`BrewingMode`) or off (`StandBy`).
    @discardableResult
    public func setPower(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "CoffeeMachineChangeMode",
                                 body: ModeBody(mode: on ? "BrewingMode" : "StandBy"))
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

    /// Enable or disable a grinder's barista light (ignored while in standby).
    @discardableResult
    public func setGrinderBaristaLight(serial: String, on: Bool) async throws -> CommandResponse {
        try await executeCommand(serial: serial, "GrinderSettingBaristaLightEnabled",
                                 body: GrinderLightBody(index: 1, enabled: on))
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
