import Foundation

/// `machineCapabilities` element [0] (MBT:22-39).
public struct BluetoothMachineCapabilities: Sendable, Hashable {
    public let family: Model
    /// The family string as sent (e.g. "MICRA").
    public let rawFamily: String
    public let groupsNumber: Int
    public let coffeeBoilersNumber: Int
    public let hasCupWarmer: Bool
    public let steamBoilersNumber: Int
    public let teaDosesNumber: Int
    public let machineModes: [MachineMode]
    public let schedulingType: String

    public init(family: Model, rawFamily: String, groupsNumber: Int, coffeeBoilersNumber: Int,
                hasCupWarmer: Bool, steamBoilersNumber: Int, teaDosesNumber: Int,
                machineModes: [MachineMode], schedulingType: String) {
        self.family = family
        self.rawFamily = rawFamily
        self.groupsNumber = groupsNumber
        self.coffeeBoilersNumber = coffeeBoilersNumber
        self.hasCupWarmer = hasCupWarmer
        self.steamBoilersNumber = steamBoilersNumber
        self.teaDosesNumber = teaDosesNumber
        self.machineModes = machineModes
        self.schedulingType = schedulingType
    }
}

/// One `boilers` element (MBT:42-49). Temperatures in °C.
public struct BluetoothBoilerDetails: Sendable, Hashable {
    public let id: BluetoothBoilerType
    public let isEnabled: Bool
    public let target: Double
    public let current: Double

    public init(id: BluetoothBoilerType, isEnabled: Bool, target: Double, current: Double) {
        self.id = id
        self.isEnabled = isEnabled
        self.target = target
        self.current = current
    }
}

/// `smartStandBy` (MBT:51-57).
public struct BluetoothSmartStandbyDetails: Sendable, Hashable {
    public let mode: SmartStandbyAfter
    public let minutes: Int
    public let enabled: Bool

    public init(mode: SmartStandbyAfter, minutes: Int, enabled: Bool) {
        self.mode = mode
        self.minutes = minutes
        self.enabled = enabled
    }
}

/// A command's status reply read back from the command characteristic (MBT:59-65).
public struct BluetoothCommandStatus: Sendable, Hashable {
    public let id: String
    public let message: String
    public let status: String
    /// `status.lowercased() == "success"` (MACH:1023).
    public var isSuccess: Bool { status.lowercased() == "success" }

    public init(id: String, message: String, status: String) {
        self.id = id
        self.message = message
        self.status = status
    }
}
