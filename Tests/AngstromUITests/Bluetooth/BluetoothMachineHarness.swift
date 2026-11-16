import Foundation
@testable import Angstrom
@testable import AngstromUI
import AngstromTestSupport

/// The shared fixture of every AngstromUI Bluetooth test (PLAN §3.3).
///
/// It builds a **real** `LaMarzoccoBluetoothClient` over the AngstromTestSupport fakes (SPEC §9.2: no
/// mocked client) and, optionally, a cloud client over the existing `MockBackend`/`MockURLProtocol`
/// (`Tests/AngstromUITests/MockTransport.swift`), then a `LaMarzoccoMachine` holding whichever clients
/// were asked for.
///
/// - The Bluetooth client always uses the token `"token"` (upstream `LaMarzoccoBluetoothClient(ble_device,
///   "token")`). The harness's `token` parameter is the token the scripted machine **accepts** (upstream
///   `FakeBleakClient.token`, `tests/test_bluetooth_client.py:168`, overridden as `bleak_client.token =
///   "other"` at `:621`), so `token: "other"` makes authentication fail.
/// - Every link the central makes is `FakeBluetoothLink.laMarzocco(token:commandResponse:settingResponses:)`
///   with the harness's arguments, plus the write failure of `failure` (if any).
/// - The cloud backend answers `/auth/init`, `/auth/signin`, `/dashboard`, `/settings`, `/scheduling` and
///   `/stats` from `Tests/AngstromUITests/Fixtures` (the Micra set, serial `MR123456`) and acknowledges
///   every `/command/` with `[{"id":"cmd1","status":"Pending"}]` — `fixtureBackend()` of
///   `LaMarzoccoMachineTests.swift`.
@MainActor
final class BluetoothMachineHarness {
    enum Seed { case standard, empty, none, custom(Dashboard) }

    enum BluetoothFailure: Equatable {
        case none
        /// Every connect attempt fails `.disconnected(code: 7)` — via `central.connectFailure`.
        case connect
        /// Writes to 0b0b… throw `.gatt(domain: "CBATTErrorDomain", code: 14)`.
        case commandWrite
        /// Writes to 0b0b… throw `.timedOut("write")`.
        case commandTimeout
        /// The central reports this availability.
        case unavailable(BluetoothAvailability)
    }

    /// The serial of the harness machine, the Micra fixtures and upstream's `serial` fixture
    /// (`tests/conftest.py:199-202`).
    static let serial: String = "MR123456"

    let central: FakeBluetoothCentral
    /// Manual: `[.idleDisconnect]` (upstream patches `IDLE_TIMEOUT`; every other wait returns at once).
    let sleeper: ManualBluetoothSleeper
    /// Starts at 2026-01-01T12:00:00Z.
    let clock: BluetoothTestClock
    /// nil when `cloud == false`.
    let backend: MockBackend?
    /// nil when `bluetooth == false`.
    let bluetooth: LaMarzoccoBluetoothClient?
    let machine: LaMarzoccoMachine

    /// `.standard` seeds BT-DASH-SEED-001 (SPEC §9.3.6) for `model` through a MachineSnapshot;
    /// `.empty` seeds Dashboard(machine: Machine(serialNumber:, model:), widgets: []); `.none` seeds nothing.
    /// `.custom` seeds the given dashboard, also through a MachineSnapshot.
    init(model: Model = .lineaMicra, seed: Seed = .standard, cloud: Bool = true, bluetooth: Bool = true,
         token: String = "token", settingResponses: [BluetoothReadSetting: Data] = [:],
         commandResponse: Data = BluetoothTestVectors.commandSuccess, failure: BluetoothFailure = .none) {
        let central = FakeBluetoothCentral()
        let sleeper = ManualBluetoothSleeper(manual: [.idleDisconnect])
        let clock = BluetoothTestClock(Self.clockStart)

        let writeFailure: BluetoothTransportError?
        switch failure {
        case .none:
            writeFailure = nil
        case .connect:
            writeFailure = nil
            central.connectFailure = .disconnected(code: 7)
        case .commandWrite:
            writeFailure = .gatt(domain: "CBATTErrorDomain", code: 14)
        case .commandTimeout:
            writeFailure = .timedOut("write")
        case .unavailable(let availability):
            writeFailure = nil
            central.setAvailability(availability)
        }
        central.makeLink = {
            let link = FakeBluetoothLink.laMarzocco(token: token, commandResponse: commandResponse,
                                                    settingResponses: settingResponses)
            if let writeFailure {
                let machineWrite = link.onWrite
                link.onWrite = { characteristic, data in
                    if characteristic == BluetoothConstants.writeCharacteristic { throw writeFailure }
                    try machineWrite(characteristic, data)
                }
            }
            return link
        }

        let backend: MockBackend? = cloud ? Self.makeBackend() : nil
        let cloudClient = backend.map { backend in
            LaMarzoccoCloudClient(username: "u", password: "p", installationKey: .generate(),
                                  urlSession: MockURLProtocol.session(backend: backend))
        }
        let bluetoothClient: LaMarzoccoBluetoothClient? = bluetooth
            ? LaMarzoccoBluetoothClient(transport: .fake(central, sleeper: sleeper, clock: clock),
                                        peripheral: .fake, token: BluetoothAuthToken("token"))
            : nil

        let seeded: Dashboard?
        switch seed {
        case .standard:
            seeded = Self.seedDashboard(model: model)
        case .empty:
            seeded = Dashboard(machine: Machine(serialNumber: Self.serial, model: model), widgets: [])
        case .none:
            seeded = nil
        case .custom(let dashboard):
            seeded = dashboard
        }
        let snapshot = seeded.map { MachineSnapshot(serialNumber: Self.serial, dashboard: $0) }

        self.central = central
        self.sleeper = sleeper
        self.clock = clock
        self.backend = backend
        self.bluetooth = bluetoothClient
        self.machine = LaMarzoccoMachine(serialNumber: Self.serial, client: cloudClient,
                                         bluetooth: bluetoothClient, snapshot: snapshot)
    }

