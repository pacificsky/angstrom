import Foundation

// MARK: - Statistics (GET /things/{serial}/stats)

/// A machine's statistics dashboard: identity plus the typed stat widgets the
/// cloud reports. Like the live dashboard, widgets are decoded resiliently — an
/// unrecognized stat code becomes ``StatWidgetKind/unknown(code:)``.
public struct ThingStatistics: Sendable, Hashable, Decodable {
    /// Device identity carried at the top of the stats payload.
    public let machine: Machine
    /// Firmware summary string the stats payload carries (often `nil`).
    public let firmwares: String?
    /// Stat widget codes the account has selected for display.
    public let selectedWidgetCodes: [String]
    /// All stat widget codes available for this machine.
    public let allWidgetCodes: [String]
    /// The selected stat widgets, decoded.
    public let widgets: [StatWidget]

    private enum CodingKeys: String, CodingKey {
        case firmwares, selectedWidgetCodes, allWidgetCodes, selectedWidgets
    }

    public init(machine: Machine, firmwares: String? = nil, selectedWidgetCodes: [String], allWidgetCodes: [String], widgets: [StatWidget]) {
        self.machine = machine
        self.firmwares = firmwares
        self.selectedWidgetCodes = selectedWidgetCodes
        self.allWidgetCodes = allWidgetCodes
        self.widgets = widgets
    }

    public init(from decoder: Decoder) throws {
        machine = try Machine(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firmwares = (try? c.decodeIfPresent(String.self, forKey: .firmwares)) ?? nil
        selectedWidgetCodes = (try? c.decode([String].self, forKey: .selectedWidgetCodes)) ?? []
        allWidgetCodes = (try? c.decode([String].self, forKey: .allWidgetCodes)) ?? []
        widgets = (try? c.decode([StatWidget].self, forKey: .selectedWidgets)) ?? []
    }

    private func first<T>(_ extract: (StatWidgetKind) -> T?) -> T? {
        for widget in widgets { if let value = extract(widget.kind) { return value } }
        return nil
    }

    /// The coffee-and-flush trend widget, if present.
    public var coffeeAndFlushTrend: CoffeeAndFlushTrend? {
        first { if case .coffeeAndFlushTrend(let v) = $0 { return v }; return nil }
    }
    /// The last-coffees widget, if present.
    public var lastCoffees: LastCoffeeList? {
        first { if case .lastCoffee(let v) = $0 { return v }; return nil }
    }
    /// The coffee-and-flush counter widget, if present.
    public var coffeeAndFlushCounter: CoffeeAndFlushCounter? {
        first { if case .coffeeAndFlushCounter(let v) = $0 { return v }; return nil }
    }

    /// Codes of stat widgets this version did not recognize.
    public var unknownWidgetCodes: [String] {
        widgets.compactMap { if case .unknown(let code) = $0.kind { return code }; return nil }
    }
}

/// One entry from a statistics `selectedWidgets` array: its `code`, `index`, and
/// decoded payload (``kind``).
public struct StatWidget: Sendable, Hashable, Decodable {
    public let code: String
    public let index: Int
    public let kind: StatWidgetKind

    private enum CodingKeys: String, CodingKey { case code, index, output }

    public init(code: String, index: Int, kind: StatWidgetKind) {
        self.code = code
        self.index = index
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = (try? c.decode(String.self, forKey: .code)) ?? ""
        self.code = code
        self.index = (try? c.decode(Int.self, forKey: .index)) ?? 0
        func output<T: Decodable>(_ type: T.Type) -> T? { try? c.decode(T.self, forKey: .output) }
        switch code {
        case "COFFEE_AND_FLUSH_TREND": if let v = output(CoffeeAndFlushTrend.self) { self.kind = .coffeeAndFlushTrend(v); return }
        case "LAST_COFFEE": if let v = output(LastCoffeeList.self) { self.kind = .lastCoffee(v); return }
        case "COFFEE_AND_FLUSH_COUNTER": if let v = output(CoffeeAndFlushCounter.self) { self.kind = .coffeeAndFlushCounter(v); return }
        default: break
        }
        self.kind = .unknown(code: code)
    }
}

/// The decoded payload of a ``StatWidget``.
public enum StatWidgetKind: Sendable, Hashable {
    case coffeeAndFlushTrend(CoffeeAndFlushTrend)
    case lastCoffee(LastCoffeeList)
    case coffeeAndFlushCounter(CoffeeAndFlushCounter)
    /// A stat widget code this version doesn't model, or whose payload failed to decode.
    case unknown(code: String)
}

// MARK: - Stat widget payloads

/// Daily coffee and flush counts over a window of days.
public struct CoffeeAndFlushTrend: Sendable, Hashable, Decodable {
    public let days: Int
    public let timezone: String
    public let coffees: [TrendPoint]
    /// Daily flush counts. The cloud reports these alongside `coffees` even
    /// though pylamarzocco's model omits them.
    public let flushes: [TrendPoint]

