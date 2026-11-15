import XCTest
@testable import Angstrom
import AngstromTestSupport

/// The raw diagnostics tap, `LaMarzoccoBluetoothClient.rawFrames()` / `rawRead(_:)` (SPEC §5.7, §6.10):
/// verbatim and directional frames, `isSecret` only on the auth write, notifications tapped before the
/// replay drop, lifecycle markers in order, no buffering for late listeners, multiplexing.
final class BluetoothDiagnosticsTests: XCTestCase {
    // Duplicates of the library's UUIDs on purpose, to pin the machine's protocol (TBC:40-44).
    private let settingsChar = GATTUUID("0b0b7847-e12b-09a8-b04b-8e0922a9abab")
    private let authChar = GATTUUID("0d0b7847-e12b-09a8-b04b-8e0922a9abab")
    private let readChar = GATTUUID("0a0b7847-e12b-09a8-b04b-8e0922a9abab")
    private let shotCounterChar = GATTUUID("0e0b7847-e12b-09a8-b04b-8e0922a9abab")
    private let settingsUUID = "0b0b7847-e12b-09a8-b04b-8e0922a9abab"
    private let authUUID = "0d0b7847-e12b-09a8-b04b-8e0922a9abab"
    private let readUUID = "0a0b7847-e12b-09a8-b04b-8e0922a9abab"
    private let shotCounterUUID = "0e0b7847-e12b-09a8-b04b-8e0922a9abab"

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let powerOn = Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]
    private let success = Data(#"{"id":"test-id","message":"Success","status":"success"}"#.utf8)
    /// `REPLAY` (`tests/test_bluetooth_client.py:811`).
    private let replay = Data(#"{"MachineMode":"StandBy"}"#.utf8)

    /// Angstrom-only: §5.7 — only the auth write carries isSecret (verbatim token bytes); every write, read, notification and marker of a full session is not secret
    func testAuthWriteIsSecretOthersNot() async throws {
        let link = FakeBluetoothLink.laMarzocco(token: "s3cr3t-token", confirmOnRead: 3,
                                                settingResponses: [.machineMode: Data(#""StandBy""#.utf8)])
        link.mtu = 185
        link.replayOnSubscribe = []
        let rig = makeRig(link, token: "s3cr3t-token")
        let raw = Recorder(await rig.client.rawFrames())

        _ = try await rig.client.setPower(on: true)
        _ = try await rig.client.machineMode()
        let started = try await rig.client.startShotCounter()
        XCTAssertTrue(started)
        // Taken as the replay (none was delivered on subscribe), so it is followed by [replay dropped].
        link.notify(shotCounterChar, Data(#"{"CoffeeBoiler1UpdateTemperature":95}"#.utf8), at: t0)
        await fulfillment(of: [raw.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.replayDroppedMarker)) }],
                          timeout: 5)
        await rig.client.disconnect()
        await fulfillment(of: [raw.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.disconnectedMarker)) }],
                          timeout: 5)

        let frames = raw.elements
        let secret = frames.filter(\.isSecret)
        XCTAssertEqual(secret, [RawBluetoothFrame(timestamp: t0, direction: .outbound, kind: .write,
                                                  characteristic: authUUID, data: Data("s3cr3t-token".utf8),
                                                  isSecret: true)],
                       "exactly one secret frame: the auth write, verbatim")
        let others = frames.filter { !$0.isSecret }
        XCTAssertEqual(others.count, frames.count - 1)
        // Non-vacuous: the session produced every kind of frame, including all three auth reads.
        XCTAssertEqual(others.filter { $0.kind == .read && $0.characteristic == authUUID }.map(\.data),
                       [Data([0x00]), Data([0x00]), Data([0x01])])
        XCTAssertTrue(others.contains { $0.kind == .write && $0.characteristic == settingsUUID })
        XCTAssertTrue(others.contains { $0.kind == .read && $0.characteristic == readUUID })
        XCTAssertTrue(others.contains { $0.kind == .notification })
        XCTAssertEqual(Set(others.filter { $0.kind == .event }.map { String(decoding: $0.data, as: UTF8.self) }), [
            "[connecting]", "[connected]", "[mtu 185]", "[authenticated]", "[subscribed]", "[replay dropped]",
            "[unsubscribed]", "[disconnected]",
        ])
    }

    /// Angstrom-only: §5.7 — writes are outbound and reads/notifications/markers inbound, each with its lowercase characteristic, verbatim bytes and the transport clock's timestamp
    func testFramesVerbatimAndDirectional() async throws {
        let commandReply = success + [0x00, 0x00] + Data("tail".utf8)
        let modeReply = Data(#""BrewingMode""#.utf8) + [0x00, 0xFF] + Data("junk".utf8)
        let link = FakeBluetoothLink.laMarzocco(token: "token", commandResponse: commandReply,
                                                settingResponses: [.machineMode: modeReply])
        link.replayOnSubscribe = []
        let clock = BluetoothTestClock(t0)
        let rig = makeRig(link, clock: clock)
        let raw = Recorder(await rig.client.rawFrames())

        let status = try await rig.client.setPower(on: true)
        XCTAssertTrue(status.isSuccess)
        let t1 = t0.addingTimeInterval(1.5)
        clock.set(t1)
        let mode = try await rig.client.machineMode()
        XCTAssertEqual(mode, .brewing)
        let t2 = t0.addingTimeInterval(7)
        clock.set(t2)
        _ = try await rig.client.startShotCounter()
        // A notification with NULs at both ends: the tap keeps them (the parser strips them, §3.8).
        let notification = Data([0x00]) + Data(#"{"SteamBoilerUpdateTemperature":127}"#.utf8) + [0x00, 0x00]
        link.notify(shotCounterChar, notification, at: t2)
        await fulfillment(of: [raw.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.replayDroppedMarker)) }],
                          timeout: 5)
        await rig.client.disconnect()
        await fulfillment(of: [raw.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.disconnectedMarker)) }],
                          timeout: 5)

        func frame(_ at: Date, _ direction: RawBluetoothFrame.Direction, _ kind: RawBluetoothFrame.Kind,
                   _ characteristic: String?, _ data: Data, secret: Bool = false) -> RawBluetoothFrame {
            RawBluetoothFrame(timestamp: at, direction: direction, kind: kind, characteristic: characteristic,
                              data: data, isSecret: secret)
        }
        func marker(_ at: Date, _ text: String) -> RawBluetoothFrame {
            frame(at, .inbound, .event, nil, Data(text.utf8))
        }
        XCTAssertEqual(raw.elements, [
            marker(t0, "[connecting]"),
            marker(t0, "[connected]"),
            frame(t0, .outbound, .write, authUUID, Data("token".utf8), secret: true),
            frame(t0, .inbound, .read, authUUID, Data([0x01])),
            marker(t0, "[authenticated]"),
            frame(t0, .outbound, .write, settingsUUID, powerOn),
            frame(t0, .inbound, .read, settingsUUID, commandReply),           // verbatim, NULs and tail kept
            frame(t1, .outbound, .write, readUUID, Data("machineMode".utf8) + [0x00]),
            frame(t1, .inbound, .read, readUUID, modeReply),                 // verbatim, invalid UTF-8 tail kept
            marker(t2, "[subscribed]"),
            frame(t2, .inbound, .notification, shotCounterUUID, notification),
            marker(t2, "[replay dropped]"),   // no replay arrived, so this first notification is taken as it
            marker(t2, "[unsubscribed]"),
            marker(t2, "[disconnected]"),
        ])
    }

    /// Angstrom-only: §5.7 — a shot-counter notification is tapped verbatim BEFORE the replay check: the replay frame is followed by [replay dropped], later ones are not
    func testNotificationTappedBeforeReplayDrop() async throws {
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.replayOnSubscribe = [replay]
        let rig = makeRig(link)
        let raw = Recorder(await rig.client.rawFrames())
        let events = Recorder(await rig.client.shotCounterEvents())

        let started = try await rig.client.startShotCounter()
        XCTAssertTrue(started)
        await fulfillment(of: [raw.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.replayDroppedMarker)) }],
                          timeout: 5)
        let replayFrames = raw.elements
        let dropIndex = try XCTUnwrap(replayFrames.firstIndex(where: Self.isMarker(RawBluetoothFrame.replayDroppedMarker)))
        XCTAssertGreaterThan(dropIndex, 0)
        XCTAssertEqual(replayFrames[dropIndex - 1],
                       RawBluetoothFrame(timestamp: t0, direction: .inbound, kind: .notification,
                                         characteristic: shotCounterUUID, data: replay, isSecret: false),
                       "the replay itself is tapped, immediately before the drop marker")

        // The same payload again is a live notification: tapped, not dropped, and dispatched.
        link.notify(shotCounterChar, replay, at: t0)
        // An unparseable one is still tapped verbatim (the parser drops it later).
        link.notify(shotCounterChar, Data("not json".utf8), at: t0)
        let coffee = Data(#"{"CoffeeBoiler1UpdateTemperature":95}"#.utf8)
        link.notify(shotCounterChar, coffee, at: t0)
        await fulfillment(of: [events.expectation { $0.count == 3 }], timeout: 5)
        XCTAssertEqual(events.elements, [
            .subscribed,
            .telemetry(BluetoothMachineTelemetry(machineMode: .standby)),
            .telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 95)),
        ], "the replay emitted nothing; the identical second notification did")

        await rig.client.disconnect()
        await fulfillment(of: [raw.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.disconnectedMarker)) }],
                          timeout: 5)
        // [subscribed] is emitted on the subscribe path, the replay on the link-event path: their relative
        // order is not fixed, so [subscribed] is checked on its own.
        XCTAssertEqual(raw.elements.filter(Self.isMarker(RawBluetoothFrame.subscribedMarker)).count, 1)
        let tail = raw.elements.dropFirst(dropIndex + 1).filter { !Self.isMarker(RawBluetoothFrame.subscribedMarker)($0) }
        XCTAssertEqual(tail.map(Self.describe), [
            "notification \(shotCounterUUID) {\"MachineMode\":\"StandBy\"}",
            "notification \(shotCounterUUID) not json",
            "notification \(shotCounterUUID) {\"CoffeeBoiler1UpdateTemperature\":95}",
            "[unsubscribed]",
            "[disconnected]",
        ])
        XCTAssertEqual(raw.elements.filter(Self.isMarker(RawBluetoothFrame.replayDroppedMarker)).count, 1)
        XCTAssertTrue(raw.elements.filter { $0.kind == .notification }.allSatisfy { $0.direction == .inbound && !$0.isSecret })
    }

    /// Angstrom-only: §6.10 — lifecycle markers in order: connecting, connected, mtu, authenticated, subscribed, services invalidated, unsubscribed, disconnected; a link loss and a reconnect repeat them
    func testLifecycleMarkerOrder() async throws {
        let first = FakeBluetoothLink.laMarzocco(token: "token")
        first.mtu = 185
        first.replayOnSubscribe = []
        let second = FakeBluetoothLink.laMarzocco(token: "token")  // mtu unknown: no [mtu] marker
        let central = FakeBluetoothCentral()
        central.enqueueConnect(.success(first))
        central.enqueueConnect(.success(second))
        let rig = makeRig(central: central)
        let raw = Recorder(await rig.client.rawFrames())

        _ = try await rig.client.setPower(on: true)
        _ = try await rig.client.startShotCounter()
        first.invalidateServices()
        await fulfillment(of: [raw.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.servicesInvalidatedMarker)) }],
                          timeout: 5)
        await rig.client.stopShotCounter()
        await rig.client.disconnect()
        // A request after a user disconnect reconnects on a new link; then the peripheral drops.
        _ = try await rig.client.tankStatus()
        second.drop(.disconnected(code: 7))
        await fulfillment(of: [raw.expectation { $0.filter(Self.isMarker(RawBluetoothFrame.disconnectedMarker)).count == 2 }],
                          timeout: 5)
        await rig.client.disconnect()  // already down: no further marker

        XCTAssertEqual(raw.elements.map(Self.describe), [
            "[connecting]",
            "[connected]",
            "[mtu 185]",
            "write \(authUUID) token",
            "read \(authUUID) \u{01}",
            "[authenticated]",
            "write \(settingsUUID) {\"name\":\"MachineChangeMode\",\"parameter\":{\"mode\":\"BrewingMode\"}}\u{00}",
            "read \(settingsUUID) {\"id\":\"test-id\",\"message\":\"Success\",\"status\":\"success\"}",
            "[subscribed]",
            "[services invalidated]",
            "[unsubscribed]",
            "[disconnected]",
            "[connecting]",
            "[connected]",
            "write \(authUUID) token",
            "read \(authUUID) \u{01}",
            "[authenticated]",
            "write \(readUUID) tankStatus\u{00}",
            "read \(readUUID) []",
            "[disconnected]",
        ])
        XCTAssertTrue(raw.elements.filter { $0.kind == .event }.allSatisfy {
            $0.direction == .inbound && $0.characteristic == nil && !$0.isSecret
        })
        XCTAssertEqual(RawBluetoothFrame.mtuMarker(185), "[mtu 185]")
    }

    /// Angstrom-only: §5.7 — nothing is buffered without listeners: a listener registered later sees only frames emitted after it registered
    func testNoBufferingWithoutListeners() async throws {
        let link = FakeBluetoothLink.laMarzocco(token: "token", settingResponses: [.isPlumbedIn: Data("true".utf8)])
        link.mtu = 185
        link.replayOnSubscribe = [replay]
        let rig = makeRig(link)
        let noListeners = await rig.client.peek { $0.rawFrameListeners.isEmpty }
        XCTAssertTrue(noListeners)

        // A whole connect + command + shot-counter start (with its replay) while nobody listens.
        _ = try await rig.client.setPower(on: true)
        let events = Recorder(await rig.client.shotCounterEvents())
        _ = try await rig.client.startShotCounter()
        link.notify(shotCounterChar, Data(#"{"CoffeeBoiler1UpdateTemperature":91}"#.utf8), at: t0)
        // The live notification was handled (so the replay before it was too) before anyone listens.
        await fulfillment(of: [events.expectation { $0.contains(.telemetry(BluetoothMachineTelemetry(coffeeBoilerTemperature: 91))) }],
                          timeout: 5)

        let raw = Recorder(await rig.client.rawFrames())
        let plumbed = try await rig.client.isPlumbedIn()
        XCTAssertTrue(plumbed)
        await rig.client.disconnect()
        await fulfillment(of: [raw.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.disconnectedMarker)) }],
                          timeout: 5)

        XCTAssertEqual(raw.elements.map(Self.describe), [
            "write \(readUUID) isPlumbedIn\u{00}",
            "read \(readUUID) true",
            "[unsubscribed]",
            "[disconnected]",
        ], "no earlier frame (connect markers, auth, command, replay, notification) was buffered")
    }

    /// Angstrom-only: §5.7 — the tap is multiplexed: two listeners each receive every frame, identically and in order
    func testTwoListenersBothReceive() async throws {
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        link.replayOnSubscribe = [replay]
        let rig = makeRig(link)
        let a = Recorder(await rig.client.rawFrames())
        let b = Recorder(await rig.client.rawFrames())

        _ = try await rig.client.setSteam(on: true)
        _ = try await rig.client.startShotCounter()
        await fulfillment(of: [a.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.replayDroppedMarker)) },
                               b.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.replayDroppedMarker)) }],
                          timeout: 5)
        await rig.client.disconnect()
        let done: (([RawBluetoothFrame]) -> Bool) = { $0.contains(where: Self.isMarker(RawBluetoothFrame.disconnectedMarker)) }
        await fulfillment(of: [a.expectation(where: done), b.expectation(where: done)], timeout: 5)

        XCTAssertEqual(a.elements, b.elements)
        let described = a.elements.map(Self.describe)
        // [subscribed] and the replay are delivered on different paths, so their relative order is
        // not fixed; everything else is.
        XCTAssertEqual(Array(described.prefix(7)), [
            "[connecting]",
            "[connected]",
            "write \(authUUID) token",
            "read \(authUUID) \u{01}",
            "[authenticated]",
            "write \(settingsUUID) {\"name\":\"SettingBoilerEnable\",\"parameter\":{\"identifier\":\"SteamBoiler\",\"state\":true}}\u{00}",
            "read \(settingsUUID) {\"id\":\"test-id\",\"message\":\"Success\",\"status\":\"success\"}",
        ])
        XCTAssertEqual(Set(described.dropFirst(7).dropLast(2)), [
            "[subscribed]", "notification \(shotCounterUUID) {\"MachineMode\":\"StandBy\"}", "[replay dropped]",
        ])
        XCTAssertEqual(described.count, 12)
        XCTAssertEqual(Array(described.suffix(2)), ["[unsubscribed]", "[disconnected]"])
    }

    /// Angstrom-only: §6.11 — rawRead returns the verbatim response bytes before NUL truncation (and before any UTF-8 or JSON decoding)
    func testRawReadBeforeNulTruncation() async throws {
        let mode = Data(#""BrewingMode""#.utf8) + [0x00, 0x00] + Data("garbage".utf8)
        let invalid = Data([0xFF, 0xFE]) + [0x00] + Data("x".utf8)
        let link = FakeBluetoothLink.laMarzocco(token: "token", settingResponses: [.machineMode: mode, .tankStatus: invalid])
        let rig = makeRig(link)
        let raw = Recorder(await rig.client.rawFrames())

        let rawMode = try await rig.client.rawRead(.machineMode)
        XCTAssertEqual(rawMode, mode, "verbatim: both NULs and the garbage after them are kept")
        let decoded = try await rig.client.machineMode()
        XCTAssertEqual(decoded, .brewing, "the typed read cuts the same bytes at the first NUL")

        // rawRead never decodes: bytes the typed read rejects are returned as they are.
        let rawTank = try await rig.client.rawRead(.tankStatus)
        XCTAssertEqual(rawTank, invalid)
        do {
            _ = try await rig.client.tankStatus()
            XCTFail("expected .decoding")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .decoding("bluetooth tankStatus: invalid UTF-8"))
        }

        // Each rawRead is one ordinary read request: `<setting>\0` to 0a0b…, then a read of 0a0b….
        XCTAssertEqual(link.recordedOps, [
            .discover(refresh: false), .write(authChar, Data("token".utf8)), .read(authChar),
            .write(readChar, Data("machineMode".utf8) + [0x00]), .read(readChar),
            .write(readChar, Data("machineMode".utf8) + [0x00]), .read(readChar),
            .write(readChar, Data("tankStatus".utf8) + [0x00]), .read(readChar),
            .write(readChar, Data("tankStatus".utf8) + [0x00]), .read(readChar),
        ])
        // The tap shows the same verbatim bytes for every read.
        await rig.client.disconnect()
        await fulfillment(of: [raw.expectation { $0.contains(where: Self.isMarker(RawBluetoothFrame.disconnectedMarker)) }],
                          timeout: 5)
        XCTAssertEqual(raw.elements.filter { $0.kind == .read && $0.characteristic == readUUID }.map(\.data),
                       [mode, mode, invalid, invalid])
    }

    // MARK: - Helpers

    private struct Rig {
        let central: FakeBluetoothCentral
        let sleeper: ManualBluetoothSleeper
        let client: LaMarzoccoBluetoothClient
    }

    /// A client whose first connect returns `link`; every frame and notification is stamped by `clock`.
    private func makeRig(_ link: FakeBluetoothLink, token: String = "token", clock: BluetoothTestClock? = nil) -> Rig {
        let central = FakeBluetoothCentral()
        central.enqueueConnect(.success(link))
        return makeRig(central: central, token: token, clock: clock)
    }

    private func makeRig(central: FakeBluetoothCentral, token: String = "token", clock: BluetoothTestClock? = nil) -> Rig {
        let sleeper = ManualBluetoothSleeper()
        let client = LaMarzoccoBluetoothClient(
            transport: .fake(central, sleeper: sleeper, clock: clock ?? BluetoothTestClock(t0)),
            peripheral: .fake, token: BluetoothAuthToken(token))
        return Rig(central: central, sleeper: sleeper, client: client)
    }

    /// Matches the `.event` frame carrying `marker`.
    private static func isMarker(_ marker: String) -> (RawBluetoothFrame) -> Bool {
        { $0.kind == .event && $0.data == Data(marker.utf8) }
    }

    /// A raw frame as text: the marker for `.event`, else `<kind> <characteristic> <UTF-8 data>`.
    private static func describe(_ frame: RawBluetoothFrame) -> String {
        let text = String(decoding: frame.data, as: UTF8.self)
        guard frame.kind != .event else { return text }
        return "\(frame.kind) \(frame.characteristic ?? "-") \(text)"
    }
}

// MARK: - Private test doubles

/// Records every element of a stream from creation on; expectations fire once a predicate over
/// everything recorded so far holds (immediately, if it already does). No polling.
private final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    private var waiters: [(predicate: ([Element]) -> Bool, expectation: XCTestExpectation)] = []
    private var reader: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        reader = Task { [self] in
            for await element in stream {
                append(element)
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

    private func append(_ element: Element) {
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

extension LaMarzoccoBluetoothClient {
    /// Runs `body` on the actor: read internal state from a test.
    fileprivate func peek<T: Sendable>(_ body: @Sendable (isolated LaMarzoccoBluetoothClient) -> T) -> T {
        body(self)
    }
}
