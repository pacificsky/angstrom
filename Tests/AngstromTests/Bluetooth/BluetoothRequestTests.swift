import XCTest
@testable import Angstrom
import AngstromTestSupport

/// Parity suite for the request path (SPEC §3.5–§3.7, §3.10, §4.4; vectors §9.3.1/§9.3.2): the
/// upstream read/command tests C01–C08 and C42–C46 (`tests/test_bluetooth_client.py:295-430`,
/// `1223-1250`), plus the Angstrom-only gap tests. Every test asserts the exact bytes written, the
/// characteristic used (writes are always "with response"), and the decoded value.
final class BluetoothRequestTests: XCTestCase {
    // Duplicates of the library's UUIDs on purpose, to pin the machine's protocol (TBC:40-44).
    private let settingsChar = GATTUUID("0b0b7847-e12b-09a8-b04b-8e0922a9abab")
    private let authChar = GATTUUID("0d0b7847-e12b-09a8-b04b-8e0922a9abab")
    private let readChar = GATTUUID("0a0b7847-e12b-09a8-b04b-8e0922a9abab")

    /// `COMMAND_SUCCESS` decoded (BT-RSP-CMD-001, `TBC:47`): the fake machine's default command reply.
    private let commandSuccess = BluetoothCommandStatus(id: "test-id", message: "Success", status: "success")

    /// What every first request performs before its own write: discover, auth write, one auth read.
    private var connectOps: [FakeOp] {
        [.discover(refresh: false), .write(authChar, Data("token".utf8)), .read(authChar)]
    }

    // MARK: - Commands (C01–C03)

