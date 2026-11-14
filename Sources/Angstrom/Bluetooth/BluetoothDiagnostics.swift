import Foundation

/// A raw BLE frame on the diagnostic tap (`LaMarzoccoBluetoothClient.rawFrames()`).
public struct RawBluetoothFrame: Sendable, Hashable {
    public enum Direction: Sendable, Hashable { case inbound, outbound }
    public enum Kind: Sendable, Hashable { case write, read, notification, event }
    public let timestamp: Date
    public let direction: Direction
    public let kind: Kind
    /// Lowercase characteristic UUID; nil for `.event`.
    public let characteristic: String?
    /// Verbatim bytes; for `.event`, the UTF-8 marker text.
    public let data: Data
    /// True for the auth write and the token read: display layers MUST redact `data`.
    public let isSecret: Bool

    public init(timestamp: Date, direction: Direction, kind: Kind, characteristic: String?,
                data: Data, isSecret: Bool) {
        self.timestamp = timestamp
        self.direction = direction
        self.kind = kind
        self.characteristic = characteristic
        self.data = data
        self.isSecret = isSecret
    }

    // `.event` markers (exact text).
    public static let connectingMarker = "[connecting]"
    public static let connectedMarker = "[connected]"
    public static let authenticatedMarker = "[authenticated]"
    public static let disconnectedMarker = "[disconnected]"
    public static let subscribedMarker = "[subscribed]"
    public static let unsubscribedMarker = "[unsubscribed]"
    public static let replayDroppedMarker = "[replay dropped]"
    public static let servicesInvalidatedMarker = "[services invalidated]"
    /// "[mtu <n>]".
    public static func mtuMarker(_ mtu: Int) -> String { "[mtu \(mtu)]" }
}
