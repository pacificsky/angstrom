import Angstrom

extension LaMarzoccoMachine {
    /// Build the dashboard from Bluetooth reads (SPEC §4.17, upstream `get_dashboard_from_bluetooth`).
    ///
    /// Reads, in this order, the machine mode, the plumb-in state, the water tank and the boilers, then
    /// updates the machine status, coffee boiler, steam boiler and no-water widgets of the base dashboard
    /// (creating it, and any missing widget, when absent) and re-renders ``dashboard`` with any active
    /// shot-counter overlay.
    ///
    /// - When the model is unknown (`nil` or `.unknown`), the machine's capabilities are read first
    ///   (``refreshModelFromBluetooth()``); there is no silent Linea Micra default (D17). With a known
    ///   model, capabilities are not read.
    /// - A plumb-in reply that cannot be decoded counts as "not plumbed in" (older firmware might not
    ///   know this setting); every other error propagates.
    /// - Any read error propagates with no change to the dashboard, and never falls back to the cloud.
    /// - It doesn't stamp ``lastUpdateAt`` (a cloud freshness signal) and leaves ``settings``,
    ///   ``schedule`` and the machine's identity and cloud connectivity untouched.
    ///
    /// - Like every other throwing operation on the machine (SPEC §4.15), a failure — the missing-client
    ///   error included — is recorded in ``lastError`` before it is rethrown, and a success clears it.
    ///
    /// - Returns: The rendered ``dashboard`` (base + the Bluetooth brewing overlay).
    /// - Throws: `LaMarzoccoError.bluetoothConnectionFailed("Bluetooth client not initialized")` without a
    ///   Bluetooth client; otherwise whatever the Bluetooth reads throw.
    @discardableResult
    public func refreshDashboardFromBluetooth() async throws -> Dashboard {
        try await capturing { try await performRefreshDashboardFromBluetooth() }
    }

    /// Resolve the model from the machine's Bluetooth capabilities (upstream `get_model_info_from_bluetooth`).
    ///
    /// Reads `machineCapabilities` and sets only the base dashboard's `machine.model` to the reported
    /// family (creating an empty dashboard when there is none). No other capability field is stored.
    /// A failure — the missing-client error included — is recorded in ``lastError`` before it is
    /// rethrown, and a success clears it (SPEC §4.15).
    ///
    /// - Returns: The capabilities as read.
    /// - Throws: `LaMarzoccoError.bluetoothConnectionFailed("Bluetooth client not initialized")` without a
    ///   Bluetooth client; otherwise whatever the read throws (an unknown family is
    ///   `LaMarzoccoError.decoding`), with no change to the dashboard.
    @discardableResult
    public func refreshModelFromBluetooth() async throws -> BluetoothMachineCapabilities {
        try await capturing { try await performRefreshModelFromBluetooth() }
    }

    // MARK: - Uncaptured bodies
    //
    // The public methods wrap these in `capturing`. The dashboard refresh calls the model body directly
    // (not the public method), so `lastError` is written exactly once per public call: no intermediate
    // clear after a successful capabilities read that a later read failure would then overwrite.

    private func performRefreshDashboardFromBluetooth() async throws -> Dashboard {
        guard let bluetooth else {
            throw LaMarzoccoError.bluetoothConnectionFailed("Bluetooth client not initialized")
        }

        // Model resolution (D17): read the capabilities only when the model is unknown.
        let resolvedModel: Model
        if let known = model, !Self.isUnknown(known) {
            resolvedModel = known
        } else {
            resolvedModel = try await performRefreshModelFromBluetooth().family
        }

        // Reads, in upstream order (MACH:356-364). Any error propagates before any mutation.
        let machineMode = try await bluetooth.machineMode()
        let isPlumbedIn: Bool
        do {
            isPlumbedIn = try await bluetooth.isPlumbedIn()
        } catch let error as LaMarzoccoError {
            // Older firmware might not know this setting (MACH:359-362): an undecodable reply is
            // "not plumbed in". Every other error propagates.
            guard case .decoding = error else { throw error }
            isPlumbedIn = false
        }
        let tankStatus = try await bluetooth.tankStatus()
        let boilers = try await bluetooth.boilers()

        let state = BluetoothDashboardState(machineMode: machineMode, isPlumbedIn: isPlumbedIn,
                                            tankStatus: tankStatus, boilers: boilers)
        // Read the base only now, after the last suspension point, so nothing written meanwhile is lost.
        let base = baseDashboard
            ?? Dashboard(machine: Machine(serialNumber: serialNumber, model: resolvedModel), widgets: [])
        let updated = base.applyingBluetoothState(state, model: resolvedModel)
        setBaseDashboard(updated)
        return dashboard ?? updated
    }

    private func performRefreshModelFromBluetooth() async throws -> BluetoothMachineCapabilities {
        guard let bluetooth else {
            throw LaMarzoccoError.bluetoothConnectionFailed("Bluetooth client not initialized")
        }
        let capabilities = try await bluetooth.machineCapabilities()
        if let base = baseDashboard {
            var machine = base.machine
            machine.model = capabilities.family
            setBaseDashboard(Dashboard(machine: machine, widgets: base.widgets))
        } else {
            setBaseDashboard(Dashboard(machine: Machine(serialNumber: serialNumber, model: capabilities.family),
                                       widgets: []))
        }
        return capabilities
    }

    private static func isUnknown(_ model: Model) -> Bool {
        if case .unknown = model { return true }
        return false
    }
}
