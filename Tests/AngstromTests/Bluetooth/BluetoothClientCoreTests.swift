import XCTest
@testable import Angstrom
import AngstromTestSupport

/// The client core (SPEC §4.1–§4.8, §3.4, §4.4.1): gates, connect, auth, idle, teardown, link
/// events, connection events and the raw tap, driven through the internal `ensureConnected()`,
/// `disconnect()` and link events over the AngstromTestSupport fakes.
final class BluetoothClientCoreTests: XCTestCase {
    private let auth = BluetoothConstants.authCharacteristic
    private let authUUIDString = "0d0b7847-e12b-09a8-b04b-8e0922a9abab"

    // MARK: Connect + auth

    /// Angstrom-only: §4.2 — one attempt, discovery of the four session characteristics, auth, idle armed, `.connected`; step 1 reuses the stored link
    func testEnsureConnectedDiscoversAndAuthenticates() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        await rig.client.inspect { client in
            client.needsRediscovery = true
            client.shotCounterSubscribed = true
        }

        let link = try await rig.client.ensureConnected()

        let fake = try XCTUnwrap(rig.central.links.first)
        XCTAssertTrue(link === fake)
        XCTAssertEqual(rig.central.connectCount, 1)
        XCTAssertEqual(rig.central.connectTimeouts, [.seconds(20)])
        XCTAssertEqual(rig.central.connectPeripheralIDs, [.fake])
        XCTAssertEqual(fake.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8)), .read(auth)])
        XCTAssertEqual(fake.requestedTimeouts, [.seconds(20), .seconds(20), .seconds(20)])
        XCTAssertEqual(rig.sleeper.requested(.authPoll), [])
        XCTAssertEqual(rig.sleeper.requested(.connectBackoff), [])
        let state = await rig.client.inspect { client in
            (client.isConnected, client.link === fake, client.discovered, client.needsRediscovery,
             client.shotCounterSubscribed, client.authenticationFailed, client.reportedConnected,
             client.linkWatcher != nil, client.gateBusy)
        }
        XCTAssertTrue(state.0)
        XCTAssertTrue(state.1)
        // Exactly the four session characteristics were asked for (the fake also has the token one).
        XCTAssertEqual(state.2, [BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
                                 BluetoothConstants.authCharacteristic, BluetoothConstants.shotCounterCharacteristic])
        XCTAssertFalse(state.3, "a successful connect clears needsRediscovery")
        XCTAssertFalse(state.4, "a new connection never has active notifications")
        XCTAssertFalse(state.5)
        XCTAssertTrue(state.6)
        XCTAssertTrue(state.7, "the link watcher runs")
        XCTAssertEqual(state.8, [], "the connection gate is released")

        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect), [.seconds(30)])

        // Step 1: the stored link is trusted and the idle timer is reset; no I/O.
        let again = try await rig.client.ensureConnected()
        XCTAssertTrue(again === fake)
        XCTAssertEqual(rig.central.connectCount, 1)
        XCTAssertEqual(fake.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8)), .read(auth)])
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        XCTAssertEqual(rig.sleeper.startedCount(.idleDisconnect), 2)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1, "the first idle sleep was cancelled")

        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected])

        // refresh: true is passed to discovery; the auth read is polled until it is exactly [0x01].
        let polled = makeRig()
        let scripted = FakeBluetoothLink()
        let replies = Locked<[Data]>([Data([0x00]), Data([0x01, 0x00]), Data(), Data([0x01])])
        scripted.onRead = { _ in replies.withLock { $0.removeFirst() } }
        polled.central.enqueueConnect(.success(scripted))
        _ = try await polled.client.ensureConnected(refresh: true)
        XCTAssertEqual(scripted.recordedOps, [.discover(refresh: true), .write(auth, Data("token".utf8)),
                                              .read(auth), .read(auth), .read(auth), .read(auth)])
        XCTAssertEqual(polled.sleeper.requested(.authPoll), [.milliseconds(50), .milliseconds(50), .milliseconds(50)])
        let polledState = await polled.client.inspect { ($0.isConnected, $0.authenticationFailed) }
        XCTAssertTrue(polledState.0)
        XCTAssertFalse(polledState.1)

        await rig.client.disconnect()
        await polled.client.disconnect()
    }

    /// Angstrom-only: §4.1 — both gates are FIFO and independent; ensureConnected holds only `.connection`, disconnect never takes `.request`
    func testGatesAreFIFOAndOrdered() async throws {
        let rig = makeRig()
        let client = rig.client

        // FIFO: three waiters queue behind a held gate and get it in the order they queued.
        await client.acquire(.connection)
        let log = Locked<[String]>([])
        let queued = expectation(description: "three waiters queued")
        queued.expectedFulfillmentCount = 3
        var waiters: [Task<Void, Never>] = []
        for label in ["A", "B", "C"] {
            waiters.append(Task {
                await client.acquireRecording(.connection, label: label, log: log) { queued.fulfill() }
            })
        }
        await fulfillment(of: [queued], timeout: 5)
        XCTAssertEqual(log.value.filter { $0.hasPrefix("acquired") }, [], "nobody gets a held gate")
        let waiting = await client.inspect { ($0.gateWaiters[.connection]?.count ?? 0, $0.gateBusy) }
        XCTAssertEqual(waiting.0, 3)
        XCTAssertEqual(waiting.1, [.connection])

        // The request gate is independent of the held connection gate.
        await assertCompletes("acquire(.request) while .connection is held") {
            await client.acquire(.request)
            await client.release(.request)
        }

        await client.release(.connection)
        for waiter in waiters { await waiter.value }
        let entries = log.value
        let queueOrder = entries.filter { $0.hasPrefix("queued ") }.map { $0.dropFirst("queued ".count) }
        let grantOrder = entries.filter { $0.hasPrefix("acquired ") }.map { $0.dropFirst("acquired ".count) }
        XCTAssertEqual(queueOrder.count, 3)
        XCTAssertEqual(grantOrder, queueOrder, "the gate is handed over first-in, first-out")
        XCTAssertEqual(entries.filter { $0 == "overlap" }, [], "one holder at a time")
        var final = await client.inspect { ($0.gateBusy, $0.gateWaiters[.connection]?.count ?? 0) }
        XCTAssertEqual(final.0, [])
        XCTAssertEqual(final.1, 0)

        // ensureConnected runs under `.connection` only.
        let held = Latch()
        let insideDiscover = expectation(description: "discovery started")
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.beforeOp = { op in
            if op == .discover(refresh: false) {
                insideDiscover.fulfill()
                await held.wait()
            }
        }
        rig.central.enqueueConnect(.success(link))
        let connecting = Task { try await client.ensureConnected() }
        await fulfillment(of: [insideDiscover], timeout: 5)
        let busy = await client.inspect { $0.gateBusy }
        XCTAssertEqual(busy, [.connection])
        await assertCompletes("acquire(.request) during a connect") {
            await client.acquire(.request)
            await client.release(.request)
        }
        held.open()
        _ = try await connecting.value

        // disconnect() takes `.connection` but never `.request` (lock order request → connection).
        await client.acquire(.request)
        await assertCompletes("disconnect() while .request is held") {
            await client.disconnect()
        }
        let afterDisconnect = await client.inspect { ($0.isConnected, $0.gateBusy) }
        XCTAssertFalse(afterDisconnect.0)
        XCTAssertEqual(afterDisconnect.1, [.request])
        XCTAssertEqual(link.recordedOps.last, .disconnect)
        await client.release(.request)
        final = await client.inspect { client in
            (client.gateBusy, client.gateWaiters.values.reduce(0) { total, waiters in total + waiters.count })
        }
        XCTAssertEqual(final.0, [])
        XCTAssertEqual(final.1, 0)
    }

    /// Angstrom-only: D10 — poweredOff, unsupported and unauthorized(denied/restricted/allowedAlways) fail fast with no attempt and no wait
    func testAvailabilityFailFast() async throws {
        let states: [BluetoothAvailability] = [
            .poweredOff, .unsupported, .unauthorized(.denied), .unauthorized(.restricted), .unauthorized(.allowedAlways),
        ]
        for state in states {
            // `.poweredOnWait` is not manual: an implementation that waited would time out at once
            // (and record the wait) instead of hanging.
            let rig = makeRig()
            rig.central.setAvailability(state)
            let raw = await rig.client.rawFrames()
            let events = await rig.client.connectionEvents()

            await assertThrows(.bluetoothUnavailable(state), "\(state)") { try await rig.client.ensureConnected() }

            XCTAssertEqual(rig.central.connectCount, 0, "\(state)")
            XCTAssertEqual(rig.sleeper.requested(.poweredOnWait), [], "\(state): no wait")
            XCTAssertEqual(rig.central.availabilitySubscriberCount, 0, "\(state): the update stream is released")
            let connected = await rig.client.isConnected
            XCTAssertFalse(connected)
            let frames = await drain(raw)
            XCTAssertEqual(frames, [], "\(state): not even [connecting]")
            let seen = await drain(events)
            XCTAssertEqual(seen, [])
        }
    }

    /// Angstrom-only: §8.1 — unknown/resetting/notDetermined wait for `.poweredOn` (stream created before the read), then connect; a terminal state ends the wait
    func testAvailabilityWaitsForPoweredOn() async throws {
        let waiting: [BluetoothAvailability] = [.unknown, .resetting, .unauthorized(.notDetermined)]
        for initial in waiting {
            let sleeper = ManualBluetoothSleeper(manual: [.idleDisconnect, .poweredOnWait])
            let fake = FakeBluetoothCentral()
            fake.setAvailability(initial)
            let central = ScriptedCentral(fake)
            let client = LaMarzoccoBluetoothClient(transport: BluetoothTransport(central: central, sleeper: sleeper),
                                                   peripheral: .fake, token: BluetoothAuthToken("token"))
            let connecting = Task { try await client.ensureConnected() }
            await sleeper.waitForPending(.poweredOnWait, count: 1)
            XCTAssertEqual(central.calls, ["availabilityUpdates", "availability"],
                           "\(initial): the update stream is created BEFORE the state is read")
            XCTAssertEqual(fake.connectCount, 0)

            fake.setAvailability(.resetting)   // still not ready: keep waiting
            fake.setAvailability(.poweredOn)
            _ = try await connecting.value

            XCTAssertEqual(central.calls, ["availabilityUpdates", "availability", "connect"], "\(initial)")
            XCTAssertEqual(fake.connectCount, 1)
            XCTAssertEqual(sleeper.requested(.poweredOnWait), [.seconds(10)])
            XCTAssertEqual(sleeper.pendingCount(.poweredOnWait), 0, "\(initial): the losing sleep was cancelled")
            XCTAssertEqual(fake.availabilitySubscriberCount, 0, "\(initial): the update stream is released")
            let connected = await client.isConnected
            XCTAssertTrue(connected)
            await client.disconnect()
        }

        // A terminal state during the wait ends it with that state, without a connect attempt.
        for terminal: BluetoothAvailability in [.poweredOff, .unauthorized(.denied), .unsupported] {
            let rig = makeRig(manual: [.idleDisconnect, .poweredOnWait])
            rig.central.setAvailability(.unknown)
            let connecting = Task { try await rig.client.ensureConnected() }
            await rig.sleeper.waitForPending(.poweredOnWait, count: 1)
            rig.central.setAvailability(terminal)
            await assertThrows(.bluetoothUnavailable(terminal), "\(terminal)") { try await connecting.value }
            XCTAssertEqual(rig.central.connectCount, 0)
            XCTAssertEqual(rig.sleeper.pendingCount(.poweredOnWait), 0)
            XCTAssertEqual(rig.central.availabilitySubscriberCount, 0)
        }
    }

    /// Angstrom-only: §8.1 — the 10 s `.poweredOnWait` sleep finishing first throws `.bluetoothUnavailable(<last state>)`; caller cancellation throws CancellationError
    func testAvailabilityWaitTimesOut() async throws {
        for initial: BluetoothAvailability in [.unknown, .resetting, .unauthorized(.notDetermined)] {
            let rig = makeRig(manual: [.idleDisconnect, .poweredOnWait])
            rig.central.setAvailability(initial)
            let raw = await rig.client.rawFrames()
            let connecting = Task { try await rig.client.ensureConnected() }
            await rig.sleeper.waitForPending(.poweredOnWait, count: 1)
            rig.sleeper.fire(.poweredOnWait)

            await assertThrows(.bluetoothUnavailable(initial), "\(initial)") { try await connecting.value }
            XCTAssertEqual(rig.sleeper.requested(.poweredOnWait), [.seconds(10)])
            XCTAssertEqual(rig.central.connectCount, 0)
            XCTAssertEqual(rig.central.availabilitySubscriberCount, 0, "\(initial): the losing child was cancelled")
            let frames = await drain(raw)
            XCTAssertEqual(frames, [])
        }

        // The bound comes from timing.poweredOnWait.
        let custom = makeRig(manual: [.idleDisconnect, .poweredOnWait])
        var timing = BluetoothTiming()
        timing.poweredOnWait = .seconds(3)
        await custom.client.setTimingForTesting(timing)
        custom.central.setAvailability(.resetting)
        let connecting = Task { try await custom.client.ensureConnected() }
        await custom.sleeper.waitForPending(.poweredOnWait, count: 1)
        custom.sleeper.fire(.poweredOnWait)
        await assertThrows(.bluetoothUnavailable(.resetting)) { try await connecting.value }
        XCTAssertEqual(custom.sleeper.requested(.poweredOnWait), [.seconds(3)])

        // Cancelling the caller during the wait throws CancellationError, not an availability error.
        let cancelled = makeRig(manual: [.idleDisconnect, .poweredOnWait])
        cancelled.central.setAvailability(.unknown)
        let waitingTask = Task { try await cancelled.client.ensureConnected() }
        await cancelled.sleeper.waitForPending(.poweredOnWait, count: 1)
        waitingTask.cancel()
        await assertCancellation { try await waitingTask.value }
        XCTAssertEqual(cancelled.central.connectCount, 0)
        XCTAssertEqual(cancelled.sleeper.pendingCount(.poweredOnWait), 0)
        XCTAssertEqual(cancelled.central.availabilitySubscriberCount, 0)
    }

    /// Angstrom-only: G-CONN-1, D1 — up to 3 single attempts of 20 s, 0.25 s backoff after `.timedOut` else 0.1 s, typed final error
    func testConnectRetriesThreeTimesWithBackoff() async throws {
        // Two failures, then success.
        let rig = makeRig()
        let raw = await rig.client.rawFrames()
        rig.central.enqueueConnect(.failure(.timedOut("connect")))
        rig.central.enqueueConnect(.failure(.disconnected(code: 7)))
        _ = try await rig.client.ensureConnected()
        XCTAssertEqual(rig.central.connectCount, 3)
        XCTAssertEqual(rig.central.connectTimeouts, [.seconds(20), .seconds(20), .seconds(20)])
        XCTAssertEqual(rig.central.connectPeripheralIDs, [.fake, .fake, .fake])
        XCTAssertEqual(rig.sleeper.requested(.connectBackoff), [.milliseconds(250), .milliseconds(100)])
        let connected = await rig.client.isConnected
        XCTAssertTrue(connected)
        let markers = await drain(raw).filter { $0.kind == .event }.map { String(decoding: $0.data, as: UTF8.self) }
        XCTAssertEqual(markers, ["[connecting]", "[connected]", "[authenticated]"], "one [connecting] for all attempts")
        await rig.client.disconnect()

        // Three failures: no sleep after the last one, and the last error is reported.
        let failing = makeRig()
        let events = await failing.client.connectionEvents()
        failing.central.enqueueConnect(.failure(.gatt(domain: "CBErrorDomain", code: 14)))
        failing.central.enqueueConnect(.failure(.timedOut("connect")))
        failing.central.enqueueConnect(.failure(.notConnected))
        await assertThrows(.bluetoothConnectionFailed(
            "Failed to connect to 00000000-0000-0000-0000-000000000001 after 3 attempts: not connected")) {
            try await failing.client.ensureConnected()
        }
        XCTAssertEqual(failing.central.connectCount, 3)
        XCTAssertEqual(failing.sleeper.requested(.connectBackoff), [.milliseconds(100), .milliseconds(250)])
        XCTAssertEqual(failing.central.links.count, 0)
        XCTAssertEqual(failing.sleeper.startedCount(.idleDisconnect), 0)
        let failedState = await failing.client.inspect { ($0.isConnected, $0.reportedConnected) }
        XCTAssertFalse(failedState.0)
        XCTAssertFalse(failedState.1)
        let seen = await drain(events)
        XCTAssertEqual(seen, [])

        // The count, timeout and backoffs come from BluetoothTiming.
        let tuned = makeRig()
        var timing = BluetoothTiming()
        timing.connectAttempts = 2
        timing.connectTimeout = .seconds(7)
        timing.connectBackoffAfterTimeout = .seconds(2)
        timing.connectBackoff = .seconds(1)
        await tuned.client.setTimingForTesting(timing)
        tuned.central.connectFailure = .timedOut("connect")
        await assertThrows(.bluetoothConnectionFailed(
            "Failed to connect to 00000000-0000-0000-0000-000000000001 after 2 attempts: timed out (connect)")) {
            try await tuned.client.ensureConnected()
        }
        XCTAssertEqual(tuned.central.connectTimeouts, [.seconds(7), .seconds(7)])
        XCTAssertEqual(tuned.sleeper.requested(.connectBackoff), [.seconds(2)])
    }

    /// Angstrom-only: §4.2 — `.unknownPeripheral` (and `.unavailable`) end the retry loop at once
    func testUnknownPeripheralIsTerminal() async throws {
        let unknownID = BluetoothPeripheralID(rawValue: "11111111-2222-3333-4444-555555555555")
        let rig = makeRig()
        rig.central.enqueueConnect(.failure(.unknownPeripheral(unknownID)))
        rig.central.enqueueConnect(.success(.laMarzocco(token: "token")))
        await assertThrows(.bluetoothConnectionFailed(
            "Unknown peripheral 11111111-2222-3333-4444-555555555555; scan again")) {
            try await rig.client.ensureConnected()
        }
        XCTAssertEqual(rig.central.connectCount, 1)
        XCTAssertEqual(rig.central.links.count, 0, "the queued success was not used")
        XCTAssertEqual(rig.sleeper.requested(.connectBackoff), [])

        // After a retryable failure, an unknown peripheral still stops the loop.
        let second = makeRig()
        second.central.enqueueConnect(.failure(.timedOut("connect")))
        second.central.enqueueConnect(.failure(.unknownPeripheral(unknownID)))
        await assertThrows(.bluetoothConnectionFailed(
            "Unknown peripheral 11111111-2222-3333-4444-555555555555; scan again")) {
            try await second.client.ensureConnected()
        }
        XCTAssertEqual(second.central.connectCount, 2)
        XCTAssertEqual(second.sleeper.requested(.connectBackoff), [.milliseconds(250)])

        // An unavailable adapter reported by an attempt is terminal too.
        let off = makeRig()
        off.central.enqueueConnect(.failure(.unavailable(.poweredOff)))
        await assertThrows(.bluetoothUnavailable(.poweredOff)) { try await off.client.ensureConnected() }
        XCTAssertEqual(off.central.connectCount, 1)
        XCTAssertEqual(off.sleeper.requested(.connectBackoff), [])
    }

    /// Angstrom-only: §3.4 — no auth characteristic after discovery → typed error, the link is closed, no auth write
    func testMissingAuthCharacteristic() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.present = [BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
                        BluetoothConstants.tokenCharacteristic, BluetoothConstants.shotCounterCharacteristic]
        rig.central.enqueueConnect(.success(link))

        await assertThrows(.bluetoothConnectionFailed(
            "Could not find characteristic 0d0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")) {
            try await rig.client.ensureConnected()
        }

        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .disconnect])
        let state = await rig.client.inspect { ($0.isConnected, $0.authenticationFailed, $0.idleTask == nil) }
        XCTAssertFalse(state.0)
        XCTAssertFalse(state.1, "no auth read happened")
        XCTAssertTrue(state.2)
        XCTAssertEqual(rig.sleeper.startedCount(.idleDisconnect), 0)
        let seen = await drain(events)
        XCTAssertEqual(seen, [])
    }

    /// Angstrom-only: §4.2 — every failure after a link exists (discovery, auth write/read, wrong token) closes that link once and emits no event
    func testFailedConnectDisconnectsLinkWithoutEvent() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()

        // Wrong token: 10 reads, 9 polls of 50 ms, then .bluetoothAuthenticationFailed.
        let wrong = FakeBluetoothLink.laMarzocco(token: "other")
        rig.central.enqueueConnect(.success(wrong))
        await assertThrows(.bluetoothAuthenticationFailed) { try await rig.client.ensureConnected() }
        XCTAssertEqual(wrong.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8))]
                       + Array(repeating: .read(auth), count: 10) + [.disconnect])
        XCTAssertEqual(rig.sleeper.requested(.authPoll), Array(repeating: .milliseconds(50), count: 9))
        var flag = await rig.client.authenticationFailed
        XCTAssertTrue(flag)

        // A transport error during an auth read: connection failure, the flag is not reset.
        let readFails = FakeBluetoothLink()
        readFails.onRead = { _ in throw BluetoothTransportError.gatt(domain: "CBATTErrorDomain", code: 14) }
        rig.central.enqueueConnect(.success(readFails))
        await assertThrows(.bluetoothConnectionFailed(
            "Failed to connect to machine with Bluetooth: GATT error CBATTErrorDomain 14")) {
            try await rig.client.ensureConnected()
        }
        XCTAssertEqual(readFails.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8)), .read(auth), .disconnect])
        flag = await rig.client.authenticationFailed
        XCTAssertTrue(flag, "only a read of [0x01] resets the flag")

        // A timed-out auth write.
        let writeTimesOut = FakeBluetoothLink.laMarzocco(token: "token")
        writeTimesOut.onWrite = { _, _ in throw BluetoothTransportError.timedOut("write") }
        rig.central.enqueueConnect(.success(writeTimesOut))
        await assertThrows(.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: timed out (write)")) {
            try await rig.client.ensureConnected()
        }
        XCTAssertEqual(writeTimesOut.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8)), .disconnect])

        // Bluetooth turning off during auth maps to .bluetoothUnavailable (D10).
        let unavailable = FakeBluetoothLink.laMarzocco(token: "token")
        unavailable.onWrite = { _, _ in throw BluetoothTransportError.unavailable(.poweredOff) }
        rig.central.enqueueConnect(.success(unavailable))
        await assertThrows(.bluetoothUnavailable(.poweredOff)) { try await rig.client.ensureConnected() }
        XCTAssertEqual(unavailable.recordedOps.last, .disconnect)

        // A discovery error on a link that is already down.
        let dead = FakeBluetoothLink.laMarzocco(token: "token")
        dead.drop(.disconnected(code: 7))
        rig.central.enqueueConnect(.success(dead))
        await assertThrows(.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: not connected")) {
            try await rig.client.ensureConnected()
        }
        XCTAssertEqual(dead.recordedOps, [.discover(refresh: false), .disconnect])

        // A pre-auth connect failure leaves the flag alone.
        rig.central.enqueueConnect(.failure(.unknownPeripheral(.fake)))
        await assertThrows(.bluetoothConnectionFailed("Unknown peripheral 00000000-0000-0000-0000-000000000001; scan again")) {
            try await rig.client.ensureConnected()
        }
        flag = await rig.client.authenticationFailed
        XCTAssertTrue(flag)

        let failedState = await rig.client.inspect { ($0.isConnected, $0.reportedConnected, $0.idleTask == nil, $0.linkWatcher == nil) }
        XCTAssertFalse(failedState.0)
        XCTAssertFalse(failedState.1)
        XCTAssertTrue(failedState.2)
        XCTAssertTrue(failedState.3)
        XCTAssertEqual(rig.sleeper.startedCount(.idleDisconnect), 0, "the idle timer is armed only after auth")

        // The next good link connects; only now is `.connected` reported and the flag cleared.
        _ = try await rig.client.ensureConnected()
        flag = await rig.client.authenticationFailed
        XCTAssertFalse(flag)
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected])
        await rig.client.disconnect()
    }

    /// Angstrom-only: §4.2 — cancellation during auth, the auth poll or the connect backoff rethrows CancellationError and leaves no link up
    func testCancellationDuringConnectDisconnects() async throws {
        // Cancelled while the auth read is in flight.
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        let held = Latch()
        let readStarted = expectation(description: "auth read started")
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.beforeOp = { [auth] op in
            if op == .read(auth) {
                readStarted.fulfill()
                await held.wait()
            }
        }
        rig.central.enqueueConnect(.success(link))
        let connecting = Task { try await rig.client.ensureConnected() }
        await fulfillment(of: [readStarted], timeout: 5)
        connecting.cancel()
        held.open()
        await assertCancellation { try await connecting.value }
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8)), .read(auth), .disconnect])
        let state = await rig.client.inspect { ($0.isConnected, $0.reportedConnected, $0.idleTask == nil, $0.gateBusy) }
        XCTAssertFalse(state.0)
        XCTAssertFalse(state.1)
        XCTAssertTrue(state.2)
        XCTAssertEqual(state.3, [], "the gate is released on cancellation")
        let seen = await drain(events)
        XCTAssertEqual(seen, [])

        // Cancelled during the 50 ms auth poll.
        let polling = makeRig(manual: [.idleDisconnect, .authPoll])
        let slow = FakeBluetoothLink.laMarzocco(token: "token", confirmOnRead: 3)
        polling.central.enqueueConnect(.success(slow))
        let pollTask = Task { try await polling.client.ensureConnected() }
        await polling.sleeper.waitForPending(.authPoll, count: 1)
        pollTask.cancel()
        await assertCancellation { try await pollTask.value }
        XCTAssertEqual(slow.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8)), .read(auth), .disconnect])
        let pollConnected = await polling.client.isConnected
        XCTAssertFalse(pollConnected)

        // Cancelled during the connect backoff: no link was obtained, nothing to close, no more attempts.
        let backoff = makeRig(manual: [.idleDisconnect, .connectBackoff])
        backoff.central.enqueueConnect(.failure(.timedOut("connect")))
        let backoffTask = Task { try await backoff.client.ensureConnected() }
        await backoff.sleeper.waitForPending(.connectBackoff, count: 1)
        backoffTask.cancel()
        await assertCancellation { try await backoffTask.value }
        XCTAssertEqual(backoff.central.connectCount, 1)
        XCTAssertEqual(backoff.central.links.count, 0)
    }

    // MARK: Connection events

    /// Angstrom-only: §4.8 — setConnected emits only on a change, to every registered listener, from registration on
    func testSetConnectedIsEdgeTriggered() async throws {
        let rig = makeRig()
        let first = await rig.client.connectionEvents()
        await rig.client.setConnected(false)   // already false: nothing
        await rig.client.setConnected(true)
        await rig.client.setConnected(true)
        let second = await rig.client.connectionEvents()
        await rig.client.setConnected(false)
        await rig.client.setConnected(false)
        await rig.client.setConnected(true)
        let reported = await rig.client.reportedConnected
        XCTAssertTrue(reported)
        let firstSeen = await drain(first)
        let secondSeen = await drain(second)
        XCTAssertEqual(firstSeen, [.connected, .disconnected, .connected])
        XCTAssertEqual(secondSeen, [.disconnected, .connected], "a later listener sees no earlier transition")

        // A cancelled listener is unregistered; the other keeps receiving.
        let kept = await rig.client.connectionEvents()
        let dropped = await rig.client.connectionEvents()
        _ = await drain(dropped)   // cancels its iteration
        await rig.client.setConnected(false)
        let keptSeen = await drain(kept)
        XCTAssertEqual(keptSeen, [.disconnected])
    }

    // MARK: Idle

    /// Angstrom-only: §4.6 — the 30 s idle sleep, once fired, closes the link and reports `.disconnected`; no idle task while the shot counter is enabled
    func testIdleTimerFiresDisconnect() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        _ = try await rig.client.ensureConnected()
        let link = try XCTUnwrap(rig.central.links.first)
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect), [.seconds(30)])

        rig.sleeper.fire(.idleDisconnect)
        let seen = try await waitFor(events) { $0 == .disconnected }
        XCTAssertEqual(seen, [.connected, .disconnected])

        let state = await rig.client.inspect {
            ($0.isConnected, $0.idleTask == nil, $0.linkWatcher == nil, $0.hasBackgroundWorkForTesting, $0.gateBusy)
        }
        XCTAssertFalse(state.0)
        XCTAssertTrue(state.1)
        XCTAssertTrue(state.2)
        XCTAssertFalse(state.3)
        XCTAssertEqual(state.4, [])
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8)), .read(auth), .disconnect])
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 0)

        // The next connect re-arms it, with timing.idleTimeout.
        var timing = BluetoothTiming()
        timing.idleTimeout = .seconds(4321)
        await rig.client.setTimingForTesting(timing)
        _ = try await rig.client.ensureConnected()
        XCTAssertEqual(rig.central.connectCount, 2)
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect), [.seconds(30), .seconds(4321)])

        // While the shot counter is enabled, a reset cancels the timer and starts none.
        await rig.client.inspect { client in
            client.shotCounterEnabled = true
            client.resetIdleTimer()
        }
        var suppressed = await rig.client.inspect { ($0.idleTask == nil, $0.hasBackgroundWorkForTesting) }
        XCTAssertTrue(suppressed.0)
        XCTAssertFalse(suppressed.1)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 0)
        XCTAssertEqual(rig.sleeper.startedCount(.idleDisconnect), 2)
        _ = try await rig.client.ensureConnected()   // a reused link resets, but still no timer
        suppressed = await rig.client.inspect { ($0.idleTask == nil, $0.hasBackgroundWorkForTesting) }
        XCTAssertTrue(suppressed.0)
        XCTAssertEqual(rig.sleeper.startedCount(.idleDisconnect), 2)

        await rig.client.inspect { $0.shotCounterEnabled = false }

        // A fired timer that is reset (the link was used) before its drop gets the gate drops nothing,
        // and the new timer it was replaced by stays armed. (Depending on scheduling, the fired task
        // sees its cancellation right after the sleep or after it got the gate; both must abandon.
        // testIdleDropCancelledAtGateIsAbandoned pins the at-gate branch deterministically.)
        let events2 = await rig.client.connectionEvents()
        await rig.client.inspect { $0.resetIdleTimer() }
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        let firedTask = await rig.client.inspect { $0.idleTask }
        let fired = try XCTUnwrap(firedTask)
        await rig.client.acquire(.connection)
        rig.sleeper.fire(.idleDisconnect)
        await rig.client.inspect { $0.resetIdleTimer() }
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        await rig.client.release(.connection)
        await fired.value
        let second = try XCTUnwrap(rig.central.links.last)
        let afterReset = await rig.client.inspect { ($0.link === second, $0.idleTask != nil, $0.gateBusy) }
        XCTAssertTrue(afterReset.0, "the abandoned drop left the link up")
        XCTAssertTrue(afterReset.1, "the replacement timer is still referenced")
        XCTAssertEqual(afterReset.2, [])
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        XCTAssertFalse(second.recordedOps.contains(.disconnect))

        await rig.client.disconnect()
        let tail = await drain(events2)
        XCTAssertEqual(tail, [.disconnected], "only the explicit disconnect")
    }

    /// Angstrom-only: §4.6 — the idle task performing its own disconnect is not cancelled (upstream fix 83289c6, TBC:1373)
    func testIdleTaskDoesNotCancelItself() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        let held = Latch()
        let disconnecting = expectation(description: "idle disconnect started")
        let cancelledInsideDisconnect = Locked<[Bool]>([])
        link.beforeOp = { op in
            guard op == .disconnect else { return }
            // Runs in the task that performs the disconnect: the idle task.
            cancelledInsideDisconnect.withLock { $0.append(Task.isCancelled) }
            disconnecting.fulfill()
            await held.wait()
            cancelledInsideDisconnect.withLock { $0.append(Task.isCancelled) }
        }
        rig.central.enqueueConnect(.success(link))
        _ = try await rig.client.ensureConnected()
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)

        rig.sleeper.fire(.idleDisconnect)
        await fulfillment(of: [disconnecting], timeout: 5)
        let midway = await rig.client.inspect { ($0.link == nil, $0.idleTask == nil, $0.reportedConnected, $0.gateBusy) }
        XCTAssertTrue(midway.0, "the link is detached before it is closed")
        XCTAssertTrue(midway.1, "the idle reference is cleared")
        XCTAssertTrue(midway.2, ".disconnected comes after the close")
        XCTAssertEqual(midway.3, [.connection])
        held.open()

        let seen = try await waitFor(events) { $0 == .disconnected }
        XCTAssertEqual(seen, [.connected, .disconnected])
        XCTAssertEqual(cancelledInsideDisconnect.value, [false, false])
        XCTAssertEqual(link.recordedOps.filter { $0 == .disconnect }.count, 1)
        let state = await rig.client.inspect { ($0.isConnected, $0.hasBackgroundWorkForTesting) }
        XCTAssertFalse(state.0)
        XCTAssertFalse(state.1)
    }

    /// Angstrom-only: §4.6 — an idle drop whose task is cancelled (the timer was reset because the link
    /// was used) while it is queued on the connection gate is abandoned once it gets the gate: the link
    /// stays up and the replacement timer stays armed. Upstream's `_drop_connection` gets `CancelledError`
    /// from its lock wait (`BT:282-291`); the Swift gate is not cancellable, so `dropConnection` checks
    /// after acquiring. Deterministic: the idle task is queued on the held gate before the reset.
    func testIdleDropCancelledAtGateIsAbandoned() async throws {
        let rig = makeRig()
        _ = try await rig.client.ensureConnected()
        let link = try XCTUnwrap(rig.central.links.first)
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        let events = await rig.client.connectionEvents()

        // The idle task, past its fired sleep, queued on the held connection gate.
        await rig.client.acquire(.connection)
        let queued = expectation(description: "idle drop queued on the gate")
        await rig.client.startIdleDropQueuedOnGate { queued.fulfill() }
        await fulfillment(of: [queued], timeout: 5)
        let queuedState = await rig.client.inspect { ($0.gateWaiters[.connection]?.count ?? 0, $0.idleTask) }
        XCTAssertEqual(queuedState.0, 1, "the idle drop waits for the gate")
        let queuedDrop = try XCTUnwrap(queuedState.1)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 0, "the original sleep was replaced")

        // The link is used: the timer is reset, which cancels the queued drop and arms a new timer.
        await rig.client.inspect { $0.resetIdleTimer() }
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        XCTAssertTrue(queuedDrop.isCancelled)
        let replacement = await rig.client.inspect { $0.idleTask }
        XCTAssertNotNil(replacement)

        // Only now does the cancelled drop get the gate.
        await rig.client.release(.connection)
        await queuedDrop.value
        let state = await rig.client.inspect {
            ($0.link === link, $0.idleTask == replacement, $0.reportedConnected, $0.gateBusy, $0.linkWatcher != nil)
        }
        XCTAssertTrue(state.0, "the abandoned drop left the link up")
        XCTAssertTrue(state.1, "the replacement timer is untouched")
        XCTAssertTrue(state.2, "no .disconnected was reported")
        XCTAssertEqual(state.3, [], "the abandoned drop released the gate")
        XCTAssertTrue(state.4)
        XCTAssertFalse(link.recordedOps.contains(.disconnect))
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        let abandoned = await drain(events)
        XCTAssertEqual(abandoned, [], "no connection event from the abandoned drop")

        // Control: the same queued idle drop, not cancelled, does disconnect when it gets the gate.
        let controlEvents = await rig.client.connectionEvents()
        await rig.client.acquire(.connection)
        let queuedAgain = expectation(description: "uncancelled idle drop queued on the gate")
        await rig.client.startIdleDropQueuedOnGate { queuedAgain.fulfill() }
        await fulfillment(of: [queuedAgain], timeout: 5)
        let controlTask = await rig.client.inspect { $0.idleTask }
        let controlDrop = try XCTUnwrap(controlTask)
        await rig.client.release(.connection)
        await controlDrop.value
        let controlState = await rig.client.inspect { ($0.isConnected, $0.idleTask == nil, $0.gateBusy) }
        XCTAssertFalse(controlState.0)
        XCTAssertTrue(controlState.1)
        XCTAssertEqual(controlState.2, [])
        XCTAssertEqual(link.recordedOps.filter { $0 == .disconnect }.count, 1)
        let dropped = await drain(controlEvents)
        XCTAssertEqual(dropped, [.disconnected])
    }

    // MARK: Link events

    /// Angstrom-only: §4.7 — `.disconnected` from the current link clears it, cancels the idle task (D16), reports `.disconnected`, resets shot-counter state; the next connect is lazy
    func testLinkLossFromCurrentLink() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        let raw = await rig.client.rawFrames()
        _ = try await rig.client.ensureConnected()
        let first = try XCTUnwrap(rig.central.links.first)
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        let (shotStream, shotContinuation) = AsyncStream.makeStream(of: ShotCounterEvent.self)
        await rig.client.inspect { client in
            client.shotCounterSubscribed = true
            client.shotCounterListeners[UUID()] = shotContinuation
        }

        first.drop(.disconnected(code: 7))
        let seen = try await waitFor(events) { $0 == .disconnected }
        XCTAssertEqual(seen, [.connected, .disconnected])

        let state = await rig.client.inspect {
            ($0.link == nil, $0.idleTask == nil, $0.linkWatcher == nil, $0.shotCounterSubscribed,
             $0.reconnectTask == nil, $0.hasBackgroundWorkForTesting, $0.reportedConnected)
        }
        XCTAssertTrue(state.0)
        XCTAssertTrue(state.1, "D16: the idle task is cancelled")
        XCTAssertTrue(state.2)
        XCTAssertFalse(state.3, "handleConnectionLost clears the subscription")
        XCTAssertTrue(state.4, "no reconnect loop while the shot counter is disabled")
        XCTAssertFalse(state.5)
        XCTAssertFalse(state.6)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 0, "D16: the idle sleep was cancelled")
        XCTAssertEqual(first.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8)), .read(auth)],
                       "a loss does not call disconnect()")
        let shotEvents = await drain(shotStream)
        XCTAssertEqual(shotEvents, [], "no .unsubscribed while the shot counter is disabled")

        // The next connect is lazy and uses a new link.
        _ = try await rig.client.ensureConnected()
        XCTAssertEqual(rig.central.connectCount, 2)
        let second = try XCTUnwrap(rig.central.links.last)
        XCTAssertFalse(first === second)
        await rig.client.disconnect()

        let all = await drain(events)
        XCTAssertEqual(all, [.connected, .disconnected])   // after the two consumed above
        let markers = await drain(raw).filter { $0.kind == .event }.map { String(decoding: $0.data, as: UTF8.self) }
        XCTAssertEqual(markers, ["[connecting]", "[connected]", "[authenticated]", "[disconnected]",
                                 "[connecting]", "[connected]", "[authenticated]", "[disconnected]"])
    }

    /// Angstrom-only: §4.1 — events from a link that is not the current one are ignored (link identity, BT:469-470)
    func testStaleLinkEventsIgnored() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        _ = try await rig.client.ensureConnected()
        let first = try XCTUnwrap(rig.central.links.first)
        // The fake reports the user disconnect as `.disconnected(nil)`; the client detached first, so it is ignored.
        await rig.client.disconnect()
        XCTAssertEqual(first.recordedOps.last, .disconnect)

        _ = try await rig.client.ensureConnected()
        let second = try XCTUnwrap(rig.central.links.last)
        XCTAssertFalse(first === second)
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        let raw = await rig.client.rawFrames()

        await rig.client.handleLinkEvent(.disconnected(.disconnected(code: 7)), from: first)
        await rig.client.handleLinkEvent(.servicesInvalidated, from: first)

        let state = await rig.client.inspect {
            ($0.link === second, $0.needsRediscovery, $0.idleTask != nil, $0.reportedConnected, $0.linkWatcher != nil)
        }
        XCTAssertTrue(state.0, "the current link stays")
        XCTAssertFalse(state.1, "a stale servicesInvalidated is ignored")
        XCTAssertTrue(state.2, "the idle task stays")
        XCTAssertTrue(state.3)
        XCTAssertTrue(state.4)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        let frames = await drain(raw)
        XCTAssertEqual(frames, [], "no marker for a stale event")
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected, .connected])
        await rig.client.disconnect()
    }

    /// Angstrom-only: D7c — `.servicesInvalidated` from the current link sets needsRediscovery and the raw marker; the link stays up
    func testServicesInvalidatedSetsRediscovery() async throws {
        let rig = makeRig()
        let raw = await rig.client.rawFrames()
        _ = try await rig.client.ensureConnected()
        let link = try XCTUnwrap(rig.central.links.first)

        link.invalidateServices()
        let frames = try await waitFor(raw) { $0.kind == .event && $0.data == Data("[services invalidated]".utf8) }
        let marker = try XCTUnwrap(frames.last)
        XCTAssertEqual(marker.direction, .inbound)
        XCTAssertNil(marker.characteristic)
        XCTAssertFalse(marker.isSecret)

        let state = await rig.client.inspect { ($0.needsRediscovery, $0.isConnected, $0.discovered.count) }
        XCTAssertTrue(state.0)
        XCTAssertTrue(state.1, "the link stays up")
        XCTAssertEqual(state.2, 4)
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8)), .read(auth)])

        // A fresh connection (which discovers again) clears it.
        await rig.client.disconnect()
        let stillSet = await rig.client.needsRediscovery
        XCTAssertTrue(stillSet)
        _ = try await rig.client.ensureConnected()
        let cleared = await rig.client.needsRediscovery
        XCTAssertFalse(cleared)
        await rig.client.disconnect()
    }

    // MARK: Errors

    /// Angstrom-only: §4.4.1 — every cell of the frozen error-mapping table
    func testMapTransportErrorTable() throws {
        typealias Client = LaMarzoccoBluetoothClient
        let prefix = "Failed to connect to machine with Bluetooth: "
        let phases: [Client.BluetoothErrorPhase] = [.connect, .authenticate, .request]

        // .unavailable(a) → .bluetoothUnavailable(a) in every phase.
        for phase in phases {
            for availability: BluetoothAvailability in [.poweredOff, .unauthorized(.denied), .unknown, .unsupported] {
                assertMapped(.unavailable(availability), phase, .bluetoothUnavailable(availability))
            }
        }

        // .timedOut(d).
        assertMapped(.timedOut("write"), .connect, .bluetoothConnectionFailed("timed out (write)"))
        assertMapped(.timedOut("write"), .authenticate, .bluetoothConnectionFailed(prefix + "timed out (write)"))
        assertMapped(.timedOut("write"), .request, .bluetoothTimedOut("write"))

        // .notConnected, .disconnected, .gatt, .valueTooLong.
        let linkErrors: [(BluetoothTransportError, String)] = [
            (.notConnected, "not connected"),
            (.disconnected(code: nil), "disconnected"),
            (.disconnected(code: 7), "disconnected (code 7)"),
            (.gatt(domain: "CBATTErrorDomain", code: 14), "GATT error CBATTErrorDomain 14"),
            (.valueTooLong(600, max: 512), "value too long (600 bytes, max 512)"),
        ]
        for (error, text) in linkErrors {
            assertMapped(error, .connect, .bluetoothConnectionFailed(text))
            assertMapped(error, .authenticate, .bluetoothConnectionFailed(prefix + text))
            assertMapped(error, .request, .bluetoothConnectionFailed(text))
        }

        // .unknownPeripheral(id) (connect) and .characteristicNotFound(u) (request).
        let id = BluetoothPeripheralID(rawValue: "ABCDEF01-0000-0000-0000-000000000002")
        assertMapped(.unknownPeripheral(id), .connect,
                     .bluetoothConnectionFailed("Unknown peripheral ABCDEF01-0000-0000-0000-000000000002; scan again"))
        assertMapped(.characteristicNotFound(BluetoothConstants.writeCharacteristic), .request,
                     .bluetoothConnectionFailed("Could not find characteristic 0b0b7847-e12b-09a8-b04b-8e0922a9abab on machine."))
        assertMapped(.characteristicNotFound(GATTUUID("0E0B7847-E12B-09A8-B04B-8E0922A9ABAB")), .request,
                     .bluetoothConnectionFailed("Could not find characteristic 0e0b7847-e12b-09a8-b04b-8e0922a9abab on machine."))

        // CancellationError and LaMarzoccoError pass through unchanged.
        for phase in phases {
            XCTAssertTrue(Client.mapTransportError(CancellationError(), phase: phase) is CancellationError)
            for error: LaMarzoccoError in [.decoding("bluetooth setting: x"), .bluetoothAuthenticationFailed,
                                           .bluetoothConnectionFailed("Client is not connected"), .bluetoothTimedOut("read")] {
                XCTAssertEqual(Client.mapTransportError(error, phase: phase) as? LaMarzoccoError, error)
            }
            // Anything else still becomes a LaMarzoccoError.
            let foreign = Client.mapTransportError(ForeignError(), phase: phase)
            guard case .bluetoothConnectionFailed? = foreign as? LaMarzoccoError else {
                return XCTFail("\(phase): \(foreign)")
            }
        }
    }

    // MARK: Teardown

    /// Angstrom-only: §4.7 — disconnect() is idempotent, closes the link once, cancels the idle task, reports `.disconnected` once and never reconnects
    func testDisconnectIsIdempotent() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        let raw = await rig.client.rawFrames()

        await rig.client.disconnect()   // never connected: nothing happens
        XCTAssertEqual(rig.central.connectCount, 0)

        _ = try await rig.client.ensureConnected()
        let link = try XCTUnwrap(rig.central.links.first)
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)

        await rig.client.disconnect()
        await rig.client.disconnect()
        await rig.client.disconnect()

        XCTAssertEqual(rig.central.connectCount, 1, "disconnect never reconnects")
        XCTAssertEqual(link.recordedOps, [.discover(refresh: false), .write(auth, Data("token".utf8)), .read(auth), .disconnect])
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 0, "the idle task is cancelled")
        let state = await rig.client.inspect {
            ($0.isConnected, $0.idleTask == nil, $0.linkWatcher == nil, $0.hasBackgroundWorkForTesting, $0.gateBusy)
        }
        XCTAssertFalse(state.0)
        XCTAssertTrue(state.1)
        XCTAssertTrue(state.2)
        XCTAssertFalse(state.3)
        XCTAssertEqual(state.4, [])
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected])
        let markers = await drain(raw).filter { $0.kind == .event }.map { String(decoding: $0.data, as: UTF8.self) }
        XCTAssertEqual(markers.filter { $0 == "[disconnected]" }.count, 1)
    }

    /// Angstrom-only: G-CONN-3 — every teardown path completes and reports on a link that is already dead (its ops throw `.notConnected`)
    func testTeardownCompletesOnDeadLink() async throws {
        // Path 1: disconnect().
        do {
            let rig = makeScriptedRig()
            let dead = SilentlyDyingLink(.laMarzocco(token: "token"))
            rig.central.enqueue(dead)
            let events = await rig.client.connectionEvents()
            let raw = await rig.client.rawFrames()
            _ = try await rig.client.ensureConnected()
            dead.die()
            try await assertLinkIsDead(dead)

            await assertCompletes("disconnect() on a dead link") { await rig.client.disconnect() }
            let state = await rig.client.inspect { ($0.isConnected, $0.idleTask == nil, $0.gateBusy) }
            XCTAssertFalse(state.0)
            XCTAssertTrue(state.1)
            XCTAssertEqual(state.2, [])
            XCTAssertEqual(dead.inner.recordedOps.last, .disconnect)
            let seen = await drain(events)
            XCTAssertEqual(seen, [.connected, .disconnected])
            let markers = await drain(raw).filter { $0.kind == .event }.map { String(decoding: $0.data, as: UTF8.self) }
            XCTAssertEqual(markers.last, "[disconnected]")
        }

        // Path 2: a background drop (the request wrapper's path).
        do {
            let rig = makeScriptedRig()
            let dead = SilentlyDyingLink(.laMarzocco(token: "token"))
            rig.central.enqueue(dead)
            let events = await rig.client.connectionEvents()
            _ = try await rig.client.ensureConnected()
            dead.die()
            let tracked = await rig.client.inspect { client in
                client.dropConnectionInBackground()
                return client.backgroundTasks.count
            }
            XCTAssertEqual(tracked, 1)
            await rig.client.drainBackgroundWorkForTesting()
            let state = await rig.client.inspect { ($0.isConnected, $0.hasBackgroundWorkForTesting, $0.backgroundTasks.isEmpty) }
            XCTAssertFalse(state.0)
            XCTAssertFalse(state.1)
            XCTAssertTrue(state.2)
            XCTAssertEqual(dead.inner.recordedOps.last, .disconnect)
            let seen = await drain(events)
            XCTAssertEqual(seen, [.connected, .disconnected])
        }

        // Path 3: the idle timer.
        do {
            let rig = makeScriptedRig()
            let dead = SilentlyDyingLink(.laMarzocco(token: "token"))
            rig.central.enqueue(dead)
            let events = await rig.client.connectionEvents()
            _ = try await rig.client.ensureConnected()
            await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
            dead.die()
            rig.sleeper.fire(.idleDisconnect)
            let seen = try await waitFor(events) { $0 == .disconnected }
            XCTAssertEqual(seen, [.connected, .disconnected])
            let state = await rig.client.inspect { ($0.isConnected, $0.hasBackgroundWorkForTesting) }
            XCTAssertFalse(state.0)
            XCTAssertFalse(state.1)
            XCTAssertEqual(dead.inner.recordedOps.last, .disconnect)
        }
    }

    // MARK: Lifetime

    /// Angstrom-only: §5.5 Lifetime — a connected client released without disconnect() closes its link (once) and deallocates
    func testReleasedClientClosesLinkAndDeallocates() async throws {
        let central = ScriptedCentral(FakeBluetoothCentral())
        let sleeper = ManualBluetoothSleeper()
        let observed = ObservedLink(.laMarzocco(token: "token"))
        central.enqueue(observed)
        var client: LaMarzoccoBluetoothClient? = LaMarzoccoBluetoothClient(
            transport: BluetoothTransport(central: central, sleeper: sleeper), peripheral: .fake,
            token: BluetoothAuthToken("token"))
        _ = try await client?.ensureConnected()
        await sleeper.waitForPending(.idleDisconnect, count: 1)
        let released = Weak(client)

        client = nil

        await fulfillment(of: [observed.disconnected], timeout: 5)
        XCTAssertNil(released.value, "the client deallocated")
        XCTAssertEqual(observed.inner.recordedOps,
                       [.discover(refresh: false), .write(auth, Data("token".utf8)), .read(auth), .disconnect])
        XCTAssertEqual(central.calls.filter { $0 == "connect" }.count, 1, "release never reconnects")
    }

    /// Angstrom-only: §5.5 Lifetime — consumers parked on connectionEvents() / rawFrames() / shotCounterEvents() end their loops when the client is released; deinit emits nothing
    func testReleasedClientEndsListenerStreams() async throws {
        // Connected client.
        do {
            let central = FakeBluetoothCentral()
            let sleeper = ManualBluetoothSleeper()
            var client: LaMarzoccoBluetoothClient? = LaMarzoccoBluetoothClient(
                transport: .fake(central, sleeper: sleeper), peripheral: .fake, token: BluetoothAuthToken("token"))
            let connection = collectUntilFinished(try await XCTUnwrap(client).connectionEvents(), "connectionEvents")
            let raw = collectUntilFinished(try await XCTUnwrap(client).rawFrames(), "rawFrames")
            let shots = collectUntilFinished(try await XCTUnwrap(client).shotCounterEvents(), "shotCounterEvents")
            _ = try await client?.ensureConnected()
            await sleeper.waitForPending(.idleDisconnect, count: 1)
            let released = Weak(client)

            client = nil

            await fulfillment(of: [connection.finished, raw.finished, shots.finished], timeout: 5)
            XCTAssertNil(released.value)
            let connectionSeen = await connection.values()
            XCTAssertEqual(connectionSeen, [.connected], "no .disconnected from deinit")
            let markers = await raw.values().filter { $0.kind == .event }.map { String(decoding: $0.data, as: UTF8.self) }
            XCTAssertEqual(markers, ["[connecting]", "[connected]", "[authenticated]"], "no [disconnected] from deinit")
            let shotsSeen = await shots.values()
            XCTAssertTrue(shotsSeen.isEmpty, "\(shotsSeen)")
        }

        // Never-connected client: the streams end too, and nothing touches the transport.
        do {
            let central = FakeBluetoothCentral()
            var client: LaMarzoccoBluetoothClient? = LaMarzoccoBluetoothClient(
                transport: .fake(central, sleeper: ManualBluetoothSleeper()), peripheral: .fake,
                token: BluetoothAuthToken("token"))
            let connection = collectUntilFinished(try await XCTUnwrap(client).connectionEvents(), "connectionEvents")
            let raw = collectUntilFinished(try await XCTUnwrap(client).rawFrames(), "rawFrames")

            client = nil

            await fulfillment(of: [connection.finished, raw.finished], timeout: 5)
            let connectionSeen = await connection.values()
            XCTAssertEqual(connectionSeen, [])
            let rawSeen = await raw.values()
            XCTAssertEqual(rawSeen, [])
            XCTAssertEqual(central.connectCount, 0)
        }
    }

    /// Angstrom-only: §5.5 Lifetime — releasing a client with a pending idle sleep and a running link watcher cancels both; nothing stays parked on the sleeper
    func testReleasedClientCancelsIdleTaskAndLinkWatcher() async throws {
        let central = ScriptedCentral(FakeBluetoothCentral())
        let sleeper = ManualBluetoothSleeper()
        let observed = ObservedLink(.laMarzocco(token: "token"))
        central.enqueue(observed)
        var client: LaMarzoccoBluetoothClient? = LaMarzoccoBluetoothClient(
            transport: BluetoothTransport(central: central, sleeper: sleeper), peripheral: .fake,
            token: BluetoothAuthToken("token"))
        _ = try await client?.ensureConnected()
        await sleeper.waitForPending(.idleDisconnect, count: 1)
        let watching = await client?.inspect { $0.linkWatcher != nil && $0.idleTask != nil }
        XCTAssertEqual(watching, true)
        let released = Weak(client)

        client = nil

        await fulfillment(of: [observed.watcherEnded, observed.disconnected], timeout: 5)
        XCTAssertNil(released.value)
        XCTAssertEqual(sleeper.pendingCount(.idleDisconnect), 0, "the idle sleep was cancelled, not left parked")
        XCTAssertEqual(sleeper.startedCount(.idleDisconnect), 1, "no new idle sleep was started")
        XCTAssertEqual(sleeper.requested(.connectBackoff), [])
    }

    /// Angstrom-only: §5.5 Lifetime — a client disconnected normally and then released does not touch the closed link again
    func testDisconnectedClientReleaseIsQuiet() async throws {
        let central = ScriptedCentral(FakeBluetoothCentral())
        let sleeper = ManualBluetoothSleeper()
        let observed = ObservedLink(.laMarzocco(token: "token"))
        central.enqueue(observed)
        var client: LaMarzoccoBluetoothClient? = LaMarzoccoBluetoothClient(
            transport: BluetoothTransport(central: central, sleeper: sleeper), peripheral: .fake,
            token: BluetoothAuthToken("token"))
        _ = try await client?.ensureConnected()
        await client?.disconnect()
        await fulfillment(of: [observed.disconnected, observed.watcherEnded], timeout: 5)
        let connection = collectUntilFinished(try await XCTUnwrap(client).connectionEvents(), "connectionEvents")
        let released = Weak(client)

        client = nil

        await fulfillment(of: [connection.finished], timeout: 5)
        XCTAssertNil(released.value)
        let seen = await connection.values()
        XCTAssertEqual(seen, [], "release after disconnect reports nothing")
        XCTAssertEqual(observed.inner.recordedOps.filter { $0 == .disconnect }.count, 1, "the link is closed exactly once")
        XCTAssertEqual(observed.disconnectCount, 1)
        XCTAssertEqual(sleeper.pendingCount(.idleDisconnect), 0)
    }

    // MARK: Raw tap

    /// Angstrom-only: §5.7 — lifecycle markers in order, verbatim directional frames stamped by `now`; nothing (not even `now()`) without a listener
    func testRawFrameLifecycleMarkers() async throws {
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let nowCalls = Locked(0)
        let clock: @Sendable () -> Date = {
            nowCalls.withLock { $0 += 1 }
            return start
        }
        let central = FakeBluetoothCentral()
        let sleeper = ManualBluetoothSleeper()
        let client = LaMarzoccoBluetoothClient(transport: BluetoothTransport(central: central, sleeper: sleeper, now: clock),
                                               peripheral: .fake, token: BluetoothAuthToken("token"))
        let quiet = FakeBluetoothLink.laMarzocco(token: "token")
        quiet.mtu = 185
        central.enqueueConnect(.success(quiet))

        // No listener: emission costs nothing.
        _ = try await client.ensureConnected()
        await client.disconnect()
        XCTAssertEqual(nowCalls.value, 0)

        // With a listener.
        let raw = await client.rawFrames()
        let link = FakeBluetoothLink.laMarzocco(token: "token", confirmOnRead: 2)
        link.mtu = 185
        central.enqueueConnect(.success(link))
        _ = try await client.ensureConnected()
        await client.disconnect()
        // A link with no MTU emits no [mtu] marker.
        let noMTU = FakeBluetoothLink.laMarzocco(token: "token")
        central.enqueueConnect(.success(noMTU))
        _ = try await client.ensureConnected()
        await client.disconnect()

        let frames = await drain(raw)
        func event(_ marker: String) -> RawBluetoothFrame {
            RawBluetoothFrame(timestamp: start, direction: .inbound, kind: .event, characteristic: nil,
                              data: Data(marker.utf8), isSecret: false)
        }
        let authWrite = RawBluetoothFrame(timestamp: start, direction: .outbound, kind: .write,
                                          characteristic: authUUIDString, data: Data("token".utf8), isSecret: true)
        func authRead(_ byte: UInt8) -> RawBluetoothFrame {
            RawBluetoothFrame(timestamp: start, direction: .inbound, kind: .read, characteristic: authUUIDString,
                              data: Data([byte]), isSecret: false)
        }
        XCTAssertEqual(frames, [
            event("[connecting]"), event("[connected]"), event("[mtu 185]"),
            authWrite, authRead(0x00), authRead(0x01),
            event("[authenticated]"), event("[disconnected]"),
            event("[connecting]"), event("[connected]"),
            authWrite, authRead(0x01),
            event("[authenticated]"), event("[disconnected]"),
        ])
        XCTAssertEqual(nowCalls.value, frames.count, "one timestamp per frame")

        // A failed connect: markers up to the failure, no [authenticated] and no [disconnected].
        let failedTap = await client.rawFrames()
        central.enqueueConnect(.success(.laMarzocco(token: "other")))
        var timing = BluetoothTiming()
        timing.authReadAttempts = 2
        await client.setTimingForTesting(timing)
        await assertThrows(.bluetoothAuthenticationFailed) { try await client.ensureConnected() }
        let failedFrames = await drain(failedTap)
        XCTAssertEqual(failedFrames, [event("[connecting]"), event("[connected]"), authWrite, authRead(0x00), authRead(0x00)])
    }

    /// Angstrom-only: §4.3 — only the auth write is tapped with isSecret, verbatim; auth reads and markers are not secret
    func testAuthWriteIsSecretOnRawTap() async throws {
        let rig = makeRig(token: "s3cret-token")
        let raw = await rig.client.rawFrames()
        rig.central.enqueueConnect(.success(.laMarzocco(token: "s3cret-token", confirmOnRead: 3)))
        _ = try await rig.client.ensureConnected()
        await rig.client.disconnect()

        let frames = await drain(raw)
        let secret = frames.filter(\.isSecret)
        XCTAssertEqual(secret.count, 1)
        let write = try XCTUnwrap(secret.first)
        XCTAssertEqual(write.kind, .write)
        XCTAssertEqual(write.direction, .outbound)
        XCTAssertEqual(write.characteristic, authUUIDString)
        XCTAssertEqual(write.data, Data("s3cret-token".utf8), "the library tap is verbatim")
        let reads = frames.filter { $0.kind == .read }
        XCTAssertEqual(reads.map(\.data), [Data([0x00]), Data([0x00]), Data([0x01])])
        XCTAssertTrue(reads.allSatisfy { !$0.isSecret && $0.characteristic == authUUIDString && $0.direction == .inbound })
        let markers = frames.filter { $0.kind == .event }
        XCTAssertEqual(markers.count, 4)
        XCTAssertTrue(markers.allSatisfy { !$0.isSecret })
        XCTAssertEqual(frames.count, 8)
    }

    /// Angstrom-only: §10.4 — logHandler output never contains the token, on success, failure, idle, loss and teardown paths
    func testLogNeverContainsToken() async throws {
        let token = "T0K3N-9f8e7d6c5b4a"
        let lines = Locked<[String]>([])
        let rig = makeRig(token: token, log: { line in lines.withLock { $0.append(line) } })
        var errors: [any Error] = []

        // Wrong token, then a transport error during auth.
        rig.central.enqueueConnect(.success(.laMarzocco(token: "other")))
        let readFails = FakeBluetoothLink()
        readFails.onRead = { _ in throw BluetoothTransportError.timedOut("read") }
        rig.central.enqueueConnect(.success(readFails))
        rig.central.enqueueConnect(.failure(.timedOut("connect")))
        for _ in 0..<2 {
            do { _ = try await rig.client.ensureConnected() } catch { errors.append(error) }
        }
        // Success (after one failed attempt), idle drop, reconnect, loss, reconnect, disconnect.
        rig.central.makeLink = { .laMarzocco(token: token) }
        _ = try await rig.client.ensureConnected()
        let events = await rig.client.connectionEvents()
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        rig.sleeper.fire(.idleDisconnect)
        _ = try await waitFor(events) { $0 == .disconnected }
        _ = try await rig.client.ensureConnected()
        try XCTUnwrap(rig.central.links.last).drop(.disconnected(code: 7))
        _ = try await waitFor(events) { $0 == .disconnected }
        _ = try await rig.client.ensureConnected()
        await rig.client.disconnect()
        // Bluetooth off.
        rig.central.setAvailability(.poweredOff)
        do { _ = try await rig.client.ensureConnected() } catch { errors.append(error) }

        // The token really was on the wire, so the check below is not vacuous.
        XCTAssertTrue(rig.central.links.contains { $0.recordedOps.contains(.write(auth, Data(token.utf8))) })
        let logged = lines.value
        XCTAssertGreaterThanOrEqual(logged.count, 10)
        XCTAssertTrue(logged.contains { $0.contains("Connecting") })
        XCTAssertTrue(logged.contains { $0.contains("failed") })
        XCTAssertTrue(logged.contains { $0.contains("Auto-disconnect") })
        XCTAssertTrue(logged.contains { $0.contains("disconnected") })
        for line in logged {
            XCTAssertFalse(line.contains(token), line)
        }
        XCTAssertEqual(errors.count, 3)
        for error in errors {
            XCTAssertFalse(String(describing: error).contains(token))
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
    }

    // MARK: - Helpers

    private struct Rig {
        let central: FakeBluetoothCentral
        let sleeper: ManualBluetoothSleeper
        let client: LaMarzoccoBluetoothClient
    }

    private struct ScriptedRig {
        let central: ScriptedCentral
        let sleeper: ManualBluetoothSleeper
        let client: LaMarzoccoBluetoothClient
    }

    private func makeRig(manual: Set<SleepPurpose> = [.idleDisconnect], token: String = "token",
                         log: (@Sendable (String) -> Void)? = nil) -> Rig {
        let central = FakeBluetoothCentral()
        let sleeper = ManualBluetoothSleeper(manual: manual)
        let client = LaMarzoccoBluetoothClient(transport: .fake(central, sleeper: sleeper), peripheral: .fake,
                                               token: BluetoothAuthToken(token), logHandler: log)
        return Rig(central: central, sleeper: sleeper, client: client)
    }

    private func makeScriptedRig() -> ScriptedRig {
        let central = ScriptedCentral(FakeBluetoothCentral())
        let sleeper = ManualBluetoothSleeper()
        let client = LaMarzoccoBluetoothClient(transport: BluetoothTransport(central: central, sleeper: sleeper),
                                               peripheral: .fake, token: BluetoothAuthToken("token"))
        return ScriptedRig(central: central, sleeper: sleeper, client: client)
    }

    /// Everything the stream has buffered right now, in order. Ends (and unregisters) the stream:
    /// the draining task is cancelled up front, so `next()` hands out the buffer and then nil.
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

    /// A consumer parked on a stream in a task that holds only the stream (never the client).
    private struct Collector<Element: Sendable> {
        let task: Task<[Element], Never>
        /// Fulfilled only when the stream itself finishes (not when `values()` cancels the reader).
        let finished: XCTestExpectation

        /// What the reader saw. Cancels it first, so a stream that never finished fails the test
        /// (through `finished`) instead of hanging here.
        func values() async -> [Element] {
            task.cancel()
            return await task.value
        }
    }

    private func collectUntilFinished<Element: Sendable>(_ stream: AsyncStream<Element>,
                                                         _ label: String) -> Collector<Element> {
        let finished = XCTestExpectation(description: "\(label) finished")
        let task = Task { () -> [Element] in
            var seen: [Element] = []
            for await element in stream {
                seen.append(element)
            }
            if !Task.isCancelled {
                finished.fulfill()
            }
            return seen
        }
        return Collector(task: task, finished: finished)
    }

    /// Iterates `stream` until `match` (hang guard: 5 s); returns every element consumed, the match last.
    private func waitFor<Element: Sendable>(_ stream: AsyncStream<Element>,
                                            file: StaticString = #filePath, line: UInt = #line,
                                            where match: @escaping @Sendable (Element) -> Bool) async throws -> [Element] {
        let matched = XCTestExpectation(description: "stream element")
        let reader = Task { () -> [Element] in
            var seen: [Element] = []
            for await element in stream {
                seen.append(element)
                if match(element) {
                    matched.fulfill()
                    return seen
                }
            }
            return seen
        }
        await fulfillment(of: [matched], timeout: 5)
        reader.cancel()
        let seen = await reader.value
        guard let last = seen.last, match(last) else {
            XCTFail("no matching element; saw \(seen)", file: file, line: line)
            throw LaMarzoccoError.operationNotAvailable("no matching element")
        }
        return seen
    }

    /// Fails (instead of hanging forever) if `operation` does not finish within 5 s.
    private func assertCompletes(_ label: String, _ operation: @escaping @Sendable () async -> Void) async {
        let done = XCTestExpectation(description: label)
        Task {
            await operation()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
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

    private func assertCancellation<T>(file: StaticString = #filePath, line: UInt = #line,
                                       _ operation: () async throws -> T) async {
        do {
            _ = try await operation()
            XCTFail("expected CancellationError", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)", file: file, line: line)
        }
    }

    private func assertMapped(_ error: BluetoothTransportError, _ phase: LaMarzoccoBluetoothClient.BluetoothErrorPhase,
                              _ expected: LaMarzoccoError, file: StaticString = #filePath, line: UInt = #line) {
        let mapped = LaMarzoccoBluetoothClient.mapTransportError(error, phase: phase)
        XCTAssertEqual(mapped as? LaMarzoccoError, expected, "\(error) in \(phase)", file: file, line: line)
    }

    private func assertLinkIsDead(_ link: any BluetoothLink, file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await link.read(auth, timeout: .seconds(1))
            XCTFail("the link should be dead", file: file, line: line)
        } catch let error as BluetoothTransportError {
            XCTAssertEqual(error, .notConnected, file: file, line: line)
        }
    }
}

// MARK: - Private test doubles

private struct ForeignError: Error {}

/// A lock-protected value shared with `@Sendable` closures.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

/// A weak reference, to observe that a released client deallocated.
private final class Weak<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?

    init(_ value: Object?) { self.value = value }
}