    private enum CodingKeys: String, CodingKey { case days, timezone, coffees, flushes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = (try? c.decode(Int.self, forKey: .days)) ?? 0
        timezone = (try? c.decode(String.self, forKey: .timezone)) ?? ""
        coffees = (try? c.decode([TrendPoint].self, forKey: .coffees)) ?? []
        flushes = (try? c.decode([TrendPoint].self, forKey: .flushes)) ?? []
    }
}

/// A single daily data point in a ``CoffeeAndFlushTrend``.
public struct TrendPoint: Sendable, Hashable, Decodable {
    public let timestamp: Date
    public let value: Int
}

/// The most recent coffees pulled, newest first.
public struct LastCoffeeList: Sendable, Hashable, Decodable {
    public let lastCoffees: [LastCoffee]

    private enum CodingKeys: String, CodingKey { case lastCoffees }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entries = (try? c.decode([Lenient<LastCoffee>].self, forKey: .lastCoffees)) ?? []
        lastCoffees = entries.compactMap(\.value)
    }
}

/// One past coffee extraction.
public struct LastCoffee: Sendable, Hashable, Decodable {
    public let time: Date
    public let extractionSeconds: Double
    public let doseMode: DoseMode
    public let doseIndex: DoseIndex
    public let doseValueNumerator: String?

    private enum CodingKeys: String, CodingKey {
        case time, extractionSeconds, doseMode, doseIndex, doseValueNumerator
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Date.self, forKey: .time)
        extractionSeconds = (try? c.decode(Double.self, forKey: .extractionSeconds)) ?? 0
        doseMode = try c.decode(DoseMode.self, forKey: .doseMode)
        doseIndex = try c.decode(DoseIndex.self, forKey: .doseIndex)
        doseValueNumerator = (try? c.decodeIfPresent(String.self, forKey: .doseValueNumerator)) ?? nil
    }
}

/// Lifetime coffee and flush totals.
public struct CoffeeAndFlushCounter: Sendable, Hashable, Decodable {
    public let totalCoffee: Int
    public let totalFlush: Int
}

// MARK: - Endpoints

extension LaMarzoccoCloudClient {
    /// Fetch a machine's statistics dashboard (`GET /things/{serial}/stats`).
    public func statistics(serial: String) async throws -> ThingStatistics {
        let data = try await authed(path: "/things/\(serial)/stats", method: "GET")
        do {
            return try JSONDecoder.laMarzocco().decode(ThingStatistics.self, from: data)
        } catch {
            throw LaMarzoccoError.decoding("stats: \(error)")
        }
    }

    /// Fetch the coffee-and-flush trend for the last `days` days.
    public func coffeeAndFlushTrend(serial: String, days: Int, timezone: String) async throws -> CoffeeAndFlushTrend {
        try await extendedStat(serial: serial, widget: "COFFEE_AND_FLUSH_TREND",
                               query: [("days", "\(days)"), ("timezone", timezone)])
    }

    /// Fetch the most recent coffees over the last `days` days.
    public func lastCoffees(serial: String, days: Int) async throws -> LastCoffeeList {
        try await extendedStat(serial: serial, widget: "LAST_COFFEE", query: [("days", "\(days)")])
    }

    /// Fetch lifetime coffee and flush counters.
    public func coffeeAndFlushCounter(serial: String) async throws -> CoffeeAndFlushCounter {
        try await extendedStat(serial: serial, widget: "COFFEE_AND_FLUSH_COUNTER")
    }

    /// The extended-statistics endpoints return `{ "output": … }` under a fixed
    /// `/stats/{WIDGET}/1` path; this unwraps `output` and decodes it.
    private func extendedStat<T: Decodable>(
        serial: String, widget: String, query: [(String, String)] = []
    ) async throws -> T {
        var path = "/things/\(serial)/stats/\(widget)/1"
        if !query.isEmpty {
            var comps = URLComponents()
            comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            if let encoded = comps.percentEncodedQuery { path += "?\(encoded)" }
        }
        let data = try await authed(path: path, method: "GET")
        do {
            return try JSONDecoder.laMarzocco().decode(StatOutput<T>.self, from: data).output
        } catch {
            throw LaMarzoccoError.decoding("stats \(widget): \(error)")
        }
    }
}

/// Wrapper for the `{ "output": … }` envelope on extended-statistics responses.
private struct StatOutput<T: Decodable>: Decodable { let output: T }
