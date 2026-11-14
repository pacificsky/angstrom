import Foundation

/// Inputs of `get_dashboard_from_bluetooth` (MACH:356-369).
public struct BluetoothDashboardState: Sendable, Hashable {
    public var machineMode: MachineMode
    public var isPlumbedIn: Bool
    /// `tankStatus`: true = water present.
    public var tankStatus: Bool
    public var boilers: [BluetoothBoilerDetails]

    public init(machineMode: MachineMode, isPlumbedIn: Bool, tankStatus: Bool,
                boilers: [BluetoothBoilerDetails]) {
        self.machineMode = machineMode
        self.isPlumbedIn = isPlumbedIn
        self.tankStatus = tankStatus
        self.boilers = boilers
    }
}

extension Dashboard {
    /// Replace the first widget with `widget.code` (keeping its index), else append `widget`.
    public func upserting(_ widget: Widget) -> Dashboard {
        fatalError("unimplemented: BT-W1-05")
    }

    /// Remove every widget with `code`.
    public func removingWidgets(code: String) -> Dashboard {
        fatalError("unimplemented: BT-W1-05")
    }

    /// Set `CMMachineStatus.status` only (not the group status). No-op without that widget.
    public func settingMachineState(_ state: MachineState) -> Dashboard {
        fatalError("unimplemented: BT-W1-05")
    }

    /// `get_dashboard_from_bluetooth`'s widget synthesis (§4.17).
    public func applyingBluetoothState(_ state: BluetoothDashboardState, model: Model) -> Dashboard {
        fatalError("unimplemented: BT-W1-05")
    }

    /// The shot-counter overlay on `CMMachineStatus` (§4.19). nil → self.
    public func overlayingBluetoothBrewing(_ update: BluetoothShotCounterUpdate?) -> Dashboard {
        fatalError("unimplemented: BT-W1-05")
    }
}
