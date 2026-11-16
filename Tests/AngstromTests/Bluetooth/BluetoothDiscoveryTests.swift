import XCTest
@testable import Angstrom
import AngstromTestSupport

/// The static discovery, pairing-mode token read and GATT table paths (SPEC §3.2, §3.3, §4.14).
final class BluetoothDiscoveryTests: XCTestCase {
    private let tokenUUID = BluetoothConstants.tokenCharacteristic
    private let authUUID = BluetoothConstants.authCharacteristic
    private let machine = BluetoothPeripheralID(rawValue: "6A1F2C3D-0000-4000-8000-00000000BEEF")
    private let opTimeout: Duration = .seconds(20)
    private let pairingHint = "Is the machine in pairing mode?"

    // MARK: - discoverMachines / scanAll

    /// Upstream: test_discover_devices_prefixes (tests/test_bluetooth_client.py:1326) [C50]
    func testNamePrefixFilter() async throws {
        let central = FakeBluetoothCentral()
        let names = ["MICRA_1", "MINI_2", "LINEA_3", "LINEAR_4", "GS3_5", "OTHER"]
        central.setScanResults(names.map { peripheral($0, name: $0) })

        let devices = try await LaMarzoccoBluetoothClient.discoverMachines(transport: .fake(central))
        XCTAssertEqual(devices.map(\.name), ["MICRA_1", "MINI_2", "LINEA_3", "LINEAR_4", "GS3_5"])
        XCTAssertEqual(devices.map(\.id.rawValue), ["MICRA_1", "MINI_2", "LINEA_3", "LINEAR_4", "GS3_5"])
        XCTAssertEqual(LaMarzoccoBluetoothClient.machineNamePrefixes, ["MICRA", "MINI", "LINEA", "GS3"])

        // `str.startswith` is case-sensitive and anchored at index 0; an exact prefix matches, and a
        // combining mark after the prefix does not hide it (Python compares code points).
        let edge: [(String, Bool)] = [
            ("micra_1", false), ("Micra", false), ("gs3", false), (" MICRA", false), ("MICR", false),
            ("XMINI", false), ("GS", false), ("LINE", false),
            ("MICRA", true), ("MINI", true), ("LINEA", true), ("GS3", true),
            ("MINI\u{0301}R", true), ("GS3MP", true),
        ]
        central.setScanResults(edge.map { peripheral("id-\($0.0)", name: $0.0) })
        let kept = try await LaMarzoccoBluetoothClient.discoverMachines(transport: .fake(central))
        XCTAssertEqual(kept.map(\.name), edge.filter(\.1).map(\.0))
    }

    /// Angstrom-only: G-CODEC-8 — discovery skips a peripheral whose name is nil or empty.
    func testNilOrEmptyNameSkipped() async throws {
        let central = FakeBluetoothCentral()
        central.setScanResults([
            peripheral("a", name: nil, rssi: -40),
            peripheral("b", name: "", rssi: -41),
            peripheral("c", name: "MICRA_ABC", rssi: -42),
            peripheral("d", name: nil, rssi: nil),
            peripheral("e", name: "GS3_X", rssi: nil),
        ])

        let devices = try await LaMarzoccoBluetoothClient.discoverMachines(transport: .fake(central))
        XCTAssertEqual(devices, [peripheral("c", name: "MICRA_ABC", rssi: -42), peripheral("e", name: "GS3_X", rssi: nil)])

        central.setScanResults([peripheral("a", name: nil), peripheral("b", name: "")])
        let none = try await LaMarzoccoBluetoothClient.discoverMachines(transport: .fake(central))
        XCTAssertEqual(none, [])
    }

    /// Angstrom-only: D3 — every match, de-duplicated by identifier, in first-seen order.
    func testFirstSeenOrderDeduplicated() async throws {
        let central = FakeBluetoothCentral()
        central.setScanResults([
            peripheral("z", name: "LINEA_Z", rssi: -70),
            peripheral("d", name: nil, rssi: -10),          // not a match yet: no name
            peripheral("a", name: "MICRA_A", rssi: -50),
            peripheral("z", name: "LINEA_Z", rssi: -20),    // duplicate: first sighting wins
            peripheral("m", name: "MINI_M", rssi: -60),
            peripheral("a", name: "OTHER", rssi: -30),      // duplicate id, not a match
            peripheral("d", name: "GS3_D", rssi: -15),      // first MATCHING sighting of d
            peripheral("m", name: "MINI_M2", rssi: -61),    // duplicate of a match: dropped
        ])

        let devices = try await LaMarzoccoBluetoothClient.discoverMachines(transport: .fake(central))
        XCTAssertEqual(devices, [
            peripheral("z", name: "LINEA_Z", rssi: -70),
            peripheral("a", name: "MICRA_A", rssi: -50),
            peripheral("m", name: "MINI_M", rssi: -60),
            peripheral("d", name: "GS3_D", rssi: -15),
        ])
    }

