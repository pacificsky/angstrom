import Foundation

extension LaMarzoccoCloudClient {
    /// The machine's Bluetooth token from `GET /things` (`bleAuthToken`); nil when the cloud has none.
    ///
    /// Reads the top-level `bleAuthToken` of the first thing whose `serialNumber` equals `serial`
    /// (upstream `Thing.ble_auth_token`). A non-empty string becomes a ``BluetoothAuthToken``;
    /// `null`, an absent key or `""` yield `nil`. The value is never logged or printed.
    ///
    /// - Throws: ``LaMarzoccoError/decoding(_:)`` with `"things shape"` when the body is not an
    ///   array of objects, or `"things: no thing with serial <serial>"` when no thing matches;
    ///   otherwise whatever the authenticated request throws.
    public func bluetoothAuthToken(serial: String) async throws -> BluetoothAuthToken? {
        let data = try await authed(path: "/things", method: "GET")
        guard let things = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw LaMarzoccoError.decoding("things shape")
        }
        guard let thing = things.first(where: { ($0["serialNumber"] as? String) == serial }) else {
            throw LaMarzoccoError.decoding("things: no thing with serial \(serial)")
        }
        guard let raw = thing["bleAuthToken"] as? String, !raw.isEmpty else { return nil }
        return BluetoothAuthToken(raw)
    }
}
