import XCTest
@testable import Angstrom
import AngstromTestSupport

/// Self-tests of the AngstromTestSupport fakes (SPEC §6.17, §9.2), driven by hand: every later client
/// test runs on them, so each documented behaviour is pinned here with exact values.
final class FakeBluetoothTests: XCTestCase {
    private let read = BluetoothConstants.readCharacteristic
    private let write = BluetoothConstants.writeCharacteristic
    private let token = BluetoothConstants.tokenCharacteristic
    private let auth = BluetoothConstants.authCharacteristic
    private let shot = BluetoothConstants.shotCounterCharacteristic
    private let opTimeout: Duration = .seconds(20)

    // MARK: - FakeBluetoothCentral

    /// Angstrom-only: §6.17 — `connect` pops queued outcomes in order, then falls back to `makeLink()`
    /// (default `.laMarzocco(token: "token")`, a new link per call).
    func testCentralPopsQueuedOutcomesThenMakeLink() async throws {
        let central = FakeBluetoothCentral()
        let queued = FakeBluetoothLink(peripheralID: BluetoothPeripheralID(rawValue: "queued"))
        let made = FakeBluetoothLink(peripheralID: BluetoothPeripheralID(rawValue: "made"))
        let makeCalls = Counter()
        central.makeLink = { makeCalls.increment(); return made }
        central.enqueueConnect(.success(queued))
        central.enqueueConnect(.failure(.timedOut("connect")))

        let first = try await central.connect(to: .fake, timeout: opTimeout)
        XCTAssertTrue(first === queued)
        XCTAssertEqual(first.peripheralID, BluetoothPeripheralID(rawValue: "queued"))
        XCTAssertEqual(makeCalls.value, 0)

        do {
            _ = try await central.connect(to: .fake, timeout: opTimeout)
            XCTFail("the queued failure must be thrown")
        } catch let error as BluetoothTransportError {
            XCTAssertEqual(error, .timedOut("connect"))
        }
        XCTAssertEqual(makeCalls.value, 0)

        let third = try await central.connect(to: .fake, timeout: opTimeout)
        let fourth = try await central.connect(to: .fake, timeout: opTimeout)
        XCTAssertTrue(third === made)
        XCTAssertTrue(fourth === made)
        XCTAssertEqual(makeCalls.value, 2)
        let links = central.links
        XCTAssertEqual(links.count, 3)
        XCTAssertTrue(links[0] === queued)
        XCTAssertTrue(links[1] === made)
        XCTAssertTrue(links[2] === made)

        // The default `makeLink` builds a fresh machine accepting "token" on every connect.
        let plain = FakeBluetoothCentral()
        let a = try await plain.connect(to: .fake, timeout: opTimeout)
        let b = try await plain.connect(to: .fake, timeout: opTimeout)
        XCTAssertFalse(a === b)
        XCTAssertEqual(a.peripheralID, .fake)
        try await a.write(Data("token".utf8), to: auth, withResponse: true, timeout: opTimeout)
        let confirmed = try await a.read(auth, timeout: opTimeout)
        XCTAssertEqual(confirmed, Data([0x01]))
        try await b.write(Data("other".utf8), to: auth, withResponse: true, timeout: opTimeout)
        let rejected = try await b.read(auth, timeout: opTimeout)
        XCTAssertEqual(rejected, Data([0x00]))
        let command = try await a.read(write, timeout: opTimeout)
        XCTAssertEqual(command, BluetoothTestVectors.commandSuccess)
    }

    /// Angstrom-only: §6.17 — every `connect` call (successful or not) is counted and its timeout recorded;
    /// only successful ones are appended to `links`.
    func testConnectCountAndTimeoutsRecorded() async throws {
        let central = FakeBluetoothCentral()
        XCTAssertEqual(central.connectCount, 0)
        XCTAssertEqual(central.connectTimeouts, [])
        XCTAssertTrue(central.links.isEmpty)

        _ = try await central.connect(to: .fake, timeout: .seconds(20))
        central.enqueueConnect(.failure(.unknownPeripheral(.fake)))
        do {
            _ = try await central.connect(to: .fake, timeout: .seconds(10))
            XCTFail("the queued failure must be thrown")
        } catch let error as BluetoothTransportError {
            XCTAssertEqual(error, .unknownPeripheral(.fake))
        }
        _ = try await central.connect(to: .fake, timeout: .milliseconds(500))

        XCTAssertEqual(central.connectCount, 3)
        XCTAssertEqual(central.connectTimeouts, [.seconds(20), .seconds(10), .milliseconds(500)])
        XCTAssertEqual(central.links.count, 2)
    }