    /// Angstrom-only: §4.14 — a terminal availability fails every static path at once: no scan, no
    /// connect, no `.poweredOnWait` sleep.
    func testDiscoveryUnavailableThrows() async throws {
        let terminal: [BluetoothAvailability] = [
            .poweredOff, .unsupported, .unauthorized(.denied), .unauthorized(.restricted),
            .unauthorized(.allowedAlways),
        ]
        for state in terminal {
            let fake = FakeBluetoothCentral()
            fake.setScanResults([peripheral("a", name: "MICRA_A")])
            fake.setAvailability(state)
            let central = RecordingCentral(fake)
            let sleeper = ManualBluetoothSleeper(manual: [.idleDisconnect, .poweredOnWait])
            let transport = BluetoothTransport(central: central, sleeper: sleeper)

            await assertThrows(.bluetoothUnavailable(state), "scanAll \(state)") {
                _ = try await LaMarzoccoBluetoothClient.scanAll(transport: transport)
            }
            await assertThrows(.bluetoothUnavailable(state), "discoverMachines \(state)") {
                _ = try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport)
            }
            await assertThrows(.bluetoothUnavailable(state), "readToken \(state)") {
                _ = try await LaMarzoccoBluetoothClient.readToken(transport: transport, peripheral: self.machine)
            }
            await assertThrows(.bluetoothUnavailable(state), "gattTable \(state)") {
                _ = try await LaMarzoccoBluetoothClient.gattTable(transport: transport, peripheral: self.machine)
            }
            XCTAssertEqual(central.scanDurations, [], "\(state)")
            XCTAssertEqual(fake.connectCount, 0, "\(state)")
            XCTAssertEqual(sleeper.startedCount(.poweredOnWait), 0, "\(state)")
        }

