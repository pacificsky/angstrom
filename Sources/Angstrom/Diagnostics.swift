import Foundation

// MARK: - Raw-frame tap (diagnostic)

/// A raw websocket frame captured at the transport boundary, in either
/// direction. This is a **diagnostic** surface for wire-debugging tools (e.g.
/// the in-repo `angcli`): the normal app path consumes the decoded
/// ``DashboardUpdate`` stream from ``LaMarzoccoCloudClient/dashboardUpdates()``.
///
/// See ``LaMarzoccoCloudClient/rawFrames()`` for how these are produced.
public struct RawFrame: Sendable, Hashable {
    /// Which way the frame travelled relative to the client.
    public enum Direction: Sendable, Hashable {
        /// Received from the server (emitted before STOMP decoding, so
        /// heartbeats, non-`MESSAGE` frames, and undecodable bodies all surface).
        case inbound
        /// Sent by the client (the STOMP handshake, subscribe/unsubscribe, and
        /// websocket heartbeat pings).
        case outbound
    }

    public let direction: Direction
    /// The verbatim frame text (STOMP framing included). Heartbeat pings and
    /// pongs, which carry no STOMP text, surface as the synthetic markers
    /// ``heartbeatMarker`` / ``pongMarker``.
    public let text: String

    public init(direction: Direction, text: String) {
        self.direction = direction
        self.text = text
    }

    /// Synthetic text emitted for an outbound websocket heartbeat ping (which has
    /// no STOMP frame of its own), so heartbeat activity is visible on the tap.
    public static let heartbeatMarker = "[heartbeat: websocket ping]"

    /// Synthetic inbound text emitted when a heartbeat ping's pong arrives
    /// within its deadline. The pong is a websocket control frame consumed
    /// inside the transport — it never surfaces as a text frame — so this
    /// marker is the tap's only direct liveness evidence: ping marker with no
    /// pong marker means the round-trip failed (and the connection is about to
    /// be torn down for reconnect).
    public static let pongMarker = "[heartbeat: websocket pong]"
}

// MARK: - Raw REST read (diagnostic)

/// A thing-scoped REST endpoint whose **verbatim** JSON body can be fetched with
/// ``LaMarzoccoCloudClient/rawRead(_:serial:)``, bypassing Angstrom's typed
/// decoding. Diagnostic only — apps should prefer the typed reads
/// (``LaMarzoccoCloudClient/dashboard(serial:)`` etc.), which this mirrors.
public enum RawEndpoint: String, Sendable, CaseIterable {
    case dashboard
    case settings
    case schedule

    /// The REST path component the cloud uses for this endpoint.
    var path: String {
        switch self {
        case .dashboard: "dashboard"
        case .settings: "settings"
        case .schedule: "scheduling"
        }
    }
}
