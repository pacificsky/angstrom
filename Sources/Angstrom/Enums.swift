import Foundation

// MARK: - Decoder

extension JSONDecoder {
    /// A decoder configured for La Marzocco's wire format, where timestamps are
    /// milliseconds since the Unix epoch. Use this for every cloud response so
    /// `Date` fields decode uniformly.
    static func laMarzocco() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

extension JSONEncoder {
    /// The encoder matching ``JSONDecoder/laMarzocco()`` (ms-epoch dates). Use
    /// this to persist `Codable` types like ``Machine`` so a ``Date`` survives a
    /// round-trip — a vanilla `JSONEncoder` would write a different date format
    /// and silently corrupt timestamps on decode.
    static func laMarzocco() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

/// Decodes `T`, capturing a decode failure as `nil` instead of throwing. Decode
/// an array as `[Lenient<T>]` and `compactMap(\.value)` so one malformed element
/// is skipped rather than dropping the whole array.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Device identity

/// A La Marzocco device model, normalized from the cloud's `modelCode`/`modelName`.
public enum Model: Sendable, Hashable, Codable {
    case lineaMini
    case lineaMicra
    case lineaMiniR
    case gs3
    case gs3AV
    case gs3MP
    case pico
    case swan
    /// A model this version doesn't recognize, carrying the raw code/name.
    case unknown(String)

    /// Resolve a model from the cloud's `modelCode`, falling back to `modelName`.
    public init(code: String, name: String = "") {
        if let m = Model.match(code) { self = m }
        else if let m = Model.match(name) { self = m }
        else { self = .unknown(name.isEmpty ? code : name) }
    }

    private static func match(_ raw: String) -> Model? {
        switch raw.uppercased().filter({ !$0.isWhitespace }) {
        case "LINEAMINI": return .lineaMini
        case "LINEAMICRA", "MICRA": return .lineaMicra
        case "LINEAMINIR", "LINEAMINI2023": return .lineaMiniR
        case "GS3": return .gs3
        case "GS3AV": return .gs3AV
        case "GS3MP": return .gs3MP
        case "PICOGRINDER", "PICO": return .pico
        case "SWANGRINDER", "SWAN": return .swan
        default: return nil
        }
    }

    /// The canonical `modelCode` string (raw value for unknown models).
    public var code: String {
        switch self {
        case .lineaMini: "LINEAMINI"
        case .lineaMicra: "LINEAMICRA"
        case .lineaMiniR: "LINEAMINIR"
        case .gs3: "GS3"
        case .gs3AV: "GS3AV"
        case .gs3MP: "GS3MP"
        case .pico: "PICOGRINDER"
        case .swan: "SWANGRINDER"
        case .unknown(let raw): raw
        }
    }

    /// A human-friendly model name.
    public var displayName: String {
        switch self {
        case .lineaMini: "Linea Mini"
        case .lineaMicra: "Linea Micra"
        case .lineaMiniR: "Linea Mini R"
        case .gs3: "GS3"
        case .gs3AV: "GS3 AV"
        case .gs3MP: "GS3 MP"
        case .pico: "Pico"
        case .swan: "Swan"
        case .unknown(let raw): raw
        }
    }

    /// Whether this is a grinder rather than an espresso machine.
    public var isGrinder: Bool { self == .pico || self == .swan }

