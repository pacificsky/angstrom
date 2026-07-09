import Foundation
import Observation
import Angstrom

/// An observable, retained view of a single La Marzocco machine, built on top of
/// the stateless `LaMarzoccoCloudClient` for SwiftUI/UI binding.
///
/// It holds the last-known ``dashboard``/``settings``/``schedule``, merges live
/// websocket pushes into ``dashboard`` while ``start()``ed, and applies
/// optimistic updates after a command is accepted so the UI reflects a change
/// before the authoritative push arrives. Model-gated commands throw
/// `LaMarzoccoError.unsupportedModel` on machines that don't support them.
///
/// All state is `@MainActor`-isolated; the underlying client remains an `actor`.
@MainActor
@Observable
public final class LaMarzoccoMachine {
    /// The machine's serial number.
    public let serialNumber: String

    private let client: LaMarzoccoCloudClient

    /// The last-known dashboard (typed widgets + identity). Updated by
    /// ``refreshDashboard()``, live websocket pushes, and optimistic command
    /// updates.
    public private(set) var dashboard: Dashboard?
    /// The last-known settings (connectivity, plumb-in, firmware).
    public private(set) var settings: MachineSettings?
    /// The last-known scheduling config (smart standby, wake-ups).
    public private(set) var schedule: MachineSchedule?
    /// The last-known statistics (refreshed on demand; not part of snapshots).
    public private(set) var statistics: ThingStatistics?
    /// Whether live updates are currently subscribed — i.e. between a successful
    /// ``start()`` and ``stop()``. The underlying socket may transiently drop and
    /// auto-reconnect while this stays `true`; it reflects the *subscription*, not
    /// the moment-to-moment socket connection — see ``isConnected`` for that.
    public private(set) var isLive = false
    /// Whether the live websocket is *actually* connected right now. Unlike
    /// ``isLive`` this flips `false` during silent drops and zombie-socket
    /// gaps while auto-reconnect works, so UIs can show "live" vs "stale"
    /// honestly.
    public private(set) var isConnected = false
    /// When ``dashboard`` last changed from the cloud — a REST refresh or an
    /// applied websocket push. `nil` until the first of either. Lets UIs show
    /// "last update Nm ago" instead of trusting a stale value.
    public private(set) var lastUpdateAt: Date?
    /// The most recent error from a refresh, command, or the live connection.
    /// Cleared automatically when a subsequent operation succeeds.
    public private(set) var lastError: Error?

    private var updateTask: Task<Void, Never>?
    /// Mirrors the client's connection events into ``isConnected`` and re-fetches
    /// the dashboard after every reconnect (the push feed is change-only, so a
    /// transition missed while the socket was down is never re-pushed).
    private var connectionTask: Task<Void, Never>?
    /// Synchronously-set guard so two interleaved ``start()`` calls can't both
    /// register a listener before ``updateTask`` is assigned.
    private var isStarting = false
    /// Bumped on every ``start()``/``stop()`` so a superseded update task's
    /// teardown can't clobber state owned by a newer session.
    private var liveGeneration = 0

    /// Create a machine view. Pass a previously persisted ``MachineSnapshot`` to
    /// render stale state immediately on launch (it is adopted only if its serial
    /// matches).
    public init(
        serialNumber: String,
        client: LaMarzoccoCloudClient,
        snapshot: MachineSnapshot? = nil
    ) {
        self.serialNumber = serialNumber
        self.client = client
        if let snapshot, snapshot.serialNumber == serialNumber {
            self.dashboard = snapshot.dashboard
            self.settings = snapshot.settings
            self.schedule = snapshot.schedule
        }
    }

    /// Test seam: the underlying client, so tests can inject a mock websocket.
    var clientForTesting: LaMarzoccoCloudClient { client }

    // MARK: - Derived

    /// The resolved device model, from whichever loaded payload carries identity.
    ///
    /// Note: this intentionally falls back to settings/schedule identity, whereas
    /// pylamarzocco gates strictly on the dashboard model. The resolved value is
    /// consistent across payloads for a given machine, so model-gated commands
    /// work as soon as *any* identity-bearing payload has loaded.
    public var model: Model? {
        dashboard?.machine.model ?? settings?.machine.model ?? schedule?.machine.model
    }

