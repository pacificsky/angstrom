import XCTest
@testable import Angstrom
import AngstromTestSupport

/// The shot-counter lifecycle parity suite (SPEC §4.4, §4.5, §4.9, §9.4 T3 lifecycle rows, D4): start,
/// stop, subscribe, the rediscovery pass and the request-error rules while the counter runs.
///
/// "No further event" assertions are made against a later sentinel event on the same stream (a restart
/// or a `disconnect()`): the client yields synchronously on the actor, so an extra event would sit in
/// the stream before the sentinel.
final class ShotCounterLifecycleTests: XCTestCase {
    private let auth = BluetoothConstants.authCharacteristic
    private let writeCharacteristic = BluetoothConstants.writeCharacteristic
    private let shotCounter = BluetoothConstants.shotCounterCharacteristic
    private let tokenWrite = Data("token".utf8)
    private let start = Date(timeIntervalSince1970: 1_000)
    /// `REPLAY` (`tests/test_bluetooth_client.py:811`).
    private let replay = Data(#"{"MachineMode":"StandBy"}"#.utf8)
    private let coffeeTemperature = Data(#"{"CoffeeBoiler1UpdateTemperature":93}"#.utf8)
    /// The ops of one successful connect: discovery (cached services), the token write, one auth read.
    private var connectOps: [FakeOp] { [.discover(refresh: false), .write(auth, tokenWrite), .read(auth)] }

    // MARK: - Parity (upstream tests)

    /// Upstream: test_start_shot_counter_characteristic_missing (tests/test_bluetooth_client.py:652) [C20]
    func testMissingCharacteristicReturnsFalseAfterOneRediscovery() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        let first = machine(missing: shotCounter)
        let second = machine(missing: shotCounter)
        rig.central.enqueueConnect(.success(first))
        rig.central.enqueueConnect(.success(second))

        let started = try await client.startShotCounter()
        XCTAssertFalse(started)

        // Cached services first; the missing characteristic closes that link (the one extra disconnect)
        // and the second pass connects with `refresh: true`. Nothing is ever subscribed.
        XCTAssertEqual(rig.central.connectCount, 2)
        XCTAssertEqual(first.recordedOps, connectOps + [.disconnect])
        XCTAssertEqual(second.recordedOps, [.discover(refresh: true), .write(auth, tokenWrite), .read(auth)])
        let state = await client.peek {
            ($0.isConnected, $0.link === second, $0.shotCounterActive, $0.shotCounterEnabled, $0.reconnectTask == nil)
        }
        XCTAssertTrue(state.0, "still connected")
        XCTAssertTrue(state.1, "the rediscovery link is kept")
        XCTAssertFalse(state.2)
        XCTAssertFalse(state.3, "a failed start disables the counter")
        XCTAssertTrue(state.4, "no reconnect loop")

        // The idle disconnect is running again: armed once, by the failed start (none while enabled).
        guard await pending(rig.sleeper, .idleDisconnect) else { return }
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect), [.seconds(30)])
        rig.sleeper.fire(.idleDisconnect)
        guard await fulfilled([connection.expectation { $0.count >= 4 }], "idle disconnect") else { return }
        XCTAssertEqual(connection.elements, [.connected, .disconnected, .connected, .disconnected])
        XCTAssertEqual(second.recordedOps.last, .disconnect)
        XCTAssertEqual(second.recordedOps.filter { $0 == .disconnect }.count, 1)
        let connected = await client.isConnected
        XCTAssertFalse(connected)

