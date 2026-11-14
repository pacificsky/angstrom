#if canImport(CoreBluetooth)
import CoreBluetooth
import Core
final class CBCentralAdapter: BluetoothCentral, @unchecked Sendable {
    func scanNames(for seconds: Double) async throws -> [String] { [] }
}
extension BluetoothTransport {
    /// The only public symbol this module adds.
    public static func coreBluetooth() -> BluetoothTransport { BluetoothTransport(central: CBCentralAdapter()) }
}
#endif