        // A terminal state arriving DURING the wait ends it at once with that state, and the pending
        // `.poweredOnWait` sleep is cancelled.
        let fake = FakeBluetoothCentral()
        fake.setScanResults([peripheral("a", name: "MICRA_A")])
        fake.setAvailability(.unknown)
        let central = RecordingCentral(fake)
        let sleeper = ManualBluetoothSleeper(manual: [.idleDisconnect, .poweredOnWait])
        let transport = BluetoothTransport(central: central, sleeper: sleeper)
        let task = Task { try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport) }
        await sleeper.waitForPending(.poweredOnWait, count: 1)
        fake.setAvailability(.resetting)                  // transient: keeps waiting
        fake.setAvailability(.unauthorized(.denied))      // terminal: decides
        await assertThrows(.bluetoothUnavailable(.unauthorized(.denied)), "terminal during wait") {
            _ = try await task.value
        }
        XCTAssertEqual(sleeper.pendingCount(.poweredOnWait), 0)
        XCTAssertEqual(sleeper.requested(.poweredOnWait), [.seconds(10)])
        XCTAssertEqual(central.scanDurations, [])
    }

    /// Angstrom-only: U3/H10 — `scanAll` returns the scan unchanged: nil, empty and OTHER names kept,
    /// in first-seen order, with the requested duration (default 5 s).
    func testScanAllIsUnfiltered() async throws {
        let fake = FakeBluetoothCentral()
        let results = [
            peripheral("1", name: "OTHER", rssi: -80),
            peripheral("2", name: nil, rssi: nil),
            peripheral("3", name: "MICRA_3", rssi: -40),
            peripheral("4", name: "", rssi: -55),
            peripheral("5", name: "micra_5", rssi: -60),
        ]
        fake.setScanResults(results)
        let central = RecordingCentral(fake)
        let transport = BluetoothTransport(central: central, sleeper: ManualBluetoothSleeper())

        let all = try await LaMarzoccoBluetoothClient.scanAll(transport: transport)
        XCTAssertEqual(all, results)
        let longer = try await LaMarzoccoBluetoothClient.scanAll(transport: transport, duration: .seconds(12))
        XCTAssertEqual(longer, results)
        let filtered = try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport,
                                                                            duration: .milliseconds(1500))
        XCTAssertEqual(filtered, [peripheral("3", name: "MICRA_3", rssi: -40)])
        _ = try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport)

        // One scan per call, with the given duration; the defaults are 5 s (bleak `discover(timeout=5.0)`).
        XCTAssertEqual(central.scanDurations, [.seconds(5), .seconds(12), .milliseconds(1500), .seconds(5)])
        XCTAssertEqual(fake.connectCount, 0)
    }

    /// Angstrom-only: §4.14 — a transient availability waits for `.poweredOn`, bounded by one 10 s
    /// `.poweredOnWait` sleep on the transport's sleeper; when it fires, the last state seen is thrown.
    func testDiscoveryAvailabilityWaitTimesOut() async throws {
        let fake = FakeBluetoothCentral()
        fake.setScanResults([peripheral("a", name: "MICRA_A")])
        fake.setAvailability(.unknown)
        let central = RecordingCentral(fake)
        let sleeper = ManualBluetoothSleeper(manual: [.idleDisconnect, .poweredOnWait])
        let transport = BluetoothTransport(central: central, sleeper: sleeper)

        let task = Task { try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport) }
        await sleeper.waitForPending(.poweredOnWait, count: 1)
        XCTAssertEqual(fake.availabilitySubscriberCount, 1)
        fake.setAvailability(.resetting)
        fake.setAvailability(.unauthorized(.notDetermined))
        sleeper.fire(.poweredOnWait)
        await assertThrows(.bluetoothUnavailable(.unauthorized(.notDetermined)), "last state seen") {
            _ = try await task.value
        }
        XCTAssertEqual(sleeper.requested(.poweredOnWait), [.seconds(10)])
        XCTAssertEqual(central.scanDurations, [])

        // No update at all: the initial state is the last one seen. Same rule for readToken/gattTable.
        fake.setAvailability(.resetting)
        let machine = self.machine
        let token = Task { try await LaMarzoccoBluetoothClient.readToken(transport: transport, peripheral: machine) }
        await sleeper.waitForPending(.poweredOnWait, count: 1)
        sleeper.fire(.poweredOnWait)
        await assertThrows(.bluetoothUnavailable(.resetting), "readToken wait") { _ = try await token.value }

        fake.setAvailability(.unauthorized(.notDetermined))
        let gatt = Task { try await LaMarzoccoBluetoothClient.gattTable(transport: transport, peripheral: machine) }
        await sleeper.waitForPending(.poweredOnWait, count: 1)
        sleeper.fire(.poweredOnWait)
        await assertThrows(.bluetoothUnavailable(.unauthorized(.notDetermined)), "gattTable wait") {
            _ = try await gatt.value
        }
        XCTAssertEqual(sleeper.requested(.poweredOnWait), [.seconds(10), .seconds(10), .seconds(10)])
        XCTAssertEqual(fake.connectCount, 0)
        XCTAssertEqual(fake.availabilitySubscriberCount, 0)
    }

    /// Angstrom-only: §4.14 — `.poweredOn` arriving during the wait proceeds (the sleep is cancelled);
    /// cancelling the caller during the wait throws `CancellationError`.
    func testDiscoveryAvailabilityWaitPoweredOnAndCancellation() async throws {
        let fake = FakeBluetoothCentral()
        fake.setScanResults([peripheral("a", name: "OTHER"), peripheral("b", name: "GS3_B")])
        fake.setAvailability(.unauthorized(.notDetermined))
        let central = RecordingCentral(fake)
        let sleeper = ManualBluetoothSleeper(manual: [.idleDisconnect, .poweredOnWait])
        let transport = BluetoothTransport(central: central, sleeper: sleeper)

        let task = Task { try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport, duration: .seconds(7)) }
        await sleeper.waitForPending(.poweredOnWait, count: 1)
        fake.setAvailability(.resetting)
        fake.setAvailability(.poweredOn)
        let devices = try await task.value
        XCTAssertEqual(devices, [peripheral("b", name: "GS3_B")])
        XCTAssertEqual(central.scanDurations, [.seconds(7)])
        XCTAssertEqual(sleeper.pendingCount(.poweredOnWait), 0)
        XCTAssertEqual(sleeper.requested(.poweredOnWait), [.seconds(10)])

        fake.setAvailability(.unknown)
        let cancelled = Task { try await LaMarzoccoBluetoothClient.scanAll(transport: transport) }
        await sleeper.waitForPending(.poweredOnWait, count: 1)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("a cancelled wait must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(sleeper.pendingCount(.poweredOnWait), 0)
        XCTAssertEqual(central.scanDurations, [.seconds(7)])
    }

    /// Angstrom-only: §4.14 — the updates stream is created BEFORE the state is read (§4.2 step 3), so a
    /// `.poweredOn` transition between the two calls is not lost.
    func testDiscoveryAvailabilitySubscribesBeforeReading() async throws {
        let fake = FakeBluetoothCentral()
        fake.setScanResults([peripheral("a", name: "LINEA_A")])
        fake.setAvailability(.unknown)
        let central = RecordingCentral(fake)
        central.transitionDuringAvailabilityRead = .poweredOn
        let sleeper = ManualBluetoothSleeper(manual: [.idleDisconnect, .poweredOnWait])
        let transport = BluetoothTransport(central: central, sleeper: sleeper)

        let done = expectation(description: "discoverMachines returns without the wait timing out")
        let task = Task {
            let devices = try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport)
            done.fulfill()
            return devices
        }
        await fulfillment(of: [done], timeout: 5)   // hang guard only
        sleeper.fire(.poweredOnWait)                 // unblocks a regressed implementation
        let devices = try await task.value
        XCTAssertEqual(devices, [peripheral("a", name: "LINEA_A")])
        XCTAssertEqual(central.scanDurations, [.seconds(5)])
    }

    // MARK: - readToken

    /// Angstrom-only: G-CODEC-1 — `readToken`: one connect attempt (10 s), no auth, discovers and reads
    /// `0c0b…` once, always disconnects.
    func testReadTokenOneAttemptNoAuth() async throws {
        let central = FakeBluetoothCentral()
        let link = tokenLink(Data("my-secret-token".utf8))
        central.enqueueConnect(.success(link))
        let recording = RecordingCentral(central)
        let sleeper = ManualBluetoothSleeper()

        let token = try await LaMarzoccoBluetoothClient.readToken(
            transport: BluetoothTransport(central: recording, sleeper: sleeper), peripheral: machine)
        XCTAssertEqual(token.rawValue, "my-secret-token")
        XCTAssertEqual(central.connectCount, 1)
        XCTAssertEqual(central.connectTimeouts, [.seconds(10)])
        XCTAssertEqual(central.connectPeripheralIDs, [machine])
        // Only the token characteristic: no auth write, no auth read, no other characteristic.
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .read(tokenUUID), .disconnect])
        XCTAssertEqual(link.requestedTimeouts, [opTimeout, opTimeout])
        XCTAssertEqual(recording.wrappedLinks.count, 1)
        XCTAssertTrue(recording.wrappedLinks.first?.base === link)
        XCTAssertEqual(recording.wrappedLinks.first?.discoverRequests, [[tokenUUID]])
        XCTAssertFalse(link.recordedOps.contains(.read(authUUID)))
        XCTAssertEqual(sleeper.startedCount(.authPoll), 0)
        XCTAssertEqual(sleeper.startedCount(.connectBackoff), 0)
        XCTAssertEqual(sleeper.startedCount(.idleDisconnect), 0)

        // A failed attempt is not retried: exactly one connect, no backoff sleep.
        let failing = FakeBluetoothCentral()
        failing.connectFailure = .timedOut("connect")
        let failingSleeper = ManualBluetoothSleeper()
        await assertThrows(.bluetoothConnectionFailed(
            "Failed to connect to \(machine) after 1 attempts: timed out (connect)"), "timed out") {
            _ = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(failing, sleeper: failingSleeper),
                                                              peripheral: self.machine)
        }
        XCTAssertEqual(failing.connectCount, 1)
        XCTAssertEqual(failing.connectTimeouts, [.seconds(10)])
        XCTAssertEqual(failing.links.count, 0)
        XCTAssertEqual(failingSleeper.startedCount(.connectBackoff), 0)

        let other = FakeBluetoothCentral()
        other.enqueueConnect(.failure(.disconnected(code: 7)))
        await assertThrows(.bluetoothConnectionFailed(
            "Failed to connect to \(machine) after 1 attempts: disconnected (code 7)"), "disconnected") {
            _ = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(other), peripheral: self.machine)
        }
        XCTAssertEqual(other.connectCount, 1)

        let unknown = FakeBluetoothCentral()
        unknown.connectFailure = .unknownPeripheral(machine)
        await assertThrows(.bluetoothConnectionFailed("Unknown peripheral \(machine); scan again"), "unknown") {
            _ = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(unknown), peripheral: self.machine)
        }
        XCTAssertEqual(unknown.connectCount, 1)

        let off = FakeBluetoothCentral()
        off.connectFailure = .unavailable(.poweredOff)
        await assertThrows(.bluetoothUnavailable(.poweredOff), "unavailable") {
            _ = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(off), peripheral: self.machine)
        }
        XCTAssertEqual(off.connectCount, 1)
    }

    /// Angstrom-only: G-CODEC-1 — the token is decoded as strict UTF-8 with NO NUL stripping
    /// (`token.decode()`, `BT:547`): NULs anywhere, a BOM and non-ASCII are all kept verbatim.
    func testReadTokenKeepsNul() async throws {
        let cases: [(Data, String)] = [
            (Data("abc\0".utf8), "abc\0"),
            (Data("ab\0cd\0\0".utf8), "ab\0cd\0\0"),
            (Data([0x00, 0x41]), "\0A"),
            (Data([0x00]), "\0"),
            (Data(), ""),
            (Data([0xEF, 0xBB, 0xBF, 0x41]), "\u{FEFF}A"),
            (Data("caf\u{E9}\0\u{1F600}".utf8), "caf\u{E9}\0\u{1F600}"),
            (Data(String(repeating: "0", count: 64).utf8), String(repeating: "0", count: 64)),
        ]
        for (bytes, expected) in cases {
            let central = FakeBluetoothCentral()
            let link = tokenLink(bytes)
            central.enqueueConnect(.success(link))
            let token = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(central), peripheral: machine)
            XCTAssertEqual(token.rawValue, expected, "\(Array(bytes))")
            XCTAssertEqual(Array(token.rawValue.utf8), Array(bytes), "\(Array(bytes))")
            XCTAssertEqual(link.recordedOps.last, .disconnect)
        }
    }

    /// Angstrom-only: G-CODEC-1 — bytes Python's strict `bytes.decode()` rejects throw
    /// `.decoding("bluetooth token: invalid UTF-8")`, after the link is closed.
    func testReadTokenInvalidUTF8() async throws {
        let invalid: [[UInt8]] = [
            [0xFF],                         // never valid
            [0x41, 0x80],                   // lone continuation byte
            [0xC0, 0xAF],                   // overlong "/"
            [0xED, 0xA0, 0x80],             // UTF-16 surrogate (Python: "surrogates not allowed")
            [0xE2, 0x82],                   // truncated sequence
            [0xF4, 0x90, 0x80, 0x80],       // above U+10FFFF
            [0x61, 0x00, 0xFE, 0x62],       // invalid byte after a NUL
        ]
        for bytes in invalid {
            let central = FakeBluetoothCentral()
            let link = tokenLink(Data(bytes))
            central.enqueueConnect(.success(link))
            await assertThrows(.decoding("bluetooth token: invalid UTF-8"), "\(bytes)") {
                _ = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(central), peripheral: self.machine)
            }
            XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .read(tokenUUID), .disconnect], "\(bytes)")
        }
    }

    /// Angstrom-only: D20 — an ATT permission error (2, 5, 8, 15) on the token read becomes the
    /// "pairing mode?" message; other GATT errors keep the request-phase mapping (§4.4.1).
    func testReadTokenATTErrorMessage() async throws {
        for code in [2, 5, 8, 15] {
            let link = try await readTokenFailing(.gatt(domain: "CBATTErrorDomain", code: code),
                                                  expect: .bluetoothConnectionFailed(
                                                    "Could not read the Bluetooth token (ATT error \(code)). Is the machine in pairing mode?"))
            XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .read(tokenUUID), .disconnect])
        }
        // Not a permission error, or not the ATT domain: no pairing-mode hint.
        for code in [1, 3, 6, 14] {
            _ = try await readTokenFailing(.gatt(domain: "CBATTErrorDomain", code: code),
                                           expect: .bluetoothConnectionFailed("GATT error CBATTErrorDomain \(code)"))
        }
        for code in [2, 5, 8, 15] {
            _ = try await readTokenFailing(.gatt(domain: "CBErrorDomain", code: code),
                                           expect: .bluetoothConnectionFailed("GATT error CBErrorDomain \(code)"))
        }
        // A link lost during discovery: request-phase mapping, no hint, still disconnected.
        let central = FakeBluetoothCentral()
        let link = tokenLink(Data("t".utf8))
        link.beforeOp = { op in if op == .discover(refresh: false) { link.drop(nil) } }
        central.enqueueConnect(.success(link))
        await assertThrows(.bluetoothConnectionFailed("not connected"), "drop during discover") {
            _ = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(central), peripheral: self.machine)
        }
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .disconnect])
    }

    /// Angstrom-only: D20 — `readToken` disconnects on success and on every failure after the connect:
    /// read errors, timeouts, decode errors and cancellation.
    func testReadTokenAlwaysDisconnects() async throws {
        // Success.
        let okCentral = FakeBluetoothCentral()
        let ok = tokenLink(Data("tok".utf8))
        okCentral.enqueueConnect(.success(ok))
        _ = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(okCentral), peripheral: machine)
        XCTAssertEqual(ok.recordedOps, [.discover(refresh: false), .read(tokenUUID), .disconnect])

        // Read errors (request-phase mapping, §4.4.1).
        var link = try await readTokenFailing(.timedOut("read"), expect: .bluetoothTimedOut("read"))
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .read(tokenUUID), .disconnect])
        link = try await readTokenFailing(.disconnected(code: nil), expect: .bluetoothConnectionFailed("disconnected"))
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .read(tokenUUID), .disconnect])

        // Decode error.
        let badCentral = FakeBluetoothCentral()
        let bad = tokenLink(Data([0xFF]))
        badCentral.enqueueConnect(.success(bad))
        await assertThrows(.decoding("bluetooth token: invalid UTF-8"), "decode") {
            _ = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(badCentral), peripheral: self.machine)
        }
        XCTAssertEqual(bad.recordedOps, [.discover(refresh: false), .read(tokenUUID), .disconnect])

        // Cancellation while the read is in flight.
        let gate = Gate()
        let heldCentral = FakeBluetoothCentral()
        let held = tokenLink(Data("tok".utf8))
        held.beforeOp = { op in if op == .read(BluetoothConstants.tokenCharacteristic) { await gate.hold() } }
        heldCentral.enqueueConnect(.success(held))
        let heldTransport = BluetoothTransport.fake(heldCentral)
        let machine = self.machine
        let task = Task { try await LaMarzoccoBluetoothClient.readToken(transport: heldTransport, peripheral: machine) }
        await gate.waitUntilHeld()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("a cancelled read must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(held.recordedOps, [.discover(refresh: false), .read(tokenUUID), .disconnect])
    }

    /// Angstrom-only: §4.14 — a missing `0c0b…` fails with the exact message, without a read, and the
    /// link is still closed.
    func testReadTokenMissingCharacteristic() async throws {
        let central = FakeBluetoothCentral()
        let link = tokenLink(Data("tok".utf8))
        link.present = [BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
                        authUUID, BluetoothConstants.shotCounterCharacteristic]
        link.presentAfterRefresh = [tokenUUID]   // must not be consulted: refresh is false
        central.enqueueConnect(.success(link))

        await assertThrows(.bluetoothConnectionFailed(
            "Could not find characteristic 0c0b7847-e12b-09a8-b04b-8e0922a9abab on machine."), "missing") {
            _ = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(central), peripheral: self.machine)
        }
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .disconnect])
        XCTAssertEqual(central.connectCount, 1)

        // The seam reporting it on the read maps to the same message.
        _ = try await readTokenFailing(.characteristicNotFound(tokenUUID), expect: .bluetoothConnectionFailed(
            "Could not find characteristic 0c0b7847-e12b-09a8-b04b-8e0922a9abab on machine."))
    }

    // MARK: - gattTable

    /// Angstrom-only: §4.14 — `gattTable`: one connect attempt (20 s), the table read with the 20 s
    /// operation timeout, no discovery, no auth, then disconnect — on success and on failure.
    func testGattTableOneConnectNoAuth() async throws {
        let table = [
            BluetoothGATTService(uuid: "180a", characteristics: [
                BluetoothGATTCharacteristic(uuid: "2a29", properties: ["read"]),
            ]),
            BluetoothGATTService(uuid: "d30a7847-e12b-09a8-b04b-8e0922a9abab", characteristics: [
                BluetoothGATTCharacteristic(uuid: "0a0b7847-e12b-09a8-b04b-8e0922a9abab", properties: ["read", "write"]),
                BluetoothGATTCharacteristic(uuid: "0e0b7847-e12b-09a8-b04b-8e0922a9abab", properties: ["notify"]),
            ]),
        ]
        let central = FakeBluetoothCentral()
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.gatt = table
        central.enqueueConnect(.success(link))
        let sleeper = ManualBluetoothSleeper()

        let result = try await LaMarzoccoBluetoothClient.gattTable(transport: .fake(central, sleeper: sleeper),
                                                                   peripheral: machine)
        XCTAssertEqual(result, table)
        XCTAssertEqual(central.connectCount, 1)
        XCTAssertEqual(central.connectTimeouts, [.seconds(20)])
        XCTAssertEqual(central.connectPeripheralIDs, [machine])
        XCTAssertEqual(link.requestedTimeouts, [opTimeout])     // the gattTable call only
        XCTAssertEqual(link.recordedOps, [.disconnect])        // no discover, no auth write/read
        XCTAssertEqual(sleeper.startedCount(.authPoll), 0)
        XCTAssertEqual(sleeper.startedCount(.idleDisconnect), 0)

        // A failed connect is not retried.
        let failing = FakeBluetoothCentral()
        failing.connectFailure = .timedOut("connect")
        let failingSleeper = ManualBluetoothSleeper()
        await assertThrows(.bluetoothConnectionFailed(
            "Failed to connect to \(machine) after 1 attempts: timed out (connect)"), "connect") {
            _ = try await LaMarzoccoBluetoothClient.gattTable(transport: .fake(failing, sleeper: failingSleeper),
                                                              peripheral: self.machine)
        }
        XCTAssertEqual(failing.connectCount, 1)
        XCTAssertEqual(failing.connectTimeouts, [.seconds(20)])
        XCTAssertEqual(failingSleeper.startedCount(.connectBackoff), 0)

        // A failing table read still disconnects.
        let droppedCentral = FakeBluetoothCentral()
        let dropped = FakeBluetoothLink()
        dropped.gatt = table
        dropped.drop(.disconnected(code: 7))
        droppedCentral.enqueueConnect(.success(dropped))
        await assertThrows(.bluetoothConnectionFailed("not connected"), "table") {
            _ = try await LaMarzoccoBluetoothClient.gattTable(transport: .fake(droppedCentral), peripheral: self.machine)
        }
        XCTAssertEqual(dropped.recordedOps, [.disconnect])
        XCTAssertEqual(dropped.requestedTimeouts, [opTimeout])
    }

    // MARK: - Private helpers

    private func peripheral(_ id: String, name: String?, rssi: Int? = -50) -> DiscoveredPeripheral {
        DiscoveredPeripheral(id: BluetoothPeripheralID(rawValue: id), name: name, rssi: rssi)
    }

    /// A link whose token characteristic reads `value`; every other read fails.
    private func tokenLink(_ value: Data) -> FakeBluetoothLink {
        let link = FakeBluetoothLink()
        link.onRead = { characteristic in
            guard characteristic == BluetoothConstants.tokenCharacteristic else {
                throw BluetoothTransportError.characteristicNotFound(characteristic)
            }
            return value
        }
        return link
    }

    /// Runs `readToken` against a link whose token read throws `failure`; asserts `expect`.
    private func readTokenFailing(_ failure: BluetoothTransportError, expect: LaMarzoccoError,
                                  file: StaticString = #filePath, line: UInt = #line) async throws -> FakeBluetoothLink {
        let central = FakeBluetoothCentral()
        let link = FakeBluetoothLink()
        link.onRead = { _ in throw failure }
        central.enqueueConnect(.success(link))
        await assertThrows(expect, "\(failure)", file: file, line: line) {
            _ = try await LaMarzoccoBluetoothClient.readToken(transport: .fake(central), peripheral: self.machine)
        }
        XCTAssertEqual(link.recordedOps.last, .disconnect, "\(failure)", file: file, line: line)
        XCTAssertEqual(central.connectCount, 1, file: file, line: line)
        return link
    }

    private func assertThrows(_ expected: LaMarzoccoError, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected): \(message)", file: file, line: line)
        } catch let error as LaMarzoccoError {
            XCTAssertEqual(error, expected, message, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error): \(message)", file: file, line: line)
        }
    }
}