/// One-shot gate: `wait()` suspends until `open()`; afterwards it returns at once.
private final class Latch: @unchecked Sendable {
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

/// Wraps a FakeBluetoothCentral: records the order of seam calls and can hand out any link.
private final class ScriptedCentral: BluetoothCentral, @unchecked Sendable {
    let inner: FakeBluetoothCentral
    private let lock = NSLock()
    private var queued: [any BluetoothLink] = []
    private var callLog: [String] = []

    init(_ inner: FakeBluetoothCentral) { self.inner = inner }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return callLog
    }

    func enqueue(_ link: any BluetoothLink) {
        lock.lock()
        queued.append(link)
        lock.unlock()
    }

    private func record(_ call: String) {
        lock.lock()
        callLog.append(call)
        lock.unlock()
    }

    func availability() async -> BluetoothAvailability {
        record("availability")
        return await inner.availability()
    }

    func availabilityUpdates() -> AsyncStream<BluetoothAvailability> {
        record("availabilityUpdates")
        return inner.availabilityUpdates()
    }

    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] {
        try await inner.scan(for: duration)
    }

    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        record("connect")
        let next: (any BluetoothLink)? = {
            lock.lock()
            defer { lock.unlock() }
            return queued.isEmpty ? nil : queued.removeFirst()
        }()
        if let next { return next }
        return try await inner.connect(to: id, timeout: timeout)
    }
}

