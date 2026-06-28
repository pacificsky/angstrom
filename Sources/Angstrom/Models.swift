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
    /// Whether the device is operating in offline (local-only) mode.
    public var offlineMode: Bool
    /// The coffee station this device belongs to, if any. (`bleAuthToken` is
    /// intentionally not modeled — Bluetooth is out of scope.)
    public var coffeeStation: CoffeeStation?
    public var imageURL: URL?

    public var id: String { serialNumber }
    /// Falls back to the serial when the machine has no friendly name.
    public var displayName: String { name.isEmpty ? serialNumber : name }
    /// Whether this device supports remote power on/off. Only coffee machines
    /// accept the change-mode command; grinders manage their own standby.
    public var supportsPower: Bool { type == .coffeeMachine }

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
        offlineMode: Bool = false,
        coffeeStation: CoffeeStation? = nil,
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
        self.offlineMode = offlineMode
        self.coffeeStation = coffeeStation
        self.imageURL = imageURL
    }

    private enum CodingKeys: String, CodingKey {
        case serialNumber, name, modelName, modelCode, type, location
        case connected, connectionDate, requireFirmwareUpdate, availableFirmwareUpdate
        case offlineMode, coffeeStation, imageUrl
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
        offlineMode = (try? c.decode(Bool.self, forKey: .offlineMode)) ?? false
        coffeeStation = (try? c.decodeIfPresent(CoffeeStation.self, forKey: .coffeeStation)) ?? nil
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
        try c.encode(offlineMode, forKey: .offlineMode)
        try c.encodeIfPresent(coffeeStation, forKey: .coffeeStation)
        try c.encodeIfPresent(imageURL?.absoluteString, forKey: .imageUrl)
    }
}

/// A coffee station: a named grouping of a coffee machine with its grinders and
/// accessories. pylamarzocco keeps this as an opaque `dict`; here the identity
/// and paired ``accessories`` (e.g. scales) are modeled so the data isn't lost,
/// while the redundant nested machine/grinder payloads are skipped.
public struct CoffeeStation: Codable, Sendable, Hashable {
    public let id: String?
    public let name: String?
    public let accessories: [CoffeeStationAccessory]

    private enum CodingKeys: String, CodingKey { case id, name, accessories }

    public init(id: String? = nil, name: String? = nil, accessories: [CoffeeStationAccessory] = []) {
        self.id = id
        self.name = name
        self.accessories = accessories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        let entries = (try? c.decode([Lenient<CoffeeStationAccessory>].self, forKey: .accessories)) ?? []
        accessories = entries.compactMap(\.value)
    }
}

/// An accessory paired to a ``CoffeeStation`` (e.g. a connected scale).
public struct CoffeeStationAccessory: Codable, Sendable, Hashable {
    public let type: String
    public let name: String?
    public let connected: Bool
    public let batteryLevel: Int?
    public let imageURL: URL?

    private enum CodingKeys: String, CodingKey { case type, name, connected, batteryLevel, imageUrl }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        connected = (try? c.decode(Bool.self, forKey: .connected)) ?? false
        batteryLevel = (try? c.decodeIfPresent(Int.self, forKey: .batteryLevel)) ?? nil
        let urlString = (try? c.decodeIfPresent(String.self, forKey: .imageUrl)) ?? nil
        imageURL = urlString.flatMap(URL.init(string:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(connected, forKey: .connected)
        try c.encodeIfPresent(batteryLevel, forKey: .batteryLevel)
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
    /// The requested action isn't supported on this device model.
    case unsupportedModel(String)
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
        case .unsupportedModel(let message):
            return "Unsupported for this machine: \(message)"
        }
    }
}
