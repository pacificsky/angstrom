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
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

// MARK: - Pushed dashboard update

/// A dashboard update pushed over the websocket. Carries the same typed widget
/// schema as ``Dashboard`` plus the websocket-only envelope: which widgets were
/// removed, and any ``commands`` results (used to confirm pending commands).
public struct DashboardUpdate: Sendable, Hashable, Decodable {
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
}

/// A widget removed in a ``DashboardUpdate``, identified by code + group index.
public struct RemovedWidget: Sendable, Hashable, Decodable {
    public let code: String
    public let index: Int
}

extension Dashboard {
    /// Return a new dashboard with `update` applied: widgets are replaced by
    /// `(code, index)`, removed widgets are dropped, and new widgets appended —
    /// preserving existing order. The machine identity is retained.
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
        return Dashboard(machine: machine, widgets: order.compactMap { byKey[$0] })
    }
}