/// A link that dies without ever reporting `.disconnected` (its events stay silent), so the client
/// still holds it when a teardown path runs: every op then throws `.notConnected`.
private final class SilentlyDyingLink: BluetoothLink, @unchecked Sendable {
    let inner: FakeBluetoothLink
    let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation

    init(_ inner: FakeBluetoothLink) {
        self.inner = inner
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self, bufferingPolicy: .unbounded)
    }

    deinit { continuation.finish() }

    var peripheralID: BluetoothPeripheralID { inner.peripheralID }

    /// The inner link goes down (its own event stream is never read); ours says nothing.
    func die() { inner.drop(.disconnected(code: 7)) }

    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        try await inner.discover(wanted, refresh: refresh, timeout: timeout)
    }

    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data {
        try await inner.read(characteristic, timeout: timeout)
    }

    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        try await inner.write(data, to: characteristic, withResponse: withResponse, timeout: timeout)
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

/// A live link that reports when it is closed and when its event stream stops being iterated (the
/// client's link watcher was cancelled). Its own events stay silent, so only the client's teardown
/// (not a `.disconnected` event) can end the watcher.
private final class ObservedLink: BluetoothLink, @unchecked Sendable {
    let inner: FakeBluetoothLink
    let events: AsyncStream<LinkEvent>
    let disconnected = XCTestExpectation(description: "link disconnected")
    let watcherEnded = XCTestExpectation(description: "link watcher ended")
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()
    private var disconnects = 0