    /// Angstrom-only: §6.17 — availability defaults to `.poweredOn`; `setAvailability` sets the state and
    /// yields it on every open `availabilityUpdates()` stream, which only sees changes after its creation.
    func testAvailabilityUpdatesYieldOnSet() async throws {
        let central = FakeBluetoothCentral()
        let initial = await central.availability()
        XCTAssertEqual(initial, .poweredOn)

        var first = central.availabilityUpdates().makeAsyncIterator()
        var second = central.availabilityUpdates().makeAsyncIterator()
        central.setAvailability(.poweredOff)
        central.setAvailability(.unauthorized(.denied))
        let current = await central.availability()
        XCTAssertEqual(current, .unauthorized(.denied))

        var late = central.availabilityUpdates().makeAsyncIterator()
        central.setAvailability(.poweredOn)

        var firstSeen: [BluetoothAvailability?] = []
        var secondSeen: [BluetoothAvailability?] = []
        for _ in 0..<3 {
            firstSeen.append(await first.next())
            secondSeen.append(await second.next())
        }
        XCTAssertEqual(firstSeen, [.poweredOff, .unauthorized(.denied), .poweredOn])
        XCTAssertEqual(secondSeen, [.poweredOff, .unauthorized(.denied), .poweredOn])
        let lateFirst = await late.next()
        XCTAssertEqual(lateFirst, .poweredOn)
        let after = await central.availability()
        XCTAssertEqual(after, .poweredOn)
    }

    // MARK: - FakeBluetoothLink

    /// Angstrom-only: §6.17 — every seam op is appended to `recordedOps` in call order, with its arguments.
    func testLinkRecordsOpsInOrder() async throws {
        let link = FakeBluetoothLink()
        link.replayOnSubscribe = []
        let writes = Recorder<FakeOp>()
        link.onWrite = { characteristic, data in writes.append(.write(characteristic, data)) }
        link.onRead = { characteristic in
            XCTAssertEqual(characteristic, BluetoothConstants.readCharacteristic)
            return Data([0x07])
        }

        _ = try await link.discover(BluetoothConstants.sessionCharacteristics, refresh: false, timeout: opTimeout)
        try await link.write(Data("boilers\0".utf8), to: read, withResponse: true, timeout: opTimeout)
        let value = try await link.read(read, timeout: opTimeout)
        try await link.subscribe(shot, timeout: opTimeout)
        await link.unsubscribe(shot)
        _ = try await link.discover([shot], refresh: true, timeout: opTimeout)
        await link.disconnect()

        XCTAssertEqual(value, Data([0x07]))
        XCTAssertEqual(writes.values, [.write(read, Data("boilers\0".utf8))])
        XCTAssertEqual(link.recordedOps, [
            .discover(refresh: false),
            .write(read, Data("boilers\0".utf8)),
            .read(read),
            .subscribe(shot),
            .unsubscribe(shot),
            .discover(refresh: true),
            .disconnect,
        ])
    }

    /// Angstrom-only: §6.17 — `discover(wanted, refresh:)` returns
    /// `wanted ∩ (refresh ? (presentAfterRefresh ?? present) : present)`; `present` defaults to all five.
    func testDiscoverHonoursPresentAndPresentAfterRefresh() async throws {
        let link = FakeBluetoothLink()
        let allFive: Set<GATTUUID> = [read, write, token, auth, shot]
        XCTAssertEqual(link.present, allFive)
        XCTAssertNil(link.presentAfterRefresh)

        let unknown = GATTUUID("0f0b7847-e12b-09a8-b04b-8e0922a9abab")
        let cached = try await link.discover(allFive.union([unknown]), refresh: false, timeout: opTimeout)
        XCTAssertEqual(cached, allFive)
        let refreshedDefault = try await link.discover([auth, unknown], refresh: true, timeout: opTimeout)
        XCTAssertEqual(refreshedDefault, [auth])

        link.present = [read, write, auth]
        link.presentAfterRefresh = [read, write, auth, shot]
        let session = BluetoothConstants.sessionCharacteristics
        let stale = try await link.discover(session, refresh: false, timeout: opTimeout)
        XCTAssertEqual(stale, [read, write, auth])
        let refreshed = try await link.discover(session, refresh: true, timeout: opTimeout)
        XCTAssertEqual(refreshed, [read, write, auth, shot])
        let notWanted = try await link.discover([token], refresh: true, timeout: opTimeout)
        XCTAssertEqual(notWanted, [])
        // `refresh: true` does not change what a later cached discovery reports.
        let cachedAgain = try await link.discover(session, refresh: false, timeout: opTimeout)
        XCTAssertEqual(cachedAgain, [read, write, auth])

        XCTAssertEqual(link.recordedOps, [
            .discover(refresh: false), .discover(refresh: true), .discover(refresh: false),
            .discover(refresh: true), .discover(refresh: true), .discover(refresh: false),
        ])
    }

