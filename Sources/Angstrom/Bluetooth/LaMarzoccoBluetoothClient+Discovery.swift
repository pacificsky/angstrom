import Foundation

extension LaMarzoccoBluetoothClient {
    // MARK: Discovery & pairing (static; no instance state)

    /// Every peripheral seen, unfiltered (diagnostic; §4.14). `discoverMachines` = this, filtered.
    public static func scanAll(transport: BluetoothTransport,
                               duration: Duration = .seconds(5)) async throws -> [DiscoveredPeripheral] {
        try await discoveryAwaitPoweredOn(transport, timing: BluetoothTiming())
        do {
            return try await transport.central.scan(for: duration)
        } catch {
            throw discoveryMapError(error, phase: .request)
        }
    }

    /// Peripherals whose name starts with one of ``machineNamePrefixes`` (§4.14).
    public static func discoverMachines(transport: BluetoothTransport,
                                        duration: Duration = .seconds(5)) async throws -> [DiscoveredPeripheral] {
        let seen = try await scanAll(transport: transport, duration: duration)
        var kept: [DiscoveredPeripheral] = []
        var ids: Set<BluetoothPeripheralID> = []
        for peripheral in seen where discoveryNameMatches(peripheral.name) {
            // De-duplicated by identifier, first-seen order (§3.2, D3).
            if ids.insert(peripheral.id).inserted {
                kept.append(peripheral)
            }
        }
        return kept
    }

    /// Reads the token from a machine in pairing mode (§4.14).
    public static func readToken(transport: BluetoothTransport,
                                 peripheral: BluetoothPeripheralID) async throws -> BluetoothAuthToken {
        let timing = BluetoothTiming()
        try await discoveryAwaitPoweredOn(transport, timing: timing)
        // ONE attempt with bleak's `BleakClient` default timeout; no auth (`BT:545`).
        let link = try await discoveryConnectOnce(transport, peripheral: peripheral,
                                                  timeout: timing.tokenReadConnectTimeout)
        let characteristic = BluetoothConstants.tokenCharacteristic
        let data: Data
        do {
            let found = try await link.discover([characteristic], refresh: false, timeout: timing.operationTimeout)
            guard found.contains(characteristic) else {
                throw LaMarzoccoError.bluetoothConnectionFailed(
                    "Could not find characteristic \(characteristic) on machine.")
            }
            data = try await link.read(characteristic, timeout: timing.operationTimeout)
        } catch {
            await link.disconnect()
            throw discoveryMapTokenReadError(error)
        }
        await link.disconnect()
        // `token.decode()` (`BT:547`): strict UTF-8, NUL bytes kept.
        guard let text = discoveryStrictUTF8(data) else {
            throw LaMarzoccoError.decoding("bluetooth token: invalid UTF-8")
        }
        return BluetoothAuthToken(text)
    }

    /// Full GATT table of a peripheral (diagnostic; §4.14).
    public static func gattTable(transport: BluetoothTransport,
                                 peripheral: BluetoothPeripheralID) async throws -> [BluetoothGATTService] {
        let timing = BluetoothTiming()
        try await discoveryAwaitPoweredOn(transport, timing: timing)
        let link = try await discoveryConnectOnce(transport, peripheral: peripheral, timeout: timing.connectTimeout)
        let table: [BluetoothGATTService]
        do {
            table = try await link.gattTable(timeout: timing.operationTimeout)
        } catch {
            await link.disconnect()
            throw discoveryMapError(error, phase: .request)
        }
        await link.disconnect()
        return table
    }
}

// MARK: - Private helpers (static paths only; no client instance)

/// Which §4.4.1 column a seam error of a static path is mapped by.
private enum DiscoveryErrorPhase {
    /// The single connect attempt.
    case connect
    /// Every seam call after the connect (scan, discover, read, gatt table).
    case request
}

/// One availability-wait child's outcome.
private enum DiscoveryAvailabilityOutcome: Sendable {
    /// `.poweredOn` or a terminal state arrived on the updates stream.
    case decided(BluetoothAvailability)
    /// The updates stream ended (the waiting task was cancelled); carries the last state seen.
    case streamEnded(BluetoothAvailability)
    /// The `.poweredOnWait` sleep finished first.
    case timedOut
}

/// States that end the wait without `.poweredOn` (§4.2 step 3, §8.1).
private func discoveryIsTerminal(_ availability: BluetoothAvailability) -> Bool {
    switch availability {
    case .poweredOff, .unsupported, .unauthorized(.denied), .unauthorized(.restricted),
         .unauthorized(.allowedAlways):
        return true
    case .unknown, .resetting, .unauthorized(.notDetermined), .poweredOn:
        return false
    }
}

