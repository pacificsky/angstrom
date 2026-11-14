import Foundation

/// REC, copied verbatim to Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt.
package enum ShotCounterRecording {
    package struct Line: Sendable { package let receivedAt: Date; package let payload: Data; package let isReplay: Bool }

    /// Ports `_load_sessions` (TBC:894-909): skip lines starting with `#` (file comments, REC:1-5); split
    /// each other line at the first space into `HH:MM:SS.fff` (UTC, 2026-10-05) and payload. A payload
    /// ending in `# replay` starts a new session; its first Line is that payload with the suffix removed
    /// and whitespace stripped (`isReplay == true`). Every other line appends to the current session.
    package static func sessions() throws -> [[Line]] {
        guard let url = Bundle.module.url(forResource: "shot_counter_2026-10-05", withExtension: "txt",
                                          subdirectory: "Fixtures") else {
            throw RecordingError("missing fixture Fixtures/shot_counter_2026-10-05.txt")
        }
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw RecordingError("fixture is not UTF-8")
        }
        var sessions: [[Line]] = []
        // `str.splitlines()`; a Swift `Character` treats "\r\n" as one newline.
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") { continue }
            // `line.split(" ", 1)`
            guard let space = line.firstIndex(of: " ") else {
                throw RecordingError("line without a payload: \(line)")
            }
            let receivedAt = try timestamp(line[..<space])
            let payload = line[line.index(after: space)...]
            if payload.hasSuffix(replaySuffix) {
                // `payload.removesuffix("# replay").strip().encode()`
                let replay = payload.dropLast(replaySuffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                sessions.append([Line(receivedAt: receivedAt, payload: Data(replay.utf8), isReplay: true)])
            } else {
                guard !sessions.isEmpty else {
                    throw RecordingError("notification before the first replay: \(line)")
                }
                sessions[sessions.count - 1].append(Line(receivedAt: receivedAt, payload: Data(payload.utf8),
                                                         isReplay: false))
            }
        }
        return sessions
    }

    private static let replaySuffix = "# replay"

    /// 2026-10-05T00:00:00Z — the recording's day (`date(2026, 10, 5)`, combined in UTC).
    private static let day = Date(timeIntervalSince1970: 1_791_158_400)

    /// `datetime.strptime(time, "%H:%M:%S.%f")` combined with the day in UTC. `%f` takes 1–6 digits,
    /// right-padded to microseconds.
    private static func timestamp(_ text: Substring) throws -> Date {
        func number(_ field: Substring, maxDigits: Int) -> Int? {
            guard (1...maxDigits).contains(field.count),
                  field.allSatisfy({ $0.isASCII && $0.isWholeNumber }) else { return nil }
            return Int(field)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hours = number(parts[0], maxDigits: 2), let minutes = number(parts[1], maxDigits: 2),
              (0..<24).contains(hours), (0..<60).contains(minutes) else {
            throw RecordingError("bad time: \(text)")
        }
        let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard secondParts.count == 2,
              let seconds = number(secondParts[0], maxDigits: 2), (0..<62).contains(seconds),
              let digits = number(secondParts[1], maxDigits: 6) else {
            throw RecordingError("bad time: \(text)")
        }
        let fraction = secondParts[1]
        var micros = digits
        for _ in fraction.count..<6 { micros *= 10 }
        let totalMicros = ((hours * 60 + minutes) * 60 + seconds) * 1_000_000 + micros
        return day.addingTimeInterval(Double(totalMicros) / 1_000_000)
    }

    private struct RecordingError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