    /// BT-DASH-SEED-001: CMMachineStatus(standby,[brewing,standby],standby), CMCoffeeBoiler(standby, enabled,
    /// enabledSupported false, 93.0, 80…100 step 0.1), CMSteamBoilerLevel(standby, enabled, true, level1, true),
    /// CMSteamBoilerTemperature(standby, enabled, false, 126.0, 126…131 step 1.0, true); all index 1.
    ///
    /// Verbatim from upstream's `mock_machine_with_dashboard` fixture
    /// (`tests/test_bluetooth_dashboard.py:68-105`), in its order; every optional (`next_status`,
    /// `brewing_start_time`, `ready_start_time`) is `None` there and nil here. The machine is
    /// `Machine(serialNumber: "MR123456", model: model)`.
    static func seedDashboard(model: Model) -> Dashboard {
        Dashboard(machine: Machine(serialNumber: serial, model: model), widgets: [
            Widget(code: "CMMachineStatus", index: 1, kind: .machineStatus(MachineStatus(
                status: .standby,
                availableModes: [.brewing, .standby],
                mode: .standby,
                nextStatus: nil,
                brewingStartTime: nil))),
            Widget(code: "CMCoffeeBoiler", index: 1, kind: .coffeeBoiler(CoffeeBoiler(
                status: .standby,
                enabled: true,
                enabledSupported: false,
                targetTemperature: 93.0,
                targetTemperatureMin: 80,
                targetTemperatureMax: 100,
                targetTemperatureStep: 0.1,
                readyStartTime: nil))),
            Widget(code: "CMSteamBoilerLevel", index: 1, kind: .steamBoilerLevel(SteamBoilerLevel(
                status: .standby,
                enabled: true,
                enabledSupported: true,
                targetLevel: .level1,
                targetLevelSupported: true,
                readyStartTime: nil))),
            Widget(code: "CMSteamBoilerTemperature", index: 1, kind: .steamBoilerTemperature(SteamBoilerTemperature(
                status: .standby,
                enabled: true,
                enabledSupported: false,
                targetTemperature: 126.0,
                targetTemperatureMin: 126,
                targetTemperatureMax: 131,
                targetTemperatureStep: 1.0,
                targetTemperatureSupported: true,
                readyStartTime: nil))),
        ])
    }

    /// `central.links`: every link the central handed out, in order.
    var links: [FakeBluetoothLink] { central.links }

    /// Every value written to `characteristic`, across all links, in order.
    func bluetoothWrites(to characteristic: GATTUUID) -> [Data] {
        links.flatMap { link in
            link.recordedOps.compactMap { op -> Data? in
                guard case .write(let written, let data) = op, written == characteristic else { return nil }
                return data
            }
        }
    }

    /// Number of cloud requests whose path ends with `/command/<name>` (0 without a cloud backend).
    func cloudCommandCount(_ name: String) -> Int {
        backend?.count(pathSuffix: "/command/\(name)") ?? 0
    }

    /// The JSON body of the last cloud request whose path ends with `/command/<name>`; nil when there is
    /// no such request, it carried no body, or there is no cloud backend. Throws when the body is not a
    /// JSON object.
    func cloudCommandBody(_ name: String) throws -> [String: Any]? {
        guard let body = backend?.body(pathSuffix: "/command/\(name)") else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LaMarzoccoError.decoding("cloud command \(name): body is not a JSON object")
        }
        return object
    }

    // MARK: - Private

    /// 2026-01-01T12:00:00Z.
    private static let clockStart = Date(timeIntervalSince1970: 1_767_268_800)

    /// `fixtureBackend()` of `LaMarzoccoMachineTests.swift`. A missing fixture is a broken test target,
    /// not a test outcome, so it traps.
    private static func makeBackend() -> MockBackend {
        let dashboard = fixture("dashboard_micra")
        let settings = fixture("settings_micra")
        let schedule = fixture("schedule")
        let stats = fixture("statistics")
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.hasSuffix("/dashboard") { return MockBackend.Reply(status: 200, body: dashboard) }
            if path.hasSuffix("/settings") { return MockBackend.Reply(status: 200, body: settings) }
            if path.hasSuffix("/scheduling") { return MockBackend.Reply(status: 200, body: schedule) }
            if path.hasSuffix("/stats") { return MockBackend.Reply(status: 200, body: stats) }
            if path.contains("/command/") { return .jsonArray([["id": "cmd1", "status": "Pending"]]) }
            return MockBackend.Reply(status: 404)
        }
        return backend
    }

    private static func fixture(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            fatalError("missing UI test fixture \(name).json")
        }
        return data
    }
}