/// §4.2 step 3 for the static paths: subscribe first, then read the state; wait (bounded by the
/// `.poweredOnWait` sleep on the transport's sleeper) through the transient states.
private func discoveryAwaitPoweredOn(_ transport: BluetoothTransport, timing: BluetoothTiming) async throws {
    let central = transport.central
    let sleeper = transport.sleeper
    let updates = central.availabilityUpdates()
    let initial = await central.availability()
    if initial == .poweredOn { return }
    if discoveryIsTerminal(initial) { throw LaMarzoccoError.bluetoothUnavailable(initial) }

    let wait = timing.poweredOnWait
    try await withThrowingTaskGroup(of: DiscoveryAvailabilityOutcome.self) { group in
        group.addTask {
            var last = initial
            // No early exit on cancellation: states already buffered are still drained, so the
            // last state seen survives the group cancelling this child.
            for await state in updates {
                last = state
                if state == .poweredOn || discoveryIsTerminal(state) { return .decided(state) }
            }
            return .streamEnded(last)
        }
        group.addTask {
            try await sleeper.sleep(for: wait, purpose: .poweredOnWait)
            return .timedOut
        }
        guard let first = try await group.next() else { throw CancellationError() }
        group.cancelAll()
        switch first {
        case .decided(.poweredOn):
            return
        case .decided(let state):
            throw LaMarzoccoError.bluetoothUnavailable(state)
        case .streamEnded(let last):
            try Task.checkCancellation()
            throw LaMarzoccoError.bluetoothUnavailable(last)
        case .timedOut:
            var last = initial
            while let outcome = try? await group.next() {
                switch outcome {
                case .decided(let state), .streamEnded(let state): last = state
                case .timedOut: break
                }
            }
            throw LaMarzoccoError.bluetoothUnavailable(last)
        }
    }
}

/// ONE `central.connect` attempt (no retry, no backoff), mapped by the `.connect` column.
private func discoveryConnectOnce(_ transport: BluetoothTransport, peripheral: BluetoothPeripheralID,
                                  timeout: Duration) async throws -> any BluetoothLink {
    do {
        return try await transport.central.connect(to: peripheral, timeout: timeout)
    } catch let error as BluetoothTransportError {
        switch error {
        case .unavailable, .unknownPeripheral:
            throw discoveryMapError(error, phase: .connect)
        default:
            // §4.2 step 4's exhausted-attempts message, with the single attempt these paths make.
            throw LaMarzoccoError.bluetoothConnectionFailed(
                "Failed to connect to \(peripheral) after 1 attempts: \(error)")
        }
    } catch {
        throw discoveryMapError(error, phase: .connect)
    }
}

/// `readToken`'s discover/read errors: ATT permission errors get the pairing-mode hint (D20).
private func discoveryMapTokenReadError(_ error: any Error) -> any Error {
    if case BluetoothTransportError.gatt(let domain, let code) = error,
       domain == "CBATTErrorDomain", [2, 5, 8, 15].contains(code) {
        return LaMarzoccoError.bluetoothConnectionFailed(
            "Could not read the Bluetooth token (ATT error \(code)). Is the machine in pairing mode?")
    }
    return discoveryMapError(error, phase: .request)
}

/// The §4.4.1 table for the static paths.
private func discoveryMapError(_ error: any Error, phase: DiscoveryErrorPhase) -> any Error {
    if error is CancellationError || error is LaMarzoccoError { return error }
    guard let transportError = error as? BluetoothTransportError else {
        return LaMarzoccoError.bluetoothConnectionFailed(String(describing: error))
    }
    switch transportError {
    case .unavailable(let availability):
        return LaMarzoccoError.bluetoothUnavailable(availability)
    case .unknownPeripheral(let id):
        return LaMarzoccoError.bluetoothConnectionFailed("Unknown peripheral \(id); scan again")
    case .characteristicNotFound(let uuid):
        return LaMarzoccoError.bluetoothConnectionFailed("Could not find characteristic \(uuid) on machine.")
    case .timedOut(let operation) where phase == .request:
        return LaMarzoccoError.bluetoothTimedOut(operation)
    case .timedOut, .notConnected, .disconnected, .gatt, .valueTooLong:
        return LaMarzoccoError.bluetoothConnectionFailed("\(transportError)")
    }
}

/// `device.name and device.name.startswith(BT_MODEL_PREFIXES)` (`BT:534`): non-nil, non-empty, and a
/// case-sensitive prefix compared by Unicode scalars (Python compares code points, not graphemes).
private func discoveryNameMatches(_ name: String?) -> Bool {
    guard let name, !name.isEmpty else { return false }
    return LaMarzoccoBluetoothClient.machineNamePrefixes.contains { prefix in
        name.unicodeScalars.starts(with: prefix.unicodeScalars)
    }
}

/// Python `bytes.decode()`: strict UTF-8, nothing stripped (no NUL truncation, BOM kept). nil if invalid.
private func discoveryStrictUTF8(_ data: Data) -> String? {
    let text = String(decoding: data, as: UTF8.self)
    // Decoding repairs invalid input with U+FFFD, so valid input — and only valid input —
    // re-encodes to the identical bytes.
    return Data(text.utf8) == data ? text : nil
}
