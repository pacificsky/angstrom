import XCTest
@testable import Angstrom
import AngstromTestSupport

/// Narrow smoke tests of the request path (SPEC §3.5–§3.7, §4.4, §4.4.1, §4.5): the six reads, the four
/// commands and `rawRead` driven end to end over the AngstromTestSupport fakes. The parity suites are
/// BT-W3-01/02/03.
final class BluetoothClientRequestsSmokeTests: XCTestCase {
    private let readChar = BluetoothConstants.readCharacteristic
    private let writeChar = BluetoothConstants.writeCharacteristic
    private let authChar = BluetoothConstants.authCharacteristic
    private let connectOps: [FakeOp] = [
        .discover(refresh: false),
        .write(BluetoothConstants.authCharacteristic, Data("token".utf8)),
        .read(BluetoothConstants.authCharacteristic),
    ]

    /// Angstrom-only: §3.6 — each of the six reads writes `<setting>\0` to 0a0b…, reads 0a0b… and decodes the upstream vector
    func testEachReadDecodes() async throws {
        let link = FakeBluetoothLink.laMarzocco(token: "token", settingResponses: [
            // TBC:342 (verbatim)
            .machineCapabilities: Data(#"[{"family":"MICRA","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":false,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":["BrewingMode","StandBy"],"schedulingType":"smartWakeUpSleep"}]"#.utf8),
            // TBC:1227: cut at the first NUL
            .machineMode: Data(#""BrewingMode""#.utf8) + [0x00, 0x00] + Data("garbage".utf8),
            // TBC:410
            .tankStatus: Data(#""true""#.utf8),
            // TBC:365
            .boilers: Data(#"[{"id":"SteamBoiler","isEnabled":true,"target":131,"current":45},{"id":"CoffeeBoiler1","isEnabled":true,"target":94,"current":65}]"#.utf8),
            // TBC:393
            .smartStandBy: Data(#"{"mode":"PowerOn","minutes":42,"enabled":"true"}"#.utf8),
            // TBC:1237 (b"false")
            .isPlumbedIn: Data("false".utf8),
        ])
        let rig = makeRig(link)

        let capabilities = try await rig.client.machineCapabilities()
        XCTAssertEqual(capabilities, BluetoothMachineCapabilities(
            family: .lineaMicra, rawFamily: "MICRA", groupsNumber: 1, coffeeBoilersNumber: 1,
            hasCupWarmer: false, steamBoilersNumber: 1, teaDosesNumber: 0,
            machineModes: [.brewing, .standby], schedulingType: "smartWakeUpSleep"))
        let mode = try await rig.client.machineMode()
        XCTAssertEqual(mode, .brewing)
        let tank = try await rig.client.tankStatus()
        XCTAssertTrue(tank)
        let boilers = try await rig.client.boilers()
        XCTAssertEqual(boilers, [
            BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 131, current: 45),
            BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 94, current: 65),
        ])
        let standby = try await rig.client.smartStandby()
        XCTAssertEqual(standby, BluetoothSmartStandbyDetails(mode: .powerOn, minutes: 42, enabled: true))
        let plumbed = try await rig.client.isPlumbedIn()
        XCTAssertFalse(plumbed)

        // One connection; every request is exactly write(<setting>\0) → read on 0a0b…, no rediscovery.
        XCTAssertEqual(rig.central.connectCount, 1)
        var expected = connectOps
        for setting in ["machineCapabilities", "machineMode", "tankStatus", "boilers", "smartStandBy", "isPlumbedIn"] {
            expected += [.write(readChar, Data(setting.utf8) + [0x00]), .read(readChar)]
        }
        XCTAssertEqual(link.recordedOps, expected)
        // D19: every GATT operation is bounded by the 20 s operation timeout.
        XCTAssertEqual(link.requestedTimeouts, Array(repeating: .seconds(20), count: 3 + 12))

        let state = await rig.client.peek { ($0.isConnected, $0.gateBusy, $0.backgroundTasks.isEmpty) }
        XCTAssertTrue(state.0)
        XCTAssertEqual(state.1, [], "both gates are released")
        XCTAssertTrue(state.2, "no drop was scheduled")
        await rig.client.disconnect()
    }

    /// Angstrom-only: §3.7 — each command writes its pinned frame (BT-REQ-001…006) to 0b0b…, reads 0b0b… and returns the decoded status
    func testEachCommandWritesFrameAndReturnsStatus() async throws {
        let link = FakeBluetoothLink.laMarzocco(
            token: "token", commandResponse: Data(#"{"id":"cmd-7","message":"Accepted","status":"Success"}"#.utf8))
        // §4.4 step 5: the idle timer is reset between the write and the read (a new idle task).
        let idleAtWrite = Box<Task<Void, Never>?>(nil)
        let idleAtRead = Box<Task<Void, Never>?>(nil)
        let rig = makeRig(link)
        let client = rig.client
        let powerOn = Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]
        link.beforeOp = { [writeChar] op in
            if op == .write(writeChar, powerOn) {
                idleAtWrite.set(await client.peek { $0.idleTask })
            } else if op == .read(writeChar), idleAtRead.value == nil {
                idleAtRead.set(await client.peek { $0.idleTask })
            }
        }
        let accepted = BluetoothCommandStatus(id: "cmd-7", message: "Accepted", status: "Success")

        let statuses = [
            try await client.setPower(on: true),
            try await client.setPower(on: false),
            try await client.setTemperature(boiler: .steam, celsius: 90),
            try await client.setSmartStandby(enabled: true, mode: .powerOn, minutes: 42),
            try await client.setSteam(on: true),
            try await client.setTemperature(boiler: .coffee, celsius: 96.5),
        ]
        XCTAssertEqual(statuses, Array(repeating: accepted, count: 6))
        XCTAssertTrue(statuses.allSatisfy(\.isSuccess))

        let frames = [
            #"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#,                              // BT-REQ-001
            #"{"name":"MachineChangeMode","parameter":{"mode":"StandBy"}}"#,                                  // BT-REQ-002
            #"{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":90}}"#,           // BT-REQ-003
            #"{"name":"SettingSmartStandby","parameter":{"minutes":42,"mode":"PowerOn","enabled":true}}"#,    // BT-REQ-004
            #"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":true}}"#,         // BT-REQ-005
            #"{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":96.5}}"#,       // BT-REQ-006
        ]
        var expected = connectOps
        for frame in frames {
            expected += [.write(writeChar, Data(frame.utf8) + [0x00]), .read(writeChar)]
        }
        XCTAssertEqual(link.recordedOps, expected)
        XCTAssertEqual(rig.central.connectCount, 1)

        let atWrite = try XCTUnwrap(idleAtWrite.value)
        let atRead = try XCTUnwrap(idleAtRead.value)
        XCTAssertNotEqual(atWrite, atRead, "resetIdleTimer() runs after the write, before the read")
        await rig.client.disconnect()
    }

    /// Angstrom-only: §3.7 — a non-success status is returned, not thrown, and keeps the link
    func testNonSuccessStatusIsReturned() async throws {
        let link = FakeBluetoothLink.laMarzocco(
            token: "token", commandResponse: Data(#"{"id":"e-1","message":"Boiler busy","status":"error"}"#.utf8) + [0x00, 0x7B])
        let rig = makeRig(link)

        let status = try await rig.client.setSteam(on: false)

        XCTAssertEqual(status, BluetoothCommandStatus(id: "e-1", message: "Boiler busy", status: "error"))
        XCTAssertFalse(status.isSuccess)
        await rig.client.drainBackgroundWorkForTesting()
        let connected = await rig.client.isConnected
        XCTAssertTrue(connected)
        XCTAssertEqual(link.recordedOps, connectOps + [
            .write(writeChar, Data(#"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":false}}"#.utf8) + [0x00]),
            .read(writeChar),
        ])
        await rig.client.disconnect()
    }

    /// Angstrom-only: §4.4 — a `.decoding` error (bad JSON, bad value, invalid UTF-8, bad status) is thrown after the gate is released and never drops the link
    func testDecodeErrorKeepsLink() async throws {
        let link = FakeBluetoothLink.laMarzocco(
            token: "token", commandResponse: Data(#"{"id":"x","message":"m"}"#.utf8),
            settingResponses: [
                .machineMode: Data(#""Foo""#.utf8),
                .machineCapabilities: Data("[]".utf8),
                .tankStatus: Data([0xFF, 0x00]),
                .boilers: Data("not json".utf8),
            ])
        let rig = makeRig(link)
        let events = await rig.client.connectionEvents()

        await assertThrows(.decoding("bluetooth machineMode: Foo is not a valid MachineMode")) {
            try await rig.client.machineMode()
        }
        await assertThrows(.decoding("bluetooth machineCapabilities: empty array (no element [0])")) {
            try await rig.client.machineCapabilities()
        }
        await assertThrows(.decoding("bluetooth tankStatus: invalid UTF-8")) {
            try await rig.client.tankStatus()
        }
        await assertThrows(.decoding(#"bluetooth boilers: not valid JSON: "not json""#)) {
            try await rig.client.boilers()
        }
        await assertThrows(.decoding("bluetooth command: missing status")) {
            try await rig.client.setPower(on: true)
        }

        await rig.client.drainBackgroundWorkForTesting()
        let state = await rig.client.peek {
            ($0.isConnected, $0.backgroundTasks.isEmpty, $0.idleTask != nil, $0.gateBusy)
        }
        XCTAssertTrue(state.0, "the link stays up")
        XCTAssertTrue(state.1, "no drop was scheduled")
        XCTAssertTrue(state.2, "the idle timer keeps running")
        XCTAssertEqual(state.3, [])
        XCTAssertFalse(link.recordedOps.contains(.disconnect))
        XCTAssertEqual(rig.central.connectCount, 1)
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected])
        await rig.client.disconnect()
    }

    /// Angstrom-only: §4.4 — a drop-class transport error is mapped (§4.4.1), drops an idle link in the background and is rethrown; the next request reconnects; with the shot counter on and a link up it does not drop
    func testDropClassErrorDropsIdleLink() async throws {
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        let rig = makeRig(link)
        let events = await rig.client.connectionEvents()
        _ = try await rig.client.tankStatus()
        let original = link.onWrite
        link.onWrite = { [writeChar] characteristic, data in
            if characteristic == writeChar { throw BluetoothTransportError.gatt(domain: "CBATTErrorDomain", code: 3) }
            try original(characteristic, data)
        }

        await assertThrows(.bluetoothConnectionFailed("GATT error CBATTErrorDomain 3")) {
            try await rig.client.setPower(on: true)
        }
        await rig.client.drainBackgroundWorkForTesting()

        let afterDrop = await rig.client.peek { ($0.isConnected, $0.link == nil, $0.idleTask == nil, $0.backgroundTasks.isEmpty) }
        XCTAssertFalse(afterDrop.0)
        XCTAssertTrue(afterDrop.1)
        XCTAssertTrue(afterDrop.2, "the drop cancelled the idle timer")
        XCTAssertTrue(afterDrop.3)
        XCTAssertEqual(link.recordedOps.last, .disconnect)
        // No read after the failed write.
        XCTAssertEqual(Array(link.recordedOps.suffix(2)),
                       [.write(writeChar, Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]),
                        .disconnect])
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected])

        // Plain requests never auto-reconnect; the next one reconnects lazily on a new link.
        XCTAssertEqual(rig.central.connectCount, 1)
        let status = try await rig.client.setPower(on: true)
        XCTAssertTrue(status.isSuccess)
        XCTAssertEqual(rig.central.connectCount, 2)
        let second = try XCTUnwrap(rig.central.links.last)
        XCTAssertFalse(second === link)

        // "A single failed command must not kill a running shot counter" (`_bluetooth.py:130-134`).
        await rig.client.peek { $0.shotCounterEnabled = true }
        second.onWrite = { _, _ in throw BluetoothTransportError.gatt(domain: "CBATTErrorDomain", code: 3) }
        await assertThrows(.bluetoothConnectionFailed("GATT error CBATTErrorDomain 3")) {
            try await rig.client.setSteam(on: true)
        }
        let kept = await rig.client.peek { client -> (Bool, Bool) in
            let result = (client.isConnected, client.backgroundTasks.isEmpty)
            client.shotCounterEnabled = false
            return result
        }
        XCTAssertTrue(kept.0)
        XCTAssertTrue(kept.1, "no drop was scheduled")
        XCTAssertFalse(second.recordedOps.contains(.disconnect))
        await rig.client.disconnect()
    }

    /// Angstrom-only: §4.5 — a characteristic missing after one in-place rediscovery fails the request and drops the link; one found by the rediscovery (or after servicesInvalidated) serves it on the same link
    func testSmokeMissingCharacteristicDrops() async throws {
        let all: Set<GATTUUID> = [readChar, writeChar, BluetoothConstants.tokenCharacteristic, authChar,
                                  BluetoothConstants.shotCounterCharacteristic]

        // Missing even after the rediscovery → drop + `Could not find characteristic …`.
        let missing = FakeBluetoothLink.laMarzocco(token: "token")
        missing.present = all.subtracting([writeChar])
        missing.presentAfterRefresh = all.subtracting([writeChar])
        let rig = makeRig(missing)
        let events = await rig.client.connectionEvents()

        await assertThrows(.bluetoothConnectionFailed("Could not find characteristic 0b0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")) {
            try await rig.client.setPower(on: true)
        }
        await rig.client.drainBackgroundWorkForTesting()
        XCTAssertEqual(missing.recordedOps, connectOps + [.discover(refresh: true), .disconnect],
                       "one rediscovery, nothing written, then the drop")
        let dropped = await rig.client.isConnected
        XCTAssertFalse(dropped)
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected])

        // Found by the in-place rediscovery → served on the same link (D7b).
        let stale = FakeBluetoothLink.laMarzocco(token: "token")
        stale.present = all.subtracting([writeChar])
        stale.presentAfterRefresh = all
        let found = makeRig(stale)
        let status = try await found.client.setPower(on: true)
        XCTAssertTrue(status.isSuccess)
        XCTAssertEqual(found.central.connectCount, 1)
        XCTAssertEqual(stale.recordedOps, connectOps + [
            .discover(refresh: true),
            .write(writeChar, Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]),
            .read(writeChar),
        ])
        let foundState = await found.client.peek { ($0.isConnected, $0.discovered.contains(BluetoothConstants.writeCharacteristic)) }
        XCTAssertTrue(foundState.0)
        XCTAssertTrue(foundState.1)

        // `needsRediscovery` (services invalidated) → discover(refresh: true) first, once.
        await found.client.peek { $0.needsRediscovery = true }
        _ = try await found.client.setPower(on: false)
        _ = try await found.client.setPower(on: true)
        XCTAssertEqual(Array(stale.recordedOps.dropFirst(connectOps.count + 3)), [
            .discover(refresh: true),
            .write(writeChar, Data(#"{"name":"MachineChangeMode","parameter":{"mode":"StandBy"}}"#.utf8) + [0x00]),
            .read(writeChar),
            .write(writeChar, Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]),
            .read(writeChar),
        ])
        let cleared = await found.client.peek { $0.needsRediscovery }
        XCTAssertFalse(cleared)
        await found.client.disconnect()
    }

    /// Angstrom-only: D7a — a link drop between a request's write and read fails it with `Client is not connected`; no read, no silent reconnect
    func testLinkDropBetweenWriteAndReadFails() async throws {
        let fake = FakeBluetoothCentral()
        let inner = FakeBluetoothLink.laMarzocco(token: "token")
        let disconnectSeen = Gate()
        let link = DropAfterWriteLink(inner, target: BluetoothConstants.writeCharacteristic, resume: disconnectSeen)
        let central = HandOffCentral(fake, first: link)
        let sleeper = ManualBluetoothSleeper()
        let client = LaMarzoccoBluetoothClient(transport: BluetoothTransport(central: central, sleeper: sleeper),
                                               peripheral: .fake, token: BluetoothAuthToken("token"))
        let events = await client.connectionEvents()
        let watcher = Task {
            for await event in events where event == .disconnected {
                disconnectSeen.open()
                return
            }
        }

        await assertThrows(.bluetoothConnectionFailed("Client is not connected")) {
            try await client.setPower(on: true)
        }
        await client.drainBackgroundWorkForTesting()
        await watcher.value

        XCTAssertEqual(inner.recordedOps, connectOps + [
            .write(writeChar, Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]),
        ], "the status is never read")
        XCTAssertEqual(central.connectCount, 1, "no silent reconnect")
        let connected = await client.isConnected
        XCTAssertFalse(connected)

        // The next request reconnects lazily.
        let status = try await client.setPower(on: true)
        XCTAssertTrue(status.isSuccess)
        XCTAssertEqual(central.connectCount, 2)
        await client.disconnect()
    }

    /// Angstrom-only: D21 — NaN/±∞ are rejected before any I/O; a finite value is sent unrounded
    func testNonFiniteTemperatureRejected() async throws {
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        let rig = makeRig(link)

        for value in [Double.nan, -Double.nan, Double.signalingNaN, Double.infinity, -Double.infinity] {
            await assertThrows(.operationNotAvailable("temperature must be finite"), "\(value)") {
                try await rig.client.setTemperature(boiler: .coffee, celsius: value)
            }
        }
        XCTAssertEqual(rig.central.connectCount, 0, "no I/O at all")
        XCTAssertEqual(link.recordedOps, [])

        _ = try await rig.client.setTemperature(boiler: .coffee, celsius: 93.25)
        XCTAssertEqual(link.recordedOps, connectOps + [
            .write(writeChar, Data(#"{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":93.25}}"#.utf8) + [0x00]),
            .read(writeChar),
        ])
        await rig.client.disconnect()
    }

    /// Angstrom-only: §6.11 — rawRead returns the response bytes verbatim (before NUL truncation); the tap carries the request write and the verbatim read
    func testRawReadIsVerbatim() async throws {
        let response = Data(#""BrewingMode""#.utf8) + [0x00, 0x00, 0xFF] + Data("garbage".utf8)
        let link = FakeBluetoothLink.laMarzocco(token: "token", settingResponses: [.machineMode: response])
        let rig = makeRig(link)
        let frames = await rig.client.rawFrames()

        let raw = try await rig.client.rawRead(.machineMode)
        XCTAssertEqual(raw, response)
        // The same bytes decode through the NUL cut.
        let mode = try await rig.client.machineMode()
        XCTAssertEqual(mode, .brewing)

        XCTAssertEqual(link.recordedOps, connectOps + [
            .write(readChar, Data("machineMode".utf8) + [0x00]), .read(readChar),
            .write(readChar, Data("machineMode".utf8) + [0x00]), .read(readChar),
        ])
        let tapped = await drain(frames).filter { $0.characteristic == "0a0b7847-e12b-09a8-b04b-8e0922a9abab" }
        XCTAssertEqual(tapped.map(\.kind), [.write, .read, .write, .read])
        XCTAssertEqual(tapped.map(\.direction), [.outbound, .inbound, .outbound, .inbound])
        XCTAssertEqual(tapped.map(\.data), [Data("machineMode".utf8) + [0x00], response,
                                            Data("machineMode".utf8) + [0x00], response])
        XCTAssertEqual(tapped.map(\.isSecret), [false, false, false, false])
        await rig.client.disconnect()
    }

    /// Angstrom-only: D19 — a request-phase `.timedOut` is `.bluetoothTimedOut` (drop-class): the link is dropped
    func testRequestTimeoutIsBluetoothTimedOut() async throws {
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        let rig = makeRig(link)
        _ = try await rig.client.setPower(on: true)
        link.onRead = { _ in throw BluetoothTransportError.timedOut("read 0a0b7847") }

        await assertThrows(.bluetoothTimedOut("read 0a0b7847")) {
            try await rig.client.isPlumbedIn()
        }
        await rig.client.drainBackgroundWorkForTesting()

        let connected = await rig.client.isConnected
        XCTAssertFalse(connected)
        XCTAssertEqual(Array(link.recordedOps.suffix(3)),
                       [.write(readChar, Data("isPlumbedIn".utf8) + [0x00]), .read(readChar), .disconnect])
        XCTAssertEqual(Array(link.requestedTimeouts.suffix(2)), [.seconds(20), .seconds(20)])
        await rig.client.disconnect()
    }

    // MARK: - Helpers

    private struct Rig {
        let central: FakeBluetoothCentral
        let sleeper: ManualBluetoothSleeper
        let client: LaMarzoccoBluetoothClient
    }

    /// A client whose first connect returns `link`.
    private func makeRig(_ link: FakeBluetoothLink) -> Rig {
        let central = FakeBluetoothCentral()
        central.enqueueConnect(.success(link))
        let sleeper = ManualBluetoothSleeper()
        let client = LaMarzoccoBluetoothClient(transport: .fake(central, sleeper: sleeper), peripheral: .fake,
                                               token: BluetoothAuthToken("token"))
        return Rig(central: central, sleeper: sleeper, client: client)
    }

    /// Everything the stream has buffered right now, in order (the draining task is cancelled up front).
    private func drain<Element: Sendable>(_ stream: AsyncStream<Element>) async -> [Element] {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var elements: [Element] = []
            for await element in stream {
                elements.append(element)
            }
            return elements
        }.value
    }

    private func assertThrows<T>(_ expected: LaMarzoccoError, _ message: String = "",
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ operation: () async throws -> T) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected) \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, expected, "\(message) got \(error)", file: file, line: line)
        }
    }
}

// MARK: - Private test doubles

/// A lock-protected value shared with `@Sendable` closures.
private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

/// One-shot gate: `wait()` suspends until `open()`; afterwards it returns at once.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

/// Hands out `first` on the first connect, then defers to the wrapped FakeBluetoothCentral.
private final class HandOffCentral: BluetoothCentral, @unchecked Sendable {
    private let inner: FakeBluetoothCentral
    private let lock = NSLock()
    private var first: (any BluetoothLink)?
    private var count = 0

