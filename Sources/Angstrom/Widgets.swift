import Foundation

// MARK: - Dashboard

/// A machine's decoded dashboard: its identity plus the typed widgets the cloud
/// reports for it. The same widget schema is returned by the REST `/dashboard`
/// endpoint and pushed over the websocket.
///
/// Widgets are decoded resiliently — an unrecognized widget code, or one whose
/// payload this version can't decode, becomes ``WidgetKind/unknown(code:)``
/// rather than failing the whole dashboard.
public struct Dashboard: Sendable, Hashable, Decodable {
    /// Device identity carried at the top of the dashboard payload.
    public let machine: Machine
    /// The machine's widgets, in the order the cloud returned them.
    public let widgets: [Widget]

    private enum CodingKeys: String, CodingKey { case widgets }

    public init(machine: Machine, widgets: [Widget]) {
        self.machine = machine
        self.widgets = widgets
    }

    public init(from decoder: Decoder) throws {
        machine = try Machine(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        widgets = (try? c.decode([Widget].self, forKey: .widgets)) ?? []
    }

    private func first<T>(_ extract: (WidgetKind) -> T?) -> T? {
        for widget in widgets { if let value = extract(widget.kind) { return value } }
        return nil
    }

    public var machineStatus: MachineStatus? { first { if case .machineStatus(let v) = $0 { return v }; return nil } }
    public var coffeeBoiler: CoffeeBoiler? { first { if case .coffeeBoiler(let v) = $0 { return v }; return nil } }
    public var steamBoilerLevel: SteamBoilerLevel? { first { if case .steamBoilerLevel(let v) = $0 { return v }; return nil } }
    public var steamBoilerTemperature: SteamBoilerTemperature? { first { if case .steamBoilerTemperature(let v) = $0 { return v }; return nil } }
    public var preExtraction: PreExtraction? { first { if case .preExtraction(let v) = $0 { return v }; return nil } }
    public var preBrewing: PreBrewing? { first { if case .preBrewing(let v) = $0 { return v }; return nil } }
    public var backFlush: BackFlush? { first { if case .backFlush(let v) = $0 { return v }; return nil } }
    public var groupDoses: GroupDoses? { first { if case .groupDoses(let v) = $0 { return v }; return nil } }
    public var hotWaterDose: HotWaterDose? { first { if case .hotWaterDose(let v) = $0 { return v }; return nil } }
    public var brewByWeightDoses: BrewByWeightDoses? { first { if case .brewByWeightDoses(let v) = $0 { return v }; return nil } }
    public var rinseFlush: RinseFlush? { first { if case .rinseFlush(let v) = $0 { return v }; return nil } }
    public var noWater: NoWater? { first { if case .noWater(let v) = $0 { return v }; return nil } }
    public var scale: Scale? { first { if case .scale(let v) = $0 { return v }; return nil } }

    /// Codes of widgets this version did not recognize or could not decode.
    public var unknownWidgetCodes: [String] {
        widgets.compactMap { if case .unknown(let code) = $0.kind { return code }; return nil }
    }

    /// All widgets reported under a given code, preserving group ``Widget/index``
    /// order (a multi-group machine reports e.g. `CMGroupDoses` once per group).
    public func widgets(code: String) -> [Widget] { widgets.filter { $0.code == code } }

    /// Every group-dose widget (one per group on multi-group machines). The
    /// single-valued ``groupDoses`` returns only the first.
    public var allGroupDoses: [GroupDoses] {
        widgets.compactMap { if case .groupDoses(let v) = $0.kind { return v }; return nil }
    }
}

// MARK: - Widget envelope + discriminated union

/// One entry from a dashboard's `widgets` array: its `code`, group `index`, and
/// the decoded payload (``kind``).
public struct Widget: Sendable, Hashable, Decodable {
    public let code: String
    public let index: Int
    public let kind: WidgetKind

    private enum CodingKeys: String, CodingKey { case code, index, output }

    public init(code: String, index: Int, kind: WidgetKind) {
        self.code = code
        self.index = index
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = (try? c.decode(String.self, forKey: .code)) ?? ""
        self.code = code
        self.index = (try? c.decode(Int.self, forKey: .index)) ?? 0
        self.kind = Widget.decodeKind(code: code, from: c)
    }