    /// Upstream: test_ble_set_power (tests/test_bluetooth_client.py:295) [C01]
    func testSetPowerOnWritesMachineChangeMode() async throws {
        let rig = makeRig(.laMarzocco(token: "token"))

        let status = try await rig.client.setPower(on: true)

        // BT-REQ-001 (TBC:302-306): to 0b0b…, with response, one trailing NUL.
        let frame = Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]
        XCTAssertEqual(rig.link.recordedOps, connectOps + [.write(settingsChar, frame), .read(settingsChar)])
        XCTAssertEqual(rig.writes.value, [Write(characteristic: authChar, data: Data("token".utf8), withResponse: true),
                                          Write(characteristic: settingsChar, data: frame, withResponse: true)])
        XCTAssertEqual(status, commandSuccess)
        XCTAssertTrue(status.isSuccess)
        XCTAssertEqual(rig.central.connectCount, 1)
        await rig.client.disconnect()
        XCTAssertEqual(rig.link.recordedOps.last, .disconnect)
    }

    /// Upstream: test_ble_set_temperature (tests/test_bluetooth_client.py:310) [C02]
    func testSetTemperatureSteamWritesSettingBoilerTarget() async throws {
        let rig = makeRig(.laMarzocco(token: "token"))

        let status = try await rig.client.setTemperature(boiler: .steam, celsius: 90)

        // BT-REQ-003 (TBC:317-320).
        let frame = Data(#"{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":90}}"#.utf8) + [0x00]
        XCTAssertEqual(rig.link.recordedOps, connectOps + [.write(settingsChar, frame), .read(settingsChar)])
        XCTAssertEqual(rig.writes.value.last, Write(characteristic: settingsChar, data: frame, withResponse: true))
        XCTAssertEqual(status, commandSuccess)
        await rig.client.disconnect()
    }

    /// Upstream: test_ble_set_smart_standby (tests/test_bluetooth_client.py:324) [C03]
    func testSetSmartStandbyWritesMinutesModeEnabled() async throws {
        let rig = makeRig(.laMarzocco(token: "token"))

        let status = try await rig.client.setSmartStandby(enabled: true, mode: .powerOn, minutes: 42)

        // BT-REQ-004 (TBC:331-334): key order minutes, mode, enabled — never sorted.
        let frame = Data(#"{"name":"SettingSmartStandby","parameter":{"minutes":42,"mode":"PowerOn","enabled":true}}"#.utf8) + [0x00]
        XCTAssertEqual(rig.link.recordedOps, connectOps + [.write(settingsChar, frame), .read(settingsChar)])
        XCTAssertEqual(rig.writes.value.last, Write(characteristic: settingsChar, data: frame, withResponse: true))
        XCTAssertEqual(status, commandSuccess)
        await rig.client.disconnect()
    }

    // MARK: - Reads (C04–C08)

    /// Upstream: test_ble_get_machine_capability (tests/test_bluetooth_client.py:338) [C04]
    func testGetMachineCapabilitiesDecodesFirstElement() async throws {
        // BT-RSP-CAP-001 (TBC:342), verbatim.
        let rig = makeRig(.laMarzocco(token: "token", settingResponses: [
            .machineCapabilities: Data(#"[{"family":"MICRA","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":false,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":["BrewingMode","StandBy"],"schedulingType":"smartWakeUpSleep"}]"#.utf8),
        ]))

        let capabilities = try await rig.client.machineCapabilities()

        // BT-READ-REQ-001 (TBC:347).
        let request = Data("machineCapabilities".utf8) + [0x00]
        XCTAssertEqual(rig.link.recordedOps, connectOps + [.write(readChar, request), .read(readChar)])
        XCTAssertEqual(rig.writes.value.last, Write(characteristic: readChar, data: request, withResponse: true))
        XCTAssertEqual(capabilities, BluetoothMachineCapabilities(
            family: .lineaMicra, rawFamily: "MICRA", groupsNumber: 1, coffeeBoilersNumber: 1,
            hasCupWarmer: false, steamBoilersNumber: 1, teaDosesNumber: 0,
            machineModes: [.brewing, .standby], schedulingType: "smartWakeUpSleep"))
        await rig.client.disconnect()
    }

    /// Upstream: test_ble_get_boiler_details (tests/test_bluetooth_client.py:361) [C05]
    func testGetBoilersDecodesList() async throws {
        // BT-RSP-BOIL-001 (TBC:365), verbatim.
        let rig = makeRig(.laMarzocco(token: "token", settingResponses: [
            .boilers: Data(#"[{"id":"SteamBoiler","isEnabled":true,"target":131,"current":45},{"id":"CoffeeBoiler1","isEnabled":true,"target":94,"current":65}]"#.utf8),
        ]))

        let boilers = try await rig.client.boilers()

        // BT-READ-REQ-002 (TBC:370).
        let request = Data("boilers".utf8) + [0x00]
        XCTAssertEqual(rig.link.recordedOps, connectOps + [.write(readChar, request), .read(readChar)])
        XCTAssertEqual(rig.writes.value.last, Write(characteristic: readChar, data: request, withResponse: true))
        // Wire order kept: steam first, then coffee.
        XCTAssertEqual(boilers, [
            BluetoothBoilerDetails(id: .steam, isEnabled: true, target: 131, current: 45),
            BluetoothBoilerDetails(id: .coffee, isEnabled: true, target: 94, current: 65),
        ])
        await rig.client.disconnect()
    }

    /// Upstream: test_ble_get_smart_standby_details (tests/test_bluetooth_client.py:388) [C06]
    func testGetSmartStandbyAcceptsStringBool() async throws {
        // BT-RSP-SSB-001 (TBC:392-394): `"enabled"` is the STRING "true".
        let rig = makeRig(.laMarzocco(token: "token", settingResponses: [
            .smartStandBy: Data(#"{"mode":"PowerOn","minutes":42,"enabled":"true"}"#.utf8),
        ]))

        let standby = try await rig.client.smartStandby()

        // BT-READ-REQ-003 (TBC:399): capital B.
        let request = Data("smartStandBy".utf8) + [0x00]
        XCTAssertEqual(rig.link.recordedOps, connectOps + [.write(readChar, request), .read(readChar)])
        XCTAssertEqual(rig.writes.value.last, Write(characteristic: readChar, data: request, withResponse: true))
        XCTAssertEqual(standby, BluetoothSmartStandbyDetails(mode: .powerOn, minutes: 42, enabled: true))
        await rig.client.disconnect()
    }

    /// Upstream: test_ble_get_tank_status (tests/test_bluetooth_client.py:406) [C07]
    func testGetTankStatusStringTrue() async throws {
        // BT-RSP-TANK-001 (TBC:410): the JSON string "true".
        let rig = makeRig(.laMarzocco(token: "token", settingResponses: [.tankStatus: Data(#""true""#.utf8)]))

        let tank = try await rig.client.tankStatus()

        // BT-READ-REQ-004 (TBC:415).
        let request = Data("tankStatus".utf8) + [0x00]
        XCTAssertEqual(rig.link.recordedOps, connectOps + [.write(readChar, request), .read(readChar)])
        XCTAssertEqual(rig.writes.value.last, Write(characteristic: readChar, data: request, withResponse: true))
        XCTAssertTrue(tank)
        await rig.client.disconnect()
    }

    /// Upstream: test_get_machine_mode (tests/test_bluetooth_client.py:420) [C08]
    func testGetMachineModeBrewing() async throws {
        // BT-RSP-MODE-001 (TBC:424).
        let rig = makeRig(.laMarzocco(token: "token", settingResponses: [.machineMode: Data(#""BrewingMode""#.utf8)]))

        let mode = try await rig.client.machineMode()

        // BT-READ-REQ-005 (TBC:429).
        let request = Data("machineMode".utf8) + [0x00]
        XCTAssertEqual(rig.link.recordedOps, connectOps + [.write(readChar, request), .read(readChar)])
        XCTAssertEqual(rig.writes.value.last, Write(characteristic: readChar, data: request, withResponse: true))
        XCTAssertEqual(mode, .brewing)
        await rig.client.disconnect()
    }

    // MARK: - Framing (C42) and plumb-in (C43–C46)

    /// Upstream: test_read_response_is_nul_terminated (tests/test_bluetooth_client.py:1223) [C42]
    func testReadResponseCutAtFirstNul() async throws {
        // BT-RSP-MODE-002 (TBC:1227): everything from the first NUL on is ignored, even bytes that are
        // not JSON (and not UTF-8) after it.
        let rig = makeRig(.laMarzocco(token: "token", settingResponses: [
            .machineMode: Data(#""BrewingMode""#.utf8) + [0x00, 0x00] + Data("garbage".utf8),
            .tankStatus: Data(#""true""#.utf8) + [0x00, 0xFF, 0xFE],
        ]))

        let mode = try await rig.client.machineMode()
        XCTAssertEqual(mode, .brewing)
        let tank = try await rig.client.tankStatus()
        XCTAssertTrue(tank)

        XCTAssertEqual(rig.link.recordedOps, connectOps + [
            .write(readChar, Data("machineMode".utf8) + [0x00]), .read(readChar),
            .write(readChar, Data("tankStatus".utf8) + [0x00]), .read(readChar),
        ])
        await rig.client.disconnect()
    }

    /// Upstream: test_get_plumbed_in (tests/test_bluetooth_client.py:1238) [C43, C44, C45, C46]
    func testGetPlumbedIn() async throws {
        // BT-RSP-PLUMB-001…004 (TBC:1236), in upstream's parametrize order.
        let cases: [(response: String, expected: Bool)] = [
            ("true", true),          // C43
            ("false", false),        // C44
            (#""true""#, true),      // C45
            (#""false""#, false),    // C46
        ]
        for (response, expected) in cases {
            let rig = makeRig(.laMarzocco(token: "token", settingResponses: [.isPlumbedIn: Data(response.utf8)]))

            let plumbed = try await rig.client.isPlumbedIn()

            XCTAssertEqual(plumbed, expected, response)
            // BT-READ-REQ-006 (TBC:1249).
            let request = Data("isPlumbedIn".utf8) + [0x00]
            XCTAssertEqual(rig.link.recordedOps, connectOps + [.write(readChar, request), .read(readChar)], response)
            XCTAssertEqual(rig.writes.value.last, Write(characteristic: readChar, data: request, withResponse: true), response)
            await rig.client.disconnect()
        }
    }

    // MARK: - Gap tests

    /// Angstrom-only: G-CODEC-5 — malformed read responses ([] capabilities, unknown mode, unknown family, non-JSON, empty) throw .decoding and do not drop the link
    func testMalformedReadsThrowDecodingAndKeepLink() async throws {
        let responses = ScriptedReplies([
            .machineCapabilities: Data("[]".utf8),       // IndexError parity (§3.6)
            .machineMode: Data(#""Foo""#.utf8),           // ValueError parity (BT:558)
            .boilers: Data("not json".utf8),              // JSONDecodeError parity
            .smartStandBy: Data(),                        // empty reply (§3.6, U9)
            .tankStatus: Data([0xFF]) + [0x00],           // invalid UTF-8 before the NUL (§3.5)
            .isPlumbedIn: Data("\u{FEFF}true".utf8),      // UTF-8 BOM (§3.6)
        ])
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        let machineRead = link.onRead
        let machineWrite = link.onWrite
        link.onRead = { [readChar] characteristic in
            characteristic == readChar ? responses.reply() : try machineRead(characteristic)
        }
        link.onWrite = { [readChar] characteristic, data in
            if characteristic == readChar { responses.requested(data) }
            try machineWrite(characteristic, data)
        }
        let rig = makeRig(link)
        let events = await rig.client.connectionEvents()

        await assertThrows(.decoding("bluetooth machineCapabilities: empty array (no element [0])")) {
            try await rig.client.machineCapabilities()
        }
        await assertThrows(.decoding("bluetooth machineMode: Foo is not a valid MachineMode")) {
            try await rig.client.machineMode()
        }
        await assertThrows(.decoding(#"bluetooth boilers: not valid JSON: "not json""#)) {
            try await rig.client.boilers()
        }
        await assertThrows(.decoding(#"bluetooth smartStandBy: not valid JSON: """#)) {
            try await rig.client.smartStandby()
        }
        await assertThrows(.decoding("bluetooth tankStatus: invalid UTF-8")) {
            try await rig.client.tankStatus()
        }
        await assertThrows(.decoding("bluetooth isPlumbedIn: unexpected UTF-8 BOM: \"\u{FEFF}true\"")) {
            try await rig.client.isPlumbedIn()
        }
        // An unknown family is `.decoding` with upstream's ValueError text (CONST:216-217).
        responses.set(.machineCapabilities, Data(#"[{"family":"FOO","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":false,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":["BrewingMode","StandBy"],"schedulingType":"smartWakeUpSleep"}]"#.utf8))
        await assertThrows(.decoding("bluetooth machineCapabilities: Invalid model name: FOO")) {
            try await rig.client.machineCapabilities()
        }

        await rig.client.drainBackgroundWorkForTesting()
        var expected = connectOps
        for setting in ["machineCapabilities", "machineMode", "boilers", "smartStandBy", "tankStatus", "isPlumbedIn",
                        "machineCapabilities"] {
            expected += [.write(readChar, Data(setting.utf8) + [0x00]), .read(readChar)]
        }
        XCTAssertEqual(rig.link.recordedOps, expected, "every request was answered on the same link; no disconnect")
        let state = await rig.client.peek {
            ($0.isConnected, $0.backgroundTasks.isEmpty, $0.idleTask != nil, $0.gateBusy)
        }
        XCTAssertTrue(state.0, "the link stays up")
        XCTAssertTrue(state.1, "no drop was scheduled")
        XCTAssertTrue(state.2, "the idle timer keeps running")
        XCTAssertEqual(state.3, [], "both gates are released")
        XCTAssertEqual(rig.central.connectCount, 1)

        // The link is still usable: the next good read reuses it without reconnecting.
        responses.set(.machineMode, Data(#""StandBy""#.utf8))
        let mode = try await rig.client.machineMode()
        XCTAssertEqual(mode, .standby)
        XCTAssertEqual(rig.central.connectCount, 1)

        // The idle timer that kept running closes the link when it fires (one pending idle sleep).
        await rig.sleeper.waitForPending(.idleDisconnect, count: 1)
        XCTAssertEqual(rig.sleeper.pendingCount(.idleDisconnect), 1)
        rig.sleeper.fire(.idleDisconnect)
        let seen = await take(2, from: events)
        XCTAssertEqual(seen, [.connected, .disconnected], "the only disconnect is the idle one")
        XCTAssertEqual(rig.link.recordedOps.last, .disconnect)
        XCTAssertEqual(rig.link.recordedOps.filter { $0 == .disconnect }.count, 1)
    }

    /// Angstrom-only: §3.7 — the derived frames BT-REQ-002/005/006 (and steam off) are written verbatim to 0b0b… at client level
    func testDerivedCommandFramesAtClientLevel() async throws {
        let rig = makeRig(.laMarzocco(token: "token"))

        let statuses = [
            try await rig.client.setPower(on: false),                          // BT-REQ-002
            try await rig.client.setSteam(on: true),                           // BT-REQ-005
            try await rig.client.setTemperature(boiler: .coffee, celsius: 96.5), // BT-REQ-006
            try await rig.client.setSteam(on: false),                          // BT-FALLBACK-002 frame
        ]

        XCTAssertEqual(statuses, Array(repeating: commandSuccess, count: 4))
        let frames = [
            #"{"name":"MachineChangeMode","parameter":{"mode":"StandBy"}}"#,
            #"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":true}}"#,
            #"{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":96.5}}"#,
            #"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":false}}"#,
        ].map { Data($0.utf8) + [0x00] }
        var expected = connectOps
        for frame in frames {
            expected += [.write(settingsChar, frame), .read(settingsChar)]
        }
        XCTAssertEqual(rig.link.recordedOps, expected)
        XCTAssertEqual(Array(rig.writes.value.dropFirst()),
                       frames.map { Write(characteristic: settingsChar, data: $0, withResponse: true) })
        XCTAssertEqual(rig.central.connectCount, 1)
        await rig.client.disconnect()
    }

    /// Angstrom-only: D21 — a non-finite temperature throws .operationNotAvailable before any I/O: no connect, no write, no drop
    func testNonFiniteTemperatureWritesNothing() async throws {
        let rig = makeRig(.laMarzocco(token: "token"))
        let nonFinite: [Double] = [.nan, -.nan, .signalingNaN, .infinity, -.infinity]

        // Not connected: nothing at all happens.
        for value in nonFinite {
            for boiler in [BluetoothBoilerType.coffee, .steam] {
                await assertThrows(.operationNotAvailable("temperature must be finite"), "\(boiler) \(value)") {
                    try await rig.client.setTemperature(boiler: boiler, celsius: value)
                }
            }
        }
        XCTAssertEqual(rig.central.connectCount, 0, "no connect")
        XCTAssertEqual(rig.link.recordedOps, [])
        XCTAssertEqual(rig.writes.value, [])

        // Connected: still no write, and the link is kept.
        _ = try await rig.client.tankStatus()
        let opsBefore = rig.link.recordedOps
        for value in nonFinite {
            await assertThrows(.operationNotAvailable("temperature must be finite"), "\(value)") {
                try await rig.client.setTemperature(boiler: .steam, celsius: value)
            }
        }
        await rig.client.drainBackgroundWorkForTesting()
        XCTAssertEqual(rig.link.recordedOps, opsBefore, "nothing written or read")
        let state = await rig.client.peek { ($0.isConnected, $0.backgroundTasks.isEmpty, $0.gateBusy) }
        XCTAssertTrue(state.0)
        XCTAssertTrue(state.1, "no drop was scheduled")
        XCTAssertEqual(state.2, [])
        XCTAssertEqual(rig.central.connectCount, 1)
        await rig.client.disconnect()
    }

    /// Angstrom-only: §3.7 — a non-success command status is returned (not thrown), keeps the link, and isSuccess is status.lowercased() == "success"
    func testNonSuccessStatusReturned() async throws {
        let reply = Box<Data>(Data(#"{"id":"ble","message":"Failed","status":"error"}"#.utf8))  // TBD:517-519
        let link = FakeBluetoothLink.laMarzocco(token: "token")
        let original = link.onRead
        link.onRead = { [settingsChar] characteristic in
            characteristic == settingsChar ? reply.value : try original(characteristic)
        }
        let rig = makeRig(link)
        let events = await rig.client.connectionEvents()

        let failed = try await rig.client.setPower(on: true)
        XCTAssertEqual(failed, BluetoothCommandStatus(id: "ble", message: "Failed", status: "error"))
        XCTAssertFalse(failed.isSuccess)

        // An upper-case "SUCCESS" is a success; a null message is "None" (BT-COERCE-001).
        reply.set(Data(#"{"id":"a","message":null,"status":"SUCCESS"}"#.utf8))
        let upper = try await rig.client.setSteam(on: true)
        XCTAssertEqual(upper, BluetoothCommandStatus(id: "a", message: "None", status: "SUCCESS"))
        XCTAssertTrue(upper.isSuccess)

        // A status that merely contains "success" is not one.
        reply.set(Data(#"{"id":"b","message":"m","status":"not success"}"#.utf8))
        let other = try await rig.client.setSmartStandby(enabled: false, mode: .lastBrewing, minutes: 10)
        XCTAssertEqual(other, BluetoothCommandStatus(id: "b", message: "m", status: "not success"))
        XCTAssertFalse(other.isSuccess)

        await rig.client.drainBackgroundWorkForTesting()
        XCTAssertEqual(rig.link.recordedOps, connectOps + [
            .write(settingsChar, Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]),
            .read(settingsChar),
            .write(settingsChar, Data(#"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":true}}"#.utf8) + [0x00]),
            .read(settingsChar),
            .write(settingsChar, Data(#"{"name":"SettingSmartStandby","parameter":{"minutes":10,"mode":"LastBrewing","enabled":false}}"#.utf8) + [0x00]),
            .read(settingsChar),
        ], "no disconnect after a failed status")
        let state = await rig.client.peek { ($0.isConnected, $0.backgroundTasks.isEmpty) }
        XCTAssertTrue(state.0)
        XCTAssertTrue(state.1, "no drop was scheduled")
        XCTAssertEqual(rig.central.connectCount, 1)
        await rig.client.disconnect()
        let seen = await take(2, from: events)
        XCTAssertEqual(seen, [.connected, .disconnected])
    }

    /// Angstrom-only: D5 — smartStandBy "enabled":"false" decodes as false (upstream bool("false") is True); string bools are case-insensitive
    func testSmartStandbyStringFalse() async throws {
        let cases: [(json: String, expected: BluetoothSmartStandbyDetails)] = [
            // BT-RSP-SSB-002.
            (#"{"mode":"PowerOn","minutes":42,"enabled":"false"}"#,
             BluetoothSmartStandbyDetails(mode: .powerOn, minutes: 42, enabled: false)),
            (#"{"mode":"LastBrewing","minutes":15,"enabled":"FALSE"}"#,
             BluetoothSmartStandbyDetails(mode: .lastBrewing, minutes: 15, enabled: false)),
            (#"{"mode":"PowerOn","minutes":42,"enabled":"True"}"#,
             BluetoothSmartStandbyDetails(mode: .powerOn, minutes: 42, enabled: true)),
        ]
        for (json, expected) in cases {
            let rig = makeRig(.laMarzocco(token: "token", settingResponses: [.smartStandBy: Data(json.utf8)]))

            let standby = try await rig.client.smartStandby()

            XCTAssertEqual(standby, expected, json)
            XCTAssertEqual(rig.link.recordedOps,
                           connectOps + [.write(readChar, Data("smartStandBy".utf8) + [0x00]), .read(readChar)], json)
            await rig.client.disconnect()
        }
    }

    // MARK: - Helpers

    private struct Rig {
        let central: SingleLinkCentral
        let link: FakeBluetoothLink
        let writes: Box<[Write]>
        let sleeper: ManualBluetoothSleeper
        let client: LaMarzoccoBluetoothClient
    }

    /// A client whose (only) connection is `link`, wrapped so every write's `withResponse` flag is recorded.
    private func makeRig(_ link: FakeBluetoothLink) -> Rig {
        let writes = Box<[Write]>([])
        let central = SingleLinkCentral(WriteFlagLink(link, writes: writes))
        let sleeper = ManualBluetoothSleeper()
        let client = LaMarzoccoBluetoothClient(transport: BluetoothTransport(central: central, sleeper: sleeper),
                                               peripheral: .fake, token: BluetoothAuthToken("token"))
        return Rig(central: central, link: link, writes: writes, sleeper: sleeper, client: client)
    }

    /// The first `count` elements of `stream` (hang-guarded by a 5 s expectation).
    private func take<Element: Sendable>(_ count: Int, from stream: AsyncStream<Element>) async -> [Element] {
        let done = XCTestExpectation(description: "\(count) stream elements")
        let collector = Task {
            var elements: [Element] = []
            for await element in stream {
                elements.append(element)
                if elements.count == count { break }
            }
            done.fulfill()
            return elements
        }
        await fulfillment(of: [done], timeout: 5)
        collector.cancel()
        return await collector.value
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

/// One recorded GATT write, with its "with response" flag.
private struct Write: Equatable, Sendable {
    let characteristic: GATTUUID
    let data: Data
    let withResponse: Bool
}

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

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

/// A mutable stand-in for the machine's read-setting replies: a read of 0a0b… returns the reply for
/// the setting last written to 0a0b… (like `FakeBluetoothLink.laMarzocco`, but changeable mid-test).
private final class ScriptedReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [BluetoothReadSetting: Data]
    private var lastSetting: BluetoothReadSetting?

    init(_ replies: [BluetoothReadSetting: Data]) {
        self.replies = replies
    }

    func set(_ setting: BluetoothReadSetting, _ data: Data) {
        lock.lock()
        replies[setting] = data
        lock.unlock()
    }

    /// Records the setting named by a read request frame (`<rawValue>\0`).
    func requested(_ frame: Data) {
        lock.lock()
        lastSetting = BluetoothReadSetting(rawValue: String(decoding: frame.prefix { $0 != 0 }, as: UTF8.self))
        lock.unlock()
    }

    /// The reply to the last requested setting (empty when there is none).
    func reply() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return lastSetting.flatMap { replies[$0] } ?? Data()
    }
}

/// Hands out one link on the first `connect`; every later attempt fails with `.notConnected`.
private final class SingleLinkCentral: BluetoothCentral, @unchecked Sendable {
    private let lock = NSLock()
    private var link: (any BluetoothLink)?
    private var count = 0

    init(_ link: any BluetoothLink) {
        self.link = link
    }

    /// Every `connect` call.
    var connectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func availability() async -> BluetoothAvailability { .poweredOn }

    func availabilityUpdates() -> AsyncStream<BluetoothAvailability> { AsyncStream { _ in } }

    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] { [] }

    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        let handed: (any BluetoothLink)? = {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            let next = link
            link = nil
            return next
        }()
        guard let handed else { throw BluetoothTransportError.notConnected }
        return handed
    }
}

/// Forwards to a FakeBluetoothLink, recording every write's characteristic, bytes and `withResponse`.
private final class WriteFlagLink: BluetoothLink, @unchecked Sendable {
    private let inner: FakeBluetoothLink
    private let writes: Box<[Write]>

    init(_ inner: FakeBluetoothLink, writes: Box<[Write]>) {
        self.inner = inner
        self.writes = writes
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
        writes.mutate { $0.append(Write(characteristic: characteristic, data: data, withResponse: withResponse)) }
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

extension LaMarzoccoBluetoothClient {
    /// Runs `body` on the actor: read internal state from a test.
    fileprivate func peek<T: Sendable>(_ body: @Sendable (isolated LaMarzoccoBluetoothClient) -> T) -> T {
        body(self)
    }
}