    init(_ inner: FakeBluetoothLink) {
        self.inner = inner
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self, bufferingPolicy: .unbounded)
        let ended = watcherEnded
        continuation.onTermination = { termination in
            if case .cancelled = termination { ended.fulfill() }
        }
    }

    deinit { continuation.finish() }

    var disconnectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return disconnects
    }

    var peripheralID: BluetoothPeripheralID { inner.peripheralID }

    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        try await inner.discover(wanted, refresh: refresh, timeout: timeout)
    }

    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data {
        try await inner.read(characteristic, timeout: timeout)
    }

    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        try await inner.write(data, to: characteristic, withResponse: withResponse, timeout: timeout)
    }

    func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws {
        try await inner.subscribe(characteristic, timeout: timeout)
    }

    func unsubscribe(_ characteristic: GATTUUID) async { await inner.unsubscribe(characteristic) }

    /// Recorded by the inner fake first, so `disconnected` fires after `.disconnect` is in `recordedOps`.
    func disconnect() async {
        await inner.disconnect()
        lock.withLock { disconnects += 1 }
        disconnected.fulfill()
    }

    func attMTU() async -> Int? { await inner.attMTU() }

    func gattTable(timeout: Duration) async throws -> [BluetoothGATTService] {
        try await inner.gattTable(timeout: timeout)
    }
}

