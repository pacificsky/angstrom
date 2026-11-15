import XCTest
@testable import Angstrom
import AngstromTestSupport

/// T1 parity suite, connection lifecycle (SPEC §4.2–§4.8, §4.4.1, §12 D7/D11/D16/D19): the upstream
/// connection tests of `tests/test_bluetooth_client.py` and the Angstrom-only gap/divergence tests, run
/// against the real `LaMarzoccoBluetoothClient` over the AngstromTestSupport fakes.
final class BluetoothConnectionTests: XCTestCase {

    // MARK: - Upstream parity

    /// Upstream: test_persistent_connection_auto_connect (tests/test_bluetooth_client.py:434) [C09]
    func testFirstCommandConnectsAndAuthenticates() async throws {
        let rig = makeRig()
        let before = await rig.client.isConnected
        XCTAssertFalse(before, "no connection before the first command")
        XCTAssertEqual(rig.central.connectCount, 0)

        let status = try await rig.client.setPower(on: true)

        XCTAssertTrue(status.isSuccess)
        XCTAssertEqual(rig.central.connectCount, 1, "establish_connection awaited once")
        XCTAssertEqual(rig.central.connectTimeouts, [.seconds(20)])
        let link = try XCTUnwrap(rig.central.links.first)
        XCTAssertEqual(rig.central.links.count, 1)
        // `writes[0] == (AUTH_CHAR, b"token")`, then the command and its status read.
        XCTAssertEqual(link.recordedOps.compactMap(Self.write).first, Write(authChar, Data("token".utf8)))
        XCTAssertEqual(link.recordedOps, connectOps + [.write(writeChar, powerOn), .read(writeChar)])
        XCTAssertEqual(link.requestedTimeouts, Array(repeating: .seconds(20), count: 5))
        let state = await rig.client.connectionTestState { ($0.isConnected, $0.authenticationFailed, $0.reportedConnected) }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertTrue(state.2)

        await rig.client.disconnect()
        XCTAssertEqual(link.recordedOps.last, .disconnect)
    }

    /// Upstream: test_persistent_connection_reuse (tests/test_bluetooth_client.py:454) [C10]
    func testSequentialCommandsReuseConnection() async throws {
        let rig = makeRig()

        _ = try await rig.client.setPower(on: true)
        _ = try await rig.client.setPower(on: false)
        _ = try await rig.client.setSteam(on: true)

        XCTAssertEqual(rig.central.connectCount, 1, "the connection is established only once")
        XCTAssertEqual(rig.central.links.count, 1)
        let link = try XCTUnwrap(rig.central.links.first)
        XCTAssertEqual(link.recordedOps, connectOps + [
            .write(writeChar, powerOn), .read(writeChar),
            .write(writeChar, powerOff), .read(writeChar),
            .write(writeChar, steamOn), .read(writeChar),
        ], "one auth, then three write/read pairs on the same link")
        let connected = await rig.client.isConnected
        XCTAssertTrue(connected, "the connection is still active")

        await rig.client.disconnect()
    }

    /// Upstream: test_auto_disconnect_after_idle (tests/test_bluetooth_client.py:475) [C11]
    func testIdleTimeoutDisconnects() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        _ = try await rig.client.setPower(on: true)
        let connected = await rig.client.isConnected
        XCTAssertTrue(connected)
        let link = try XCTUnwrap(rig.central.links.first)

        await waitForPending(rig.sleeper, .idleDisconnect)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        XCTAssertEqual(link.recordedOps.filter { $0 == .disconnect }, [], "nothing closed before the timer fires")
        rig.sleeper.fire(.idleDisconnect)
        let seen = try await waitFor(events) { $0 == .disconnected }

