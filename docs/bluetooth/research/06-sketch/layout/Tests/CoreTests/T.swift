import Testing
@testable import Core
struct Fake: BluetoothCentral { func scanNames(for seconds: Double) async throws -> [String] { ["MICRA_X", "Speaker", "GS3_Y"] } }
@Test func filters() async throws {
    let c = BluetoothClient(transport: BluetoothTransport(central: Fake()))
    #expect(try await c.discover() == ["MICRA_X", "GS3_Y"])
}