/// Wraps a `FakeBluetoothCentral` and records the duration of every `scan(for:)` call.
private final class RecordingCentral: BluetoothCentral, @unchecked Sendable {
    private let base: FakeBluetoothCentral
    private let lock = NSLock()
    private var durations: [Duration] = []
    private var wrapped: [WantedRecordingLink] = []
    private var transition: BluetoothAvailability?

    init(_ base: FakeBluetoothCentral) { self.base = base }

    var scanDurations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return durations
    }

    /// When set, the next `availability()` call returns the current state and THEN switches the fake
    /// to this state (yielding it to every live updates stream): a transition between the two calls.
    var transitionDuringAvailabilityRead: BluetoothAvailability? {
        get { lock.withLock { transition } }
        set { lock.withLock { transition = newValue } }
    }

    func availability() async -> BluetoothAvailability {
        let state = await base.availability()
        let next: BluetoothAvailability? = lock.withLock {
            defer { transition = nil }
            return transition
        }
        if let next { base.setAvailability(next) }
        return state
    }
    func availabilityUpdates() -> AsyncStream<BluetoothAvailability> { base.availabilityUpdates() }
    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] {
        lock.withLock { durations.append(duration) }
        return try await base.scan(for: duration)
    }
    /// Every link `connect` returned, wrapped so `discover` requests are recorded.
    var wrappedLinks: [WantedRecordingLink] {
        lock.lock()
        defer { lock.unlock() }
        return wrapped
    }

    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        guard let link = try await base.connect(to: id, timeout: timeout) as? FakeBluetoothLink else {
            preconditionFailure("FakeBluetoothCentral returns FakeBluetoothLink")
        }
        let recording = WantedRecordingLink(link)
        lock.withLock { wrapped.append(recording) }
        return recording
    }
}