        XCTAssertEqual(seen, [.connected, .disconnected])
        let state = await rig.client.connectionTestState { ($0.isConnected, $0.link == nil, $0.idleTask == nil) }
        XCTAssertFalse(state.0, "the connection is closed")
        XCTAssertTrue(state.1)
        XCTAssertTrue(state.2)
        XCTAssertEqual(link.recordedOps, connectOps + [.write(writeChar, powerOn), .read(writeChar), .disconnect],
                       "disconnect awaited exactly once")
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect).filter { $0 != .seconds(30) }, [])
    }

    /// Upstream: test_timer_reset_on_new_command (tests/test_bluetooth_client.py:493) [C12]
    ///
    /// Restated (SPEC §9.4): exactly one pending idle sleep after each command; firing it disconnects.
    func testCommandRestartsIdleTimer() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()

        _ = try await rig.client.setPower(on: true)
        await waitForPending(rig.sleeper, .idleDisconnect)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        let first = try await currentIdleTask(rig.client)

        // Another command restarts the timer: the old idle task is cancelled, one new sleep pends.
        _ = try await rig.client.setSteam(on: true)
        await waitForPending(rig.sleeper, .idleDisconnect)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1, "exactly one pending idle sleep")
        let second = try await currentIdleTask(rig.client)
        XCTAssertNotEqual(first, second, "the timer was restarted")
        XCTAssertTrue(first.isCancelled, "the previous idle task was cancelled")
        XCTAssertFalse(second.isCancelled)
        let connected = await rig.client.isConnected
        XCTAssertTrue(connected)
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect).filter { $0 != .seconds(30) }, [])

        rig.sleeper.fire(.idleDisconnect)
        let seen = try await waitFor(events) { $0 == .disconnected }
        XCTAssertEqual(seen, [.connected, .disconnected])
        let after = await rig.client.isConnected
        XCTAssertFalse(after, "firing the one pending idle sleep disconnects")
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 0)
        XCTAssertEqual(rig.central.links.first?.recordedOps.last, .disconnect)

        await rig.client.disconnect()
    }

    /// Upstream: test_concurrent_commands_thread_safe (tests/test_bluetooth_client.py:516) [C13]
    func testConcurrentCommandsConnectOnce() async throws {
        let rig = makeRig()
        let client = rig.client

        async let first = client.setPower(on: true)
        async let second = client.setSteam(on: true)
        async let third = client.setPower(on: false)
        let statuses = try await [first, second, third]

        XCTAssertEqual(statuses.map(\.isSuccess), [true, true, true])
        XCTAssertEqual(rig.central.connectCount, 1, "connected only once despite the concurrent calls")
        let link = try XCTUnwrap(rig.central.links.first)
        let writes = link.recordedOps.compactMap(Self.write)
        XCTAssertEqual(writes.map(\.characteristic), [authChar, writeChar, writeChar, writeChar])
        // Every command ran exactly once (in some order), each write followed by its own status read.
        XCTAssertEqual(Array(link.recordedOps.prefix(3)), connectOps)
        let commandOps = Array(link.recordedOps.dropFirst(3))
        XCTAssertEqual(commandOps.count, 6)
        XCTAssertEqual(commandOps.enumerated().filter { $0.offset % 2 == 1 }.map(\.element),
                       Array(repeating: FakeOp.read(writeChar), count: 3))
        XCTAssertEqual(writes.dropFirst().map(\.data).sorted { $0.lexicographicallyPrecedes($1) },
                       [powerOn, powerOff, steamOn].sorted { $0.lexicographicallyPrecedes($1) })

        await client.disconnect()
    }

    /// Upstream: test_exception_triggers_disconnect (tests/test_bluetooth_client.py:544) [C14]
    func testCommandErrorDropsIdleConnection() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        _ = try await rig.client.setPower(on: true)
        let connected = await rig.client.isConnected
        XCTAssertTrue(connected)
        let link = try XCTUnwrap(rig.central.links.first)

        link.onWrite = { _, _ in throw BluetoothTransportError.gatt(domain: "CBATTErrorDomain", code: 14) }
        await assertThrows(.bluetoothConnectionFailed("GATT error CBATTErrorDomain 14")) {
            try await rig.client.setPower(on: false)
        }
        await rig.client.drainBackgroundWorkForTesting()

        let state = await rig.client.connectionTestState {
            ($0.isConnected, $0.idleTask == nil, $0.backgroundTasks.isEmpty, $0.hasBackgroundWorkForTesting)
        }
        XCTAssertFalse(state.0, "the error dropped the connection")
        XCTAssertTrue(state.1)
        XCTAssertTrue(state.2)
        XCTAssertFalse(state.3)
        XCTAssertEqual(link.recordedOps, connectOps + [
            .write(writeChar, powerOn), .read(writeChar),
            .write(writeChar, powerOff), .disconnect,
        ], "no status read after the failed write; one disconnect")
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected])
    }

    /// Upstream: test_characteristic_resolution_failure_clears_cache (tests/test_bluetooth_client.py:565) [C15]
    func testMissingCharacteristicRediscoversThenDrops() async throws {
        let rig = makeRig()
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.present = allCharacteristics.subtracting([writeChar])  // missing from cache and machine
        rig.central.enqueueConnect(.success(link))
        let events = await rig.client.connectionEvents()

        await assertThrows(.bluetoothConnectionFailed("Could not find characteristic 0b0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")) {
            try await rig.client.setPower(on: true)
        }
        await rig.client.drainBackgroundWorkForTesting()

        // The `clear_cache()` analogue: exactly one in-place rediscovery, nothing written, then the drop.
        XCTAssertEqual(link.recordedOps, connectOps + [.discover(refresh: true), .disconnect])
        let state = await rig.client.connectionTestState { ($0.isConnected, $0.link == nil, $0.hasBackgroundWorkForTesting) }
        XCTAssertFalse(state.0)
        XCTAssertTrue(state.1)
        XCTAssertFalse(state.2)
        XCTAssertEqual(rig.central.connectCount, 1)
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected])
    }

    /// Upstream: test_is_connected_property (tests/test_bluetooth_client.py:584) [C16]
    func testIsConnectedLifecycle() async throws {
        let rig = makeRig()
        let initially = await rig.client.isConnected
        XCTAssertFalse(initially)

        _ = try await rig.client.setPower(on: true)
        let afterCommand = await rig.client.isConnected
        XCTAssertTrue(afterCommand)

        await rig.client.disconnect()
        let afterDisconnect = await rig.client.isConnected
        XCTAssertFalse(afterDisconnect)
        XCTAssertEqual(rig.central.links.first?.recordedOps.last, .disconnect)
    }

    /// Upstream: test_reconnect_after_disconnect (tests/test_bluetooth_client.py:600) [C17]
    func testCommandAfterManualDisconnectReconnects() async throws {
        let rig = makeRig()
        _ = try await rig.client.setPower(on: true)
        await rig.client.disconnect()
        let disconnected = await rig.client.isConnected
        XCTAssertFalse(disconnected)

        let status = try await rig.client.setSteam(on: true)
        XCTAssertTrue(status.isSuccess)
        let reconnected = await rig.client.isConnected
        XCTAssertTrue(reconnected)
        XCTAssertEqual(rig.central.connectCount, 2)
        XCTAssertEqual(rig.central.links.count, 2)
        let first = rig.central.links[0]
        let second = rig.central.links[1]
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.recordedOps, connectOps + [.write(writeChar, powerOn), .read(writeChar), .disconnect])
        XCTAssertEqual(second.recordedOps, connectOps + [.write(writeChar, steamOn), .read(writeChar)],
                       "the new link authenticates again")

        await rig.client.disconnect()
        XCTAssertEqual(second.recordedOps.last, .disconnect)
    }

    /// Upstream: test_requests_are_atomic (tests/test_bluetooth_client.py:1253) [C47]
    func testRequestWriteReadPairsAreAtomic() async throws {
        let rig = makeRig()
        let link = FakeBluetoothLink.laMarzocco(token: "token")  // 0a0b… answers "[]" (`values[READ_CHAR] = b"[]"`)
        // Every op is logged when it starts, then lets the other request run (`asyncio.sleep(0)`).
        let started = Locked<[FakeOp]>([])
        link.beforeOp = { op in
            started.withLock { $0.append(op) }
            for _ in 0..<5 { await Task.yield() }
        }
        rig.central.enqueueConnect(.success(link))
        let client = rig.client

        async let boilers = client.boilers()
        async let status = client.setTemperature(boiler: .coffee, celsius: 93)
        let (readBoilers, setStatus) = try await (boilers, status)

        XCTAssertEqual(readBoilers, [])
        XCTAssertTrue(setStatus.isSuccess)
        let log = started.value
        let io = log.filter { op in
            switch op {
            case .write, .read: return true
            default: return false
            }
        }
        // Three writes (auth + two requests), each directly followed by its read.
        XCTAssertEqual(io.count, 6)
        XCTAssertEqual(Array(io.prefix(2)), [.write(authChar, Data("token".utf8)), .read(authChar)])
        let pairs = stride(from: 2, to: io.count, by: 2).map { Array(io[$0...($0 + 1)]) }
        let boilersPair: [FakeOp] = [.write(readChar, Data("boilers".utf8) + [0x00]), .read(readChar)]
        let tempPair: [FakeOp] = [.write(writeChar, coffee93), .read(writeChar)]
        XCTAssertTrue(pairs == [boilersPair, tempPair] || pairs == [tempPair, boilersPair],
                      "a request's write and read must not interleave with the other request: \(io)")
        XCTAssertEqual(rig.central.connectCount, 1)

        await client.disconnect()
    }

    /// Upstream: test_ble_device_callback (tests/test_bluetooth_client.py:1345) [C51]
    ///
    /// Restated (D3): no device callback; `connect(to: peripheral)` uses the stored id on every
    /// (re)connect attempt.
    func testConnectUsesStoredPeripheralID() async throws {
        let peripheral = BluetoothPeripheralID(rawValue: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        let rig = makeRig(peripheral: peripheral)
        XCTAssertEqual(rig.client.peripheral, peripheral)
        let events = await rig.client.connectionEvents()

        _ = try await rig.client.setPower(on: true)
        XCTAssertEqual(rig.central.connectPeripheralIDs, [peripheral])

        // After a manual disconnect.
        await rig.client.disconnect()
        _ = try await rig.client.setSteam(on: true)
        XCTAssertEqual(rig.central.connectPeripheralIDs, [peripheral, peripheral])

        // After a link loss.
        let lossEvents = await rig.client.connectionEvents()
        try XCTUnwrap(rig.central.links.last).drop(.disconnected(code: 7))
        _ = try await waitFor(lossEvents) { $0 == .disconnected }
        _ = try await rig.client.setPower(on: false)
        XCTAssertEqual(rig.central.connectPeripheralIDs, [peripheral, peripheral, peripheral])

        // Every retried attempt too.
        await rig.client.disconnect()
        rig.central.enqueueConnect(.failure(.timedOut("connect")))
        _ = try await rig.client.setPower(on: true)
        XCTAssertEqual(rig.central.connectCount, 5)
        XCTAssertEqual(rig.central.connectPeripheralIDs, Array(repeating: peripheral, count: 5))

        await rig.client.disconnect()
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected, .connected, .disconnected, .connected, .disconnected,
                              .connected, .disconnected])
    }

    /// Upstream: test_connection_callback_connect_and_idle_disconnect (tests/test_bluetooth_client.py:1361) [C52]
    func testConnectionEventsConnectAndIdle() async throws {
        let rig = makeRig()
        let afterCommands = await rig.client.connectionEvents()
        let untilIdle = await rig.client.connectionEvents()
        let whole = await rig.client.connectionEvents()

        _ = try await rig.client.setPower(on: true)
        _ = try await rig.client.setSteam(on: true)
        let early = await drain(afterCommands)
        XCTAssertEqual(early, [.connected], "called once with True")

        // The fake disconnect yields; the idle timer must not cancel itself.
        await waitForPending(rig.sleeper, .idleDisconnect)
        rig.sleeper.fire(.idleDisconnect)
        let seen = try await waitFor(untilIdle) { $0 == .disconnected }
        XCTAssertEqual(seen, [.connected, .disconnected])

        let state = await rig.client.connectionTestState { ($0.isConnected, $0.reportedConnected) }
        XCTAssertFalse(state.0)
        XCTAssertFalse(state.1)
        XCTAssertEqual(rig.central.links.first?.recordedOps.last, .disconnect)
        let all = await drain(whole)
        XCTAssertEqual(all, [.connected, .disconnected])
    }

    /// Upstream: test_connection_callback_connection_lost (tests/test_bluetooth_client.py:1382) [C53]
    func testConnectionEventsDeduplicate() async throws {
        let rig = makeRig()
        let lossWatch = await rig.client.connectionEvents()
        let firstHalf = await rig.client.connectionEvents()
        let whole = await rig.client.connectionEvents()
        _ = try await rig.client.setPower(on: true)
        let first = try XCTUnwrap(rig.central.links.first)

        first.drop(.disconnected(code: 7))
        _ = try await waitFor(lossWatch) { $0 == .disconnected }
        let lost = await rig.client.isConnected
        XCTAssertFalse(lost)
        await rig.client.disconnect()  // already disconnected: no second event
        let afterLoss = await drain(firstHalf)
        XCTAssertEqual(afterLoss, [.connected, .disconnected])
        XCTAssertEqual(first.recordedOps, connectOps + [.write(writeChar, powerOn), .read(writeChar)],
                       "a lost link is not disconnected again")

        _ = try await rig.client.setPower(on: true)
        await rig.client.disconnect()
        let all = await drain(whole)
        XCTAssertEqual(all, [.connected, .disconnected, .connected, .disconnected])
        XCTAssertEqual(rig.central.connectCount, 2)
    }

    /// Upstream: test_connection_callback_unregister (tests/test_bluetooth_client.py:1424) [C55]
    ///
    /// Restated (D4): a cancelled event-stream iteration stops delivery to that consumer only.
    func testCancelledEventStreamStopsDelivery() async throws {
        let rig = makeRig()
        let cancelled = await rig.client.connectionEvents()
        let kept = await rig.client.connectionEvents()
        let firstSeen = expectation(description: "the cancelled consumer saw .connected")
        let consumer = Task { () -> [ConnectionEvent] in
            var seen: [ConnectionEvent] = []
            for await event in cancelled {
                seen.append(event)
                if seen.count == 1 { firstSeen.fulfill() }
            }
            return seen
        }

        _ = try await rig.client.setPower(on: true)
        await fulfillment(of: [firstSeen], timeout: 5)
        // Cancelling twice is harmless (`unregister(); unregister()`).
        consumer.cancel()
        consumer.cancel()
        let ended = expectation(description: "the cancelled iteration ended")
        let collector = Task { () -> [ConnectionEvent] in
            let seen = await consumer.value
            ended.fulfill()
            return seen
        }
        await fulfillment(of: [ended], timeout: 5)
        let cancelledSeen = await collector.value
        XCTAssertEqual(cancelledSeen, [.connected], "nothing after the cancellation")

        await rig.client.disconnect()
        _ = try await rig.client.setPower(on: true)
        await rig.client.disconnect()

        let keptSeen = await drain(kept)
        XCTAssertEqual(keptSeen, [.connected, .disconnected, .connected, .disconnected],
                       "the other consumer is unaffected")
        let fresh = await rig.client.connectionEvents()
        _ = try await rig.client.setPower(on: true)
        let freshSeen = await drain(fresh)
        XCTAssertEqual(freshSeen, [.connected], "the client keeps emitting after a consumer left")
        await rig.client.disconnect()
    }

    // MARK: - Angstrom-only

    /// Angstrom-only: G-CONN-2 — a characteristic found by the in-place rediscovery serves the request on the same link (D7b)
    func testRediscoveredCharacteristicServesRequest() async throws {
        let rig = makeRig()
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.present = allCharacteristics.subtracting([writeChar])  // stale cache
        link.presentAfterRefresh = allCharacteristics
        rig.central.enqueueConnect(.success(link))

        let status = try await rig.client.setPower(on: true)

        XCTAssertTrue(status.isSuccess)
        XCTAssertEqual(rig.central.connectCount, 1, "served on the same link")
        XCTAssertEqual(link.recordedOps, connectOps + [.discover(refresh: true), .write(writeChar, powerOn), .read(writeChar)])
        let state = await rig.client.connectionTestState {
            ($0.isConnected, $0.discovered.contains(BluetoothConstants.writeCharacteristic), $0.backgroundTasks.isEmpty)
        }
        XCTAssertTrue(state.0)
        XCTAssertTrue(state.1, "the rediscovery result replaced the stale table")
        XCTAssertTrue(state.2, "no drop was scheduled")

        // The refreshed table is kept: the next request does not rediscover.
        _ = try await rig.client.setPower(on: false)
        XCTAssertEqual(Array(link.recordedOps.dropFirst(connectOps.count + 3)),
                       [.write(writeChar, powerOff), .read(writeChar)])
        XCTAssertFalse(link.recordedOps.contains(.disconnect))

        await rig.client.disconnect()
    }

    /// Angstrom-only: G-CONN-4 — the idle timer is armed only after auth, requests 30 s, and is re-armed on a reused link
    func testIdleTimerArmedAfterAuthAndReusedLink() async throws {
        // A failed auth arms nothing.
        let rejected = makeRig()
        rejected.central.makeLink = { .laMarzocco(token: "other") }
        await assertThrows(.bluetoothAuthenticationFailed) { try await rejected.client.setPower(on: true) }
        await rejected.client.drainBackgroundWorkForTesting()
        let rejectedIdle = await rejected.client.connectionTestState { $0.idleTask == nil }
        XCTAssertTrue(rejectedIdle)
        XCTAssertEqual(rejected.sleeper.startedCount(.idleDisconnect), 0)

        // While auth is in flight, no idle timer exists.
        let rig = makeRig()
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        let held = Latch()
        let inAuth = expectation(description: "auth read in flight")
        link.beforeOp = { op in
            if op == .read(authChar) {
                inAuth.fulfill()
                await held.wait()
            }
        }
        rig.central.enqueueConnect(.success(link))
        let command = Task { try await rig.client.setPower(on: true) }
        await fulfillment(of: [inAuth], timeout: 5)
        let duringAuth = await rig.client.connectionTestState { $0.idleTask == nil }
        XCTAssertTrue(duringAuth, "not armed before auth succeeds")
        XCTAssertEqual(rig.sleeper.startedCount(.idleDisconnect), 0)
        held.open()
        _ = try await command.value

        await waitForPending(rig.sleeper, .idleDisconnect)
        let first = try await currentIdleTask(rig.client)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        XCTAssertFalse(rig.sleeper.requested(.idleDisconnect).isEmpty)
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect).filter { $0 != .seconds(30) }, [], "every idle sleep is 30 s")

        // Reused link: ensureConnected re-arms (no reconnect).
        _ = try await rig.client.ensureConnected()
        await waitForPending(rig.sleeper, .idleDisconnect)
        let rearmed = try await currentIdleTask(rig.client)
        XCTAssertNotEqual(first, rearmed)
        XCTAssertTrue(first.isCancelled)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        XCTAssertEqual(rig.central.connectCount, 1)

        // A request on the reused link re-arms it twice: in ensureConnected (§4.4 step 2), and again
        // after the write, before the read (step 5, the second `_ensure_connected`).
        let writeHeld = Latch()
        let readHeld = Latch()
        let inWrite = expectation(description: "request write in flight")
        let inRead = expectation(description: "request read in flight")
        link.beforeOp = { op in
            if op == .write(writeChar, powerOff) {
                inWrite.fulfill()
                await writeHeld.wait()
            } else if op == .read(writeChar) {
                inRead.fulfill()
                await readHeld.wait()
            }
        }
        let request = Task { try await rig.client.setPower(on: false) }
        await fulfillment(of: [inWrite], timeout: 5)
        let duringWrite = try await currentIdleTask(rig.client)
        XCTAssertNotEqual(rearmed, duringWrite, "re-armed by ensureConnected on the reused link")
        XCTAssertTrue(rearmed.isCancelled)
        writeHeld.open()
        await fulfillment(of: [inRead], timeout: 5)
        let duringRead = try await currentIdleTask(rig.client)
        XCTAssertNotEqual(duringWrite, duringRead, "re-armed again after the write")
        XCTAssertTrue(duringWrite.isCancelled)
        readHeld.open()
        _ = try await request.value
        await waitForPending(rig.sleeper, .idleDisconnect)
        let afterRequest = try await currentIdleTask(rig.client)
        XCTAssertEqual(afterRequest, duringRead, "the read does not re-arm")
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect).filter { $0 != .seconds(30) }, [])

        await rig.client.disconnect()
    }

    /// Angstrom-only: G-CONN-5 — with the shot counter enabled but no link, a failed request does drop (dropConnectionInBackground runs)
    func testFailedRequestDropsWhenShotCounterEnabledButUnlinked() async throws {
        // The reconnect backoff is manual, so the loop a drop starts parks before its first attempt.
        let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
        rig.central.connectFailure = .gatt(domain: "CBErrorDomain", code: 14)
        await rig.client.connectionTestState { $0.shotCounterEnabled = true }
        let before = await rig.client.connectionTestState { ($0.link == nil, $0.reconnectTask == nil) }
        XCTAssertTrue(before.0)
        XCTAssertTrue(before.1)

        await assertThrows(.bluetoothConnectionFailed(
            "Failed to connect to 00000000-0000-0000-0000-000000000001 after 3 attempts: GATT error CBErrorDomain 14")) {
            try await rig.client.setPower(on: true)
        }

        // Only the scheduled `dropConnection()` (its `handleConnectionLost()`) can start the loop here.
        await waitForPending(rig.sleeper, .reconnectBackoff)
        let after = await rig.client.connectionTestState { ($0.reconnectTask != nil, $0.link == nil, $0.shotCounterEnabled) }
        XCTAssertTrue(after.0, "the drop ran and started the reconnect loop")
        XCTAssertTrue(after.1)
        XCTAssertTrue(after.2)
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
        XCTAssertEqual(rig.central.connectCount, 3, "the loop has not attempted yet")

        await rig.client.disconnect()
        await rig.client.drainBackgroundWorkForTesting()
        let cleaned = await rig.client.connectionTestState { ($0.reconnectTask == nil, $0.shotCounterEnabled) }
        XCTAssertTrue(cleaned.0)
        XCTAssertFalse(cleaned.1)
    }

    /// Angstrom-only: G-CONN-7 — a link loss cancels the idle task (D16)
    func testLinkLossCancelsIdleTask() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        _ = try await rig.client.setPower(on: true)
        await waitForPending(rig.sleeper, .idleDisconnect)
        let idle = try await currentIdleTask(rig.client)
        let link = try XCTUnwrap(rig.central.links.first)

        link.drop(.disconnected(code: 7))
        let seen = try await waitFor(events) { $0 == .disconnected }

        XCTAssertEqual(seen, [.connected, .disconnected])
        XCTAssertTrue(idle.isCancelled, "the loss cancelled the idle task")
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 0, "its sleep is gone")
        let state = await rig.client.connectionTestState { ($0.idleTask == nil, $0.isConnected, $0.link == nil) }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertTrue(state.2)
        XCTAssertEqual(link.recordedOps, connectOps + [.write(writeChar, powerOn), .read(writeChar)],
                       "a lost link is not disconnected by the client")
    }

    /// Angstrom-only: G-CONN-8 — a link drop between a request's write and read fails the request; no silent reconnect (D7a)
    func testLinkDropBetweenWriteAndReadFailsRequest() async throws {
        let fake = FakeBluetoothCentral()
        let inner = FakeBluetoothLink.laMarzocco(token: "token")
        let disconnectSeen = Latch()
        let central = QueueCentral(fake)
        central.enqueue(DropAfterWriteLink(inner, target: writeChar, resume: disconnectSeen))
        let client = LaMarzoccoBluetoothClient(transport: .fake(fake, sleeper: ManualBluetoothSleeper()).replacingCentral(central),
                                               peripheral: .fake, token: BluetoothAuthToken("token"))
        let events = await client.connectionEvents()
        let watched = await client.connectionEvents()
        let watcher = Task {
            for await event in watched where event == .disconnected {
                disconnectSeen.open()
                return
            }
        }

        await assertThrows(.bluetoothConnectionFailed("Client is not connected")) {
            try await client.setPower(on: true)
        }
        await watcher.value
        XCTAssertEqual(central.connectCount, 1, "no silent reconnect inside the request")
        await client.drainBackgroundWorkForTesting()

        XCTAssertEqual(inner.recordedOps, connectOps + [.write(writeChar, powerOn)], "the stale status is never read")
        XCTAssertEqual(central.connectCount, 1)
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected])

        // The next request reconnects lazily on a new link.
        let status = try await client.setPower(on: true)
        XCTAssertTrue(status.isSuccess)
        XCTAssertEqual(central.connectCount, 2)
        let second = try XCTUnwrap(fake.links.first)
        XCTAssertEqual(second.recordedOps, connectOps + [.write(writeChar, powerOn), .read(writeChar)])
        await client.disconnect()
    }

    /// Angstrom-only: D7c — `.servicesInvalidated` makes the next request rediscover on the live link before using the table
    func testServicesInvalidatedForcesRediscovery() async throws {
        let rig = makeRig()
        let raw = await rig.client.rawFrames()
        let events = await rig.client.connectionEvents()
        _ = try await rig.client.setPower(on: true)
        let link = try XCTUnwrap(rig.central.links.first)

        link.invalidateServices()
        _ = try await waitFor(raw) { $0.kind == .event && $0.data == Data("[services invalidated]".utf8) }
        let flagged = await rig.client.connectionTestState { ($0.needsRediscovery, $0.isConnected) }
        XCTAssertTrue(flagged.0)
        XCTAssertTrue(flagged.1, "the link stays up")

        _ = try await rig.client.setPower(on: false)
        _ = try await rig.client.setSteam(on: true)
        XCTAssertEqual(Array(link.recordedOps.dropFirst(connectOps.count + 2)), [
            .discover(refresh: true),
            .write(writeChar, powerOff), .read(writeChar),
            .write(writeChar, steamOn), .read(writeChar),
        ], "one rediscovery before the next request, none after")
        let cleared = await rig.client.connectionTestState { $0.needsRediscovery }
        XCTAssertFalse(cleared)

        // The rediscovered table is what the request trusts: a characteristic gone after the change fails.
        link.presentAfterRefresh = allCharacteristics.subtracting([readChar])
        link.invalidateServices()
        _ = try await waitFor(raw) { $0.kind == .event && $0.data == Data("[services invalidated]".utf8) }
        await assertThrows(.bluetoothConnectionFailed("Could not find characteristic 0a0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")) {
            try await rig.client.isPlumbedIn()
        }
        await rig.client.drainBackgroundWorkForTesting()
        XCTAssertEqual(Array(link.recordedOps.suffix(3)), [.discover(refresh: true), .discover(refresh: true), .disconnect])
        XCTAssertEqual(rig.central.connectCount, 1)
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected])
    }

    /// Angstrom-only: D7d — cancellation inside a request is drop-class: the caller gets CancellationError and the link is dropped
    func testCancellationInsideRequestDrops() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        _ = try await rig.client.setPower(on: true)
        let link = try XCTUnwrap(rig.central.links.first)
        let held = Latch()
        let inRead = expectation(description: "status read in flight")
        link.beforeOp = { op in
            if op == .read(writeChar) {
                inRead.fulfill()
                await held.wait()
            }
        }

        let command = Task { try await rig.client.setPower(on: false) }
        await fulfillment(of: [inRead], timeout: 5)
        command.cancel()
        held.open()
        await assertCancellation { try await command.value }
        await rig.client.drainBackgroundWorkForTesting()

        XCTAssertEqual(link.recordedOps, connectOps + [
            .write(writeChar, powerOn), .read(writeChar),
            .write(writeChar, powerOff), .read(writeChar), .disconnect,
        ])
        let state = await rig.client.connectionTestState { ($0.isConnected, $0.gateBusy, $0.hasBackgroundWorkForTesting) }
        XCTAssertFalse(state.0, "the cancelled request dropped the link")
        XCTAssertEqual(state.1, [], "both gates released")
        XCTAssertFalse(state.2)
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected])
        XCTAssertEqual(rig.central.connectCount, 1)
    }

    /// Angstrom-only: D7e — a request in the window after the peripheral dropped but before `.disconnected` arrives fails (no reconnect), drops once, and the next request reconnects
    func testRequestInDisconnectWindowFailsThenReconnects() async throws {
        let rig = makeRig()
        let events = await rig.client.connectionEvents()
        _ = try await rig.client.setPower(on: true)
        let link = try XCTUnwrap(rig.central.links.first)
        // The peripheral is gone, but no `.disconnected` event has been yielded yet.
        link.onWrite = { _, _ in throw BluetoothTransportError.disconnected(code: 7) }
        link.onRead = { _ in throw BluetoothTransportError.disconnected(code: 7) }

        await assertThrows(.bluetoothConnectionFailed("disconnected (code 7)")) {
            try await rig.client.setSteam(on: true)
        }
        XCTAssertEqual(rig.central.connectCount, 1, "the stored link was trusted: no reconnect")
        await rig.client.drainBackgroundWorkForTesting()

        XCTAssertEqual(link.recordedOps, connectOps + [
            .write(writeChar, powerOn), .read(writeChar),
            .write(writeChar, steamOn), .disconnect,
        ], "exactly one drop")
        let dropped = await rig.client.isConnected
        XCTAssertFalse(dropped)

        let status = try await rig.client.setSteam(on: true)
        XCTAssertTrue(status.isSuccess)
        XCTAssertEqual(rig.central.connectCount, 2)
        let second = rig.central.links[1]
        XCTAssertEqual(second.recordedOps, connectOps + [.write(writeChar, steamOn), .read(writeChar)])
        await rig.client.disconnect()
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected, .connected, .disconnected])
    }

    /// Angstrom-only: D11 — `isConnected` is false while the transport link is up but unauthenticated
    func testIsConnectedOnlyAfterAuth() async throws {
        let rig = makeRig()
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        let held = Latch()
        let inAuth = expectation(description: "auth read in flight")
        link.beforeOp = { op in
            if op == .read(authChar) {
                inAuth.fulfill()
                await held.wait()
            }
        }
        rig.central.enqueueConnect(.success(link))
        let raw = await rig.client.rawFrames()
        let earlyEvents = await rig.client.connectionEvents()
        let events = await rig.client.connectionEvents()

        let command = Task { try await rig.client.setPower(on: true) }
        await fulfillment(of: [inAuth], timeout: 5)
        let during = await rig.client.connectionTestState { ($0.isConnected, $0.link == nil, $0.reportedConnected) }
        XCTAssertFalse(during.0, "the transport link is up, but not authenticated")
        XCTAssertTrue(during.1)
        XCTAssertFalse(during.2)
        let frames = await drain(raw)
        XCTAssertEqual(frames.map(\.kind), [.event, .event, .write])
        XCTAssertEqual(frames.prefix(2).map(\.data), [Data("[connecting]".utf8), Data("[connected]".utf8)],
                       "the link is up at the transport level")
        XCTAssertEqual(frames.last?.characteristic, "0d0b7847-e12b-09a8-b04b-8e0922a9abab")
        let noneYet = await drain(earlyEvents)
        XCTAssertEqual(noneYet, [])

        held.open()
        _ = try await command.value
        let after = await rig.client.connectionTestState { ($0.isConnected, $0.reportedConnected) }
        XCTAssertTrue(after.0)
        XCTAssertTrue(after.1)
        await rig.client.disconnect()
        let seen = await drain(events)
        XCTAssertEqual(seen, [.connected, .disconnected])
    }

    /// Angstrom-only: D19 — timeouts map per phase (connect retried, authenticate → connection failed, request → `.bluetoothTimedOut`, drop-class); every GATT op requests `timing.operationTimeout`
    func testOperationTimeoutsMapPerPhase() async throws {
        var timing = BluetoothTiming()
        timing.operationTimeout = .seconds(7)  // not the default, so a hard-coded 20 s would show
        var links: [FakeBluetoothLink] = []

        // Connect: `.timedOut` is retried (0.25 s backoff), then wrapped after 3 attempts.
        let connect = await makeRig(timing: timing)
        for _ in 0..<3 { connect.central.enqueueConnect(.failure(.timedOut("connect"))) }
        await assertThrows(.bluetoothConnectionFailed(
            "Failed to connect to 00000000-0000-0000-0000-000000000001 after 3 attempts: timed out (connect)")) {
            try await connect.client.setPower(on: true)
        }
        XCTAssertEqual(connect.central.connectCount, 3)
        XCTAssertEqual(connect.central.connectTimeouts, [.seconds(20), .seconds(20), .seconds(20)])
        XCTAssertEqual(connect.sleeper.requested(.connectBackoff), [.milliseconds(250), .milliseconds(250)])
        await connect.client.drainBackgroundWorkForTesting()

        // Authenticate, discovery: `Failed to connect to machine with Bluetooth: timed out (…)`.
        let discoverInner = FakeBluetoothLink.laMarzocco(token: "token")
        let discoverFake = FakeBluetoothCentral()
        let discoverCentral = QueueCentral(discoverFake)
        discoverCentral.enqueue(DiscoverFailingLink(discoverInner, error: .timedOut("discover")))
        let discoverClient = LaMarzoccoBluetoothClient(
            transport: .fake(discoverFake, sleeper: ManualBluetoothSleeper()).replacingCentral(discoverCentral),
            peripheral: .fake, token: BluetoothAuthToken("token"))
        await discoverClient.setTimingForTesting(timing)
        await assertThrows(.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: timed out (discover)")) {
            try await discoverClient.setPower(on: true)
        }
        await discoverClient.drainBackgroundWorkForTesting()
        XCTAssertEqual(discoverInner.recordedOps, [.discover(refresh: false), .disconnect])
        links.append(discoverInner)

        // Authenticate, auth write and auth read.
        for (label, failWrite) in [("write 0d0b7847", true), ("read 0d0b7847", false)] {
            let rig = await makeRig(timing: timing)
            let link = FakeBluetoothLink.laMarzocco(token: "token")
            let original = (link.onWrite, link.onRead)
            if failWrite {
                link.onWrite = { characteristic, data in
                    if characteristic == authChar { throw BluetoothTransportError.timedOut(label) }
                    try original.0(characteristic, data)
                }
            } else {
                link.onRead = { characteristic in
                    if characteristic == authChar { throw BluetoothTransportError.timedOut(label) }
                    return try original.1(characteristic)
                }
            }
            rig.central.enqueueConnect(.success(link))
            await assertThrows(.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: timed out (\(label))"), label) {
                try await rig.client.setPower(on: true)
            }
            await rig.client.drainBackgroundWorkForTesting()
            XCTAssertEqual(link.recordedOps.last, .disconnect, label)
            XCTAssertEqual(link.recordedOps.filter { $0 == .disconnect }.count, 1, label)
            XCTAssertEqual(rig.central.connectCount, 1, "\(label): an auth failure is not a retried connect attempt")
            let connected = await rig.client.isConnected
            XCTAssertFalse(connected, label)
            links.append(link)
        }

        // Request: `.bluetoothTimedOut`, drop-class (the link is dropped).
        for (label, failWrite) in [("write 0b0b7847", true), ("read 0b0b7847", false)] {
            let rig = await makeRig(timing: timing)
            let events = await rig.client.connectionEvents()
            _ = try await rig.client.setPower(on: true)
            let link = try XCTUnwrap(rig.central.links.first)
            if failWrite {
                link.onWrite = { _, _ in throw BluetoothTransportError.timedOut(label) }
            } else {
                link.onRead = { _ in throw BluetoothTransportError.timedOut(label) }
            }
            await assertThrows(.bluetoothTimedOut(label), label) {
                try await rig.client.setPower(on: false)
            }
            await rig.client.drainBackgroundWorkForTesting()
            let expectedTail: [FakeOp] = failWrite
                ? [.write(writeChar, powerOff), .disconnect]
                : [.write(writeChar, powerOff), .read(writeChar), .disconnect]
            XCTAssertEqual(Array(link.recordedOps.suffix(expectedTail.count)), expectedTail, label)
            let connected = await rig.client.isConnected
            XCTAssertFalse(connected, "\(label): a request timeout drops the link")
            let seen = await drain(events)
            XCTAssertEqual(seen, [.connected, .disconnected], label)
            links.append(link)
        }

        // Every bounded GATT op asked for exactly `timing.operationTimeout`.
        for link in links {
            XCTAssertFalse(link.requestedTimeouts.isEmpty)
            XCTAssertEqual(link.requestedTimeouts, Array(repeating: timing.operationTimeout, count: link.requestedTimeouts.count))
        }
    }

    // MARK: - Helpers

    private struct Rig {
        let central: FakeBluetoothCentral
        let sleeper: ManualBluetoothSleeper
        let client: LaMarzoccoBluetoothClient
    }

    private struct Write: Equatable {
        let characteristic: GATTUUID
        let data: Data
        init(_ characteristic: GATTUUID, _ data: Data) {
            self.characteristic = characteristic
            self.data = data
        }
    }

    private static func write(_ op: FakeOp) -> Write? {
        if case .write(let characteristic, let data) = op { return Write(characteristic, data) }
        return nil
    }

    private func makeRig(manual: Set<SleepPurpose> = [.idleDisconnect],
                         peripheral: BluetoothPeripheralID = .fake) -> Rig {
        let central = FakeBluetoothCentral()
        let sleeper = ManualBluetoothSleeper(manual: manual)
        let client = LaMarzoccoBluetoothClient(transport: .fake(central, sleeper: sleeper), peripheral: peripheral,
                                               token: BluetoothAuthToken("token"))
        return Rig(central: central, sleeper: sleeper, client: client)
    }

    private func makeRig(timing: BluetoothTiming) async -> Rig {
        let rig = makeRig()
        await rig.client.setTimingForTesting(timing)
        return rig
    }

    private func currentIdleTask(_ client: LaMarzoccoBluetoothClient,
                                 file: StaticString = #filePath, line: UInt = #line) async throws -> Task<Void, Never> {
        let task = await client.connectionTestState { $0.idleTask }
        return try XCTUnwrap(task, "no idle task", file: file, line: line)
    }

    /// Suspends until `count` sleeps of `purpose` are pending (hang guard: 5 s).
    private func waitForPending(_ sleeper: ManualBluetoothSleeper, _ purpose: SleepPurpose, count: Int = 1) async {
        let done = XCTestExpectation(description: "\(count) pending \(purpose) sleep(s)")
        let waiter = Task {
            await sleeper.waitForPending(purpose, count: count)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        waiter.cancel()
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
}

// MARK: - Wire values (verbatim from SPEC §3.1/§3.7 and the codec vectors)

private let readChar = BluetoothConstants.readCharacteristic
private let writeChar = BluetoothConstants.writeCharacteristic
private let authChar = BluetoothConstants.authCharacteristic
private let allCharacteristics: Set<GATTUUID> = [
    BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
    BluetoothConstants.tokenCharacteristic, BluetoothConstants.authCharacteristic,
    BluetoothConstants.shotCounterCharacteristic,
]
/// Discovery of the four session characteristics, the auth write of `b"token"` and one confirming read.
private let connectOps: [FakeOp] = [
    .discover(refresh: false),
    .write(BluetoothConstants.authCharacteristic, Data("token".utf8)),
    .read(BluetoothConstants.authCharacteristic),
]
private let powerOn = Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]
private let powerOff = Data(#"{"name":"MachineChangeMode","parameter":{"mode":"StandBy"}}"#.utf8) + [0x00]
private let steamOn = Data(#"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":true}}"#.utf8) + [0x00]
private let coffee93 = Data(#"{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":93}}"#.utf8) + [0x00]

// MARK: - Private test doubles

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

/// Hands out queued links (of any type) first, then defers to the wrapped FakeBluetoothCentral.
/// Counts every connect attempt itself.
private final class QueueCentral: BluetoothCentral, @unchecked Sendable {
    private let inner: FakeBluetoothCentral
    private let lock = NSLock()
    private var queued: [any BluetoothLink] = []
    private var count = 0

    init(_ inner: FakeBluetoothCentral) { self.inner = inner }

    var connectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func enqueue(_ link: any BluetoothLink) {
        lock.lock()
        queued.append(link)
        lock.unlock()
    }

    func availability() async -> BluetoothAvailability { await inner.availability() }

    func availabilityUpdates() -> AsyncStream<BluetoothAvailability> { inner.availabilityUpdates() }

    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] { try await inner.scan(for: duration) }

    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        let next: (any BluetoothLink)? = {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return queued.isEmpty ? nil : queued.removeFirst()
        }()
        if let next { return next }
        return try await inner.connect(to: id, timeout: timeout)
    }
}

/// After a successful write to `target`, the peripheral drops; the write only returns once the test
/// saw the client process `.disconnected` (it opens `resume`), so the client's same-link check runs
/// against a detached link.
private final class DropAfterWriteLink: BluetoothLink, @unchecked Sendable {
    let inner: FakeBluetoothLink
    private let target: GATTUUID
    private let resume: Latch

    init(_ inner: FakeBluetoothLink, target: GATTUUID, resume: Latch) {
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

/// Discovery runs on the inner link (recording the op and its timeout), then fails with `error`.
private final class DiscoverFailingLink: BluetoothLink, @unchecked Sendable {
    let inner: FakeBluetoothLink
    private let error: BluetoothTransportError

    init(_ inner: FakeBluetoothLink, error: BluetoothTransportError) {
        self.inner = inner
        self.error = error
    }

    var peripheralID: BluetoothPeripheralID { inner.peripheralID }
    var events: AsyncStream<LinkEvent> { inner.events }

    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        _ = try await inner.discover(wanted, refresh: refresh, timeout: timeout)
        throw error
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

extension BluetoothTransport {
    /// The same sleeper and clock, with `central` in place of the fake central.
    fileprivate func replacingCentral(_ central: any BluetoothCentral) -> BluetoothTransport {
        BluetoothTransport(central: central, sleeper: sleeper, now: now)
    }
}

extension LaMarzoccoBluetoothClient {
    /// Runs `body` on the actor: read or set internal state from a test.
    @discardableResult
    fileprivate func connectionTestState<T: Sendable>(_ body: @Sendable (isolated LaMarzoccoBluetoothClient) -> T) -> T {
        body(self)
    }
}