    private static func decodeKind(code: String, from c: KeyedDecodingContainer<CodingKeys>) -> WidgetKind {
        func output<T: Decodable>(_ type: T.Type) -> T? { try? c.decode(T.self, forKey: .output) }
        switch code {
        case "CMMachineStatus": if let v = output(MachineStatus.self) { return .machineStatus(v) }
        case "CMCoffeeBoiler": if let v = output(CoffeeBoiler.self) { return .coffeeBoiler(v) }
        case "CMSteamBoilerLevel": if let v = output(SteamBoilerLevel.self) { return .steamBoilerLevel(v) }
        case "CMSteamBoilerTemperature": if let v = output(SteamBoilerTemperature.self) { return .steamBoilerTemperature(v) }
        case "CMPreExtraction": if let v = output(PreExtraction.self) { return .preExtraction(v) }
        case "CMPreBrewing": if let v = output(PreBrewing.self) { return .preBrewing(v) }
        case "CMBackFlush": if let v = output(BackFlush.self) { return .backFlush(v) }
        case "CMGroupDoses": if let v = output(GroupDoses.self) { return .groupDoses(v) }
        case "CMHotWaterDose": if let v = output(HotWaterDose.self) { return .hotWaterDose(v) }
        case "CMBrewByWeightDoses": if let v = output(BrewByWeightDoses.self) { return .brewByWeightDoses(v) }
        case "CMRinseFlush": if let v = output(RinseFlush.self) { return .rinseFlush(v) }
        case "CMNoWater": if let v = output(NoWater.self) { return .noWater(v) }
        case "ThingScale": if let v = output(Scale.self) { return .scale(v) }
        default: break
        }
        return .unknown(code: code)
    }
}

/// The decoded payload of a ``Widget``.
public enum WidgetKind: Sendable, Hashable {
    case machineStatus(MachineStatus)
    case coffeeBoiler(CoffeeBoiler)
    case steamBoilerLevel(SteamBoilerLevel)
    case steamBoilerTemperature(SteamBoilerTemperature)
    case preExtraction(PreExtraction)
    case preBrewing(PreBrewing)
    case backFlush(BackFlush)
    case groupDoses(GroupDoses)
    case hotWaterDose(HotWaterDose)
    case brewByWeightDoses(BrewByWeightDoses)
    case rinseFlush(RinseFlush)
    case noWater(NoWater)
    case scale(Scale)
    /// A widget code this version doesn't model, or whose payload failed to decode.
    case unknown(code: String)
}

// MARK: - Machine status

public struct MachineStatus: Sendable, Hashable, Decodable {
    public let status: MachineState
    public let availableModes: [MachineMode]
    public let mode: MachineMode
    public let nextStatus: NextStatus?
    public let brewingStartTime: Date?
}

public struct NextStatus: Sendable, Hashable, Decodable {
    public let status: MachineState
    public let startTime: Date
}

// MARK: - Boilers

public struct CoffeeBoiler: Sendable, Hashable, Decodable {
    public let status: BoilerStatus
    public let enabled: Bool
    public let enabledSupported: Bool
    public let targetTemperature: Double
    public let targetTemperatureMin: Double
    public let targetTemperatureMax: Double
    public let targetTemperatureStep: Double
    public let readyStartTime: Date?

    /// Target temperature as a `Measurement` (stored value is degrees Celsius).
    public var target: Measurement<UnitTemperature> { .init(value: targetTemperature, unit: .celsius) }
}

public struct SteamBoilerLevel: Sendable, Hashable, Decodable {
    public let status: BoilerStatus
    public let enabled: Bool
    public let enabledSupported: Bool
    public let targetLevel: SteamLevel
    public let targetLevelSupported: Bool
    public let readyStartTime: Date?
}

public struct SteamBoilerTemperature: Sendable, Hashable, Decodable {
    public let status: BoilerStatus
    public let enabled: Bool
    public let enabledSupported: Bool
    public let targetTemperature: Double
    public let targetTemperatureMin: Double
    public let targetTemperatureMax: Double
    public let targetTemperatureStep: Double
    public let targetTemperatureSupported: Bool
    public let readyStartTime: Date?

