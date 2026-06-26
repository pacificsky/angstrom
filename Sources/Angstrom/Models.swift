import Foundation

/// A machine ("thing") registered to the account.
public struct Machine: Codable, Sendable, Identifiable, Hashable {
    public let serialNumber: String
    public var name: String
    public var modelName: String

    public var id: String { serialNumber }
    /// Falls back to the serial when the machine has no friendly name.
    public var displayName: String { name.isEmpty ? serialNumber : name }

    public init(serialNumber: String, name: String = "", modelName: String = "") {
        self.serialNumber = serialNumber
        self.name = name
        self.modelName = modelName
    }

    private enum CodingKeys: String, CodingKey {
        case serialNumber, name, modelName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serialNumber = try c.decode(String.self, forKey: .serialNumber)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        modelName = (try? c.decode(String.self, forKey: .modelName)) ?? ""
    }
}

/// Power state derived from the machine's `CMMachineStatus` dashboard widget.
public enum PowerState: Sendable, Equatable {
    /// Mode is `BrewingMode` — on and ready to brew.
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