    /// Angstrom-only: §6.17 — the scripted machine confirms auth from the `confirmOnRead`-th read after a
    /// write whose bytes equal UTF8(token); every auth write resets the count (TBC:246-261).
    func testScriptedAuthConfirmsOnNthRead() async throws {
        let link = FakeBluetoothLink.laMarzocco(token: "secret", confirmOnRead: 3)
        let beforeWrite = try await authReads(link, 2)
        XCTAssertEqual(beforeWrite, [0x00, 0x00])

        try await link.write(Data("secret".utf8), to: auth, withResponse: true, timeout: opTimeout)
        let afterMatch = try await authReads(link, 4)
        XCTAssertEqual(afterMatch, [0x00, 0x00, 0x01, 0x01])

        try await link.write(Data("wrong".utf8), to: auth, withResponse: true, timeout: opTimeout)
        let afterMismatch = try await authReads(link, 4)
        XCTAssertEqual(afterMismatch, [0x00, 0x00, 0x00, 0x00])

        // A NUL-terminated token is not the token.
        try await link.write(Data("secret\0".utf8), to: auth, withResponse: true, timeout: opTimeout)
        let afterNul = try await authReads(link, 3)
        XCTAssertEqual(afterNul, [0x00, 0x00, 0x00])

        try await link.write(Data("secret".utf8), to: auth, withResponse: true, timeout: opTimeout)
        let afterRewrite = try await authReads(link, 3)
        XCTAssertEqual(afterRewrite, [0x00, 0x00, 0x01])

        // A write to another characteristic neither authenticates nor resets the count.
        try await link.write(Data("secret".utf8), to: write, withResponse: true, timeout: opTimeout)
        let afterOtherWrite = try await authReads(link, 1)
        XCTAssertEqual(afterOtherWrite, [0x01])

        let quick = FakeBluetoothLink.laMarzocco(token: "token")
        try await quick.write(Data("token".utf8), to: auth, withResponse: true, timeout: opTimeout)
        let defaultConfirm = try await authReads(quick, 2)
        XCTAssertEqual(defaultConfirm, [0x01, 0x01])
    }

    /// Angstrom-only: §6.17 — 0b0b… reads return `commandResponse`; 0a0b… reads return the response of the
    /// setting named by the last 0a0b… write (NUL removed), else `[]`; other reads throw.
    func testScriptedSettingAndCommandResponses() async throws {
        let link = FakeBluetoothLink.laMarzocco(
            token: "t", commandResponse: Data("cmd".utf8),
            settingResponses: [.boilers: Data("B".utf8), .machineMode: Data("M".utf8)])

        let unasked = try await link.read(read, timeout: opTimeout)
        XCTAssertEqual(unasked, Data("[]".utf8))

        try await link.write(Data("boilers\0".utf8), to: read, withResponse: true, timeout: opTimeout)
        let boilers = try await link.read(read, timeout: opTimeout)
        XCTAssertEqual(boilers, Data("B".utf8))
        // A command write does not change the selected setting, and a re-read repeats the answer.
        try await link.write(Data("{}".utf8), to: write, withResponse: true, timeout: opTimeout)
        let boilersAgain = try await link.read(read, timeout: opTimeout)
        XCTAssertEqual(boilersAgain, Data("B".utf8))

        try await link.write(Data("machineMode\0".utf8), to: read, withResponse: true, timeout: opTimeout)
        let mode = try await link.read(read, timeout: opTimeout)
        XCTAssertEqual(mode, Data("M".utf8))

        try await link.write(Data("tankStatus\0".utf8), to: read, withResponse: true, timeout: opTimeout)
        let unscripted = try await link.read(read, timeout: opTimeout)
        XCTAssertEqual(unscripted, Data("[]".utf8))

        try await link.write(Data("bogus\0".utf8), to: read, withResponse: true, timeout: opTimeout)
        let unknown = try await link.read(read, timeout: opTimeout)
        XCTAssertEqual(unknown, Data("[]".utf8))

        try await link.write(Data("boilers".utf8), to: read, withResponse: true, timeout: opTimeout)
        let withoutNul = try await link.read(read, timeout: opTimeout)
        XCTAssertEqual(withoutNul, Data("B".utf8))

        let command = try await link.read(write, timeout: opTimeout)
        XCTAssertEqual(command, Data("cmd".utf8))

        do {
            _ = try await link.read(token, timeout: opTimeout)
            XCTFail("the scripted machine has no token value")
        } catch let error as BluetoothTransportError {
            XCTAssertEqual(error, .characteristicNotFound(token))
        }

        let defaults = FakeBluetoothLink.laMarzocco(token: "t")
        let defaultCommand = try await defaults.read(write, timeout: opTimeout)
        XCTAssertEqual(defaultCommand, BluetoothTestVectors.commandSuccess)
        try await defaults.write(Data("boilers\0".utf8), to: read, withResponse: true, timeout: opTimeout)
        let defaultSetting = try await defaults.read(read, timeout: opTimeout)
        XCTAssertEqual(defaultSetting, Data("[]".utf8))
    }

