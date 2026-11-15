import XCTest
@testable import Angstrom
@testable import AngstromUI
import AngstromTestSupport

/// BT-W3-07: `bluetoothFirst(bluetooth:cloud:)` (SPEC §4.16) through the six BLE-first commands of
/// `LaMarzoccoMachine`, over a real `LaMarzoccoBluetoothClient` on the AngstromTestSupport fakes and a
/// cloud client on `MockBackend` (`BluetoothMachineHarness`, PLAN §3.3).
///
/// Wire values: the BLE frames are BT-FALLBACK-001…006 (SPEC §9.3.7, `TM:134-189`; bytes per §3.7)
/// and the cloud command names/bodies are those of `Sources/Angstrom/Commands.swift`.
@MainActor
final class BluetoothFallbackTests: XCTestCase {
    private let write = BluetoothConstants.writeCharacteristic
    /// Hang guard only (PLAN §3.5).
    private let hangGuard: TimeInterval = 5

    // MARK: - M01–M12

    /// Upstream: test_bluetooth_command_with_cloud_fallback (tests/test_machine.py:206) [M01–M12]
    ///
    /// Six commands × {`bluetooth`: BLE succeeds → exactly one BLE frame, no cloud traffic at all, and a
    /// synthesized `CommandResponse(id: "test-id", status: .success, errorCode: nil)`; `cloud`: the BLE
    /// attempt (the same frame, written once) fails `.bluetoothConnectionFailed` → exactly one cloud
    /// call with the expected body, whose response is returned}. In both cases the optimistic update
    /// runs (§4.20) — except `setSmartStandby`, which has none.
    func testCommandUsesBluetoothThenCloud() async throws {
        for command in Self.commands {
            for bleFails in [false, true] {
                let label = "\(command.name) [\(bleFails ? "cloud" : "bluetooth")]"
                let harness = BluetoothMachineHarness(model: command.model,
                                                      failure: bleFails ? .commandWrite : .none)
                let machine = harness.machine
                let backend = try XCTUnwrap(harness.backend, label)
                let seed = machine.dashboard

                let response = try await command.run(machine)

                // The BLE attempt is made exactly once, with the exact frame, in both cases.
                XCTAssertEqual(harness.bluetoothWrites(to: write), [command.frame], label)
                if bleFails {
                    XCTAssertEqual(response.id, "cmd1", label)
                    XCTAssertEqual(response.status, .pending, label)
                    XCTAssertEqual(harness.cloudCommandCount(command.cloudCommand), 1, label)
                    XCTAssertEqual(backend.recordedPaths.filter { $0.contains("/command/") },
                                   ["/api/customer-app/things/MR123456/command/\(command.cloudCommand)"], label)
                    let body = try XCTUnwrap(try harness.cloudCommandBody(command.cloudCommand), label)
                    XCTAssertEqual(body as NSDictionary, command.cloudBody, label)
                } else {
                    XCTAssertEqual(response, CommandResponse(id: "test-id", status: .success, errorCode: nil), label)
                    XCTAssertEqual(backend.recordedPaths, [], "no cloud request of any kind: \(label)")
                }
                XCTAssertNil(machine.lastError, label)
                command.checkDashboard(try XCTUnwrap(seed, label), try XCTUnwrap(machine.dashboard, label), label)
                XCTAssertEqual(machine.baseDashboard, machine.dashboard, label)
                await harness.bluetooth?.drainBackgroundWorkForTesting()
            }
        }
    }

    // MARK: - M13, M32

    /// Upstream: test_failing_command (tests/test_machine.py:486) [M13]
    ///
    /// Restated (D18): upstream returns `False` when BLE fails with `BluetoothConnectionFailed` and the
    /// cloud returns `False`. Angstrom: the cloud error propagates (here HTTP 500 →
    /// `.requestFailed(status: 500, body: "boom")`), after exactly one BLE attempt and one cloud call; it is
    /// recorded in `lastError` and no optimistic update is applied.
    func testBothTransportsFailThrowsCloudError() async throws {
        let harness = BluetoothMachineHarness(failure: .commandWrite)
        let backend = try XCTUnwrap(harness.backend)
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.contains("/command/") { return MockBackend.Reply(status: 500, body: Data("boom".utf8)) }
            return MockBackend.Reply(status: 404)
        }
        let machine = harness.machine
        let seed = machine.dashboard

