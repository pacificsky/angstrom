import Foundation

extension LaMarzoccoBluetoothClient {
    // MARK: Reads
    //
    // Each read is one serialised request (`readSetting`), then a decode. The decode runs AFTER the
    // request gate is released, so a malformed response throws `.decoding` without dropping the link
    // (upstream's decorator does not catch `ValueError`/`JSONDecodeError`, `_bluetooth.py:129`).

    /// `get_machine_mode` (`_bluetooth.py:555-560`).
    public func machineMode() async throws -> MachineMode {
        try BluetoothResponseDecoder.machineMode(try await readSetting(.machineMode))
    }

    /// `get_machine_capabilities` (`_bluetooth.py:562-568`).
    public func machineCapabilities() async throws -> BluetoothMachineCapabilities {
        try BluetoothResponseDecoder.capabilities(try await readSetting(.machineCapabilities))
    }

    /// `get_tank_status` (`_bluetooth.py:570-575`).
    public func tankStatus() async throws -> Bool {
        try BluetoothResponseDecoder.bool(try await readSetting(.tankStatus), setting: .tankStatus)
    }

    /// `get_plumbed_in` (`_bluetooth.py:577-582`).
    public func isPlumbedIn() async throws -> Bool {
        try BluetoothResponseDecoder.bool(try await readSetting(.isPlumbedIn), setting: .isPlumbedIn)
    }

    /// `get_boilers` (`_bluetooth.py:584-588`).
    public func boilers() async throws -> [BluetoothBoilerDetails] {
        try BluetoothResponseDecoder.boilers(try await readSetting(.boilers))
    }

    /// `get_smart_standby_settings` (`_bluetooth.py:590-594`).
    public func smartStandby() async throws -> BluetoothSmartStandbyDetails {
        try BluetoothResponseDecoder.smartStandby(try await readSetting(.smartStandBy))
    }

    // MARK: Commands — a non-success status is RETURNED, not thrown.

    /// `set_power` (`_bluetooth.py:596-600`).
    @discardableResult public func setPower(on: Bool) async throws -> BluetoothCommandStatus {
        try await sendCommand(BluetoothCodec.machineChangeMode(on: on))
    }

    /// `set_steam` (`_bluetooth.py:602-608`).
    @discardableResult public func setSteam(on: Bool) async throws -> BluetoothCommandStatus {
        try await sendCommand(BluetoothCodec.settingBoilerEnable(steamOn: on))
    }

    /// `set_smart_standby` (`_bluetooth.py:610-618`).
    @discardableResult public func setSmartStandby(enabled: Bool, mode: SmartStandbyAfter,
                                                   minutes: Int) async throws -> BluetoothCommandStatus {
        try await sendCommand(BluetoothCodec.settingSmartStandby(minutes: minutes, mode: mode, enabled: enabled))
    }

    /// Throws `.operationNotAvailable("temperature must be finite")` for NaN/∞ (D21). No rounding.
    @discardableResult public func setTemperature(boiler: BluetoothBoilerType,
                                                  celsius: Double) async throws -> BluetoothCommandStatus {
        // D21: never send a value the firmware cannot parse; rejected before any I/O.
        guard celsius.isFinite else {
            throw LaMarzoccoError.operationNotAvailable("temperature must be finite")
        }
        return try await sendCommand(BluetoothCodec.settingBoilerTarget(boiler: boiler, celsius: celsius))
    }

    // MARK: Diagnostics

    /// Verbatim response bytes (before NUL truncation) of one read-setting request.
    public func rawRead(_ setting: BluetoothReadSetting) async throws -> Data {
        try await request(BluetoothConstants.readCharacteristic, frame: BluetoothCodec.readRequestFrame(setting))
    }

    // MARK: Internal helpers [+Requests]

    /// §4.4 — upstream's `disconnect_on_exception` wrapper around one write → read pair
    /// (`_bluetooth.py:114-136`, `655-700`).
    func request(_ characteristic: GATTUUID, frame: Data) async throws -> Data {
        // 1. Keep write → read pairs atomic so responses can't interleave.
        await acquire(.request)
        let response: Data
        do {
            response = try await exchange(characteristic, frame: frame)
        } catch {
            release(.request)
            // 7. Map, drop on a drop-class error (outside the gate), rethrow.
            let mapped = Self.mapTransportError(error, phase: .request)
            // A single failed command must not kill a running shot counter (`_bluetooth.py:130-134`).
            if Self.isDropClass(mapped) && !(shotCounterEnabled && link != nil) {
                dropConnectionInBackground()
            }
            throw mapped
        }
        release(.request)
        return response
    }

