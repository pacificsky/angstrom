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
    private static func emit<T: Encodable>(_ value: T) {
        // ms-epoch dates, matching the wire format, so a decoded push round-trips.
        // A fresh encoder per line keeps this trivially concurrency-safe across
        // the raw and decoded printer tasks (cost is negligible for a debug tool).
        let encoder = JSONEncoder.laMarzocco()
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            Stderr.log("· (failed to encode a frame for output)")
            return
        }
        Stdout.line(string)
    }

    /// Drain the raw-frame tap, printing every frame in both directions.
    static func printRaw(_ stream: AsyncStream<RawFrame>) async {
        for await frame in stream {
            emit(RawLine(ts: Timestamp.now(), dir: frame.direction.arrow, raw: frame.text))
        }
    }

    /// Drain the decoded-update stream, printing Angstrom's view of each push.
    static func printDecoded(_ stream: AsyncStream<DashboardUpdate>) async {
        for await update in stream {
            emit(DecodedLine(ts: Timestamp.now(), dir: "<<", decoded: update))
        }
    }
}

// MARK: - Pretty JSON (for `dump`)

enum PrettyJSON {
    /// Pretty-print verbatim JSON bytes, sorting keys for a stable, diffable
    /// shape and leaving slashes unescaped for readable URLs. Falls back to the
    /// raw UTF-8 if the bytes aren't valid JSON.
    static func string(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8)
        else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return string
    }
}