/// Wraps a `FakeBluetoothLink` and records the `wanted` set of every `discover` call.
private final class WantedRecordingLink: BluetoothLink, @unchecked Sendable {
    let base: FakeBluetoothLink
    private let lock = NSLock()
    private var wantedSets: [Set<GATTUUID>] = []

    init(_ base: FakeBluetoothLink) { self.base = base }

    var discoverRequests: [Set<GATTUUID>] {
        lock.lock()
        defer { lock.unlock() }
        return wantedSets
    }

    var peripheralID: BluetoothPeripheralID { base.peripheralID }
    var events: AsyncStream<LinkEvent> { base.events }
    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        lock.withLock { wantedSets.append(wanted) }
        return try await base.discover(wanted, refresh: refresh, timeout: timeout)
    }
    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data {
        try await base.read(characteristic, timeout: timeout)
    }
    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        try await base.write(data, to: characteristic, withResponse: withResponse, timeout: timeout)
    }
    func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws {
        try await base.subscribe(characteristic, timeout: timeout)
    }
    func unsubscribe(_ characteristic: GATTUUID) async { await base.unsubscribe(characteristic) }
    func disconnect() async { await base.disconnect() }
    func attMTU() async -> Int? { await base.attMTU() }
    func gattTable(timeout: Duration) async throws -> [BluetoothGATTService] {
        try await base.gattTable(timeout: timeout)
    }
}

/// Holds one op in flight until released (no polling).
private actor Gate {
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var isHeld = false

    func hold() async {
        isHeld = true
        for waiter in heldWaiters { waiter.resume() }
        heldWaiters = []
        await withCheckedContinuation { held = $0 }
    }

    func waitUntilHeld() async {
        if isHeld { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
