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

    /// Optimistically set the machine running mode (after `setPower`/`setMode`).
    /// Updates both `CMMachineStatus` and `CMMachineGroupStatus` (the Strada X
    /// reports only the latter), mirroring pylamarzocco's
    /// `_update_machine_mode_widgets`.
    public func settingMachineMode(_ mode: MachineMode) -> Dashboard {
        var result = self
        if let w = result.widgets.first(where: { $0.code == "CMMachineStatus" }),
           case .machineStatus(let s) = w.kind {
            let next = MachineStatus(status: s.status, availableModes: s.availableModes,
                                     mode: mode, nextStatus: s.nextStatus,
                                     brewingStartTime: s.brewingStartTime)
            result = result.replacing(Widget(code: w.code, index: w.index, kind: .machineStatus(next)))
        }
        if let w = result.widgets.first(where: { $0.code == "CMMachineGroupStatus" }),
           case .machineGroupStatus(let s) = w.kind {
            let next = MachineStatus(status: s.status, availableModes: s.availableModes,
                                     mode: mode, nextStatus: s.nextStatus,
                                     brewingStartTime: s.brewingStartTime)
            result = result.replacing(Widget(code: w.code, index: w.index, kind: .machineGroupStatus(next)))
        }
        return result
    }

    /// Optimistically set one group's mode (after `setGroupMode`, Strada X).
    public func settingGroupMode(_ mode: MachineMode, groupIndex: Int = 1) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMMachineGroupStatus" && $0.index == groupIndex }),
              case .machineGroupStatus(let s) = w.kind else { return self }
        let next = MachineStatus(status: s.status, availableModes: s.availableModes,
                                 mode: mode, nextStatus: s.nextStatus,
                                 brewingStartTime: s.brewingStartTime)
        return replacing(Widget(code: w.code, index: w.index, kind: .machineGroupStatus(next)))
    }

    /// Optimistically set the auto-flush flag (after `setAutoFlush`, Strada X).
    public func settingAutoFlush(_ enabled: Bool) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMAutoFlush" }),
              case .autoFlush = w.kind else { return self }
        return replacing(Widget(code: w.code, index: w.index, kind: .autoFlush(AutoFlush(enabled: enabled))))
    }

    /// Optimistically set the steam-flush flag (after `setSteamFlush`, Strada X).
    public func settingSteamFlush(_ enabled: Bool) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMSteamFlush" }),
              case .steamFlush = w.kind else { return self }
        return replacing(Widget(code: w.code, index: w.index, kind: .steamFlush(SteamFlush(enabled: enabled))))
    }

    /// Optimistically set the rinse-flush enabled flag (after `setRinseFlush`).
    public func settingRinseFlushEnabled(_ enabled: Bool) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMRinseFlush" }),
              case .rinseFlush(let s) = w.kind else { return self }
        let next = RinseFlush(enabled: enabled, enabledSupported: s.enabledSupported,
                              timeSeconds: s.timeSeconds, timeSecondsMin: s.timeSecondsMin,
                              timeSecondsMax: s.timeSecondsMax, timeSecondsStep: s.timeSecondsStep)
        return replacing(Widget(code: w.code, index: w.index, kind: .rinseFlush(next)))
    }

    /// Optimistically set the rinse-flush duration (after `setRinseFlushTime`).
    public func settingRinseFlushTime(_ seconds: Double) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMRinseFlush" }),
              case .rinseFlush(let s) = w.kind else { return self }
        let next = RinseFlush(enabled: s.enabled, enabledSupported: s.enabledSupported,
                              timeSeconds: seconds, timeSecondsMin: s.timeSecondsMin,
                              timeSecondsMax: s.timeSecondsMax, timeSecondsStep: s.timeSecondsStep)
        return replacing(Widget(code: w.code, index: w.index, kind: .rinseFlush(next)))
    }

    /// Optimistically set the coffee boiler enabled flag (after `setCoffeeBoilerEnabled`).
    public func settingCoffeeBoilerEnabled(_ enabled: Bool) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMCoffeeBoiler" }),
              case .coffeeBoiler(let s) = w.kind else { return self }
        let next = CoffeeBoiler(status: s.status, enabled: enabled,
                                enabledSupported: s.enabledSupported,
                                targetTemperature: s.targetTemperature,
                                targetTemperatureMin: s.targetTemperatureMin,
                                targetTemperatureMax: s.targetTemperatureMax,
                                targetTemperatureStep: s.targetTemperatureStep,
                                readyStartTime: s.readyStartTime)
        return replacing(Widget(code: w.code, index: w.index, kind: .coffeeBoiler(next)))
    }

    /// Optimistically set the hot-water-dose enabled flag (after `setHotWaterDoseEnabled`).
    public func settingHotWaterDoseEnabled(_ enabled: Bool) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMHotWaterDose" }),
              case .hotWaterDose(let s) = w.kind else { return self }
        let next = HotWaterDose(enabled: enabled, enabledSupported: s.enabledSupported, doses: s.doses)
        return replacing(Widget(code: w.code, index: w.index, kind: .hotWaterDose(next)))
    }

    /// Optimistically set one hot-water dose value (after `setHotWaterDose`).
    public func settingHotWaterDose(_ dose: Double, doseIndex: DoseIndex) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMHotWaterDose" }),
              case .hotWaterDose(let s) = w.kind else { return self }
        let doses = s.doses.map { d in
            d.doseIndex == doseIndex
                ? DoseSetting(doseIndex: d.doseIndex, dose: dose, doseMin: d.doseMin,
                              doseMax: d.doseMax, doseStep: d.doseStep)
                : d
        }
        let next = HotWaterDose(enabled: s.enabled, enabledSupported: s.enabledSupported, doses: doses)
        return replacing(Widget(code: w.code, index: w.index, kind: .hotWaterDose(next)))
    }

    /// Optimistically set a group's dose mode (after `setGroupDoseMode`).
    public func settingGroupDoseMode(_ mode: DoseMode, groupIndex: Int = 1) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMGroupDoses" && $0.index == groupIndex }),
              case .groupDoses(let s) = w.kind else { return self }
        let next = GroupDoses(availableModes: s.availableModes, mode: mode, doses: s.doses,
                              profile: s.profile,
                              mirrorWithGroup1Supported: s.mirrorWithGroup1Supported,
                              mirrorWithGroup1: s.mirrorWithGroup1,
                              mirrorWithGroup1NotEffective: s.mirrorWithGroup1NotEffective,
                              continuousDoseSupported: s.continuousDoseSupported,
                              continuousDose: s.continuousDose,
                              brewingPressureSupported: s.brewingPressureSupported,
                              brewingPressure: s.brewingPressure)
        return replacing(Widget(code: w.code, index: w.index, kind: .groupDoses(next)))
    }

    /// Optimistically set one group dose value for a mode (after `setGroupDose`).
    public func settingGroupDose(mode: DoseMode, doseIndex: DoseIndex, dose: Double, groupIndex: Int = 1) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMGroupDoses" && $0.index == groupIndex }),
              case .groupDoses(let s) = w.kind else { return self }
        func updated(_ list: [DoseSetting], for target: DoseMode) -> [DoseSetting] {
            guard mode == target else { return list }
            return list.map { d in
                d.doseIndex == doseIndex
                    ? DoseSetting(doseIndex: d.doseIndex, dose: dose, doseMin: d.doseMin,
                                  doseMax: d.doseMax, doseStep: d.doseStep)
                    : d
            }
        }
        let doses = DosePulses(pulsesType: updated(s.doses.pulsesType, for: .pulses),
                               manualType: updated(s.doses.manualType, for: .manual),
                               massType: updated(s.doses.massType, for: .mass),
                               brewRatioType: updated(s.doses.brewRatioType, for: .brewRatio),
                               profileType: updated(s.doses.profileType, for: .profile))
        let next = GroupDoses(availableModes: s.availableModes, mode: s.mode, doses: doses,
                              profile: s.profile,
                              mirrorWithGroup1Supported: s.mirrorWithGroup1Supported,
                              mirrorWithGroup1: s.mirrorWithGroup1,
                              mirrorWithGroup1NotEffective: s.mirrorWithGroup1NotEffective,
                              continuousDoseSupported: s.continuousDoseSupported,
                              continuousDose: s.continuousDose,
                              brewingPressureSupported: s.brewingPressureSupported,
                              brewingPressure: s.brewingPressure)
        return replacing(Widget(code: w.code, index: w.index, kind: .groupDoses(next)))
    }

    /// Optimistically set a group's brewing pressure (after `setBrewingPressure`).
    public func settingBrewingPressure(_ pressure: Double, groupIndex: Int = 1) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "CMGroupDoses" && $0.index == groupIndex }),
              case .groupDoses(let s) = w.kind, let current = s.brewingPressure else { return self }
        let next = GroupDoses(availableModes: s.availableModes, mode: s.mode, doses: s.doses,
                              profile: s.profile,
                              mirrorWithGroup1Supported: s.mirrorWithGroup1Supported,
                              mirrorWithGroup1: s.mirrorWithGroup1,
                              mirrorWithGroup1NotEffective: s.mirrorWithGroup1NotEffective,
                              continuousDoseSupported: s.continuousDoseSupported,
                              continuousDose: s.continuousDose,
                              brewingPressureSupported: s.brewingPressureSupported,
                              brewingPressure: BrewingPressureSettings(
                                pressure: pressure, pressureMin: current.pressureMin,
                                pressureMax: current.pressureMax, pressureStep: current.pressureStep))
        return replacing(Widget(code: w.code, index: w.index, kind: .groupDoses(next)))
    }

    /// Optimistically set the grinder running mode (after `setGrinderPower`).
    public func settingGrinderMode(_ mode: GrinderMode) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "GMachineStatus" }),
              case .grinderStatus(let s) = w.kind else { return self }
        let next = GrinderMachineStatus(status: s.status, availableModes: s.availableModes,
                                        mode: mode, readyStartTime: s.readyStartTime)
        return replacing(Widget(code: w.code, index: w.index, kind: .grinderStatus(next)))
    }

    /// Optimistically set the grind-with mode (after `setGrinderGrindWith`, Swan).
    public func settingGrinderGrindWith(_ mode: GrinderGrindWithMode) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "GGrindWith" }),
              case .grinderGrindWith = w.kind else { return self }
        return replacing(Widget(code: w.code, index: w.index, kind: .grinderGrindWith(GrinderGrindWith(mode: mode))))
    }

    /// Optimistically set a grinder dose (and optionally its speed level),
    /// updating the `GDoses` dose list, its `speedLevels`, and the matching
    /// `GSpeed` entry — mirroring pylamarzocco's `LaMarzoccoGrinder.set_dose`.
    public func settingGrinderDose(
        doseIndex: DoseIndex, dose: Double, mode: GrinderDoseMode, speedLevel: GrinderSpeedLevel? = nil
    ) -> Dashboard {
        var result = self
        if let w = result.widgets.first(where: { $0.code == "GDoses" }),
           case .grinderDoses(let s) = w.kind {
            func updated(_ list: [GrinderDoseSetting], for target: GrinderDoseMode) -> [GrinderDoseSetting] {
                guard mode == target else { return list }
                return list.map { d in
                    d.doseIndex == doseIndex
                        ? GrinderDoseSetting(doseIndex: d.doseIndex, dose: dose, doseMin: d.doseMin,
                                             doseMax: d.doseMax, doseStep: d.doseStep,
                                             speedAutoSupported: d.speedAutoSupported, speedAuto: d.speedAuto)
                        : d
                }
            }
            let doses = GrinderDosesSettings(timeType: updated(s.doses.timeType, for: .time),
                                             massType: updated(s.doses.massType, for: .mass),
                                             revType: updated(s.doses.revType, for: .rev))
            let speedLevels = s.speedLevels.map { levels in
                levels.map { entry in
                    if let speedLevel, entry.doseIndex == doseIndex {
                        return GrinderSpeedLevelSetting(doseIndex: entry.doseIndex, level: speedLevel)
                    }
                    return entry
                }
            }
            let next = GrinderDoses(scaleConnected: s.scaleConnected, mode: s.mode, doses: doses,
                                    speedLevelsSupported: s.speedLevelsSupported, speedLevels: speedLevels)
            result = result.replacing(Widget(code: w.code, index: w.index, kind: .grinderDoses(next)))
        }
        if let speedLevel,
           let w = result.widgets.first(where: { $0.code == "GSpeed" }),
           case .grinderSpeed(let s) = w.kind,
           let entry = s.doses[doseIndex.rawValue] {
            var doses = s.doses
            doses[doseIndex.rawValue] = GrinderSpeedDose(level: speedLevel, autoEnabled: entry.autoEnabled,
                                                         groupIndex: entry.groupIndex)
            let next = GrinderSpeed(doses: doses, groupsNumber: s.groupsNumber,
                                    speedAutoSupported: s.speedAutoSupported, speedAuto: s.speedAuto)
            result = result.replacing(Widget(code: w.code, index: w.index, kind: .grinderSpeed(next)))
        }
        return result
    }

    /// Optimistically set the "more dose" revolutions (after `setGrinderMoreDose`, Swan).
    public func settingGrinderMoreDose(_ revolutions: Double) -> Dashboard {
        guard let w = widgets.first(where: { $0.code == "GMoreDose" }),
              case .grinderMoreDose(let s) = w.kind else { return self }
        let next = GrinderMoreDose(revolutions: revolutions, revolutionsMin: s.revolutionsMin,
                                   revolutionsMax: s.revolutionsMax, revolutionsStep: s.revolutionsStep)
        return replacing(Widget(code: w.code, index: w.index, kind: .grinderMoreDose(next)))
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
