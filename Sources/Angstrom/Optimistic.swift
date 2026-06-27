import Foundation

// MARK: - Optimistic dashboard transforms
//
// Pure functional helpers that return a new ``Dashboard`` with a single widget
// payload changed. The observable device layer (AngstromUI) applies these
// immediately after a command is accepted so the UI reflects the change without
// waiting for the next websocket push; the authoritative state still arrives
// over the socket moments later. Each transform mirrors the equivalent
// optimistic mutation in `pylamarzocco`'s `LaMarzoccoMachine`, and is a no-op
// when the machine doesn't report the relevant widget.

extension Dashboard {
    /// Returns a copy with `widget` substituted for the existing widget of the
    /// same `code` and `index`. If no such widget exists the dashboard is
    /// returned unchanged — optimistic updates only touch widgets the machine
    /// already reports.
    public func replacing(_ widget: Widget) -> Dashboard {
        guard widgets.contains(where: { $0.code == widget.code && $0.index == widget.index })
        else { return self }
        let updated = widgets.map {
            $0.code == widget.code && $0.index == widget.index ? widget : $0
        }
        return Dashboard(machine: machine, widgets: updated)
    }

    /// Optimistically set the machine running mode (after `setPower`).
    public func settingMachineMode(_ mode: MachineMode) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMMachineStatus" }),
              case .machineStatus(let s) = w.kind else { return self }
        let next = MachineStatus(status: s.status, availableModes: s.availableModes,
                                 mode: mode, nextStatus: s.nextStatus,
                                 brewingStartTime: s.brewingStartTime)
        return replacing(Widget(code: w.code, index: w.index, kind: .machineStatus(next)))
    }

    /// Optimistically set the steam boiler enabled flag (after `setSteam`).
    /// Updates whichever steam widget the model reports (level or temperature).
    public func settingSteamEnabled(_ enabled: Bool) -> Dashboard {
        var result = self
        if let w = result.widgets.first(where: { $0.code == "CMSteamBoilerLevel" }),
           case .steamBoilerLevel(let s) = w.kind {
            let next = SteamBoilerLevel(status: s.status, enabled: enabled,
                                        enabledSupported: s.enabledSupported,
                                        targetLevel: s.targetLevel,
                                        targetLevelSupported: s.targetLevelSupported,
                                        readyStartTime: s.readyStartTime)
            result = result.replacing(Widget(code: w.code, index: w.index, kind: .steamBoilerLevel(next)))
        }
        if let w = result.widgets.first(where: { $0.code == "CMSteamBoilerTemperature" }),
           case .steamBoilerTemperature(let s) = w.kind {
            let next = SteamBoilerTemperature(
                status: s.status, enabled: enabled, enabledSupported: s.enabledSupported,
                targetTemperature: s.targetTemperature, targetTemperatureMin: s.targetTemperatureMin,
                targetTemperatureMax: s.targetTemperatureMax, targetTemperatureStep: s.targetTemperatureStep,
                targetTemperatureSupported: s.targetTemperatureSupported, readyStartTime: s.readyStartTime)
            result = result.replacing(Widget(code: w.code, index: w.index, kind: .steamBoilerTemperature(next)))
        }
        return result
    }

    /// Optimistically set the steam target level (after `setSteamTargetLevel`).
    public func settingSteamTargetLevel(_ level: SteamLevel) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMSteamBoilerLevel" }),
              case .steamBoilerLevel(let s) = w.kind else { return self }
        let next = SteamBoilerLevel(status: s.status, enabled: s.enabled,
                                    enabledSupported: s.enabledSupported, targetLevel: level,
                                    targetLevelSupported: s.targetLevelSupported,
                                    readyStartTime: s.readyStartTime)
        return replacing(Widget(code: w.code, index: w.index, kind: .steamBoilerLevel(next)))
    }

    /// Optimistically set the coffee boiler target temperature in °C
    /// (after `setCoffeeTargetTemperature`).
    public func settingCoffeeTargetTemperature(_ celsius: Double) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMCoffeeBoiler" }),
              case .coffeeBoiler(let s) = w.kind else { return self }
        let next = CoffeeBoiler(status: s.status, enabled: s.enabled,
                                enabledSupported: s.enabledSupported, targetTemperature: celsius,
                                targetTemperatureMin: s.targetTemperatureMin,
                                targetTemperatureMax: s.targetTemperatureMax,
                                targetTemperatureStep: s.targetTemperatureStep,
                                readyStartTime: s.readyStartTime)
        return replacing(Widget(code: w.code, index: w.index, kind: .coffeeBoiler(next)))
    }

    /// Optimistically set the steam boiler target temperature in °C
    /// (after `setSteamTargetTemperature`).
    public func settingSteamTargetTemperature(_ celsius: Double) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMSteamBoilerTemperature" }),
              case .steamBoilerTemperature(let s) = w.kind else { return self }
        let next = SteamBoilerTemperature(
            status: s.status, enabled: s.enabled, enabledSupported: s.enabledSupported,
            targetTemperature: celsius, targetTemperatureMin: s.targetTemperatureMin,
            targetTemperatureMax: s.targetTemperatureMax, targetTemperatureStep: s.targetTemperatureStep,
            targetTemperatureSupported: s.targetTemperatureSupported, readyStartTime: s.readyStartTime)
        return replacing(Widget(code: w.code, index: w.index, kind: .steamBoilerTemperature(next)))
    }

    /// Optimistically set the brew-by-weight dose mode
    /// (after `setBrewByWeightMode`).
    public func settingBrewByWeightMode(_ mode: DoseMode) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMBrewByWeightDoses" }),
              case .brewByWeightDoses(let s) = w.kind else { return self }
        let next = BrewByWeightDoses(scaleConnected: s.scaleConnected, mode: mode,
                                     availableModes: s.availableModes, doses: s.doses)
        return replacing(Widget(code: w.code, index: w.index, kind: .brewByWeightDoses(next)))
    }

    /// Optimistically set the two brew-by-weight doses in grams
    /// (after `setBrewByWeightDoses`).
    public func settingBrewByWeightDoses(dose1: Double, dose2: Double) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMBrewByWeightDoses" }),
              case .brewByWeightDoses(let s) = w.kind else { return self }
        let d = s.doses
        let pair = BrewByWeightDosePair(
            dose1: BaseDose(dose: dose1, doseMin: d.dose1.doseMin, doseMax: d.dose1.doseMax, doseStep: d.dose1.doseStep),
            dose2: BaseDose(dose: dose2, doseMin: d.dose2.doseMin, doseMax: d.dose2.doseMax, doseStep: d.dose2.doseStep))
        let next = BrewByWeightDoses(scaleConnected: s.scaleConnected, mode: s.mode,
                                     availableModes: s.availableModes, doses: pair)
        return replacing(Widget(code: w.code, index: w.index, kind: .brewByWeightDoses(next)))
    }

    /// Optimistically set the grinder barista-light flag
    /// (after `setGrinderBaristaLight`).
    public func settingGrinderBaristaLight(_ enabled: Bool) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "GBaristaLight" }),
              case .grinderBaristaLight = w.kind else { return self }
        return replacing(Widget(code: w.code, index: w.index,
                                kind: .grinderBaristaLight(GrinderBaristaLight(enabled: enabled))))
    }
}
