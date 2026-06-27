import XCTest
@testable import Angstrom

/// Decodes the captured `/stats` payload and exercises the extended-statistics
/// endpoints (trend / last-coffee / counter), verifying typed decode + paths.
final class StatisticsTests: XCTestCase {

    private func statsBackend() throws -> MockBackend {
        let stats = try Fixture.data("statistics")
        // The extended endpoints return their widget output wrapped in `output`.
        let trend = try wrap(extract(stats, code: "COFFEE_AND_FLUSH_TREND"))
        let lastCoffee = try wrap(extract(stats, code: "LAST_COFFEE"))
        let counter = try wrap(extract(stats, code: "COFFEE_AND_FLUSH_COUNTER"))
        let backend = MockBackend()
        backend.onRequest { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/init") { return .json([:]) }
            if path.hasSuffix("/auth/signin") { return .json(["accessToken": "a", "refreshToken": "r"]) }
            if path.contains("/stats/COFFEE_AND_FLUSH_TREND/") { return MockBackend.Reply(status: 200, body: trend) }
            if path.contains("/stats/LAST_COFFEE/") { return MockBackend.Reply(status: 200, body: lastCoffee) }
            if path.contains("/stats/COFFEE_AND_FLUSH_COUNTER/") { return MockBackend.Reply(status: 200, body: counter) }
            if path.hasSuffix("/stats") { return MockBackend.Reply(status: 200, body: stats) }
            return MockBackend.Reply(status: 404)
        }
        return backend
    }

    /// Pull a stat widget's `output` object out of the `/stats` fixture.
    private func extract(_ data: Data, code: String) throws -> [String: Any] {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let widgets = try XCTUnwrap(obj["selectedWidgets"] as? [[String: Any]])
        let widget = try XCTUnwrap(widgets.first { $0["code"] as? String == code })
        return try XCTUnwrap(widget["output"] as? [String: Any])
    }

    private func wrap(_ output: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["output": output])
    }

    private func client(_ backend: MockBackend) -> LaMarzoccoCloudClient {
        LaMarzoccoCloudClient(username: "u", password: "p", installationKey: .generate(),
                              urlSession: MockURLProtocol.session(backend: backend))
    }

    // MARK: - /stats dashboard

    func testStatisticsDashboardDecodes() throws {
        let stats = try JSONDecoder.laMarzocco().decode(ThingStatistics.self, from: Fixture.data("statistics"))
        XCTAssertEqual(stats.machine.serialNumber, "MR123456")
        XCTAssertEqual(stats.machine.model, .lineaMicra)
        XCTAssertNil(stats.firmwares) // present but null in the fixture
        XCTAssertEqual(stats.unknownWidgetCodes, [])
        XCTAssertEqual(Set(stats.selectedWidgetCodes), ["COFFEE_AND_FLUSH_TREND", "LAST_COFFEE"])

        XCTAssertEqual(stats.coffeeAndFlushTrend?.days, 7)
        XCTAssertEqual(stats.coffeeAndFlushTrend?.timezone, "Europe/Berlin")
        XCTAssertEqual(stats.coffeeAndFlushTrend?.coffees.count, 7)
        XCTAssertEqual(stats.coffeeAndFlushTrend?.flushes.count, 7)
        XCTAssertEqual(stats.coffeeAndFlushTrend?.coffees.last?.value, 1)

        XCTAssertFalse(stats.lastCoffees?.lastCoffees.isEmpty ?? true)
        XCTAssertEqual(stats.lastCoffees?.lastCoffees.first?.doseMode, .continuous)

        XCTAssertEqual(stats.coffeeAndFlushCounter?.totalCoffee, 1620)
        XCTAssertEqual(stats.coffeeAndFlushCounter?.totalFlush, 1366)
    }

    // MARK: - Extended endpoints

    func testCoffeeAndFlushTrendEndpoint() async throws {
        let backend = try statsBackend()
        let trend = try await client(backend).coffeeAndFlushTrend(serial: "SN1", days: 7, timezone: "Europe/Berlin")
        XCTAssertEqual(trend.coffees.count, 7)
        // Path carries the trailing `/1` and percent-encoded query.
        let path = backend.recordedPaths.last { $0.contains("/stats/COFFEE_AND_FLUSH_TREND/") }
        XCTAssertNotNil(path)
        XCTAssertTrue(path?.hasSuffix("/1") ?? false, "expected the trailing /1 segment")
    }

    func testLastCoffeeEndpoint() async throws {
        let backend = try statsBackend()
        let list = try await client(backend).lastCoffees(serial: "SN1", days: 7)
        XCTAssertFalse(list.lastCoffees.isEmpty)
    }

    func testCounterEndpoint() async throws {
        let backend = try statsBackend()
        let counter = try await client(backend).coffeeAndFlushCounter(serial: "SN1")
        XCTAssertEqual(counter.totalCoffee, 1620)
        XCTAssertEqual(counter.totalFlush, 1366)
    }
}