    public var target: Measurement<UnitTemperature> { .init(value: targetTemperature, unit: .celsius) }
}

// MARK: - Pre-extraction

public struct PreExtraction: Sendable, Hashable, Decodable {
    public let availableModes: [PreExtractionMode]
    public let mode: PreExtractionMode
    public let times: PreExtractionTimes
}

public struct PreExtractionTimes: Sendable, Hashable, Decodable {
    public let `in`: PreExtractionSeconds
    public let out: PreExtractionSeconds
    private enum CodingKeys: String, CodingKey { case `in` = "In", out = "Out" }
}

public struct PreExtractionSeconds: Sendable, Hashable, Decodable {
    public let seconds: Double
    public let secondsMin: PreExtractionModeValues
    public let secondsMax: PreExtractionModeValues
    public let secondsStep: PreExtractionModeValues
}

public struct PreExtractionModeValues: Sendable, Hashable, Decodable {
    public let preInfusion: Double
    public let preBrewing: Double
    private enum CodingKeys: String, CodingKey { case preInfusion = "PreInfusion", preBrewing = "PreBrewing" }
}

public struct PreBrewing: Sendable, Hashable, Decodable {
    public let availableModes: [PreExtractionMode]
    public let mode: PreExtractionMode
    public let times: PreBrewingTimes
    public let doseIndexSupported: Bool?
}

public struct PreBrewingTimes: Sendable, Hashable, Decodable {
    public let preInfusion: [PreBrewingDoseTimes]
    public let preBrewing: [PreBrewingDoseTimes]
    private enum CodingKeys: String, CodingKey { case preInfusion = "PreInfusion", preBrewing = "PreBrewing" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Either list may be absent (e.g. a machine with only pre-brewing).
        preInfusion = (try? c.decode([PreBrewingDoseTimes].self, forKey: .preInfusion)) ?? []
        preBrewing = (try? c.decode([PreBrewingDoseTimes].self, forKey: .preBrewing)) ?? []
    }
}

public struct PreBrewingDoseTimes: Sendable, Hashable, Decodable {
    public let doseIndex: DoseIndex
    public let seconds: InOutSeconds
    public let secondsMin: InOutSeconds
    public let secondsMax: InOutSeconds
    public let secondsStep: InOutSeconds
}

public struct InOutSeconds: Sendable, Hashable, Decodable {
    public let `in`: Double
    public let out: Double
    private enum CodingKeys: String, CodingKey { case `in` = "In", out = "Out" }
}

// MARK: - Cleaning

public struct BackFlush: Sendable, Hashable, Decodable {
    public let status: BackFlushStatus
    public let lastCleaningStartTime: Date?
}

public struct RinseFlush: Sendable, Hashable, Decodable {
    public let enabled: Bool
    public let enabledSupported: Bool
    public let timeSeconds: Double
    public let timeSecondsMin: Double
    public let timeSecondsMax: Double
    public let timeSecondsStep: Double
}

// MARK: - Doses

public struct GroupDoses: Sendable, Hashable, Decodable {
    public let mode: DoseMode?
    public let availableModes: [DoseMode]?
    public let doses: DosePulses
}

public struct DosePulses: Sendable, Hashable, Decodable {
    public let pulsesType: [DoseSetting]
    private enum CodingKeys: String, CodingKey { case pulsesType = "PulsesType" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pulsesType = (try? c.decode([DoseSetting].self, forKey: .pulsesType)) ?? []
    }
}

public struct DoseSetting: Sendable, Hashable, Decodable {
    public let doseIndex: DoseIndex
    public let dose: Double
    public let doseMin: Double
    public let doseMax: Double
    public let doseStep: Double
}

public struct HotWaterDose: Sendable, Hashable, Decodable {
    public let enabled: Bool
    public let enabledSupported: Bool
    public let doses: [DoseSetting]
    private enum CodingKeys: String, CodingKey { case enabled, enabledSupported, doses }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        enabledSupported = try c.decode(Bool.self, forKey: .enabledSupported)
        doses = (try? c.decode([DoseSetting].self, forKey: .doses)) ?? []
    }
}

public struct BrewByWeightDoses: Sendable, Hashable, Decodable {
    public let scaleConnected: Bool
    public let mode: DoseMode?
    public let availableModes: [DoseMode]?
    public let doses: BrewByWeightDosePair
    private enum CodingKeys: String, CodingKey { case scaleConnected, mode, availableModes, doses }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scaleConnected = (try? c.decode(Bool.self, forKey: .scaleConnected)) ?? false
        mode = (try? c.decodeIfPresent(DoseMode.self, forKey: .mode)) ?? nil
        availableModes = (try? c.decodeIfPresent([DoseMode].self, forKey: .availableModes)) ?? nil
        doses = try c.decode(BrewByWeightDosePair.self, forKey: .doses)
    }
}

public struct BrewByWeightDosePair: Sendable, Hashable, Decodable {
    public let dose1: BaseDose
    public let dose2: BaseDose
    private enum CodingKeys: String, CodingKey { case dose1 = "Dose1", dose2 = "Dose2" }
}

public struct BaseDose: Sendable, Hashable, Decodable {
    public let dose: Double
    public let doseMin: Double
    public let doseMax: Double
    public let doseStep: Double
}

// MARK: - Misc

public struct NoWater: Sendable, Hashable, Decodable {
    public let alarm: Bool
    private enum CodingKeys: String, CodingKey { case alarm = "allarm" }
}

public struct Scale: Sendable, Hashable, Decodable {
    public let name: String
    public let connected: Bool
    public let batteryLevel: Double
    public let calibrationRequired: Bool
}