        do {
            _ = try await machine.setPower(on: true)
            XCTFail("setPower must throw when both transports fail")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .requestFailed(status: 500, body: "boom"))
        }
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, .requestFailed(status: 500, body: "boom"))
        XCTAssertEqual(harness.bluetoothWrites(to: write), [Self.powerOnFrame])
        XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineChangeMode"), 1)
        XCTAssertEqual(machine.dashboard, seed)
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .standby)
        await harness.bluetooth?.drainBackgroundWorkForTesting()
    }

    /// Upstream: test_bluetooth_failure_without_cloud (tests/test_machine.py:1155) [M32]
    ///
    /// Restated (D18): upstream returns `False` on a BLE-only machine whose `set_power` raises
    /// `BluetoothConnectionFailed`. Angstrom rethrows the Bluetooth client's error unchanged (compared
    /// with the same call made directly on an identical client), records it, and applies no update.
    func testBluetoothFailureWithoutCloudRethrows() async throws {
        let expected = try await Self.directBluetoothError(failure: .connect) { try await $0.setPower(on: true) }
        guard case .bluetoothConnectionFailed = expected else {
            return XCTFail("the reference error must be .bluetoothConnectionFailed, got \(expected)")
        }

        let harness = BluetoothMachineHarness(cloud: false, failure: .connect)
        let machine = harness.machine
        let seed = machine.dashboard
        do {
            _ = try await machine.setPower(on: true)
            XCTFail("setPower must throw without a cloud client")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, expected)
        }
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, expected)
        XCTAssertEqual(harness.central.connectCount, 3)
        XCTAssertTrue(harness.links.isEmpty)
        XCTAssertEqual(machine.dashboard, seed)
        XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .standby)
        await harness.bluetooth?.drainBackgroundWorkForTesting()
    }

    // MARK: - M30–M31, G-DEV-8

    /// Upstream: test_set_smart_standby_auto_standby (tests/test_machine.py:1137) [M30, M31]
    ///
    /// With `schedule.autoStandBySupported == true`, `setSmartStandby` sends the cloud
    /// `CoffeeMachineSettingAutoStandBy` with `{"mode":"01:30"}` for `(true, 90)` and `{"mode":"Off"}` for
    /// `(false, 90)`; Bluetooth is never used (no connect, no write), although a BLE client exists. Also
    /// D22: the same machine without a cloud client throws `.cloudOnlyFunctionality`, still without BLE.
    func testSmartStandbyUsesCloudAutoStandbyWhenSupported() async throws {
        for (enabled, minutes, expected) in [(true, 90, "01:30"), (false, 90, "Off")] {
            let label = "(\(enabled), \(minutes))"
            let harness = BluetoothMachineHarness()
            let machine = harness.machine
            try await machine.refreshSchedule()
            XCTAssertEqual(machine.schedule?.autoStandBySupported, true, label)

            let response = try await machine.setSmartStandby(enabled: enabled, minutes: minutes, after: .powerOn)

            XCTAssertEqual(response.id, "cmd1", label)
            XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingAutoStandBy"), 1, label)
            let body = try XCTUnwrap(try harness.cloudCommandBody("CoffeeMachineSettingAutoStandBy"), label)
            XCTAssertEqual(body as NSDictionary, ["mode": expected] as NSDictionary, label)
            XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingSmartStandBy"), 0, label)
            XCTAssertEqual(harness.central.connectCount, 0, label)
            XCTAssertEqual(harness.bluetoothWrites(to: write), [], label)
        }

        // D22: auto-standby is cloud only.
        let harness = BluetoothMachineHarness(cloud: false)
        let machine = harness.machine
        machine.schedule = try Self.autoStandbySchedule()
        do {
            _ = try await machine.setSmartStandby(enabled: true, minutes: 90, after: .powerOn)
            XCTFail("auto-standby without a cloud client must throw")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .cloudOnlyFunctionality)
        }
        XCTAssertEqual(machine.lastError as? LaMarzoccoError, .cloudOnlyFunctionality)
        XCTAssertEqual(harness.central.connectCount, 0)
        XCTAssertEqual(harness.bluetoothWrites(to: write), [])
    }

    /// Angstrom-only: G-DEV-8 — auto-standby `"HH:MM"` formatting: 1440 → `"24:00"`, 61 → `"01:01"`,
    /// 0 → `"00:00"` (`f"{minutes // 60:02d}:{minutes % 60:02d}"`, `MACH:877`); no Bluetooth traffic.
    func testAutoStandbyMinuteFormatting() async throws {
        for (minutes, expected) in [(1440, "24:00"), (61, "01:01"), (0, "00:00"), (90, "01:30"), (5, "00:05")] {
            let harness = BluetoothMachineHarness()
            let machine = harness.machine
            machine.schedule = try Self.autoStandbySchedule()

            _ = try await machine.setSmartStandby(enabled: true, minutes: minutes, after: .lastBrewing)

            let body = try XCTUnwrap(try harness.cloudCommandBody("CoffeeMachineSettingAutoStandBy"), "\(minutes)")
            XCTAssertEqual(body as NSDictionary, ["mode": expected] as NSDictionary, "\(minutes)")
            XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineSettingAutoStandBy"), 1, "\(minutes)")
            XCTAssertEqual(harness.central.connectCount, 0, "\(minutes)")
        }
    }

    // MARK: - Gap tests

    /// Angstrom-only: G-DEV-1 — a non-success BLE status (`{"id":"ble","message":"Failed","status":"error"}`)
    /// is not a Bluetooth error: with a cloud client every one of the six commands falls through to
    /// exactly one cloud call, returns the cloud's response and applies its optimistic update. The link
    /// is not dropped (nothing was thrown on the Bluetooth side).
    func testNonSuccessStatusFallsBackToCloud() async throws {
        for command in Self.commands {
            let harness = BluetoothMachineHarness(model: command.model, commandResponse: Self.errorStatus)
            let machine = harness.machine
            let seed = try XCTUnwrap(machine.dashboard, command.name)

            let response = try await command.run(machine)

            XCTAssertEqual(response.id, "cmd1", command.name)
            XCTAssertEqual(response.status, .pending, command.name)
            XCTAssertEqual(harness.bluetoothWrites(to: write), [command.frame], command.name)
            XCTAssertEqual(harness.cloudCommandCount(command.cloudCommand), 1, command.name)
            let body = try XCTUnwrap(try harness.cloudCommandBody(command.cloudCommand), command.name)
            XCTAssertEqual(body as NSDictionary, command.cloudBody, command.name)
            XCTAssertNil(machine.lastError, command.name)
            command.checkDashboard(seed, try XCTUnwrap(machine.dashboard, command.name), command.name)
            await harness.bluetooth?.drainBackgroundWorkForTesting()
            XCTAssertEqual(harness.links.count, 1, command.name)
            XCTAssertFalse(harness.links.flatMap(\.recordedOps).contains(.disconnect), command.name)
            let connected = await harness.bluetooth?.isConnected
            XCTAssertEqual(connected, true, command.name)
        }
    }

    /// Angstrom-only: G-DEV-2 — `.bluetoothTimedOut` (D19), `.decoding` and `CancellationError` from the
    /// Bluetooth side propagate with **no** cloud call, although a cloud client exists; the error is
    /// recorded in `lastError` and no optimistic update is applied.
    func testTimeoutAndDecodeErrorsDoNotFallBack() async throws {
        // Request-phase timeout → .bluetoothTimedOut("write"), for every command.
        for command in Self.commands {
            let harness = BluetoothMachineHarness(model: command.model, failure: .commandTimeout)
            let machine = harness.machine
            let seed = machine.dashboard
            do {
                _ = try await command.run(machine)
                XCTFail("\(command.name) must throw on a Bluetooth timeout")
            } catch {
                XCTAssertEqual(error as? LaMarzoccoError, .bluetoothTimedOut("write"), command.name)
            }
            XCTAssertEqual(machine.lastError as? LaMarzoccoError, .bluetoothTimedOut("write"), command.name)
            XCTAssertEqual(harness.bluetoothWrites(to: write), [command.frame], command.name)
            XCTAssertEqual(harness.backend?.recordedPaths, [], command.name)
            XCTAssertEqual(machine.dashboard, seed, command.name)
            await harness.bluetooth?.drainBackgroundWorkForTesting()
        }

        // An undecodable command status → .decoding, for every command.
        for command in Self.commands {
            let harness = BluetoothMachineHarness(model: command.model, commandResponse: Data("not json".utf8))
            let machine = harness.machine
            let seed = machine.dashboard
            do {
                _ = try await command.run(machine)
                XCTFail("\(command.name) must throw on an undecodable status")
            } catch let error as LaMarzoccoError {
                guard case .decoding = error else {
                    XCTFail("\(command.name): expected .decoding, got \(error)")
                    continue
                }
                XCTAssertFalse(error.isBluetoothConnectionFailure, command.name)
                XCTAssertEqual(machine.lastError as? LaMarzoccoError, error, command.name)
            }
            XCTAssertEqual(harness.bluetoothWrites(to: write), [command.frame], command.name)
            XCTAssertEqual(harness.backend?.recordedPaths, [], command.name)
            XCTAssertEqual(machine.dashboard, seed, command.name)
            await harness.bluetooth?.drainBackgroundWorkForTesting()
        }

        // Cancellation while the command write is in flight → CancellationError, no cloud call.
        let harness = BluetoothMachineHarness()
        let machine = harness.machine
        let seed = machine.dashboard
        let commandCharacteristic = write
        let (reached, reachedContinuation) = AsyncStream<Void>.makeStream()
        let makeLink = harness.central.makeLink
        harness.central.makeLink = {
            let link = makeLink()
            link.beforeOp = { op in
                guard case .write(let characteristic, _) = op, characteristic == commandCharacteristic else { return }
                reachedContinuation.yield()
                // Held until the calling task is cancelled (iteration ends on cancellation).
                let (hold, holdContinuation) = AsyncStream<Void>.makeStream()
                for await _ in hold {}
                holdContinuation.finish()
            }
            return link
        }
        let task = Task { @MainActor in try await machine.setPower(on: true) }
        let inFlight = expectation(description: "command write in flight")
        let waiter = Task {
            for await _ in reached {
                inFlight.fulfill()
                break
            }
        }
        await fulfillment(of: [inFlight], timeout: hangGuard)
        // If the write was never reached (a failed expectation), end the waiter instead of hanging.
        reachedContinuation.finish()
        await waiter.value
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            XCTFail("a cancelled command must throw")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertTrue(machine.lastError is CancellationError)
        XCTAssertEqual(harness.bluetoothWrites(to: write), [Self.powerOnFrame])
        XCTAssertEqual(harness.backend?.recordedPaths, [])
        XCTAssertEqual(machine.dashboard, seed)
        await harness.bluetooth?.drainBackgroundWorkForTesting()
    }

    /// Angstrom-only: D10 — every error with `isBluetoothConnectionFailure` falls back: Bluetooth
    /// unavailable (`.poweredOff`, `.unsupported`, `.unauthorized(.denied)`: fail fast, no connect
    /// attempt), a rejected token (`.bluetoothAuthenticationFailed`) and a connect failure
    /// (`.bluetoothConnectionFailed`). With a cloud client: exactly one cloud call and the update; without
    /// one: the Bluetooth error itself is rethrown.
    func testUnavailableBluetoothFallsBack() async throws {
        struct Scenario {
            let label: String
            let failure: BluetoothMachineHarness.BluetoothFailure
            let token: String
            let expected: LaMarzoccoError?
            let connectAttempts: Int
        }
        let scenarios = [
            Scenario(label: "poweredOff", failure: .unavailable(.poweredOff), token: "token",
                     expected: .bluetoothUnavailable(.poweredOff), connectAttempts: 0),
            Scenario(label: "unsupported", failure: .unavailable(.unsupported), token: "token",
                     expected: .bluetoothUnavailable(.unsupported), connectAttempts: 0),
            Scenario(label: "denied", failure: .unavailable(.unauthorized(.denied)), token: "token",
                     expected: .bluetoothUnavailable(.unauthorized(.denied)), connectAttempts: 0),
            Scenario(label: "auth", failure: .none, token: "other",
                     expected: .bluetoothAuthenticationFailed, connectAttempts: 1),
            Scenario(label: "connect", failure: .connect, token: "token", expected: nil, connectAttempts: 3),
        ]
        for scenario in scenarios {
            // With a cloud client: falls back.
            let harness = BluetoothMachineHarness(token: scenario.token, failure: scenario.failure)
            let machine = harness.machine
            let response = try await machine.setPower(on: true)
            XCTAssertEqual(response.id, "cmd1", scenario.label)
            XCTAssertEqual(harness.cloudCommandCount("CoffeeMachineChangeMode"), 1, scenario.label)
            let body = try XCTUnwrap(try harness.cloudCommandBody("CoffeeMachineChangeMode"), scenario.label)
            XCTAssertEqual(body as NSDictionary, ["mode": "BrewingMode"] as NSDictionary, scenario.label)
            XCTAssertEqual(harness.central.connectCount, scenario.connectAttempts, scenario.label)
            XCTAssertEqual(harness.bluetoothWrites(to: write), [], "never got to the command: \(scenario.label)")
            XCTAssertEqual(machine.dashboard?.machineStatus?.mode, .brewing, scenario.label)
            XCTAssertNil(machine.lastError, scenario.label)
            await harness.bluetooth?.drainBackgroundWorkForTesting()

            // Without a cloud client: the Bluetooth error is rethrown unchanged.
            let reference = try await Self.directBluetoothError(token: scenario.token, failure: scenario.failure) {
                try await $0.setPower(on: true)
            }
            if let expected = scenario.expected {
                XCTAssertEqual(reference, expected, scenario.label)
            } else if case .bluetoothConnectionFailed = reference {
            } else {
                XCTFail("\(scenario.label): expected .bluetoothConnectionFailed, got \(reference)")
            }
            XCTAssertTrue(reference.isBluetoothConnectionFailure, scenario.label)
            let bleOnly = BluetoothMachineHarness(cloud: false, token: scenario.token, failure: scenario.failure)
            do {
                _ = try await bleOnly.machine.setPower(on: true)
                XCTFail("\(scenario.label): must rethrow without a cloud client")
            } catch {
                XCTAssertEqual(error as? LaMarzoccoError, reference, scenario.label)
            }
            XCTAssertEqual(bleOnly.machine.dashboard?.machineStatus?.mode, .standby, scenario.label)
            await bleOnly.bluetooth?.drainBackgroundWorkForTesting()
        }
    }

    /// Angstrom-only: D18 — with neither client, each of the six BLE-first commands throws
    /// `.cloudOnlyFunctionality`, records it and changes nothing.
    func testNeitherClientThrowsCloudOnly() async throws {
        for command in Self.commands {
            let harness = BluetoothMachineHarness(model: command.model, cloud: false, bluetooth: false)
            let machine = harness.machine
            XCTAssertFalse(machine.hasCloudClient)
            XCTAssertFalse(machine.hasBluetoothClient)
            let seed = machine.dashboard
            do {
                _ = try await command.run(machine)
                XCTFail("\(command.name) must throw with neither client")
            } catch {
                XCTAssertEqual(error as? LaMarzoccoError, .cloudOnlyFunctionality, command.name)
            }
            XCTAssertEqual(machine.lastError as? LaMarzoccoError, .cloudOnlyFunctionality, command.name)
            XCTAssertEqual(machine.dashboard, seed, command.name)
            XCTAssertEqual(harness.central.connectCount, 0, command.name)
        }

        // Directly: neither operation is invoked.
        let machine = LaMarzoccoMachine(serialNumber: BluetoothMachineHarness.serial, client: nil, bluetooth: nil)
        do {
            _ = try await machine.bluetoothFirst(
                bluetooth: { _ in XCTFail("no Bluetooth client: must not run"); throw CancellationError() },
                cloud: { _ in XCTFail("no cloud client: must not run"); throw CancellationError() })
            XCTFail("bluetoothFirst must throw with neither client")
        } catch {
            XCTAssertEqual(error as? LaMarzoccoError, .cloudOnlyFunctionality)
        }
    }

    /// Angstrom-only: §4.16 — the gates run before any transport: steam level on a non-level model, steam
    /// temperature on a non-temperature model, either on an unknown model, and smart standby on a
    /// grinder throw `.unsupportedModel` with no Bluetooth connect, no Bluetooth write and no cloud request.
    func testGatingRunsBeforeAnyTransport() async throws {
        func assertGated(_ harness: BluetoothMachineHarness, _ label: String,
                         _ operation: (LaMarzoccoMachine) async throws -> CommandResponse) async {
            let machine = harness.machine
            let seed = machine.dashboard
            do {
                _ = try await operation(machine)
                XCTFail("\(label) must be gated")
            } catch let error as LaMarzoccoError {
                guard case .unsupportedModel = error else {
                    return XCTFail("\(label): expected .unsupportedModel, got \(error)")
                }
                XCTAssertEqual(machine.lastError as? LaMarzoccoError, error, label)
            } catch {
                XCTFail("\(label): expected .unsupportedModel, got \(error)")
            }
            XCTAssertEqual(harness.central.connectCount, 0, label)
            XCTAssertTrue(harness.links.isEmpty, label)
            XCTAssertEqual(harness.backend?.recordedPaths ?? [], [], label)
            XCTAssertEqual(machine.dashboard, seed, label)
        }

        await assertGated(BluetoothMachineHarness(model: .lineaMicra), "steam temperature on Linea Micra") {
            try await $0.setSteamTargetTemperature(celsius: 124)
        }
        await assertGated(BluetoothMachineHarness(model: .gs3), "steam level on GS3") {
            try await $0.setSteamTargetLevel(.level2)
        }
        await assertGated(BluetoothMachineHarness(model: .lineaMini), "steam level on Linea Mini") {
            try await $0.setSteamTargetLevel(.level2)
        }
        await assertGated(BluetoothMachineHarness(seed: .none), "steam level on unknown model") {
            try await $0.setSteamTargetLevel(.level2)
        }
        await assertGated(BluetoothMachineHarness(seed: .none), "steam temperature on unknown model") {
            try await $0.setSteamTargetTemperature(celsius: 124)
        }
        let grinder = Dashboard(machine: Machine(serialNumber: BluetoothMachineHarness.serial, model: .swan, type: .grinder),
                                widgets: [])
        await assertGated(BluetoothMachineHarness(seed: .custom(grinder)), "smart standby on a grinder") {
            try await $0.setSmartStandby(enabled: true, minutes: 30, after: .powerOn)
        }
        // Bluetooth only: still gated before the BLE attempt.
        await assertGated(BluetoothMachineHarness(model: .lineaMicra, cloud: false), "BLE-only steam temperature") {
            try await $0.setSteamTargetTemperature(celsius: 124)
        }
    }

    // MARK: - Private

    /// One BLE-first command of the M01–M12 table (`TM:134-189`, SPEC §9.3.7).
    private struct Command {
        let name: String
        let model: Model
        let run: @MainActor (LaMarzoccoMachine) async throws -> CommandResponse
        let frame: Data
        let cloudCommand: String
        let cloudBody: NSDictionary
        /// Asserts the optimistic update: `(seed, after, label)`.
        let checkDashboard: @MainActor (Dashboard, Dashboard, String) -> Void
    }

    /// BT-REQ-001.
    private static let powerOnFrame = frame(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#)

    /// The upstream non-success example (`TBD:517-519`).
    private static let errorStatus = Data(#"{"id":"ble","message":"Failed","status":"error"}"#.utf8)

    private static func frame(_ json: String) -> Data { Data(json.utf8) + [0x00] }

    private static let commands: [Command] = [
        // BT-FALLBACK-001
        Command(name: "setPower", model: .lineaMicra,
                run: { try await $0.setPower(on: true) },
                frame: powerOnFrame,
                cloudCommand: "CoffeeMachineChangeMode",
                cloudBody: ["mode": "BrewingMode"],
                checkDashboard: { seed, after, label in
                    XCTAssertEqual(after.machineStatus?.mode, .brewing, label)
                    XCTAssertEqual(after.machineStatus?.status, .standby, label)
                    XCTAssertEqual(after, seed.settingMachineMode(.brewing), label)
                }),
        // BT-FALLBACK-002
        Command(name: "setSteam", model: .lineaMicra,
                run: { try await $0.setSteam(on: false) },
                frame: frame(#"{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":false}}"#),
                cloudCommand: "CoffeeMachineSettingSteamBoilerEnabled",
                cloudBody: ["boilerIndex": 1, "enabled": false],
                checkDashboard: { _, after, label in
                    XCTAssertEqual(after.steamBoilerLevel?.enabled, false, label)
                    XCTAssertEqual(after.steamBoilerTemperature?.enabled, false, label)
                    XCTAssertEqual(after.machineStatus?.mode, .standby, label)
                }),
        // BT-FALLBACK-003
        Command(name: "setSteamTargetLevel", model: .lineaMicra,
                run: { try await $0.setSteamTargetLevel(.level2) },
                frame: frame(#"{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":128}}"#),
                cloudCommand: "CoffeeMachineSettingSteamBoilerTargetLevel",
                cloudBody: ["boilerIndex": 1, "targetLevel": "Level2"],
                checkDashboard: { _, after, label in
                    XCTAssertEqual(after.steamBoilerLevel?.targetLevel, .level2, label)
                    XCTAssertEqual(after.steamBoilerTemperature?.targetTemperature, 126.0, label)
                }),
        // BT-FALLBACK-004
        Command(name: "setCoffeeTargetTemperature", model: .lineaMicra,
                run: { try await $0.setCoffeeTargetTemperature(celsius: 93) },
                frame: frame(#"{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":93}}"#),
                cloudCommand: "CoffeeMachineSettingCoffeeBoilerTargetTemperature",
                cloudBody: ["boilerIndex": 1, "targetTemperature": 93],
                checkDashboard: { seed, after, label in
                    // The seed's coffee target is already 93.0: the dashboard is unchanged by value.
                    XCTAssertEqual(after.coffeeBoiler?.targetTemperature, 93.0, label)
                    XCTAssertEqual(after, seed, label)
                }),
        // BT-FALLBACK-005
        Command(name: "setSteamTargetTemperature", model: .gs3,
                run: { try await $0.setSteamTargetTemperature(celsius: 124) },
                frame: frame(#"{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":124}}"#),
                cloudCommand: "CoffeeMachineSettingSteamBoilerTargetTemperature",
                cloudBody: ["boilerIndex": 1, "targetTemperature": 124],
                checkDashboard: { _, after, label in
                    XCTAssertEqual(after.steamBoilerTemperature?.targetTemperature, 124.0, label)
                    XCTAssertEqual(after.steamBoilerLevel?.targetLevel, .level1, label)
                }),
        // BT-FALLBACK-006
        Command(name: "setSmartStandby", model: .lineaMicra,
                run: { try await $0.setSmartStandby(enabled: true, minutes: 30, after: .powerOn) },
                frame: frame(#"{"name":"SettingSmartStandby","parameter":{"minutes":30,"mode":"PowerOn","enabled":true}}"#),
                cloudCommand: "CoffeeMachineSettingSmartStandBy",
                cloudBody: ["enabled": true, "minutes": 30, "after": "PowerOn"],
                checkDashboard: { seed, after, label in
                    XCTAssertEqual(after, seed, "setSmartStandby has no optimistic update: \(label)")
                }),
    ]

    /// The error the Bluetooth client itself throws for `operation` on a fresh harness client with the
    /// given failure mode — the reference for "rethrown unchanged".
    private static func directBluetoothError(
        token: String = "token", failure: BluetoothMachineHarness.BluetoothFailure,
        _ operation: (LaMarzoccoBluetoothClient) async throws -> BluetoothCommandStatus
    ) async throws -> LaMarzoccoError {
        let twin = BluetoothMachineHarness(cloud: false, token: token, failure: failure)
        let client = try XCTUnwrap(twin.bluetooth)
        let thrown: LaMarzoccoError
        do {
            let status = try await operation(client)
            XCTFail("expected a Bluetooth error, got status \(status)")
            thrown = .decoding("no Bluetooth error")
        } catch let error as LaMarzoccoError {
            thrown = error
        }
        await client.drainBackgroundWorkForTesting()
        return thrown
    }

    /// `schedule.json` (Micra fixture): `autoStandBySupported` true.
    private static func autoStandbySchedule() throws -> MachineSchedule {
        let schedule = try JSONDecoder.laMarzocco().decode(MachineSchedule.self, from: Fixture.data("schedule"))
        XCTAssertTrue(schedule.autoStandBySupported)
        return schedule
    }
}