    /// §4.5 (`_bluetooth.py:712-747`, D7b/D7c).
    func resolve(_ characteristic: GATTUUID, on link: any BluetoothLink) async throws {
        // 1. Services changed on the peripheral: rediscover before trusting the table.
        if needsRediscovery {
            log?("Services of \(peripheral) changed, rediscovering characteristics")
            needsRediscovery = false
            do {
                try await rediscover(on: link)
            } catch {
                if self.link === link {
                    needsRediscovery = true
                }
                throw error
            }
        }
        // 2.
        if discovered.contains(characteristic) {
            return
        }
        // 3. One real rediscovery on the live link (upstream's `clear_cache()` + retry).
        log?("Characteristic \(characteristic.string) not found in cache, rediscovering and retrying.")
        try await rediscover(on: link)
        if discovered.contains(characteristic) {
            return
        }
        // 4. Still missing: drop unconditionally (even while the shot counter runs) and fail.
        log?("Could not find characteristic \(characteristic.string) on machine. Disconnecting.")
        dropConnectionInBackground()
        throw LaMarzoccoError.bluetoothConnectionFailed("Could not find characteristic \(characteristic.string) on machine.")
    }

    /// `__read_value_from_machine` without the JSON decode: the NUL-truncated UTF-8 response text.
    func readSetting(_ setting: BluetoothReadSetting) async throws -> String {
        let data = try await request(BluetoothConstants.readCharacteristic,
                                     frame: BluetoothCodec.readRequestFrame(setting))
        return try BluetoothCodec.responseText(data, context: setting.rawValue)
    }

    /// `__send_command` (`_bluetooth.py:702-710`): write to 0b0b…, read the status back from 0b0b….
    func sendCommand(_ frame: Data) async throws -> BluetoothCommandStatus {
        let data = try await request(BluetoothConstants.writeCharacteristic, frame: frame)
        return try BluetoothResponseDecoder.commandStatus(try BluetoothCodec.responseText(data, context: "command"))
    }
}

// MARK: - Private

extension LaMarzoccoBluetoothClient {
    /// All five characteristics (§3.1) — what the in-place rediscovery of §4.5 asks for.
    private static let allCharacteristics: Set<GATTUUID> =
        BluetoothConstants.sessionCharacteristics.union([BluetoothConstants.tokenCharacteristic])

    /// §4.4 steps 2–6. The caller holds the request gate; errors are mapped by the caller.
    private func exchange(_ characteristic: GATTUUID, frame: Data) async throws -> Data {
        // 2.
        let link = try await ensureConnected()
        // 3.
        try await resolve(characteristic, on: link)
        // 4. Always with response (`_bluetooth.py:695-700`).
        try await link.write(frame, to: characteristic, withResponse: true, timeout: timing.operationTimeout)
        emitRaw(.write, .outbound, characteristic: characteristic, data: frame, isSecret: false)
        // 5. Same-link check (D7a): never read a stale value from a link that went away meanwhile.
        guard self.link === link else {
            throw LaMarzoccoError.bluetoothConnectionFailed("Client is not connected")
        }
        resetIdleTimer()
        // 6. Read the same characteristic; the raw bytes are returned untouched (no NUL cut here).
        let response = try await link.read(characteristic, timeout: timing.operationTimeout)
        emitRaw(.read, .inbound, characteristic: characteristic, data: response, isSecret: false)
        return response
    }

    /// `discover(all five, refresh: true)` on `link`; updates `discovered` while `link` is current.
    private func rediscover(on link: any BluetoothLink) async throws {
        let found = try await link.discover(Self.allCharacteristics, refresh: true, timeout: timing.operationTimeout)
        if self.link === link {
            discovered = found
        }
    }

    /// §4.4 drop-class errors: the four Bluetooth connection-level cases and `CancellationError`
    /// (D7d). `.decoding` and every other error keep the link.
    private nonisolated static func isDropClass(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        switch error as? LaMarzoccoError {
        case .bluetoothConnectionFailed?, .bluetoothAuthenticationFailed?, .bluetoothUnavailable?,
             .bluetoothTimedOut?:
            return true
        default:
            return false
        }
    }
}