    /// Whether the *machine* is reachable from La Marzocco's cloud — distinct
    /// from ``isConnected``, which reports *our* websocket. `nil` until the
    /// first ``dashboard`` exists, then tracks the dashboard's `connected` flag
    /// through REST refreshes and websocket pushes.
    ///
    /// When the machine drops off the cloud (switched off, unplugged, lost
    /// Wi-Fi), the server keeps serving a husk dashboard whose status widget is
    /// frozen at the machine's last-reported mode — so ``powerState`` keeps
    /// reporting that stale mode. UIs must gate power/status displays on this
    /// flag. Note: routine pushes carry `connected: true`, but a push announcing
    /// the *disconnect* has not been observed in wire captures — until confirmed,
    /// assume a machine going offline is only discovered on the next REST
    /// refresh (e.g. ``refreshDashboard()``), not via the live feed.
    public var isMachineConnected: Bool? { dashboard?.machine.isConnected }

    /// When the machine last (re)connected to La Marzocco's cloud, per the
    /// dashboard's `connectionDate`. While ``isMachineConnected`` is `false`
    /// this is the moment of the *last* connection — i.e. how stale the frozen
    /// dashboard is. `nil` until the first ``dashboard`` exists.
    public var machineLastConnectionDate: Date? { dashboard?.machine.connectionDate }

    /// Power state derived from the dashboard's machine- or grinder-status widget.
    ///
    /// This is the machine's *last-reported* mode: while ``isMachineConnected``
    /// is `false` the underlying widget is frozen at whatever the machine said
    /// before it dropped off the cloud, so this value is stale — gate on
    /// ``isMachineConnected`` before presenting it as live status.
    public var powerState: PowerState {
        // The Strada X reports CMMachineGroupStatus instead of CMMachineStatus.
        if let mode = dashboard?.machineStatus?.mode ?? dashboard?.machineGroupStatus?.mode {
            switch mode {
            case .brewing: return .on
            case .standby: return .off
            case .eco: return .other("EcoMode")
            case .other(let v): return .other(v)
            }
        }
        if let mode = dashboard?.grinderStatus?.mode {
            switch mode {
            case .grinding, .poweredOn: return .on
            case .standby: return .off
            case .other(let v): return .other(v)
            }
        }
        return .unknown
    }

    /// A snapshot of the current state, suitable for persistence.
    public var snapshot: MachineSnapshot {
        MachineSnapshot(serialNumber: serialNumber, dashboard: dashboard,
                        settings: settings, schedule: schedule)
    }

    // MARK: - Refresh

    @discardableResult
    public func refreshDashboard() async throws -> Dashboard {
        try await capturing {
            let value = try await client.dashboard(serial: serialNumber)
            dashboard = value
            lastUpdateAt = Date()
            return value
        }
    }

    @discardableResult
    public func refreshSettings() async throws -> MachineSettings {
        try await capturing {
            let value = try await client.settings(serial: serialNumber)
            settings = value
            return value
        }
    }

    @discardableResult
    public func refreshSchedule() async throws -> MachineSchedule {
        try await capturing {
            let value = try await client.schedule(serial: serialNumber)
            schedule = value
            return value
        }
    }

    @discardableResult
    public func refreshStatistics() async throws -> ThingStatistics {
        try await capturing {
            let value = try await client.statistics(serial: serialNumber)
            statistics = value
            return value
        }
    }

    /// Refresh dashboard, settings, and schedule concurrently.
    public func refreshAll() async throws {
        try await capturing {
            async let d = client.dashboard(serial: serialNumber)
            async let s = client.settings(serial: serialNumber)
            async let sc = client.schedule(serial: serialNumber)
            let (dashboard, settings, schedule) = try await (d, s, sc)
            self.dashboard = dashboard
            self.settings = settings
            self.schedule = schedule
            self.lastUpdateAt = Date()
        }
    }

    // MARK: - Live updates

