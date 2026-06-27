import XCTest
import Foundation
@testable import Angstrom

final class ModelsTests: XCTestCase {

    // MARK: - Device type decoding (the /things list)

    func testThingsDecodeDeviceType() throws {
        let json = """
        [
          { "serialNumber": "MR123", "name": "Kitchen", "modelName": "LINEA MICRA", "type": "CoffeeMachine" },
          { "serialNumber": "PG456", "name": "Pico",    "modelName": "PICOGRINDER", "type": "Grinder" },
          { "serialNumber": "ZZ789", "name": "Mystery", "modelName": "FUTURE",      "type": "SomethingNew" }
        ]
        """
        let machines = try JSONDecoder().decode([Machine].self, from: Data(json.utf8))

        XCTAssertEqual(machines[0].type, .coffeeMachine)
        XCTAssertTrue(machines[0].supportsPower)

        XCTAssertEqual(machines[1].type, .grinder)
        XCTAssertFalse(machines[1].supportsPower)

        XCTAssertEqual(machines[2].type, .other("SomethingNew"))
        XCTAssertFalse(machines[2].supportsPower)
    }

    func testMissingTypeDefaultsToCoffeeMachine() throws {
        let json = #"[{ "serialNumber": "OLD1", "name": "Legacy", "modelName": "GS3" }]"#
        let machines = try JSONDecoder().decode([Machine].self, from: Data(json.utf8))
        XCTAssertEqual(machines[0].type, .coffeeMachine)
        XCTAssertTrue(machines[0].supportsPower)
    }

    func testDeviceTypeCodableRoundTrip() throws {
        for type in [DeviceType.coffeeMachine, .grinder, .other("Foo")] {
            let machine = Machine(serialNumber: "S", type: type)
            let data = try JSONEncoder().encode(machine)
            let restored = try JSONDecoder().decode(Machine.self, from: data)
            XCTAssertEqual(restored.type, type)
        }
    }

    // MARK: - Power state parsing (the dashboard)

    private func dashboard(code: String, mode: String) -> Data {
        Data("""
        { "widgets": [ { "code": "\(code)", "output": { "mode": "\(mode)", "status": "\(mode)" } } ] }
        """.utf8)
    }

    func testCoffeeMachinePowerState() throws {
        XCTAssertEqual(try LaMarzoccoCloudClient.parsePowerState(fromDashboard: dashboard(code: "CMMachineStatus", mode: "BrewingMode")), .on)
        XCTAssertEqual(try LaMarzoccoCloudClient.parsePowerState(fromDashboard: dashboard(code: "CMMachineStatus", mode: "StandBy")), .off)
    }

    func testGrinderPowerState() throws {
        // GMachineStatus, the grinder widget that previously read as "unknown".
        XCTAssertEqual(try LaMarzoccoCloudClient.parsePowerState(fromDashboard: dashboard(code: "GMachineStatus", mode: "GrindingMode")), .on)
        XCTAssertEqual(try LaMarzoccoCloudClient.parsePowerState(fromDashboard: dashboard(code: "GMachineStatus", mode: "StandBy")), .off)
    }

    func testUnknownModeIsOther() throws {
        XCTAssertEqual(try LaMarzoccoCloudClient.parsePowerState(fromDashboard: dashboard(code: "CMMachineStatus", mode: "Brewing")), .other("Brewing"))
    }

    func testNoStatusWidgetIsUnknown() throws {
        let data = Data(#"{ "widgets": [ { "code": "CMSomethingElse", "output": {} } ] }"#.utf8)
        XCTAssertEqual(try LaMarzoccoCloudClient.parsePowerState(fromDashboard: data), .unknown)
    }

    func testMalformedDashboardThrows() {
        XCTAssertThrowsError(try LaMarzoccoCloudClient.parsePowerState(fromDashboard: Data("not json".utf8)))
    }
}
