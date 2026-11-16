import Foundation
/// Not public: only targets in this package can see or implement it.
package protocol BluetoothCentral: Sendable {
    func scanNames(for seconds: Double) async throws -> [String]
}
/// Public, opaque handle a consumer passes to the client.
public struct BluetoothTransport: Sendable {
    package let central: any BluetoothCentral
    package init(central: any BluetoothCentral) { self.central = central }
}
public actor BluetoothClient {
    let central: any BluetoothCentral
    public init(transport: BluetoothTransport) { central = transport.central }
    public func discover() async throws -> [String] {
        try await central.scanNames(for: 5).filter { $0.hasPrefix("MICRA") || $0.hasPrefix("MINI") || $0.hasPrefix("LINEA") || $0.hasPrefix("GS3") }
    }
}
