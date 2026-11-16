/// The machine's Bluetooth auth token. Opaque; prints and reflects as redacted; NOT Codable —
/// the library never persists it. Store `rawValue` in the Keychain yourself.
///
/// `description`, `debugDescription` and the reflection mirror never contain the token, so string
/// interpolation, `print`, `dump` and `String(reflecting:)` are all safe. Only ``rawValue`` exposes it.
public struct BluetoothAuthToken: Sendable, Hashable, CustomStringConvertible,
                                  CustomDebugStringConvertible, CustomReflectable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { "**REDACTED**" }
    public var debugDescription: String { "BluetoothAuthToken(**REDACTED**)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
