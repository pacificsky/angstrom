import Foundation

extension LaMarzoccoCloudClient {
    /// The machine's Bluetooth token from `GET /things` (`bleAuthToken`); nil when the cloud has none.
    public func bluetoothAuthToken(serial: String) async throws -> BluetoothAuthToken? {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-06")
    }
}