    /// Open the live websocket and merge pushed updates into ``dashboard`` until
    /// ``stop()``. Returns once the first connection is established.
    ///
    /// A pushed update carries no machine identity, so it can only be merged onto
    /// an existing ``dashboard``: if you ``start()`` before a ``refreshDashboard()``
    /// (or seeding a snapshot), early pushes are dropped until a dashboard exists.
    /// Call ``refreshDashboard()`` (or ``refreshAll()``) first.
    public func start() async throws {
        guard updateTask == nil, !isStarting else { return }
        isStarting = true
        liveGeneration += 1
        let generation = liveGeneration
        defer { isStarting = false }

        // Register the listeners before connecting so no early push or the
        // initial connection event is missed.
        let stream = await client.dashboardUpdates()
        let events = await client.connectionEvents()
        let task = Task { [weak self] in
            for await update in stream {
                guard let self else { return }
                if let current = self.dashboard {
                    self.dashboard = current.applying(update)
                    self.lastUpdateAt = Date()
                }
            }
            // Stream ended (disconnect). Only tear down if we still own the session.
            guard let self, self.liveGeneration == generation else { return }
            self.isLive = false
            self.updateTask = nil
        }
        updateTask = task
        let connTask = Task { [weak self] in
            // The initial snapshot is the caller's job (refresh before start());
            // only *re*connects trigger an automatic re-fetch, reconciling any
            // transition the change-only feed dropped while the socket was down.
            var sawInitialConnect = false
            for await event in events {
                guard let self else { return }
                switch event {
                case .connected:
                    self.isConnected = true
                    if sawInitialConnect {
                        _ = try? await self.refreshDashboard()
                    }
                    sawInitialConnect = true
                case .disconnected:
                    self.isConnected = false
                }
            }
            guard let self, self.liveGeneration == generation else { return }
            self.isConnected = false
        }
        connectionTask = connTask
        do {
            try await client.connectWebSocket(serial: serialNumber)
            isLive = true
        } catch {
            task.cancel()
            connTask.cancel()
            if updateTask == task { updateTask = nil }
            if connectionTask == connTask { connectionTask = nil }
            lastError = error
            throw error
        }
    }

    /// Disconnect the live websocket and stop merging updates.
    public func stop() async {
        liveGeneration += 1 // supersede the running task's teardown
        updateTask?.cancel()
        updateTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        await client.disconnectWebSocket()
        isLive = false
        isConnected = false
    }

    // MARK: - Commands (forward to client, with optimistic local updates)

    @discardableResult
    public func setPower(on: Bool) async throws -> CommandResponse {
        let response = try await capturing { try await client.setPower(serial: serialNumber, on: on) }
        dashboard = dashboard?.settingMachineMode(on ? .brewing : .standby)
        return response
    }

    @discardableResult
    public func setSteam(on: Bool) async throws -> CommandResponse {
        let response = try await capturing { try await client.setSteam(serial: serialNumber, on: on) }
        dashboard = dashboard?.settingSteamEnabled(on)
        return response
    }