    public init(from decoder: Decoder) throws {
        self = Model(code: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(code)
    }
}

/// The kind of device behind a serial number.
public enum DeviceType: Sendable, Equatable, Hashable, Codable {
    case coffeeMachine
    case grinder
    /// Any other/unrecognized device type, with the raw value.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "CoffeeMachine": self = .coffeeMachine
        case "Grinder": self = .grinder
        default: self = .other(rawValue)
        }
    }
    public var rawValue: String {
        switch self {
        case .coffeeMachine: "CoffeeMachine"
        case .grinder: "Grinder"
        case .other(let value): value
        }
    }
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

// MARK: - Machine state

/// The overall running state of a machine (`CMMachineStatus.status`).
public enum MachineState: Sendable, Hashable, Codable {
    case standby
    case poweredOn
    case brewing
    case off
    /// A state this version doesn't recognize, carrying the raw value.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "StandBy": self = .standby
        case "PoweredOn": self = .poweredOn
        case "Brewing": self = .brewing
        case "Off": self = .off
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .standby: "StandBy"
        case .poweredOn: "PoweredOn"
        case .brewing: "Brewing"
        case .off: "Off"
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

/// A selectable machine mode (`CMMachineStatus.mode` / `availableModes`).
public enum MachineMode: Sendable, Hashable, Codable {
    case brewing
    case eco
    case standby
    /// A mode this version doesn't recognize, carrying the raw value.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "BrewingMode": self = .brewing
        case "EcoMode": self = .eco
        case "StandBy": self = .standby
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .brewing: "BrewingMode"
        case .eco: "EcoMode"
        case .standby: "StandBy"
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

/// A boiler's heating state.
public enum BoilerStatus: Sendable, Hashable, Codable {
    case standby
    case heatingUp
    case ready
    case noWater
    case off
    /// A status this version doesn't recognize, carrying the raw value.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "StandBy": self = .standby
        case "HeatingUp": self = .heatingUp
        case "Ready": self = .ready
        case "NoWater": self = .noWater
        case "Off": self = .off
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .standby: "StandBy"
        case .heatingUp: "HeatingUp"
        case .ready: "Ready"
        case .noWater: "NoWater"
        case .off: "Off"
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

// MARK: - Feature enums (strict — unknown values demote their widget to `.unknown`)

/// Steam-boiler target level (Linea Micra / Mini R).
public enum SteamLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case level1 = "Level1"
    case level2 = "Level2"
    case level3 = "Level3"
}

/// Pre-extraction mode.
public enum PreExtractionMode: String, Sendable, Hashable, Codable, CaseIterable {
    case preInfusion = "PreInfusion"
    case preBrewing = "PreBrewing"
    case disabled = "Disabled"
}

/// Back-flush cleaning status.
public enum BackFlushStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case requested = "Requested"
    case cleaning = "Cleaning"
    case off = "Off"
}

/// Coffee-dose delivery mode.
public enum DoseMode: Sendable, Hashable, Codable {
    case continuous
    case pulses
    case dose1
    case dose2
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "Continuous": self = .continuous
        case "PulsesType": self = .pulses
        case "Dose1": self = .dose1
        case "Dose2": self = .dose2
        default: self = .other(rawValue)
        }
    }
    public var rawValue: String {
        switch self {
        case .continuous: "Continuous"
        case .pulses: "PulsesType"
        case .dose1: "Dose1"
        case .dose2: "Dose2"
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

/// Which dose a setting applies to (read side: dashboard dose widgets).
public enum DoseIndex: String, Sendable, Hashable, Codable, CaseIterable {
    case continuous = "Continuous"
    case byGroup = "ByGroup"
    case doseA = "DoseA"
    case doseB = "DoseB"
    case doseC = "DoseC"
    case doseD = "DoseD"
}

/// Dose-index domain accepted by the pre-extraction-times command (write side).
public enum PreExtractionDoseIndex: String, Sendable, Hashable, Codable, CaseIterable {
    case byGroup = "ByGroup"
    case byDose = "ByDose"
}

// MARK: - Settings & scheduling

/// A day of the week (wake-up schedules).
public enum Weekday: String, Sendable, Hashable, Codable, CaseIterable {
    case monday = "Monday"
    case tuesday = "Tuesday"
    case wednesday = "Wednesday"
    case thursday = "Thursday"
    case friday = "Friday"
    case saturday = "Saturday"
    case sunday = "Sunday"
}

/// When the smart-standby timer starts counting.
public enum SmartStandbyAfter: String, Sendable, Hashable, Codable {
    case lastBrewing = "LastBrewing"
    case powerOn = "PowerOn"
}

/// A firmware component.
public enum FirmwareType: String, Sendable, Hashable, Codable {
    case machine = "Machine"
    case gateway = "Gateway"
}

/// Firmware update status.
public enum UpdateStatus: Sendable, Hashable, Codable {
    case toUpdate
    case pending
    case inProgress
    case updated
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "ToUpdate": self = .toUpdate
        case "Pending": self = .pending
        case "InProgress": self = .inProgress
        case "Updated": self = .updated
        default: self = .other(rawValue)
        }
    }
    public var rawValue: String {
        switch self {
        case .toUpdate: "ToUpdate"
        case .pending: "Pending"
        case .inProgress: "InProgress"
        case .updated: "Updated"
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