    init(_ inner: FakeBluetoothCentral, first: any BluetoothLink) {
        self.inner = inner
        self.first = first
    }

    var connectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func availability() async -> BluetoothAvailability { await inner.availability() }

    func availabilityUpdates() -> AsyncStream<BluetoothAvailability> { inner.availabilityUpdates() }

    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] { try await inner.scan(for: duration) }

    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        let handed: (any BluetoothLink)? = {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            let link = first
            first = nil
            return link
        }()
        if let handed { return handed }
        return try await inner.connect(to: id, timeout: timeout)
    }
}

/// After a successful write to `target`, the peripheral drops; the write only returns once the client
/// has processed the `.disconnected` event (`resume` is opened by the test on `.disconnected`).
private final class DropAfterWriteLink: BluetoothLink, @unchecked Sendable {
    let inner: FakeBluetoothLink
    private let target: GATTUUID
    private let resume: Gate

    init(_ inner: FakeBluetoothLink, target: GATTUUID, resume: Gate) {
        self.inner = inner
        self.target = target
        self.resume = resume
    }

    var peripheralID: BluetoothPeripheralID { inner.peripheralID }
    var events: AsyncStream<LinkEvent> { inner.events }

    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        try await inner.discover(wanted, refresh: refresh, timeout: timeout)
    }

    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data {
        try await inner.read(characteristic, timeout: timeout)
    }

    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        try await inner.write(data, to: characteristic, withResponse: withResponse, timeout: timeout)
        if characteristic == target {
            inner.drop(.disconnected(code: 7))
            await resume.wait()
        }
    }

    func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws {
        try await inner.subscribe(characteristic, timeout: timeout)
    }

    func unsubscribe(_ characteristic: GATTUUID) async { await inner.unsubscribe(characteristic) }

    func disconnect() async { await inner.disconnect() }

    func attMTU() async -> Int? { await inner.attMTU() }

    func gattTable(timeout: Duration) async throws -> [BluetoothGATTService] {
        try await inner.gattTable(timeout: timeout)
    }
}

extension LaMarzoccoBluetoothClient {
    /// Runs `body` on the actor: read or set internal state from a test.
    fileprivate func peek<T: Sendable>(_ body: @Sendable (isolated LaMarzoccoBluetoothClient) -> T) -> T {
        body(self)
    }
}