        // Sentinel: a working start is the first shot-counter event ever reported.
        let restarted = try await client.startShotCounter()
        XCTAssertTrue(restarted)
        guard await fulfilled([events.expectation { $0.count >= 1 }], "sentinel .subscribed") else { return }
        XCTAssertEqual(events.elements, [.subscribed])
        await client.disconnect()
    }

    /// Upstream: test_start_shot_counter_rediscovers_services (tests/test_bluetooth_client.py:677) [C21]
    func testStaleServiceCacheRediscoversCharacteristic() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        // Both links model the same stale cache: only a `refresh: true` discovery sees the characteristic.
        let first = machine(missing: shotCounter, afterRefresh: allCharacteristics)
        let second = machine(missing: shotCounter, afterRefresh: allCharacteristics)
        rig.central.enqueueConnect(.success(first))
        rig.central.enqueueConnect(.success(second))

        let started = try await client.startShotCounter()
        XCTAssertTrue(started)

        XCTAssertEqual(rig.central.connectCount, 2)
        XCTAssertEqual(first.recordedOps, connectOps + [.disconnect])
        XCTAssertEqual(second.recordedOps, [.discover(refresh: true), .write(auth, tokenWrite), .read(auth),
                                            .subscribe(shotCounter)])
        let active = await client.shotCounterActive
        XCTAssertTrue(active)

        // `.subscribed` exactly once; the disconnect is the sentinel.
        await client.disconnect()
        guard await fulfilled([events.expectation { $0.count >= 2 }], "events") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed])
        XCTAssertEqual(second.recordedOps.suffix(2), [.unsubscribe(shotCounter), .disconnect])
        XCTAssertEqual(first.recordedOps.filter { $0 == .disconnect }.count, 1)
    }

    /// Upstream: test_start_shot_counter (tests/test_bluetooth_client.py:699) [C22]
    func testStartSubscribesAndDisconnectUnsubscribes() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let link = machine()
        rig.central.enqueueConnect(.success(link))

        let started = try await client.startShotCounter()
        XCTAssertTrue(started)
        XCTAssertEqual(link.recordedOps, connectOps + [.subscribe(shotCounter)])
        let active = await client.shotCounterActive
        XCTAssertTrue(active)
        guard await fulfilled([events.expectation { $0.count >= 1 }], ".subscribed") else { return }
        XCTAssertEqual(events.elements, [.subscribed])

        await client.disconnect()
        XCTAssertEqual(link.recordedOps, connectOps + [.subscribe(shotCounter), .unsubscribe(shotCounter), .disconnect])
        let after = await client.peek { ($0.shotCounterActive, $0.shotCounterSubscribed, $0.isConnected) }
        XCTAssertFalse(after.0)
        XCTAssertFalse(after.1)
        XCTAssertFalse(after.2)
        guard await fulfilled([events.expectation { $0.count >= 2 }], ".unsubscribed") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed])
    }

    /// Upstream: test_shot_counter_suppresses_auto_disconnect (tests/test_bluetooth_client.py:719) [C23]
    func testShotCounterSuppressesIdleDisconnect() async throws {
        let rig = makeRig()
        let client = rig.client
        let connection = Recorder(await client.connectionEvents())
        let link = machine()
        rig.central.enqueueConnect(.success(link))
        let started = try await client.startShotCounter()
        XCTAssertTrue(started)
        let status = try await client.setPower(on: true)
        XCTAssertEqual(status.status, "success")

        // No idle timer was ever started while the shot counter runs.
        await client.drainBackgroundWorkForTesting()
        XCTAssertEqual(rig.sleeper.startedCount(.idleDisconnect), 0)
        let running = await client.peek { ($0.idleTask == nil, $0.hasBackgroundWorkForTesting, $0.isConnected) }
        XCTAssertTrue(running.0)
        XCTAssertFalse(running.1)
        XCTAssertTrue(running.2)

        // Stopping the shot counter resumes the idle disconnect.
        await client.stopShotCounter()
        let power = BluetoothCodec.machineChangeMode(on: true)
        XCTAssertEqual(link.recordedOps, connectOps + [.subscribe(shotCounter), .write(writeCharacteristic, power),
                                                       .read(writeCharacteristic), .unsubscribe(shotCounter)])
        guard await pending(rig.sleeper, .idleDisconnect) else { return }
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect), [.seconds(30)])
        rig.sleeper.fire(.idleDisconnect)
        guard await fulfilled([connection.expectation { $0.count >= 2 }], "idle disconnect") else { return }
        XCTAssertEqual(connection.elements, [.connected, .disconnected])
        XCTAssertEqual(link.recordedOps.filter { $0 == .disconnect }.count, 1)
        XCTAssertEqual(link.recordedOps.last, .disconnect)
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    /// Upstream: test_start_shot_counter_twice (tests/test_bluetooth_client.py:1108) [C36]
    func testStartTwiceSubscribesOnce() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let link = machine()  // the default replay tick consumes the replay flag
        rig.central.enqueueConnect(.success(link))

        let first = try await client.startShotCounter()
        let second = try await client.startShotCounter()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(rig.central.connectCount, 1)
        XCTAssertEqual(link.recordedOps, connectOps + [.subscribe(shotCounter)])

        // Notifications keep flowing to the stream; no second `.subscribed` precedes them.
        let at = start.addingTimeInterval(7)
        link.notify(shotCounter, BluetoothTestVectors.started, at: at)
        guard await fulfilled([events.expectation { $0.count >= 2 }], "brewing event") else { return }
        let brewing = BluetoothShotCounterUpdate(state: .brewing, timerValue: 0.0, startedDoseIndex: "DoseA",
                                                 receivedAt: at, raw: BluetoothBrewingData(startedDoseIndex: "DoseA"),
                                                 brewingStartTime: at)
        XCTAssertEqual(events.elements, [.subscribed, .brewing(brewing)])
        await client.disconnect()
        guard await fulfilled([events.expectation { $0.count >= 3 }], "sentinel") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .brewing(brewing), .unsubscribed])
    }

    /// Upstream: test_stop_shot_counter_reentrant (tests/test_bluetooth_client.py:1126) [C37, C38]
    func testStopFromEventConsumerIsNoOp() async throws {
        for useDisconnect in [false, true] {
            let context = useDisconnect ? "disconnect" : "stop_shot_counter"
            let rig = makeRig()
            let client = rig.client
            let link = machine()
            rig.central.enqueueConnect(.success(link))
            let stream = await client.shotCounterEvents()
            let log = Recorder<ConsumerEntry>()
            // Like Home Assistant: stop again from the event consumer whenever it sees `.unsubscribed`.
            let consumer = Task {
                for await event in stream {
                    log.record(.event(event))
                    if event == .unsubscribed {
                        if useDisconnect {
                            await client.disconnect()
                        } else {
                            await client.stopShotCounter()
                        }
                        log.record(.stopReturned)
                    }
                }
            }
            defer { consumer.cancel() }

            let started = try await client.startShotCounter()
            XCTAssertTrue(started, context)
            if useDisconnect {
                await client.disconnect()
            } else {
                await client.stopShotCounter()
            }
            guard await fulfilled([log.expectation { $0.contains(.stopReturned) }], "consumer stop, \(context)") else {
                return
            }
            let after = await client.peek { ($0.shotCounterActive, $0.shotCounterEnabled, $0.isConnected) }
            XCTAssertFalse(after.0, context)
            XCTAssertFalse(after.1, context)
            XCTAssertEqual(after.2, !useDisconnect, context)
            XCTAssertEqual(link.recordedOps.filter { $0 == .unsubscribe(shotCounter) }.count, 1, context)
            XCTAssertEqual(link.recordedOps.filter { $0 == .disconnect }.count, useDisconnect ? 1 : 0, context)

            // Sentinel: a restart. Any event the consumer's stop emitted would precede its `.subscribed`.
            let restarted = try await client.startShotCounter()
            XCTAssertTrue(restarted, context)
            guard await fulfilled([log.expectation { $0.count >= 4 }], "sentinel, \(context)") else { return }
            XCTAssertEqual(log.elements, [.event(.subscribed), .event(.unsubscribed), .stopReturned, .event(.subscribed)],
                           context)
            XCTAssertEqual(rig.central.connectCount, useDisconnect ? 2 : 1, context)
            consumer.cancel()
            await client.disconnect()
        }
    }

    /// Upstream: test_stop_shot_counter_notifies_connection_callback (tests/test_bluetooth_client.py:1183) [C40]
    func testDisconnectReportsUnsubscribed() async throws {
        let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let first = machine()
        let second = machine()
        let third = machine()
        rig.central.enqueueConnect(.success(first))
        rig.central.enqueueConnect(.success(second))
        rig.central.enqueueConnect(.success(third))

        let started = try await client.startShotCounter()
        XCTAssertTrue(started)
        guard await fulfilled([events.expectation { $0.count >= 1 }], ".subscribed") else { return }

        // A subscribed counter: disconnect() reports `.unsubscribed` once, after closing the link.
        await client.disconnect()
        XCTAssertEqual(first.recordedOps.suffix(2), [.unsubscribe(shotCounter), .disconnect])
        let restarted = try await client.startShotCounter()
        XCTAssertTrue(restarted)
        guard await fulfilled([events.expectation { $0.count >= 3 }], "sentinel restart") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])

        // Enabled but no longer subscribed (the link was lost, `.unsubscribed` already sent at loss
        // time, a reconnect is pending): disconnect() reports nothing more.
        second.drop(.disconnected(code: 7))
        guard await pending(rig.sleeper, .reconnectBackoff) else { return }
        guard await fulfilled([events.expectation { $0.count >= 4 }], "loss .unsubscribed") else { return }
        await client.disconnect()
        await client.drainBackgroundWorkForTesting()
        let stopped = await client.peek { ($0.shotCounterEnabled, $0.reconnectTask == nil) }
        XCTAssertFalse(stopped.0)
        XCTAssertTrue(stopped.1)
        XCTAssertEqual(second.recordedOps.filter { $0 == .unsubscribe(shotCounter) }.count, 0,
                       "nothing to unsubscribe on a lost link")

        // Sentinel: the third link's `.subscribed` directly follows the loss's `.unsubscribed`.
        let thirdStart = try await client.startShotCounter()
        XCTAssertTrue(thirdStart)
        guard await fulfilled([events.expectation { $0.count >= 5 }], "sentinel third start") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed, .unsubscribed, .subscribed])
        XCTAssertEqual(third.recordedOps, connectOps + [.subscribe(shotCounter)])
        XCTAssertEqual(rig.sleeper.startedCount(.reconnectBackoff), 1, "the cancelled loop never attempted")
        await client.disconnect()
    }

    /// Upstream: test_command_error_keeps_shot_counter_connection (tests/test_bluetooth_client.py:1287) [C48]
    func testCommandErrorKeepsShotCounterLink() async throws {
        let rig = makeRig()
        let client = rig.client
        let link = machine()
        rig.central.enqueueConnect(.success(link))
        let started = try await client.startShotCounter()
        XCTAssertTrue(started)
        link.onWrite = { characteristic, _ in
            if characteristic == BluetoothConstants.writeCharacteristic {
                throw BluetoothTransportError.gatt(domain: "CBATTErrorDomain", code: 14)
            }
        }
        let power = BluetoothCodec.machineChangeMode(on: true)

        await assertThrows(LaMarzoccoError.bluetoothConnectionFailed("GATT error CBATTErrorDomain 14")) {
            _ = try await client.setPower(on: true)
        }
        await client.drainBackgroundWorkForTesting()
        let kept = await client.peek {
            ($0.isConnected, $0.shotCounterActive, $0.backgroundTasks.isEmpty, $0.reconnectTask == nil, $0.idleTask == nil)
        }
        XCTAssertTrue(kept.0, "still connected")
        XCTAssertTrue(kept.1, "the shot counter still runs")
        XCTAssertTrue(kept.2, "no drop was scheduled")
        XCTAssertTrue(kept.3)
        XCTAssertTrue(kept.4)
        XCTAssertEqual(rig.central.connectCount, 1)
        XCTAssertEqual(link.recordedOps, connectOps + [.subscribe(shotCounter), .write(writeCharacteristic, power)])

        // Contrast: the same error is drop-class once the counter is stopped.
        await client.stopShotCounter()
        await assertThrows(LaMarzoccoError.bluetoothConnectionFailed("GATT error CBATTErrorDomain 14")) {
            _ = try await client.setPower(on: true)
        }
        await client.drainBackgroundWorkForTesting()
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        XCTAssertEqual(link.recordedOps, connectOps + [.subscribe(shotCounter), .write(writeCharacteristic, power),
                                                       .unsubscribe(shotCounter), .write(writeCharacteristic, power),
                                                       .disconnect])
    }

    // MARK: - Angstrom-only gap tests

    /// Angstrom-only: G-CONN-6 — a characteristic still missing after the rediscovery drops the link even while the shot counter runs, which starts the reconnect loop
    func testMissingCharacteristicDropsEvenWithShotCounter() async throws {
        let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        let first = machine(missing: writeCharacteristic)
        let second = machine()
        rig.central.enqueueConnect(.success(first))
        rig.central.enqueueConnect(.success(second))
        let started = try await client.startShotCounter()
        XCTAssertTrue(started)

        await assertThrows(LaMarzoccoError.bluetoothConnectionFailed(
            "Could not find characteristic 0b0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")) {
            _ = try await client.setPower(on: true)
        }
        // The drop runs in the background; the loss starts the reconnect loop, which sleeps first.
        guard await pending(rig.sleeper, .reconnectBackoff) else { return }
        XCTAssertEqual(first.recordedOps, connectOps + [.subscribe(shotCounter), .discover(refresh: true), .disconnect])
        let dropped = await client.peek { ($0.isConnected, $0.shotCounterEnabled, $0.reconnectTask != nil) }
        XCTAssertFalse(dropped.0, "dropped")
        XCTAssertTrue(dropped.1, "the counter stays enabled")
        XCTAssertTrue(dropped.2, "the reconnect loop runs")
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
        guard await fulfilled([events.expectation { $0.count >= 2 }], "loss .unsubscribed") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed])

        rig.sleeper.fire(.reconnectBackoff)
        await client.drainBackgroundWorkForTesting()
        XCTAssertEqual(rig.central.connectCount, 2)
        XCTAssertEqual(second.recordedOps, connectOps + [.subscribe(shotCounter)])
        let active = await client.shotCounterActive
        XCTAssertTrue(active)
        guard await fulfilled([events.expectation { $0.count >= 3 }], "resubscribed") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])
        guard await fulfilled([connection.expectation { $0.count >= 3 }], "connection events") else { return }
        XCTAssertEqual(connection.elements, [.connected, .disconnected, .connected])
        await client.disconnect()
    }

    /// Angstrom-only: G-SC-1 — stopShotCounter() with no counter running only re-arms the idle timer
    func testStopWithoutCounterOnlyRearmsIdle() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let connection = Recorder(await client.connectionEvents())
        let link = machine()
        rig.central.enqueueConnect(.success(link))
        _ = try await client.setPower(on: true)
        guard await pending(rig.sleeper, .idleDisconnect) else { return }
        let armedTask = await client.peek { $0.idleTask }
        let before = try XCTUnwrap(armedTask)

        await client.stopShotCounter()

        let rearmedTask = await client.peek { $0.idleTask }
        let after = try XCTUnwrap(rearmedTask, "an idle timer is armed")
        XCTAssertNotEqual(before, after, "a new idle timer")
        XCTAssertTrue(before.isCancelled, "the old idle timer was cancelled")
        await before.value
        // The cancelled timer has finished, so the one pending sleep is the re-armed timer's. (How many
        // idle sleeps the connect and the request started before it is racy: the request's same-link
        // reset may cancel the post-connect timer before that timer reaches its sleep.)
        guard await pending(rig.sleeper, .idleDisconnect) else { return }
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        XCTAssertEqual(rig.sleeper.requested(.idleDisconnect).last, .seconds(30))
        let power = BluetoothCodec.machineChangeMode(on: true)
        XCTAssertEqual(link.recordedOps, connectOps + [.write(writeCharacteristic, power), .read(writeCharacteristic)],
                       "no unsubscribe, no disconnect")
        let state = await client.peek { ($0.isConnected, $0.shotCounterEnabled, $0.shotCounterSubscribed) }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertFalse(state.2)

        // The re-armed timer works.
        rig.sleeper.fire(.idleDisconnect)
        guard await fulfilled([connection.expectation { $0.count >= 2 }], "idle disconnect") else { return }
        XCTAssertEqual(connection.elements, [.connected, .disconnected])
        XCTAssertEqual(link.recordedOps.last, .disconnect)

        // Sentinel: the stop reported nothing.
        let started = try await client.startShotCounter()
        XCTAssertTrue(started)
        guard await fulfilled([events.expectation { $0.count >= 1 }], "sentinel .subscribed") else { return }
        XCTAssertEqual(events.elements, [.subscribed])
        await client.disconnect()
    }

    /// Angstrom-only: G-SC-4 — a notification after stopShotCounter() is silently dropped
    func testNotificationAfterStopDropped() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let raw = Recorder(await client.rawFrames())
        let link = machine()
        link.replayOnSubscribe = []
        rig.central.enqueueConnect(.success(link))
        let started = try await client.startShotCounter()
        XCTAssertTrue(started)
        // Consume the replay flag first, so the notifications below reach the event gate.
        link.notify(shotCounter, replay, at: start)
        guard await fulfilled([raw.expectation { $0.contains { Self.isMarker($0, RawBluetoothFrame.replayDroppedMarker) } }],
                              "replay dropped") else { return }

        await client.stopShotCounter()
        // Both would produce an event while enabled (a `.brewing` and a `.telemetry`).
        link.notify(shotCounter, BluetoothTestVectors.started, at: start.addingTimeInterval(1))
        link.notify(shotCounter, coffeeTemperature, at: start.addingTimeInterval(2))
        guard await fulfilled([raw.expectation { $0.filter { $0.kind == .notification }.count >= 3 }],
                              "late notifications handled") else { return }
        let state = await client.peek { ($0.isConnected, $0.shotCounterEnabled, $0.replayPending) }
        XCTAssertTrue(state.0, "the link stays up after a stop")
        XCTAssertFalse(state.1)
        XCTAssertFalse(state.2, "the late notifications were not swallowed as a replay")

        // Sentinel: a restart on the same link.
        let restarted = try await client.startShotCounter()
        XCTAssertTrue(restarted)
        guard await fulfilled([events.expectation { $0.count >= 3 }], "sentinel .subscribed") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed])
        await client.disconnect()
    }

    /// Angstrom-only: G-SC-5 — a second start while subscribed does not resubscribe, emit `.subscribed`, reset the tracker or touch the replay flag
    func testSecondStartKeepsTrackerAndReplayFlag() async throws {
        let rig = makeRig()
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let raw = Recorder(await client.rawFrames())
        let link = machine()
        link.replayOnSubscribe = []  // the replay flag stays armed after the subscribe
        rig.central.enqueueConnect(.success(link))

        let first = try await client.startShotCounter()
        XCTAssertTrue(first)
        let armed = await client.peek { $0.replayPending }
        XCTAssertTrue(armed)

        // A second start while armed does not clear the flag: the next notification is still dropped.
        let second = try await client.startShotCounter()
        XCTAssertTrue(second)
        let stillArmed = await client.peek { $0.replayPending }
        XCTAssertTrue(stillArmed)
        link.notify(shotCounter, replay, at: start)
        // A brewing fragment matching no rule: the tracker keeps it.
        link.notify(shotCounter, Data(#"{"BrewingUpdateGroup1Time":5.0}"#.utf8), at: start.addingTimeInterval(1))
        guard await fulfilled([raw.expectation { $0.filter { $0.kind == .notification }.count >= 2 }],
                              "replay and fragment handled") else { return }
        let rawText = raw.elements.map(Self.describe)
        XCTAssertEqual(rawText.filter { $0 == RawBluetoothFrame.replayDroppedMarker }.count, 1)

        // A third start while the flag is clear does not re-arm it, and keeps the tracker's fragment.
        let third = try await client.startShotCounter()
        XCTAssertTrue(third)
        let cleared = await client.peek { $0.replayPending }
        XCTAssertFalse(cleared)
        XCTAssertEqual(link.recordedOps, connectOps + [.subscribe(shotCounter)])

        // With the kept fragment, `ev: true` completes a `.brewing` update (a fresh tracker derives none).
        let at = start.addingTimeInterval(8)
        link.notify(shotCounter, Data(#"{"BrewingUpdateGroup1Ev":true}"#.utf8), at: at)
        guard await fulfilled([events.expectation { $0.count >= 2 }], "brewing from the kept fragment") else { return }
        let update = BluetoothShotCounterUpdate(state: .brewing, timerValue: 5.0, receivedAt: at,
                                                raw: BluetoothBrewingData(ev: true, brewingTime: 5.0),
                                                brewingStartTime: at.addingTimeInterval(-5))
        XCTAssertEqual(events.elements, [.subscribed, .brewing(update)])
        await client.disconnect()
        guard await fulfilled([events.expectation { $0.count >= 3 }], "sentinel") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .brewing(update), .unsubscribed])
    }

    /// Angstrom-only: G-SC-6 — startShotCounter() while a reconnect is pending serialises with the loop on the connection gate; one subscribe
    func testStartWhileReconnectPendingSubscribesOnce() async throws {
        let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
        let client = rig.client
        let events = Recorder(await client.shotCounterEvents())
        let first = machine()
        let second = machine()
        let loopConnecting = XCTestExpectation(description: "the reconnect loop holds the connection gate in discovery")
        loopConnecting.assertForOverFulfill = false
        let releaseDiscovery = Latch()
        defer { releaseDiscovery.open() }
        second.beforeOp = { op in
            guard case .discover = op else { return }
            loopConnecting.fulfill()
            await releaseDiscovery.wait()
        }
        rig.central.enqueueConnect(.success(first))
        rig.central.enqueueConnect(.success(second))
        let started = try await client.startShotCounter()
        XCTAssertTrue(started)

        // Link loss: `.unsubscribed`, then the reconnect loop sleeps.
        first.drop(.disconnected(code: 7))
        guard await pending(rig.sleeper, .reconnectBackoff) else { return }
        guard await fulfilled([events.expectation { $0.count >= 2 }], "loss .unsubscribed") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed])

        // The loop connects (holding the connection gate) while a start queues behind it.
        rig.sleeper.fire(.reconnectBackoff)
        guard await fulfilled([loopConnecting], "loop connecting") else { return }
        let queued = XCTestExpectation(description: "start queued on the connection gate")
        let starting = Task { try await client.startShotCounterSignalling { queued.fulfill() } }
        guard await fulfilled([queued], "start queued") else {
            starting.cancel()
            return
        }
        releaseDiscovery.open()
        let restarted = try await starting.value
        XCTAssertTrue(restarted)
        await client.drainBackgroundWorkForTesting()

        XCTAssertEqual(rig.central.connectCount, 2)
        XCTAssertEqual(first.recordedOps, connectOps + [.subscribe(shotCounter)])
        XCTAssertEqual(second.recordedOps, connectOps + [.subscribe(shotCounter)], "one connect, one subscribe")
        XCTAssertEqual(rig.sleeper.requested(.reconnectBackoff), [.seconds(1)])
        let state = await client.peek { ($0.shotCounterActive, $0.link === second, $0.reconnectTask == nil) }
        XCTAssertTrue(state.0)
        XCTAssertTrue(state.1)
        XCTAssertTrue(state.2, "the loop finished")

        // Sentinel: exactly one new `.subscribed`.
        await client.disconnect()
        guard await fulfilled([events.expectation { $0.count >= 4 }], "sentinel") else { return }
        XCTAssertEqual(events.elements, [.subscribed, .unsubscribed, .subscribed, .unsubscribed])
    }

    /// Angstrom-only: G-RC-4 — startShotCounter() throws when the first connect or auth fails, disables the counter and starts no loop
    func testStartFailureThrowsAndDisables() async throws {
        for authFails in [false, true] {
            let context = authFails ? "auth failure" : "Bluetooth powered off"
            let rig = makeRig(manual: [.idleDisconnect, .reconnectBackoff])
            let client = rig.client
            let events = Recorder(await client.shotCounterEvents())
            let rejecting = FakeBluetoothLink.laMarzocco(token: "other")
            let expected: LaMarzoccoError
            if authFails {
                rig.central.enqueueConnect(.success(rejecting))
                expected = .bluetoothAuthenticationFailed
            } else {
                rig.central.setAvailability(.poweredOff)
                expected = .bluetoothUnavailable(.poweredOff)
            }

            await assertThrows(expected, context) {
                _ = try await client.startShotCounter()
            }
            let state = await client.peek {
                ($0.shotCounterEnabled, $0.reconnectTask == nil, $0.hasBackgroundWorkForTesting, $0.isConnected,
                 $0.authenticationFailed)
            }
            XCTAssertFalse(state.0, context)
            XCTAssertTrue(state.1, context)
            XCTAssertFalse(state.2, context)
            XCTAssertFalse(state.3, context)
            XCTAssertEqual(state.4, authFails, context)
            XCTAssertEqual(rig.central.connectCount, authFails ? 1 : 0, context)
            XCTAssertEqual(rig.sleeper.startedCount(.reconnectBackoff), 0, context)
            if authFails {
                XCTAssertEqual(rejecting.recordedOps.last, .disconnect, context)
            }

            // Sentinel: a working start reports the first event.
            rig.central.setAvailability(.poweredOn)
            let started = try await client.startShotCounter()
            XCTAssertTrue(started, context)
            guard await fulfilled([events.expectation { $0.count >= 1 }], "sentinel, \(context)") else { return }
            XCTAssertEqual(events.elements, [.subscribed], context)
            await client.disconnect()
        }
    }

    // MARK: - Helpers

    private struct Rig {
        let central: FakeBluetoothCentral
        let sleeper: ManualBluetoothSleeper
        let client: LaMarzoccoBluetoothClient
    }

    private enum ConsumerEntry: Equatable, Sendable {
        case event(ShotCounterEvent)
        case stopReturned
    }

    private var allCharacteristics: Set<GATTUUID> {
        BluetoothConstants.sessionCharacteristics.union([BluetoothConstants.tokenCharacteristic])
    }

    private func makeRig(manual: Set<SleepPurpose> = [.idleDisconnect]) -> Rig {
        let central = FakeBluetoothCentral()
        let sleeper = ManualBluetoothSleeper(manual: manual)
        let clock = BluetoothTestClock(start)
        let client = LaMarzoccoBluetoothClient(transport: .fake(central, sleeper: sleeper, clock: clock),
                                               peripheral: .fake, token: BluetoothAuthToken("token"))
        return Rig(central: central, sleeper: sleeper, client: client)
    }

    /// A machine accepting "token"; `missing` is absent from cached discovery, `afterRefresh` (if set) is
    /// what a `refresh: true` discovery reports.
    private func machine(missing: GATTUUID? = nil, afterRefresh: Set<GATTUUID>? = nil) -> FakeBluetoothLink {
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        if let missing {
            link.present = allCharacteristics.subtracting([missing])
        }
        link.presentAfterRefresh = afterRefresh
        return link
    }

    /// Awaits `body` throwing exactly `expected`.
    private func assertThrows(_ expected: LaMarzoccoError, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected) to be thrown. \(message)", file: file, line: line)
        } catch let error as LaMarzoccoError {
            XCTAssertEqual(error, expected, message, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error). \(message)", file: file, line: line)
        }
    }

    /// Waits (bounded) until `count` sleeps of `purpose` are pending.
    private func pending(_ sleeper: ManualBluetoothSleeper, _ purpose: SleepPurpose, count: Int = 1,
                         file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let reached = XCTestExpectation(description: "\(count) pending \(purpose) sleep(s)")
        let waiter = Task {
            await sleeper.waitForPending(purpose, count: count)
            reached.fulfill()
        }
        defer { waiter.cancel() }
        return await fulfilled([reached], "waiting for \(count) pending \(purpose) sleep(s)", file: file, line: line)
    }

    /// `fulfillment(of:timeout:)` that reports whether everything was fulfilled, so a test can stop
    /// instead of hanging in a later unbounded wait.
    private func fulfilled(_ expectations: [XCTestExpectation], _ message: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let result = await XCTWaiter().fulfillment(of: expectations, timeout: timeout)
        guard result == .completed else {
            XCTFail("\(message): \(result)", file: file, line: line)
            return false
        }
        return true
    }

    private static func isMarker(_ frame: RawBluetoothFrame, _ marker: String) -> Bool {
        frame.kind == .event && String(decoding: frame.data, as: UTF8.self) == marker
    }

    /// A raw frame as text: the marker for `.event`, else `<kind> <characteristic> <UTF-8 data>`.
    private static func describe(_ frame: RawBluetoothFrame) -> String {
        let text = String(decoding: frame.data, as: UTF8.self)
        guard frame.kind != .event else { return text }
        return "\(frame.kind) \(frame.characteristic ?? "-") \(text)"
    }
}

