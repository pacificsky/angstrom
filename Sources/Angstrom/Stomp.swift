import Foundation

/// Minimal STOMP 1.2 frame codec for the La Marzocco websocket.
///
/// Ported from `pylamarzocco` (`util/_websocket.py`). Frame wire format is
/// `COMMAND\n` + `key:value\n` lines + a blank line + optional body + a NUL
/// terminator. Exactness here is load-bearing — verified in `StompTests`.
enum Stomp {
    enum Command: String {
        case connect = "CONNECT"
        case connected = "CONNECTED"
        case subscribe = "SUBSCRIBE"
        case unsubscribe = "UNSUBSCRIBE"
        case message = "MESSAGE"
        case error = "ERROR"
    }

    struct Frame: Equatable {
        let command: String
        let headers: [String: String]
        let body: String?
    }

    /// Encode a frame. Headers are an ordered list so the wire output is
    /// deterministic (matching the reference's insertion-ordered dict).
    static func encode(_ command: Command, headers: [(String, String)], body: String? = nil) -> String {
        var message = command.rawValue
        for (key, value) in headers { message += "\n\(key):\(value)" }
        message += "\n\n"
        if let body { message += body }
        message += "\u{00}"
        return message
    }

    /// Decode a frame: split on the first blank line into headers/body, parse
    /// the command + `key:value` headers (split on the first `:` only), and
    /// strip the trailing NUL from the body.
    static func decode(_ message: String) -> Frame? {
        guard let separator = message.range(of: "\n\n") else { return nil }
        let headerSection = message[message.startIndex..<separator.lowerBound]
        var body = String(message[separator.upperBound...])
        if body.hasSuffix("\u{00}") { body.removeLast() }

        let lines = headerSection.split(separator: "\n", omittingEmptySubsequences: false)
        guard let command = lines.first.map(String.init), !command.isEmpty else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[line.startIndex..<colon])] = String(line[line.index(after: colon)...])
        }
        return Frame(command: command, headers: headers, body: body.isEmpty ? nil : body)
    }
}