extension LaMarzoccoBluetoothClient {
    /// Runs `body` on the actor: read or set internal state from a test.
    fileprivate func inspect<T: Sendable>(_ body: @Sendable (isolated LaMarzoccoBluetoothClient) -> T) -> T {
        body(self)
    }

    /// Replaces the idle task with one standing at the point where its sleep has fired: it calls
    /// `dropConnection(fromIdleTimer: true)`. `queued` runs in the same actor turn as the drop's
    /// `acquire(.connection)`, so once it ran and a test then hops onto the actor, the drop is queued
    /// on a held gate (no polling).
    fileprivate func startIdleDropQueuedOnGate(queued: @escaping @Sendable () -> Void) {
        idleTask?.cancel()
        idleTask = Task {
            queued()
            await self.dropConnection(fromIdleTimer: true)
        }
    }

    /// `acquire(gate)` that records, in the same actor turn, when it queued and when it got the gate.
    fileprivate func acquireRecording(_ gate: BluetoothGate, label: String, log: Locked<[String]>,
                                      queued: @Sendable () -> Void) async {
        log.withLock { $0.append("queued \(label)") }
        queued()
        await acquire(gate)
        log.withLock { entries in
            // Another holder would have logged "acquired" without a matching "released" yet.
            let acquired = entries.filter { $0.hasPrefix("acquired ") }.count
            let released = entries.filter { $0.hasPrefix("released ") }.count
            if acquired != released { entries.append("overlap") }
            entries.append("acquired \(label)")
        }
        log.withLock { $0.append("released \(label)") }
        release(gate)
    }
}
