import Foundation
import Observation
import Angstrom

/// An observable, retained view of a single La Marzocco machine, built on top of
/// the stateless ``LaMarzoccoCloudClient`` for SwiftUI/UI binding.
///
/// It holds the last-known ``dashboard``/``settings``/``schedule``, merges live
/// websocket pushes into ``dashboard`` while ``start()``ed, and applies
/// optimistic updates after a command is accepted so the UI reflects a change
/// before the authoritative push arrives. Model-gated commands throw
/// ``LaMarzoccoError/unsupportedModel(_:)`` on machines that don't support them.
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
    /// the moment-to-moment socket connection.
    public private(set) var isLive = false
    /// The most recent error from a refresh, command, or the live connection.
    /// Cleared automatically when a subsequent operation succeeds.
    public private(set) var lastError: Error?

    private var updateTask: Task<Void, Never>?
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

    /// Power state derived from the dashboard's machine- or grinder-status widget.
    public var powerState: PowerState {
        if let mode = dashboard?.machineStatus?.mode {
            switch mode {
            case .brewing: return .on
            case .standby: return .off
            case .eco: return .other("EcoMode")
            case .other(let v): return .other(v)
            }
        }
        if let mode = dashboard?.grinderStatus?.mode {
            switch mode {
            case .grinding: return .on
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

        // Register the listener before connecting so no early push is missed.
        let stream = await client.dashboardUpdates()
        let task = Task { [weak self] in
            for await update in stream {
                guard let self else { return }
                if let current = self.dashboard {
                    self.dashboard = current.applying(update)
                }
            }
            // Stream ended (disconnect). Only tear down if we still own the session.
            guard let self, self.liveGeneration == generation else { return }
            self.isLive = false
            self.updateTask = nil
        }
        updateTask = task
        do {
            try await client.connectWebSocket(serial: serialNumber)
            isLive = true
        } catch {
            task.cancel()
            if updateTask == task { updateTask = nil }
            lastError = error
            throw error
        }
    }

    /// Disconnect the live websocket and stop merging updates.
    public func stop() async {
        liveGeneration += 1 // supersede the running task's teardown
        updateTask?.cancel()
        updateTask = nil
        await client.disconnectWebSocket()
        isLive = false
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

    @discardableResult
    public func setPreExtractionMode(_ mode: PreExtractionMode) async throws -> CommandResponse {
        try await capturing { try await client.setPreExtractionMode(serial: serialNumber, mode) }
    }

    @discardableResult
    public func setPreExtractionTimes(secondsIn: Double, secondsOut: Double) async throws -> CommandResponse {
        try await capturing { try await client.setPreExtractionTimes(serial: serialNumber, secondsIn: secondsIn, secondsOut: secondsOut) }
    }

    @discardableResult
    public func setSmartStandby(enabled: Bool, minutes: Int, after: SmartStandbyAfter) async throws -> CommandResponse {
        try await capturing { try await client.setSmartStandby(serial: serialNumber, enabled: enabled, minutes: minutes, after: after) }
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
    static let steamTemperatureModels: Set<Model> = [.gs3, .gs3AV, .gs3MP]
    static let brewByWeightModels: Set<Model> = [.lineaMini, .lineaMiniR]

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