    @discardableResult
    public func setSteamTargetLevel(_ level: SteamLevel) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.steamLevelModels, "steam level")
            return try await client.setSteamTargetLevel(serial: serialNumber, level)
        }
        dashboard = dashboard?.settingSteamTargetLevel(level)
        return response
    }

    @discardableResult
    public func setCoffeeTargetTemperature(celsius: Double) async throws -> CommandResponse {
        let response = try await capturing { try await client.setCoffeeTargetTemperature(serial: serialNumber, celsius: celsius) }
        dashboard = dashboard?.settingCoffeeTargetTemperature(celsius)
        return response
    }

    @discardableResult
    public func setSteamTargetTemperature(celsius: Double) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.steamTemperatureModels, "steam temperature")
            return try await client.setSteamTargetTemperature(serial: serialNumber, celsius: celsius)
        }
        dashboard = dashboard?.settingSteamTargetTemperature(celsius)
        return response
    }

    @discardableResult
    public func setBrewByWeightMode(_ mode: DoseMode) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.brewByWeightModels, "brew by weight")
            return try await client.setBrewByWeightMode(serial: serialNumber, mode)
        }
        dashboard = dashboard?.settingBrewByWeightMode(mode)
        return response
    }

    @discardableResult
    public func setBrewByWeightDoses(dose1: Double, dose2: Double) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.brewByWeightModels, "brew by weight")
            return try await client.setBrewByWeightDoses(serial: serialNumber, dose1: dose1, dose2: dose2)
        }
        dashboard = dashboard?.settingBrewByWeightDoses(dose1: dose1, dose2: dose2)
        return response
    }

    /// Enable or disable a grinder's barista light (ignored while in standby).
    @discardableResult
    public func setGrinderBaristaLight(on: Bool) async throws -> CommandResponse {
        let response = try await capturing { try await client.setGrinderBaristaLight(serial: serialNumber, on: on) }
        dashboard = dashboard?.settingGrinderBaristaLight(on)
        return response
    }

    @discardableResult
    public func startBackflush() async throws -> CommandResponse {
        try await capturing { try await client.startBackflush(serial: serialNumber) }
    }

    // MARK: Strada X commands (upstream v2.4.2)

    /// Set the operating mode directly (the Strada X accepts `EcoMode` too).
    @discardableResult
    public func setMode(_ mode: MachineMode) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.stradaXModels, "machine mode")
            return try await client.setMode(serial: serialNumber, mode)
        }
        dashboard = dashboard?.settingMachineMode(mode)
        return response
    }

    @discardableResult
    public func setAutoFlush(on: Bool) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.stradaXModels, "auto flush")
            return try await client.setAutoFlush(serial: serialNumber, on: on)
        }
        dashboard = dashboard?.settingAutoFlush(on)
        return response
    }

    @discardableResult
    public func setSteamFlush(on: Bool) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.stradaXModels, "steam flush")
            return try await client.setSteamFlush(serial: serialNumber, on: on)
        }
        dashboard = dashboard?.settingSteamFlush(on)
        return response
    }

    @discardableResult
    public func setRinseFlush(on: Bool) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.stradaXModels, "rinse flush")
            return try await client.setRinseFlush(serial: serialNumber, on: on)
        }
        dashboard = dashboard?.settingRinseFlushEnabled(on)
        return response
    }

    @discardableResult
    public func setRinseFlushTime(seconds: Double) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.stradaXModels, "rinse flush time")
            return try await client.setRinseFlushTime(serial: serialNumber, seconds: seconds)
        }
        dashboard = dashboard?.settingRinseFlushTime(seconds)
        return response
    }

    @discardableResult
    public func setHotWaterDoseEnabled(on: Bool) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.stradaXModels, "hot water dose enable")
            return try await client.setHotWaterDoseEnabled(serial: serialNumber, on: on)
        }
        dashboard = dashboard?.settingHotWaterDoseEnabled(on)
        return response
    }

    @discardableResult
    public func setHotWaterDose(dose: Double, doseIndex: DoseIndex) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.groupDoseModels, "hot water dose")
            return try await client.setHotWaterDose(serial: serialNumber, dose: dose, doseIndex: doseIndex)
        }
        dashboard = dashboard?.settingHotWaterDose(dose, doseIndex: doseIndex)
        return response
    }

    /// Enable or disable the cup warmer (ungated, matching pylamarzocco).
    @discardableResult
    public func setCupWarmer(on: Bool) async throws -> CommandResponse {
        try await capturing { try await client.setCupWarmer(serial: serialNumber, on: on) }
    }

    /// Enable or disable plumb-in mode (ungated, matching pylamarzocco).
    @discardableResult
    public func setPlumbIn(on: Bool) async throws -> CommandResponse {
        try await capturing { try await client.setPlumbIn(serial: serialNumber, on: on) }
    }

    @discardableResult
    public func setGroupMode(_ mode: MachineMode, groupIndex: Int = 1) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.stradaXModels, "group mode")
            return try await client.setGroupMode(serial: serialNumber, mode, groupIndex: groupIndex)
        }
        dashboard = dashboard?.settingGroupMode(mode, groupIndex: groupIndex)
        return response
    }

    @discardableResult
    public func setCoffeeBoilerEnabled(on: Bool, boilerIndex: Int = 1) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.stradaXModels, "coffee boiler enable")
            return try await client.setCoffeeBoilerEnabled(serial: serialNumber, on: on, boilerIndex: boilerIndex)
        }
        dashboard = dashboard?.settingCoffeeBoilerEnabled(on)
        return response
    }

    @discardableResult
    public func setGroupDoseMode(_ mode: DoseMode, groupIndex: Int = 1) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.groupDoseModels, "group dose mode")
            return try await client.setGroupDoseMode(serial: serialNumber, mode, groupIndex: groupIndex)
        }
        dashboard = dashboard?.settingGroupDoseMode(mode, groupIndex: groupIndex)
        return response
    }

    @discardableResult
    public func setGroupDose(mode: DoseMode, doseIndex: DoseIndex, dose: Double, groupIndex: Int = 1) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.groupDoseModels, "group dose")
            return try await client.setGroupDose(serial: serialNumber, mode: mode, doseIndex: doseIndex,
                                                 dose: dose, groupIndex: groupIndex)
        }
        dashboard = dashboard?.settingGroupDose(mode: mode, doseIndex: doseIndex, dose: dose, groupIndex: groupIndex)
        return response
    }

    /// Set the brewing pressure of a group. Throws
    /// `LaMarzoccoError.operationNotAvailable` when the group's current dose
    /// mode doesn't support it (upstream `OperationNotAvailable` parity).
    @discardableResult
    public func setBrewingPressure(pressure: Double, groupIndex: Int = 1) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.stradaXModels, "brewing pressure")
            if let groupDoses = dashboard?.groupDoses, !groupDoses.brewingPressureSupported {
                throw LaMarzoccoError.operationNotAvailable(
                    "brewing pressure is not supported in the current dose mode (\(groupDoses.mode.rawValue))")
            }
            return try await client.setBrewingPressure(serial: serialNumber, pressure: pressure, groupIndex: groupIndex)
        }
        dashboard = dashboard?.settingBrewingPressure(pressure, groupIndex: groupIndex)
        return response
    }

    @discardableResult
    public func setContinuousDoseEnabled(on: Bool, groupIndex: Int = 1) async throws -> CommandResponse {
        try await capturing {
            try requireModel(Self.groupDoseModels, "continuous dose enable")
            return try await client.setContinuousDoseEnabled(serial: serialNumber, on: on, groupIndex: groupIndex)
        }
    }

    @discardableResult
    public func setContinuousDose(seconds: Double, groupIndex: Int = 1) async throws -> CommandResponse {
        try await capturing {
            try requireModel(Self.groupDoseModels, "continuous dose")
            return try await client.setContinuousDose(serial: serialNumber, seconds: seconds, groupIndex: groupIndex)
        }
    }

    /// Make a group mirror group 1's doses. `groupIndex` must be 2 or 3
    /// (group 1 cannot mirror itself).
    @discardableResult
    public func setMirrorGroup1(on: Bool, groupIndex: Int = 2) async throws -> CommandResponse {
        try await capturing {
            try requireModel(Self.stradaXModels, "mirror group 1")
            guard (2...3).contains(groupIndex) else {
                throw LaMarzoccoError.operationNotAvailable("groupIndex must be 2 or 3")
            }
            return try await client.setMirrorGroup1(serial: serialNumber, on: on, groupIndex: groupIndex)
        }
    }

    // MARK: Grinder commands (upstream v2.4.2)

    /// Wake the grinder (`GrindingMode`) or send it to standby.
    @discardableResult
    public func setGrinderPower(on: Bool) async throws -> CommandResponse {
        let mode: GrinderMode = on ? .grinding : .standby
        let response = try await capturing { try await client.setGrinderMode(serial: serialNumber, mode) }
        dashboard = dashboard?.settingGrinderMode(mode)
        return response
    }

    /// Set the grind-with mode (Swan).
    @discardableResult
    public func setGrinderGrindWith(_ mode: GrinderGrindWithMode) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.swanGrinderModels, "grind-with mode")
            return try await client.setGrinderGrindWith(serial: serialNumber, mode)
        }
        dashboard = dashboard?.settingGrinderGrindWith(mode)
        return response
    }

    /// Set a grinder dose (and optionally its speed level). When `mode` is nil
    /// the dashboard's current dose mode is used (falling back to revolutions),
    /// matching pylamarzocco's `LaMarzoccoGrinder.set_dose`.
    @discardableResult
    public func setGrinderDose(
        doseIndex: DoseIndex, dose: Double,
        mode: GrinderDoseMode? = nil, speedLevel: GrinderSpeedLevel? = nil
    ) async throws -> CommandResponse {
        let resolvedMode = mode ?? dashboard?.grinderDoses?.mode ?? .rev
        let response = try await capturing {
            try await client.setGrinderDose(serial: serialNumber, doseIndex: doseIndex, dose: dose,
                                            mode: resolvedMode, speedLevel: speedLevel)
        }
        dashboard = dashboard?.settingGrinderDose(doseIndex: doseIndex, dose: dose,
                                                  mode: resolvedMode, speedLevel: speedLevel)
        return response
    }

    /// Set the additional "more dose" revolutions (Swan).
    @discardableResult
    public func setGrinderMoreDose(revolutions: Double) async throws -> CommandResponse {
        let response = try await capturing {
            try requireModel(Self.swanGrinderModels, "more dose")
            return try await client.setGrinderMoreDose(serial: serialNumber, revolutions: revolutions)
        }
        dashboard = dashboard?.settingGrinderMoreDose(revolutions)
        return response
    }

    @discardableResult
    public func setPreExtractionMode(_ mode: PreExtractionMode) async throws -> CommandResponse {
        try await capturing { try await client.setPreExtractionMode(serial: serialNumber, mode) }
    }

    @discardableResult
    public func setPreExtractionTimes(secondsIn: Double, secondsOut: Double) async throws -> CommandResponse {
        try await capturing { try await client.setPreExtractionTimes(serial: serialNumber, secondsIn: secondsIn, secondsOut: secondsOut) }
    }

    /// Configure standby. Mirrors `pylamarzocco`'s `set_smart_standby`: on machines
    /// whose scheduling payload reports ``MachineSchedule/autoStandBySupported``,
    /// this dispatches the auto-standby command with an `"HH:MM"` (or `"Off"`)
    /// mode string instead of the smart-standby command, since those machines
    /// don't honor `CoffeeMachineSettingSmartStandBy`.
    @discardableResult
    public func setSmartStandby(enabled: Bool, minutes: Int, after: SmartStandbyAfter) async throws -> CommandResponse {
        if schedule?.autoStandBySupported == true {
            let mode = enabled ? String(format: "%02d:%02d", minutes / 60, minutes % 60) : "Off"
            return try await setAutoStandby(mode: mode)
        }
        return try await capturing { try await client.setSmartStandby(serial: serialNumber, enabled: enabled, minutes: minutes, after: after) }
    }

    /// Set the auto-standby mode string directly (`"HH:MM"` / `"Off"`). Most
    /// callers want ``setSmartStandby(enabled:minutes:after:)``, which picks this
    /// path automatically on machines that require it.
    @discardableResult
    public func setAutoStandby(mode: String) async throws -> CommandResponse {
        try await capturing { try await client.setAutoStandby(serial: serialNumber, mode: mode) }
    }

    @discardableResult
    public func setWakeUpSchedule(_ schedule: WakeUpSchedule) async throws -> CommandResponse {
        try await capturing { try await client.setWakeUpSchedule(serial: serialNumber, schedule) }
    }

    @discardableResult
    public func deleteWakeUpSchedule(id: String) async throws -> CommandResponse {
        try await capturing { try await client.deleteWakeUpSchedule(serial: serialNumber, id: id) }
    }

    // MARK: - Firmware

    public func firmwareUpdateStatus() async throws -> UpdateDetails {
        try await capturing { try await client.firmwareUpdateStatus(serial: serialNumber) }
    }

    @discardableResult
    public func installFirmwareUpdate() async throws -> UpdateDetails {
        try await capturing { try await client.installFirmwareUpdate(serial: serialNumber) }
    }

    // MARK: - Model gating

    static let steamLevelModels: Set<Model> = [.lineaMicra, .lineaMiniR]
    static let steamTemperatureModels: Set<Model> = [.gs3, .gs3AV, .gs3MP, .stradaX]
    static let brewByWeightModels: Set<Model> = [.lineaMini, .lineaMiniR]
    static let stradaXModels: Set<Model> = [.stradaX]
    /// Group-dose commands the GS3 AV also accepts (upstream `@models_supported`).
    static let groupDoseModels: Set<Model> = [.stradaX, .gs3AV]
    static let swanGrinderModels: Set<Model> = [.swan]

    private func requireModel(_ supported: Set<Model>, _ what: String) throws {
        guard let model, supported.contains(model) else {
            let names = supported.map(\.displayName).sorted().joined(separator: ", ")
            throw LaMarzoccoError.unsupportedModel("\(what) is only supported on \(names)")
        }
    }

    // MARK: - Plumbing

    /// Run a throwing operation, recording any failure in ``lastError`` before
    /// rethrowing so observers can surface it, and clearing ``lastError`` on
    /// success so a stale error doesn't linger in the UI.
    private func capturing<T>(_ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            lastError = nil
            return value
        } catch {
            lastError = error
            throw error
        }
    }
}