// MARK: - Private test doubles

/// Records elements (from a stream, or appended by hand); expectations fire once a predicate over
/// everything recorded so far holds (immediately, if it already does). No polling.
private final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    private var waiters: [(predicate: ([Element]) -> Bool, expectation: XCTestExpectation)] = []
    private var reader: Task<Void, Never>?

    init() {}

    init(_ stream: AsyncStream<Element>) {
        reader = Task { [self] in
            for await element in stream {
                record(element)
            }
        }
    }

    deinit { reader?.cancel() }

    var elements: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func expectation(where predicate: @escaping ([Element]) -> Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "recorded elements")
        lock.lock()
        let satisfied = predicate(items)
        if !satisfied {
            waiters.append((predicate, expectation))
        }
        lock.unlock()
        if satisfied { expectation.fulfill() }
        return expectation
    }

    func record(_ element: Element) {
        lock.lock()
        items.append(element)
        let snapshot = items
        var ready: [XCTestExpectation] = []
        waiters.removeAll { waiter in
            guard waiter.predicate(snapshot) else { return false }
            ready.append(waiter.expectation)
            return true
        }
        lock.unlock()
        for expectation in ready { expectation.fulfill() }
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

extension LaMarzoccoBluetoothClient {
    /// Runs `body` on the actor: read internal state from a test.
    fileprivate func peek<T: Sendable>(_ body: @Sendable (isolated LaMarzoccoBluetoothClient) -> T) -> T {
        body(self)
    }

    /// Calls `entered` on the actor, then `startShotCounter()`, whose first suspension is its
    /// connection-gate wait: once `entered` has run, nothing else reaches the gate before it.
    fileprivate func startShotCounterSignalling(_ entered: @Sendable () -> Void) async throws -> Bool {
        entered()
        return try await startShotCounter()
    }
}
