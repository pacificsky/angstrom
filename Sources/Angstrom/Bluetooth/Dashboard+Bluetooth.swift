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
        guard let position = widgets.firstIndex(where: { $0.code == widget.code }) else {
            return Dashboard(machine: machine, widgets: widgets + [widget])
        }
        var updated = widgets
        updated[position] = Widget(code: widget.code, index: widgets[position].index, kind: widget.kind)
        return Dashboard(machine: machine, widgets: updated)
    }

    /// Remove every widget with `code`.
    public func removingWidgets(code: String) -> Dashboard {
        Dashboard(machine: machine, widgets: widgets.filter { $0.code != code })
    }

    /// Set `CMMachineStatus.status` only (not the group status). No-op without that widget.
    public func settingMachineState(_ state: MachineState) -> Dashboard {
        guard let found = firstTyped(code: Self.machineStatusCode, Self.extractMachineStatus) else {
            return self
        }
        let s = found.value
        let next = MachineStatus(status: state, availableModes: s.availableModes, mode: s.mode,
                                 nextStatus: s.nextStatus, brewingStartTime: s.brewingStartTime)
        return replacingKind(at: found.position, with: .machineStatus(next))
    }

    /// `get_dashboard_from_bluetooth`'s widget synthesis (§4.17).
    public func applyingBluetoothState(_ state: BluetoothDashboardState, model: Model) -> Dashboard {
        let mode = state.machineMode
        let waterOK = state.isPlumbedIn || state.tankStatus

        // `boiler_status` (MACH:371-376).
        func boilerStatus(_ enabled: Bool) -> BoilerStatus {
            if !waterOK { return .noWater }
            if !enabled { return .off }
            return BoilerStatus(bluetoothMode: mode)
        }

        // Step 1: CMMachineStatus (MACH:378-393). CMMachineGroupStatus is never touched.
        var result = upsertingTyped(code: Self.machineStatusCode, Self.extractMachineStatus) { existing in
            let base = existing ?? MachineStatus(status: .standby, availableModes: [.brewing, .standby],
                                                 mode: mode, nextStatus: nil, brewingStartTime: nil)
            return .machineStatus(MachineStatus(status: MachineState(bluetoothMode: mode),
                                                availableModes: base.availableModes, mode: mode,
                                                nextStatus: base.nextStatus,
                                                brewingStartTime: base.brewingStartTime))
        }

        // Step 2: boilers. Each widget's final value depends only on the existing widget and the
        // last entry with that id (a duplicate id: last wins); `.other` ids are ignored. Applying
        // coffee before steam gives the fixed append order of §4.17.
        let coffee = state.boilers.last { $0.id == .coffee }
        let steam = state.boilers.last { $0.id == .steam }

        // 2a: CMCoffeeBoiler (MACH:396-416). The coffee boiler never shows `.off` (MACH:413).
        if let b = coffee {
            result = result.upsertingTyped(code: Self.coffeeBoilerCode, Self.extractCoffeeBoiler) { existing in
                let base = existing ?? CoffeeBoiler(status: .standby, enabled: b.isEnabled,
                                                    enabledSupported: false, targetTemperature: b.target,
                                                    targetTemperatureMin: 80, targetTemperatureMax: 110,
                                                    targetTemperatureStep: 0.1, readyStartTime: nil)
                return .coffeeBoiler(CoffeeBoiler(status: boilerStatus(true), enabled: b.isEnabled,
                                                  enabledSupported: base.enabledSupported,
                                                  targetTemperature: b.target,
                                                  targetTemperatureMin: base.targetTemperatureMin,
                                                  targetTemperatureMax: base.targetTemperatureMax,
                                                  targetTemperatureStep: base.targetTemperatureStep,
                                                  readyStartTime: base.readyStartTime))
            }
        }

        if let b = steam {
            if Model.steamLevelModels.contains(model) {
                // 2b: CMSteamBoilerLevel (MACH:419-445), then remove every CMSteamBoilerTemperature.
                result = result.upsertingTyped(code: Self.steamLevelCode, Self.extractSteamLevel) { existing in
                    let base = existing ?? SteamBoilerLevel(status: .standby, enabled: b.isEnabled,
                                                            enabledSupported: true, targetLevel: .level1,
                                                            targetLevelSupported: true, readyStartTime: nil)
                    return .steamBoilerLevel(SteamBoilerLevel(
                        status: boilerStatus(b.isEnabled), enabled: b.isEnabled,
                        enabledSupported: base.enabledSupported,
                        targetLevel: SteamLevel(bluetoothTargetTemperature: b.target),
                        targetLevelSupported: base.targetLevelSupported,
                        readyStartTime: base.readyStartTime))
                }
                .removingWidgets(code: Self.steamTemperatureCode)
            } else {
                // 2c: CMSteamBoilerTemperature (MACH:446-472), then remove every CMSteamBoilerLevel.
                let isMini = model == .lineaMini
                result = result.upsertingTyped(code: Self.steamTemperatureCode, Self.extractSteamTemperature) { existing in
                    let base = existing ?? SteamBoilerTemperature(
                        status: .standby, enabled: b.isEnabled, enabledSupported: false,
                        targetTemperature: b.target,
                        targetTemperatureMin: isMini ? 95 : 20,
                        targetTemperatureMax: isMini ? 140 : 134,
                        targetTemperatureStep: 0.1,
                        targetTemperatureSupported: !isMini, readyStartTime: nil)
                    return .steamBoilerTemperature(SteamBoilerTemperature(
                        status: boilerStatus(b.isEnabled), enabled: b.isEnabled,
                        enabledSupported: base.enabledSupported,
                        targetTemperature: b.target,
                        targetTemperatureMin: base.targetTemperatureMin,
                        targetTemperatureMax: base.targetTemperatureMax,
                        targetTemperatureStep: base.targetTemperatureStep,
                        targetTemperatureSupported: base.targetTemperatureSupported,
                        readyStartTime: base.readyStartTime))
                }
                .removingWidgets(code: Self.steamLevelCode)
            }
        }

        // Step 3: CMNoWater, always written (MACH:474-483).
        result = result.upsertingTyped(code: Self.noWaterCode, Self.extractNoWater) { _ in
            .noWater(NoWater(alarm: !waterOK))
        }
        return result
    }

    /// The shot-counter overlay on `CMMachineStatus` (§4.19). nil → self.
    public func overlayingBluetoothBrewing(_ update: BluetoothShotCounterUpdate?) -> Dashboard {
        guard let update,
              let found = firstTyped(code: Self.machineStatusCode, Self.extractMachineStatus) else {
            return self
        }
        let base = found.value
        let status: MachineState
        let brewingStartTime: Date?
        if update.state == .brewing {
            status = .brewing
            brewingStartTime = update.brewingStartTime
        } else {
            status = base.status == .brewing ? .poweredOn : base.status
            brewingStartTime = base.brewingStartTime
        }
        let next = MachineStatus(status: status, availableModes: base.availableModes, mode: base.mode,
                                 nextStatus: base.nextStatus, brewingStartTime: brewingStartTime)
        return replacingKind(at: found.position, with: .machineStatus(next))
    }

    // MARK: - Private helpers

    private static let machineStatusCode = "CMMachineStatus"
    private static let coffeeBoilerCode = "CMCoffeeBoiler"
    private static let steamLevelCode = "CMSteamBoilerLevel"
    private static let steamTemperatureCode = "CMSteamBoilerTemperature"
    private static let noWaterCode = "CMNoWater"

    private static func extractMachineStatus(_ kind: WidgetKind) -> MachineStatus? {
        if case .machineStatus(let v) = kind { return v }
        return nil
    }

    private static func extractCoffeeBoiler(_ kind: WidgetKind) -> CoffeeBoiler? {
        if case .coffeeBoiler(let v) = kind { return v }
        return nil
    }

    private static func extractSteamLevel(_ kind: WidgetKind) -> SteamBoilerLevel? {
        if case .steamBoilerLevel(let v) = kind { return v }
        return nil
    }

    private static func extractSteamTemperature(_ kind: WidgetKind) -> SteamBoilerTemperature? {
        if case .steamBoilerTemperature(let v) = kind { return v }
        return nil
    }

    private static func extractNoWater(_ kind: WidgetKind) -> NoWater? {
        if case .noWater(let v) = kind { return v }
        return nil
    }

    /// The first widget with `code` whose kind is the matching typed case (`.unknown` and any
    /// other kind count as absent), with its position in `widgets`.
    private func firstTyped<T>(code: String,
                               _ extract: (WidgetKind) -> T?) -> (position: Int, value: T)? {
        for (position, widget) in widgets.enumerated() where widget.code == code {
            if let value = extract(widget.kind) { return (position, value) }
        }
        return nil
    }

    /// Replace the kind of the widget at `position`, keeping its code and index.
    private func replacingKind(at position: Int, with kind: WidgetKind) -> Dashboard {
        var updated = widgets
        updated[position] = Widget(code: widgets[position].code, index: widgets[position].index, kind: kind)
        return Dashboard(machine: machine, widgets: updated)
    }

    /// §4.17 upsert: rebuild the existing typed `code` widget in place (keeping code and index),
    /// else append the built default with `index: 1`.
    private func upsertingTyped<T>(code: String, _ extract: (WidgetKind) -> T?,
                                   _ build: (T?) -> WidgetKind) -> Dashboard {
        if let found = firstTyped(code: code, extract) {
            return replacingKind(at: found.position, with: build(found.value))
        }
        return Dashboard(machine: machine, widgets: widgets + [Widget(code: code, index: 1, kind: build(nil))])
    }
}