    /// Angstrom-only: §6.17 — every `replayOnSubscribe` value is yielded as a notification stamped `now()`
    /// before `subscribe` returns (upstream delivers the replay inside `start_notify`, TBC:272-273).
    func testReplayDeliveredBeforeSubscribeReturns() async throws {
        let link = FakeBluetoothLink()
        let stamp = Date(timeIntervalSince1970: 1_000)
        link.now = { stamp }
        link.replayOnSubscribe = [Data("r1".utf8), Data("r2".utf8)]

        try await link.subscribe(shot, timeout: opTimeout)
        // Anything yielded after `subscribe` returned would come after this terminal event.
        link.drop(nil)

        let events = await collect(link)
        XCTAssertEqual(events, [
            .notification(shot, GATTNotification(value: Data("r1".utf8), receivedAt: stamp)),
            .notification(shot, GATTNotification(value: Data("r2".utf8), receivedAt: stamp)),
            .disconnected(nil),
        ])
        XCTAssertEqual(link.recordedOps, [.subscribe(shot)])
    }

    /// Angstrom-only: §6.17 — `replayOnSubscribe` defaults to `[tick("3.34")]`, upstream's
    /// `self.replay = _tick(3.34)` (TBC:176); `[]` delivers nothing (upstream `replay = None`).
    func testDefaultReplayIsTick334() async throws {
        let expected = Data(
            #"{"BrewingUpdateGroup1Time": 3.34, "BrewingUpdateGroup1Ev": true, "BrewingUpdateGroup1Backflush": false}"#.utf8)
        let link = FakeBluetoothLink()
        XCTAssertEqual(link.replayOnSubscribe, [expected])
        XCTAssertEqual(FakeBluetoothLink.laMarzocco(token: "token").replayOnSubscribe, [expected])

        try await link.subscribe(shot, timeout: opTimeout)
        link.drop(nil)
        let events = await collect(link)
        XCTAssertEqual(events, [
            .notification(shot, GATTNotification(value: expected, receivedAt: Date(timeIntervalSince1970: 0))),
            .disconnected(nil),
        ])

        let silent = FakeBluetoothLink()
        silent.replayOnSubscribe = []
        try await silent.subscribe(shot, timeout: opTimeout)
        silent.drop(nil)
        let silentEvents = await collect(silent)
        XCTAssertEqual(silentEvents, [.disconnected(nil)])
    }

    /// Angstrom-only: §6.17 — `BluetoothTransport.fake` wires `clock.now` into the transport and the
    /// central, and `connect` copies it into every link (queued or made), so replays carry clock time.
    func testReplayStampedWithTransportClock() async throws {
        let start = Date(timeIntervalSince1970: 1_791_183_600)   // 2026-10-05T07:00:00Z, upstream FakeClock
        let clock = BluetoothTestClock(start)
        let central = FakeBluetoothCentral()
        let sleeper = ManualBluetoothSleeper()
        let queued = FakeBluetoothLink()
        queued.replayOnSubscribe = [BluetoothTestVectors.tick("1.0")]
        central.enqueueConnect(.success(queued))

        let transport = BluetoothTransport.fake(central, sleeper: sleeper, clock: clock)
        XCTAssertTrue((transport.central as? FakeBluetoothCentral) === central)
        XCTAssertTrue((transport.sleeper as? ManualBluetoothSleeper) === sleeper)
        XCTAssertEqual(transport.now(), start)
        XCTAssertEqual(central.now(), start)
        XCTAssertEqual(queued.now(), Date(timeIntervalSince1970: 0), "not wired before connect")

        clock.advance(by: 2.5)
        XCTAssertEqual(transport.now(), start.addingTimeInterval(2.5))
        let first = try await transport.central.connect(to: .fake, timeout: opTimeout)
        XCTAssertTrue(first === queued)
        XCTAssertEqual(queued.now(), start.addingTimeInterval(2.5))
        try await first.subscribe(shot, timeout: opTimeout)

        let later = Date(timeIntervalSince1970: 1_791_209_738)
        clock.set(later)
        let made = try await transport.central.connect(to: .fake, timeout: opTimeout)
        try await made.subscribe(shot, timeout: opTimeout)

        // `notify(_:_:at:)` uses the given time, not the clock.
        let explicit = Date(timeIntervalSince1970: 42)
        queued.notify(shot, Data("x".utf8), at: explicit)

        queued.drop(nil)
        let queuedEvents = await collect(queued)
        XCTAssertEqual(queuedEvents, [
            .notification(shot, GATTNotification(value: BluetoothTestVectors.tick("1.0"),
                                                 receivedAt: start.addingTimeInterval(2.5))),
            .notification(shot, GATTNotification(value: Data("x".utf8), receivedAt: explicit)),
            .disconnected(nil),
        ])
        let madeLink = try XCTUnwrap(made as? FakeBluetoothLink)
        madeLink.drop(nil)
        let madeEvents = await collect(madeLink)
        XCTAssertEqual(madeEvents, [
            .notification(shot, GATTNotification(value: BluetoothTestVectors.tick("3.34"), receivedAt: later)),
            .disconnected(nil),
        ])

        // Defaults: a fresh central's and link's clocks read the epoch.
        XCTAssertEqual(FakeBluetoothCentral().now(), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(FakeBluetoothLink().now(), Date(timeIntervalSince1970: 0))
    }

    /// Angstrom-only: §6.17 — `drop(_:)` yields `.disconnected(error)` exactly once, after every earlier
    /// event, and finishes `events`; nothing is yielded afterwards.
    func testDropYieldsDisconnectedOnceAndFinishes() async throws {
        let link = FakeBluetoothLink()
        let before = Date(timeIntervalSince1970: 7)
        link.notify(shot, Data("n1".utf8), at: before)
        link.invalidateServices()

        link.drop(.disconnected(code: 7))
        link.drop(.timedOut("again"))
        link.notify(shot, Data("late".utf8), at: before)
        link.invalidateServices()
        await link.disconnect()

        let events = await collect(link)
        XCTAssertEqual(events, [
            .notification(shot, GATTNotification(value: Data("n1".utf8), receivedAt: before)),
            .servicesInvalidated,
            .disconnected(.disconnected(code: 7)),
        ])
        XCTAssertEqual(link.recordedOps, [.disconnect])
        // The stream stays finished.
        let again = await collect(link)
        XCTAssertEqual(again, [])
    }

    /// Angstrom-only: §6.17 — after a drop every throwing op throws `.notConnected` (and is still recorded),
    /// the handlers are not called, no replay is delivered, and the non-throwing ops return.
    func testOpsAfterDropThrowNotConnected() async throws {
        let link = FakeBluetoothLink()
        link.mtu = 185
        link.gatt = [BluetoothGATTService(uuid: "s", characteristics: [])]
        let handlerCalls = Counter()
        link.onRead = { _ in handlerCalls.increment(); return Data([1]) }
        link.onWrite = { _, _ in handlerCalls.increment() }
        link.drop(nil)

        await assertNotConnected { _ = try await link.discover([self.auth], refresh: false, timeout: self.opTimeout) }
        await assertNotConnected { _ = try await link.read(self.read, timeout: self.opTimeout) }
        await assertNotConnected {
            try await link.write(Data("x".utf8), to: self.write, withResponse: true, timeout: self.opTimeout)
        }
        await assertNotConnected { try await link.subscribe(self.shot, timeout: self.opTimeout) }
        await assertNotConnected { _ = try await link.gattTable(timeout: self.opTimeout) }
        await link.unsubscribe(shot)
        await link.disconnect()
        let mtu = await link.attMTU()
        XCTAssertEqual(mtu, 185)

        XCTAssertEqual(handlerCalls.value, 0)
        XCTAssertEqual(link.recordedOps, [
            .discover(refresh: false), .read(read), .write(write, Data("x".utf8)), .subscribe(shot),
            .unsubscribe(shot), .disconnect,
        ])
        let events = await collect(link)
        XCTAssertEqual(events, [.disconnected(nil)])

        // While connected the same link serves its diagnostics.
        let live = FakeBluetoothLink()
        live.gatt = [BluetoothGATTService(uuid: "s", characteristics: [])]
        let table = try await live.gattTable(timeout: opTimeout)
        XCTAssertEqual(table, [BluetoothGATTService(uuid: "s", characteristics: [])])
        let liveMTU = await live.attMTU()
        XCTAssertNil(liveMTU)
    }

    /// Angstrom-only: §9.2 — a user `disconnect()` records `.disconnect`, then yields `.disconnected(nil)`
    /// once and finishes `events`, as bleak reports it through the disconnected callback (TBC:278-281).
    func testUserDisconnectYieldsDisconnected() async throws {
        let link = FakeBluetoothLink()
        let at = Date(timeIntervalSince1970: 3)
        link.notify(shot, Data("n".utf8), at: at)
        await link.disconnect()
        await link.disconnect()

        let events = await collect(link)
        XCTAssertEqual(events, [
            .notification(shot, GATTNotification(value: Data("n".utf8), receivedAt: at)),
            .disconnected(nil),
        ])
        XCTAssertEqual(link.recordedOps, [.disconnect, .disconnect])
        await assertNotConnected { _ = try await link.read(self.write, timeout: self.opTimeout) }
        XCTAssertEqual(link.recordedOps, [.disconnect, .disconnect, .read(write)])
    }

    /// Angstrom-only: §6.17 — `beforeOp` is awaited before an op is recorded, so a test can hold one op in
    /// flight while others proceed; a drop while held makes the held op throw `.notConnected`.
    func testBeforeOpHoldsOperation() async throws {
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        let gate = Gate()
        link.beforeOp = { op in await gate.arrive(op, hold: Self.isWrite(op)) }
        let frame = Data("{\"name\":\"MachineChangeMode\"}".utf8)
        let (writeUUID, authUUID, timeout) = (write, auth, opTimeout)

        let held = Task { try await link.write(frame, to: writeUUID, withResponse: true, timeout: timeout) }
        let arrived = await gate.waitForHeld()
        XCTAssertEqual(arrived, .write(write, frame))
        XCTAssertEqual(link.recordedOps, [], "a held op is not recorded yet")

        // Other ops pass while the write is held, and are recorded first.
        let command = try await link.read(write, timeout: opTimeout)
        XCTAssertEqual(command, BluetoothTestVectors.commandSuccess)
        XCTAssertEqual(link.recordedOps, [.read(write)])

        gate.release()
        try await held.value
        XCTAssertEqual(link.recordedOps, [.read(write), .write(write, frame)])
        XCTAssertEqual(gate.seen, [.write(write, frame), .read(write)])

        // A drop while an op is held: once released it is recorded and throws `.notConnected`.
        let second = Task { try await link.write(frame, to: authUUID, withResponse: true, timeout: timeout) }
        let secondArrived = await gate.waitForHeld()
        XCTAssertEqual(secondArrived, .write(auth, frame))
        link.drop(.disconnected(code: nil))
        gate.release()
        let result = await second.result
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? BluetoothTransportError, .notConnected)
        }
        XCTAssertEqual(link.recordedOps, [.read(write), .write(write, frame), .write(auth, frame)])
    }

