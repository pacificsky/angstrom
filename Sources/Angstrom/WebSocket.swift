import Foundation

// MARK: - Transport abstraction

/// A bidirectional text channel — the seam between the client's STOMP logic and
/// the underlying websocket, so the handshake/confirmation flow is testable
/// without a real socket.
protocol WebSocketChannel: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// Await the next text frame; throws when the socket closes or errors.
    func receive() async throws -> String
    func sendPing() async throws
    func close()
}

/// `URLSessionWebSocketTask`-backed channel.
final class URLSessionWebSocketChannel: WebSocketChannel, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func sendPing() async throws {
        // `URLSessionWebSocketTask.sendPing` can invoke its handler **more than
        // once** when the connection aborts mid-flight — it fires for the send
        // failure and again as the socket tears down. Resuming a checked
        // continuation twice is a fatal error (`SWIFT TASK CONTINUATION MISUSE`),
        // so latch to a single resume and drop any later callbacks.
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                guard once.claim() else { return }
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

/// A one-shot latch: ``claim()`` returns `true` exactly once across all threads.
/// Guards a continuation against framework callbacks that fire more than once.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - Connection events

/// A websocket connection transition, delivered on
/// ``LaMarzoccoCloudClient/connectionEvents()``. `.connected` fires after every
/// successful subscribe — the initial connection *and* each automatic
/// reconnect — and `.disconnected` when the connection is lost or torn down.
public enum ConnectionEvent: Sendable, Hashable {
    case connected
    case disconnected
}

// MARK: - Pushed dashboard update

/// A dashboard update pushed over the websocket. Carries the same typed widget
/// schema as ``Dashboard`` plus the websocket-only envelope: which widgets were
/// removed, and any ``commands`` results (used to confirm pending commands).
public struct DashboardUpdate: Sendable, Hashable, Codable {
    public let connected: Bool
    public let widgets: [Widget]
    /// Widgets the machine dropped since the last update (code + group index).
    public let removedWidgets: [RemovedWidget]
    /// Results for in-flight commands delivered in this frame.
    public let commands: [CommandResponse]
    public let connectionDate: Date?
    public let uuid: String?

    /// Codes of removed widgets (convenience over ``removedWidgets``).
    public var removedWidgetCodes: [String] { removedWidgets.map(\.code) }

    private enum CodingKeys: String, CodingKey {
        case connected, widgets, removedWidgets, commands, connectionDate, uuid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = (try? c.decode(Bool.self, forKey: .connected)) ?? false
        widgets = (try? c.decode([Widget].self, forKey: .widgets)) ?? []
        let removed = (try? c.decode([Lenient<RemovedWidget>].self, forKey: .removedWidgets)) ?? []
        removedWidgets = removed.compactMap(\.value)
        let cmds = (try? c.decode([Lenient<CommandResponse>].self, forKey: .commands)) ?? []
        commands = cmds.compactMap(\.value)
        connectionDate = (try? c.decodeIfPresent(Date.self, forKey: .connectionDate)) ?? nil
        uuid = (try? c.decodeIfPresent(String.self, forKey: .uuid)) ?? nil
    }

    /// Re-encode the update back to its wire shape. Provided so diagnostic tools
    /// (e.g. the `angcli` debugger) can serialize the decoded push to JSON;
    /// recognized widgets round-trip, while `.unknown` widgets keep their
    /// code/index but lose the raw `output` they couldn't decode.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connected, forKey: .connected)
        try c.encode(widgets, forKey: .widgets)
        try c.encode(removedWidgets, forKey: .removedWidgets)
        try c.encode(commands, forKey: .commands)
        try c.encodeIfPresent(connectionDate, forKey: .connectionDate)
        try c.encodeIfPresent(uuid, forKey: .uuid)
    }
}

/// A widget removed in a ``DashboardUpdate``, identified by code + group index.
public struct RemovedWidget: Sendable, Hashable, Codable {
    public let code: String
    public let index: Int
}

extension Dashboard {
    /// Return a new dashboard with `update` applied: widgets are replaced by
    /// `(code, index)`, removed widgets are dropped, and new widgets appended —
    /// preserving existing order. The machine identity is retained, except for
    /// connectivity: ``Machine/isConnected`` takes the push's `connected` flag
    /// (every routine push carries `true`, so this self-heals in both
    /// directions) and ``Machine/connectionDate`` is updated when the push
    /// carries one.
    ///
    /// This **intentionally diverges** from pylamarzocco's
    /// `_websocket_dashboard_update_received`, which replaces the whole
    /// dashboard config on push — including `connected` — and ignores
    /// `removedWidgets`. That relies on every push being a complete snapshot; the
    /// incremental merge here honors the protocol's explicit `removedWidgets`
    /// envelope and tolerates a partial frame without dropping widgets the push
    /// didn't mention. Both behave identically on a full-snapshot push, and the
    /// connectivity flag flows through either way.
    public func applying(_ update: DashboardUpdate) -> Dashboard {
        func key(_ widget: Widget) -> String { "\(widget.code)#\(widget.index)" }

        var order = widgets.map(key)
        var byKey: [String: Widget] = [:]
        for widget in widgets { byKey[key(widget)] = widget }

        for widget in update.widgets {
            let k = key(widget)
            if byKey[k] == nil { order.append(k) }
            byKey[k] = widget
        }
        for removed in update.removedWidgets {
            let k = "\(removed.code)#\(removed.index)"
            order.removeAll { $0 == k }
            byKey[k] = nil
        }
        var machine = machine
        machine.isConnected = update.connected
        if let connectionDate = update.connectionDate { machine.connectionDate = connectionDate }
        return Dashboard(machine: machine, widgets: order.compactMap { byKey[$0] })
    }
}
