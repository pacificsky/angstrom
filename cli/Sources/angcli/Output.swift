import Foundation
import Angstrom

// MARK: - Streams

/// Line-buffered stdout. The raw and decoded printers run concurrently, so a
/// lock guarantees each JSON line is written whole (no interleaved bytes).
enum Stdout {
    private static let lock = NSLock()
    static func line(_ string: String) {
        let data = Data((string + "\n").utf8)
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardOutput.write(data)
    }
}

/// Status, connection lifecycle, and errors go to stderr so stdout stays a
/// clean, jq-friendly stream of frame JSON.
enum Stderr {
    private static let lock = NSLock()
    static func log(_ string: String) { write(string + "\n") }
    static func prompt(_ string: String) { write(string) }
    private static func write(_ string: String) {
        let data = Data(string.utf8)
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(data)
    }
}

// MARK: - Timestamps

enum Timestamp {
    // ISO8601DateFormatter isn't Sendable and `now()` is called from concurrent
    // printer tasks, so a lock guards the shared, immutably-configured instance.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let lock = NSLock()
    static func now() -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: Date())
    }
}

// MARK: - Frame lines

/// One verbatim frame: `{ts, dir, raw}`. `dir` is `>>` (outbound) / `<<` (inbound).
private struct RawLine: Encodable {
    let ts: String
    let dir: String
    let raw: String
}

/// One decoded push: `{ts, dir, decoded}` where `decoded` is the re-encoded
/// ``DashboardUpdate``. Decoded pushes are always inbound (`<<`).
private struct DecodedLine: Encodable {
    let ts: String
    let dir: String
    let decoded: DashboardUpdate
}

extension RawFrame.Direction {
    /// `>>` for outbound (client→server), `<<` for inbound (server→client).
    var arrow: String { self == .outbound ? ">>" : "<<" }
}

/// Renders frames as single-line JSON to stdout.
enum FramePrinter {
    private static func encodeLine<T: Encodable>(_ value: T) -> String? {
        // ms-epoch dates, matching the wire format, so a decoded push round-trips.
        // A fresh encoder per line keeps this trivially concurrency-safe across
        // the raw and decoded printer tasks (cost is negligible for a debug tool).
        let encoder = JSONEncoder.laMarzocco()
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func emit(_ line: String?) {
        guard let line else {
            Stderr.log("· (failed to encode a frame for output)")
            return
        }
        Stdout.line(line)
    }

    /// The stdout line for one raw frame, secrets masked (see ``Redact``).
    static func rawLine(_ frame: RawFrame, ts: String = Timestamp.now()) -> String? {
        encodeLine(RawLine(ts: ts, dir: frame.direction.arrow, raw: Redact.secrets(in: frame.text)))
    }

    /// Drain the raw-frame tap, printing every frame in both directions.
    static func printRaw(_ stream: AsyncStream<RawFrame>) async {
        for await frame in stream {
            emit(rawLine(frame))
        }
    }

    /// Drain the decoded-update stream, printing Angstrom's view of each push.
    static func printDecoded(_ stream: AsyncStream<DashboardUpdate>) async {
        for await update in stream {
            emit(encodeLine(DecodedLine(ts: Timestamp.now(), dir: "<<", decoded: update)))
        }
    }
}

// MARK: - Pretty JSON (for `dump`)

enum PrettyJSON {
    /// Pretty-print verbatim JSON bytes, sorting keys for a stable, diffable
    /// shape and leaving slashes unescaped for readable URLs. Falls back to the
    /// raw UTF-8 if the bytes aren't valid JSON.
    /// Secrets are masked (see ``Redact``).
    static func string(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8)
        else {
            return Redact.secrets(in: String(data: data, encoding: .utf8) ?? "")
        }
        return Redact.secrets(in: string)
    }
}

// MARK: - Redaction

/// Masks credentials before verbatim wire text reaches stdout. The library's
/// `rawRead`/`rawFrames` stay verbatim; masking happens here, at the display
/// boundary, for two secrets:
///
/// - **The STOMP `CONNECT` bearer token.** The handshake frame carries
///   `Authorization:Bearer <accessToken>`, and `listen` taps outbound frames
///   from before the connect, so it would otherwise print the account's access
///   token on every (re)connect.
/// - **`bleAuthToken`.** Dashboard, settings, and schedule payloads are `Thing`s,
///   which carry the machine's Bluetooth auth token, both at the top level and
///   nested in `coffeeStation`. This mirrors pylamarzocco v2.5.2's
///   `_mask_bluetooth_token`, which masks it in debug logs. Upstream masks any
///   truthy value; the field is typed `str | None`, so this masks non-empty
///   string values only. `null` and `""` pass through (as upstream), keeping the
///   payload shape visible.
///
/// `dump` and `listen` output gets pasted into issues and `UPSTREAM.md`
/// captures, so both must be safe to share.
enum Redact {
    static let placeholder = "**REDACTED**"

    static func secrets(in text: String) -> String {
        bearerToken(in: bleAuthToken(in: text))
    }

    static func bleAuthToken(in text: String) -> String {
        // A JSON string value: any run of non-quote/non-backslash chars or escapes.
        replace(in: text, ifContains: "bleAuthToken",
                pattern: #""bleAuthToken"(\s*):(\s*)"(?:[^"\\]|\\.)+""#,
                template: "\"bleAuthToken\"$1:$2\"\(placeholder)\"")
    }

    static func bearerToken(in text: String) -> String {
        // A STOMP header line (`name:value`, value up to end of line).
        replace(in: text, ifContains: "Bearer",
                pattern: #"(?mi)^(authorization:[ \t]*bearer[ \t]+)[^\r\n]+"#,
                template: "$1\(placeholder)")
    }

    private static func replace(in text: String, ifContains marker: String,
                                pattern: String, template: String) -> String {
        guard text.localizedCaseInsensitiveContains(marker),
              let regex = try? NSRegularExpression(pattern: pattern)
        else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