    // MARK: - ManualBluetoothSleeper

    /// Angstrom-only: §6.17 — manual sleeps suspend until `fire` (oldest first) or cancellation, which
    /// throws `CancellationError` and removes the sleep from pending.
    func testManualSleeperFireAndCancel() async throws {
        let sleeper = ManualBluetoothSleeper()
        await sleeper.waitForPending(.idleDisconnect, count: 0)   // already satisfied
        XCTAssertEqual(sleeper.pendingCount(.idleDisconnect), 0)

        let oldest = Task { try await sleeper.sleep(for: .seconds(30), purpose: .idleDisconnect) }
        await sleeper.waitForPending(.idleDisconnect, count: 1)
        let newest = Task { try await sleeper.sleep(for: .seconds(31), purpose: .idleDisconnect) }
        await sleeper.waitForPending(.idleDisconnect, count: 2)
        XCTAssertEqual(sleeper.pendingCount(.idleDisconnect), 2)
        XCTAssertEqual(sleeper.startedCount(.idleDisconnect), 2)
        XCTAssertEqual(sleeper.requested(.idleDisconnect), [.seconds(30), .seconds(31)])

        sleeper.fire(.idleDisconnect)
        XCTAssertEqual(sleeper.pendingCount(.idleDisconnect), 1)
        // Cancelling both now: the fired (oldest) one already returned, the newest one is cancelled.
        oldest.cancel()
        newest.cancel()
        let oldestResult = await oldest.result
        let newestResult = await newest.result
        XCTAssertNoThrow(try oldestResult.get())
        XCTAssertThrowsError(try newestResult.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(sleeper.pendingCount(.idleDisconnect), 0)
        sleeper.fire(.idleDisconnect)   // nothing pending: no-op
        XCTAssertEqual(sleeper.startedCount(.idleDisconnect), 2)

        // A sleep requested by an already-cancelled task throws at once and is never pending.
        let cancelledEarly = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await sleeper.sleep(for: .seconds(32), purpose: .idleDisconnect)
        }
        let earlyResult = await cancelledEarly.result
        XCTAssertThrowsError(try earlyResult.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(sleeper.pendingCount(.idleDisconnect), 0)
        XCTAssertEqual(sleeper.requested(.idleDisconnect), [.seconds(30), .seconds(31), .seconds(32)])

        // A pending sleep resumed by `fire` lets its task run on.
        let third = Task { () throws -> String in
            try await sleeper.sleep(for: .seconds(30), purpose: .idleDisconnect)
            return "fired"
        }
        await sleeper.waitForPending(.idleDisconnect, count: 1)
        sleeper.fire(.idleDisconnect)
        let thirdValue = try await third.value
        XCTAssertEqual(thirdValue, "fired")
        XCTAssertEqual(sleeper.pendingCount(.idleDisconnect), 0)
    }

    /// Angstrom-only: §6.17 — purposes outside `manual` return at once (so the default `.poweredOnWait`
    /// sleep ends immediately) and every requested duration is recorded per purpose, in order.
    func testNonManualSleepRecordsDuration() async throws {
        let sleeper = ManualBluetoothSleeper()
        try await sleeper.sleep(for: .milliseconds(50), purpose: .authPoll)
        try await sleeper.sleep(for: .milliseconds(50), purpose: .authPoll)
        try await sleeper.sleep(for: .milliseconds(250), purpose: .connectBackoff)
        try await sleeper.sleep(for: .milliseconds(100), purpose: .connectBackoff)
        try await sleeper.sleep(for: .seconds(1), purpose: .reconnectBackoff)
        try await sleeper.sleep(for: .seconds(2), purpose: .reconnectBackoff)
        try await sleeper.sleep(for: .seconds(10), purpose: .poweredOnWait)

        XCTAssertEqual(sleeper.requested(.authPoll), [.milliseconds(50), .milliseconds(50)])
        XCTAssertEqual(sleeper.requested(.connectBackoff), [.milliseconds(250), .milliseconds(100)])
        XCTAssertEqual(sleeper.requested(.reconnectBackoff), [.seconds(1), .seconds(2)])
        XCTAssertEqual(sleeper.requested(.poweredOnWait), [.seconds(10)])
        XCTAssertEqual(sleeper.requested(.idleDisconnect), [])
        XCTAssertEqual(sleeper.startedCount(.authPoll), 2)
        XCTAssertEqual(sleeper.startedCount(.idleDisconnect), 0)
        for purpose: SleepPurpose in [.authPoll, .connectBackoff, .reconnectBackoff, .poweredOnWait] {
            XCTAssertEqual(sleeper.pendingCount(purpose), 0)
        }

        // A non-manual sleep still honours the protocol's cancellation contract.
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await sleeper.sleep(for: .milliseconds(50), purpose: .authPoll)
        }
        let cancelledResult = await cancelled.result
        XCTAssertThrowsError(try cancelledResult.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(sleeper.requested(.authPoll), [.milliseconds(50), .milliseconds(50), .milliseconds(50)])

        // With `.poweredOnWait` manual, that sleep suspends until fired.
        let waiting = ManualBluetoothSleeper(manual: [.idleDisconnect, .poweredOnWait])
        let wait = Task { try await waiting.sleep(for: .seconds(10), purpose: .poweredOnWait) }
        await waiting.waitForPending(.poweredOnWait, count: 1)
        XCTAssertEqual(waiting.pendingCount(.poweredOnWait), 1)
        XCTAssertEqual(waiting.pendingCount(.idleDisconnect), 0)
        waiting.fire(.poweredOnWait)
        try await wait.value
        XCTAssertEqual(waiting.pendingCount(.poweredOnWait), 0)
        XCTAssertEqual(waiting.requested(.poweredOnWait), [.seconds(10)])
        try await waiting.sleep(for: .milliseconds(50), purpose: .authPoll)
        XCTAssertEqual(waiting.requested(.authPoll), [.milliseconds(50)])
    }

    // MARK: - BluetoothTestClock, vectors, recording

    /// Angstrom-only: §6.17 — `now` reads the clock at call time; `set` replaces it and `advance` adds
    /// seconds (upstream `FakeClock`, TBC:86-105). Also pins `BluetoothPeripheralID.fake`.
    func testClockSetAndAdvance() {
        let clock = BluetoothTestClock(Date(timeIntervalSince1970: 100))
        let now = clock.now
        XCTAssertEqual(now(), Date(timeIntervalSince1970: 100))
        clock.advance(by: 2.5)
        XCTAssertEqual(now(), Date(timeIntervalSince1970: 102.5))
        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 102.5))
        clock.set(Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(now(), Date(timeIntervalSince1970: 5_000))
        clock.advance(by: -1)
        XCTAssertEqual(now(), Date(timeIntervalSince1970: 4_999))

        XCTAssertEqual(BluetoothPeripheralID.fake.rawValue, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(FakeBluetoothLink().peripheralID, .fake)
    }

    /// Angstrom-only: §6.17 — `tick` renders `json.dumps` default separators (`_tick`, TBC:51-59) and the
    /// constants are verbatim `COMMAND_SUCCESS`/`STARTED` (TBC:47-48).
    func testTickRendersPythonSeparators() {
        XCTAssertEqual(String(decoding: BluetoothTestVectors.tick("3.34"), as: UTF8.self),
                       #"{"BrewingUpdateGroup1Time": 3.34, "BrewingUpdateGroup1Ev": true, "BrewingUpdateGroup1Backflush": false}"#)
        XCTAssertEqual(String(decoding: BluetoothTestVectors.tick("0.64", backflush: true), as: UTF8.self),
                       #"{"BrewingUpdateGroup1Time": 0.64, "BrewingUpdateGroup1Ev": true, "BrewingUpdateGroup1Backflush": true}"#)
        XCTAssertEqual(String(decoding: BluetoothTestVectors.tick("10.0"), as: UTF8.self),
                       #"{"BrewingUpdateGroup1Time": 10.0, "BrewingUpdateGroup1Ev": true, "BrewingUpdateGroup1Backflush": false}"#)
        XCTAssertEqual(String(decoding: BluetoothTestVectors.commandSuccess, as: UTF8.self),
                       #"{"id":"test-id","message":"Success","status":"success"}"#)
        XCTAssertEqual(String(decoding: BluetoothTestVectors.started, as: UTF8.self),
                       #"{"BrewingStartedGroup1DoseIndex":"DoseA"}"#)
    }

    /// Angstrom-only: §9.3.4 — the `_load_sessions` port (TBC:894-909) yields 2 sessions and 80 data lines
    /// (67 + 13), each led by its stripped replay, with UTC 2026-10-05 millisecond timestamps.
    func testRecordingHasTwoSessionsAndEightyNotifications() throws {
        let sessions = try ShotCounterRecording.sessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map(\.count), [67, 13])
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.count }, 80)
        for session in sessions {
            XCTAssertEqual(session.map(\.isReplay), [true] + Array(repeating: false, count: session.count - 1))
        }

        let first = sessions[0], second = sessions[1]
        assertLine(first[0], "07:47:38.548",
                   #"{"BrewingUpdateGroup1Time":3.34,"BrewingUpdateGroup1Ev":true,"BrewingUpdateGroup1Backflush":false}"#)
        assertLine(first[1], "07:47:47.412", #"{"SteamBoilerUpdateTemperature":112}"#)
        assertLine(first[66], "07:59:42.983", #"{"Sleep":"command"}"#)
        assertLine(second[0], "08:36:59.441", #"{"Sleep":"command"}"#)
        assertLine(second[5], "08:37:40.800",
                   #"{"CoffeeBoiler1HeatingCoeff":"[{\"temperature\":17,\"coefficent\":0.4083},{\"temperature\":40,\"coefficent\":0.4121},{\"temperature\":60,\"coefficent\":0.4176},{\"temperature\":80,\"coefficent\":0.4252},{\"temperature\":95,\"coefficent\":0.4317}]"}"#)
        assertLine(second[12], "08:37:57.458", #"{"SteamBoilerUpdateTemperature":115}"#)

        let all = sessions.flatMap { $0 }
        XCTAssertFalse(all.contains { String(decoding: $0.payload, as: UTF8.self).contains("#") })
        for (earlier, later) in zip(all, all.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.receivedAt, later.receivedAt)
        }
    }

    // MARK: - Helpers

    private static func isWrite(_ op: FakeOp) -> Bool {
        if case .write = op { return true }
        return false
    }

    private func authReads(_ link: FakeBluetoothLink, _ count: Int) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        for _ in 0..<count {
            let value = try await link.read(auth, timeout: opTimeout)
            XCTAssertEqual(value.count, 1)
            bytes.append(contentsOf: value)
        }
        return bytes
    }

    /// Every event of a link whose stream has already finished (or is about to).
    private func collect(_ link: FakeBluetoothLink) async -> [LinkEvent] {
        var events: [LinkEvent] = []
        for await event in link.events { events.append(event) }
        return events
    }

    private func assertNotConnected(_ body: () async throws -> Void,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected .notConnected", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BluetoothTransportError, .notConnected, file: file, line: line)
        }
    }

    /// Asserts a recording line's UTC time on 2026-10-05 (to the microsecond) and its exact payload.
    private func assertLine(_ line: ShotCounterRecording.Line, _ time: String, _ payload: String,
                            file: StaticString = #filePath, lineNumber: UInt = #line) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expected = formatter.date(from: "2026-10-05T\(time)Z") else {
            return XCTFail("bad expected time \(time)", file: file, line: lineNumber)
        }
        XCTAssertEqual(line.receivedAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1e-6,
                       file: file, line: lineNumber)
        XCTAssertEqual(String(decoding: line.payload, as: UTF8.self), payload, file: file, line: lineNumber)
    }
}

/// A thread-safe counter for `@Sendable` handler closures.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

/// A thread-safe append-only list for `@Sendable` handler closures.
private final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    var values: [Element] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ element: Element) { lock.lock(); storage.append(element); lock.unlock() }
}

/// Holds selected `beforeOp` calls until released; reports arrivals without polling.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var seenOps: [FakeOp] = []
    private var heldOp: (op: FakeOp, continuation: CheckedContinuation<Void, Never>)?
    private var arrivalWaiter: CheckedContinuation<FakeOp, Never>?

    var seen: [FakeOp] { lock.lock(); defer { lock.unlock() }; return seenOps }

    /// Called from `beforeOp`: records the op and, if `hold`, suspends until `release()`.
    func arrive(_ op: FakeOp, hold: Bool) async {
        guard hold else { return record(op) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            seenOps.append(op)
            heldOp = (op, continuation)
            let waiter = arrivalWaiter
            arrivalWaiter = nil
            lock.unlock()
            waiter?.resume(returning: op)
        }
    }

    private func record(_ op: FakeOp) {
        lock.lock()
        seenOps.append(op)
        lock.unlock()
    }

    /// Returns the held op once one is held.
    func waitForHeld() async -> FakeOp {
        await withCheckedContinuation { (continuation: CheckedContinuation<FakeOp, Never>) in
            lock.lock()
            if let held = heldOp {
                lock.unlock()
                continuation.resume(returning: held.op)
            } else {
                arrivalWaiter = continuation
                lock.unlock()
            }
        }
    }

    /// Resumes the held op.
    func release() {
        lock.lock()
        let held = heldOp
        heldOp = nil
        lock.unlock()
        held?.continuation.resume()
    }
}
