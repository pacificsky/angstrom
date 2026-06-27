import Foundation

/// A machine ("thing") registered to the account.
///
/// Decoded from the `GET /things` list and the identity portion of a
/// ``Dashboard``. Decoding is tolerant: only ``serialNumber`` is required, and
/// unknown/missing fields fall back to sensible defaults.
public struct Machine: Codable, Sendable, Identifiable, Hashable {
    public let serialNumber: String
    public var name: String
    /// The normalized model.
    public var model: Model
    /// Human-friendly model name (e.g. "Linea Micra"), derived from ``model``.
    public var modelName: String { model.displayName }
    public var type: DeviceType
    public var location: String?
    public var isConnected: Bool
    public var connectionDate: Date?
    /// A firmware update is required before the machine will function fully.
    public var requiresFirmwareUpdate: Bool
    /// A firmware update is available (but not required).
    public var hasFirmwareUpdateAvailable: Bool
    public var imageURL: URL?

    public var id: String { serialNumber }
    /// Falls back to the serial when the machine has no friendly name.
    public var displayName: String { name.isEmpty ? serialNumber : name }

    public init(
        serialNumber: String,
        name: String = "",
        model: Model = .unknown(""),
        type: DeviceType = .coffeeMachine,
        location: String? = nil,
        isConnected: Bool = false,
        connectionDate: Date? = nil,
        requiresFirmwareUpdate: Bool = false,
        hasFirmwareUpdateAvailable: Bool = false,
        imageURL: URL? = nil
    ) {
        self.serialNumber = serialNumber
        self.name = name
        self.model = model
        self.type = type
        self.location = location
        self.isConnected = isConnected
        self.connectionDate = connectionDate
        self.requiresFirmwareUpdate = requiresFirmwareUpdate
        self.hasFirmwareUpdateAvailable = hasFirmwareUpdateAvailable
        self.imageURL = imageURL
    }

    private enum CodingKeys: String, CodingKey {
        case serialNumber, name, modelName, modelCode, type, location
        case connected, connectionDate, requireFirmwareUpdate, availableFirmwareUpdate, imageUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serialNumber = try c.decode(String.self, forKey: .serialNumber)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        let rawModelName = (try? c.decode(String.self, forKey: .modelName)) ?? ""
        let rawModelCode = (try? c.decode(String.self, forKey: .modelCode)) ?? ""
        model = Model(code: rawModelCode, name: rawModelName)
        type = (try? c.decode(DeviceType.self, forKey: .type)) ?? .coffeeMachine
        location = (try? c.decodeIfPresent(String.self, forKey: .location)) ?? nil
        isConnected = (try? c.decode(Bool.self, forKey: .connected)) ?? false
        connectionDate = (try? c.decodeIfPresent(Date.self, forKey: .connectionDate)) ?? nil
        requiresFirmwareUpdate = (try? c.decode(Bool.self, forKey: .requireFirmwareUpdate)) ?? false
        hasFirmwareUpdateAvailable = (try? c.decode(Bool.self, forKey: .availableFirmwareUpdate)) ?? false
        let urlString = (try? c.decodeIfPresent(String.self, forKey: .imageUrl)) ?? nil
        imageURL = urlString.flatMap(URL.init(string:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(serialNumber, forKey: .serialNumber)
        try c.encode(name, forKey: .name)
        try c.encode(modelName, forKey: .modelName)
        try c.encode(model.code, forKey: .modelCode)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(isConnected, forKey: .connected)
        try c.encodeIfPresent(connectionDate, forKey: .connectionDate)
        try c.encode(requiresFirmwareUpdate, forKey: .requireFirmwareUpdate)
        try c.encode(hasFirmwareUpdateAvailable, forKey: .availableFirmwareUpdate)
        try c.encodeIfPresent(imageURL?.absoluteString, forKey: .imageUrl)
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
    /// A websocket connection or protocol error.
    case webSocket(String)
    /// A command was accepted but the machine didn't confirm it in time.
    case commandTimedOut
    /// The machine reported a command as failed.
    case commandFailed(status: String, errorCode: String?)
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
        case .webSocket(let message):
            return "Live-update connection error: \(message)"
        case .commandTimedOut:
            return "The machine did not confirm the command in time."
        case .commandFailed(let status, let errorCode):
            return "The machine rejected the command (\(status)\(errorCode.map { ", \($0)" } ?? ""))."
        }
    }
}
