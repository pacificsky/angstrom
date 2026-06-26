import Foundation

/// The kind of device on the account. The cloud reports this as the `type`
/// field on each thing.
public enum DeviceType: Sendable, Equatable, Hashable, Codable {
    /// An espresso machine (Linea Micra/Mini, GS3, …). Supports remote power.
    case coffeeMachine
    /// A grinder (Pico, Swan). Reports status but has no remote power command.
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
        case .coffeeMachine: return "CoffeeMachine"
        case .grinder: return "Grinder"
        case .other(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A machine ("thing") registered to the account.
public struct Machine: Codable, Sendable, Identifiable, Hashable {
    public let serialNumber: String
    public var name: String
    public var modelName: String
    /// The kind of device — coffee machine, grinder, etc.
    public var type: DeviceType

    public var id: String { serialNumber }
    /// Falls back to the serial when the machine has no friendly name.
    public var displayName: String { name.isEmpty ? serialNumber : name }
    /// Whether this device supports remote power on/off. Only coffee machines
    /// accept the change-mode command; grinders manage their own standby.
    public var supportsPower: Bool { type == .coffeeMachine }

    public init(serialNumber: String, name: String = "", modelName: String = "",
                type: DeviceType = .coffeeMachine) {
        self.serialNumber = serialNumber
        self.name = name
        self.modelName = modelName
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case serialNumber, name, modelName, type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serialNumber = try c.decode(String.self, forKey: .serialNumber)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        modelName = (try? c.decode(String.self, forKey: .modelName)) ?? ""
        type = (try? c.decode(DeviceType.self, forKey: .type)) ?? .coffeeMachine
    }
}

/// Power state derived from the machine's status dashboard widget
/// (`CMMachineStatus` for coffee machines, `GMachineStatus` for grinders).
public enum PowerState: Sendable, Equatable {
    /// Mode is `BrewingMode` (coffee machine) or `GrindingMode` (grinder) — on.
    case on
    /// Mode is `StandBy` — off.
    case off
    /// Any other reported mode (e.g. a brew in progress), with the raw value.
    case other(String)
    /// State could not be determined.
    case unknown

    public var isOn: Bool { self == .on }
}

/// Errors thrown by the client.
public enum LaMarzoccoError: Error, Sendable, Equatable {
    /// The account credentials were rejected (HTTP 401).
    case authenticationFailed
    /// The persisted ``InstallationKey`` could not be reconstructed.
    case invalidInstallationKey
    /// A request returned a non-success status.
    case requestFailed(status: Int, body: String)
    /// A networking/transport error.
    case network(String)
    /// The response wasn't in the expected shape.
    case decoding(String)
    /// The account has no machines.
    case noMachines
}

extension LaMarzoccoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Invalid La Marzocco email or password."
        case .invalidInstallationKey:
            return "Stored installation key is invalid; generate a new one."
        case .requestFailed(let status, let body):
            return "Request failed (HTTP \(status)). \(body)"
        case .network(let message):
            return "Network error: \(message)"
        case .decoding(let message):
            return "Unexpected response: \(message)"
        case .noMachines:
            return "No machines found on this account."
        }
    }
}
