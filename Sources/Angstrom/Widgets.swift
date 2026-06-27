import Foundation

// MARK: - Dashboard

/// A machine's decoded dashboard: its identity plus the typed widgets the cloud
/// reports for it. The same widget schema is returned by the REST `/dashboard`
/// endpoint and pushed over the websocket.
///
/// Widgets are decoded resiliently — an unrecognized widget code, or one whose
/// payload this version can't decode, becomes ``WidgetKind/unknown(code:)``
/// rather than failing the whole dashboard.
public struct Dashboard: Sendable, Hashable, Codable {
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

    public func encode(to encoder: Encoder) throws {
        try machine.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(widgets, forKey: .widgets)
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
    public var grinderStatus: GrinderMachineStatus? { first { if case .grinderStatus(let v) = $0 { return v }; return nil } }
    public var grinderDoses: GrinderDoses? { first { if case .grinderDoses(let v) = $0 { return v }; return nil } }
    public var grinderSingleDose: GrinderSingleDose? { first { if case .grinderSingleDose(let v) = $0 { return v }; return nil } }
    public var grinderBaristaLight: GrinderBaristaLight? { first { if case .grinderBaristaLight(let v) = $0 { return v }; return nil } }

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
public struct Widget: Sendable, Hashable, Codable {
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

    /// Re-encodes the envelope and the typed payload back under `output`. A
    /// ``WidgetKind/unknown(code:)`` widget retains its `code`/`index` but has no
    /// `output` to write (the original payload wasn't captured on decode).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(index, forKey: .index)
        switch kind {
        case .machineStatus(let v): try c.encode(v, forKey: .output)
        case .coffeeBoiler(let v): try c.encode(v, forKey: .output)
        case .steamBoilerLevel(let v): try c.encode(v, forKey: .output)
        case .steamBoilerTemperature(let v): try c.encode(v, forKey: .output)
        case .preExtraction(let v): try c.encode(v, forKey: .output)
        case .preBrewing(let v): try c.encode(v, forKey: .output)
        case .backFlush(let v): try c.encode(v, forKey: .output)
        case .groupDoses(let v): try c.encode(v, forKey: .output)
        case .hotWaterDose(let v): try c.encode(v, forKey: .output)
        case .brewByWeightDoses(let v): try c.encode(v, forKey: .output)
        case .rinseFlush(let v): try c.encode(v, forKey: .output)
        case .noWater(let v): try c.encode(v, forKey: .output)
        case .scale(let v): try c.encode(v, forKey: .output)
        case .grinderStatus(let v): try c.encode(v, forKey: .output)
        case .grinderDoses(let v): try c.encode(v, forKey: .output)
        case .grinderSingleDose(let v): try c.encode(v, forKey: .output)
        case .grinderBaristaLight(let v): try c.encode(v, forKey: .output)
        case .unknown: break
        }
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
        case "GMachineStatus": if let v = output(GrinderMachineStatus.self) { return .grinderStatus(v) }
        case "GDoses": if let v = output(GrinderDoses.self) { return .grinderDoses(v) }
        case "GSingleDoseMode": if let v = output(GrinderSingleDose.self) { return .grinderSingleDose(v) }
        case "GBaristaLight": if let v = output(GrinderBaristaLight.self) { return .grinderBaristaLight(v) }
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
    case grinderStatus(GrinderMachineStatus)
    case grinderDoses(GrinderDoses)
    case grinderSingleDose(GrinderSingleDose)
    case grinderBaristaLight(GrinderBaristaLight)
    /// A widget code this version doesn't model, or whose payload failed to decode.
    case unknown(code: String)
}

// MARK: - Machine status

public struct MachineStatus: Sendable, Hashable, Codable {
    public let status: MachineState
    public let availableModes: [MachineMode]
    public let mode: MachineMode
    public let nextStatus: NextStatus?
    public let brewingStartTime: Date?
}

public struct NextStatus: Sendable, Hashable, Codable {
    public let status: MachineState
    public let startTime: Date
}

// MARK: - Boilers

public struct CoffeeBoiler: Sendable, Hashable, Codable {
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

public struct SteamBoilerLevel: Sendable, Hashable, Codable {
    public let status: BoilerStatus
    public let enabled: Bool
    public let enabledSupported: Bool
    public let targetLevel: SteamLevel
    public let targetLevelSupported: Bool
    public let readyStartTime: Date?
}

public struct SteamBoilerTemperature: Sendable, Hashable, Codable {
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

public struct PreExtraction: Sendable, Hashable, Codable {
    public let availableModes: [PreExtractionMode]
    public let mode: PreExtractionMode
    public let times: PreExtractionTimes
}

public struct PreExtractionTimes: Sendable, Hashable, Codable {
    public let `in`: PreExtractionSeconds
    public let out: PreExtractionSeconds
    private enum CodingKeys: String, CodingKey { case `in` = "In", out = "Out" }
}

public struct PreExtractionSeconds: Sendable, Hashable, Codable {
    public let seconds: Double
    public let secondsMin: PreExtractionModeValues
    public let secondsMax: PreExtractionModeValues
    public let secondsStep: PreExtractionModeValues
}

public struct PreExtractionModeValues: Sendable, Hashable, Codable {
    public let preInfusion: Double
    public let preBrewing: Double
    private enum CodingKeys: String, CodingKey { case preInfusion = "PreInfusion", preBrewing = "PreBrewing" }
}

public struct PreBrewing: Sendable, Hashable, Codable {
    public let availableModes: [PreExtractionMode]
    public let mode: PreExtractionMode
    public let times: PreBrewingTimes
    public let doseIndexSupported: Bool?
}

public struct PreBrewingTimes: Sendable, Hashable, Codable {
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

public struct PreBrewingDoseTimes: Sendable, Hashable, Codable {
    public let doseIndex: DoseIndex
    public let seconds: InOutSeconds
    public let secondsMin: InOutSeconds
    public let secondsMax: InOutSeconds
    public let secondsStep: InOutSeconds
}

public struct InOutSeconds: Sendable, Hashable, Codable {
    public let `in`: Double
    public let out: Double
    private enum CodingKeys: String, CodingKey { case `in` = "In", out = "Out" }
}

// MARK: - Cleaning

public struct BackFlush: Sendable, Hashable, Codable {
    public let status: BackFlushStatus
    public let lastCleaningStartTime: Date?
}

public struct RinseFlush: Sendable, Hashable, Codable {
    public let enabled: Bool
    public let enabledSupported: Bool
    public let timeSeconds: Double
    public let timeSecondsMin: Double
    public let timeSecondsMax: Double
    public let timeSecondsStep: Double
}

// MARK: - Doses

public struct GroupDoses: Sendable, Hashable, Codable {
    public let mode: DoseMode?
    public let availableModes: [DoseMode]?
    public let doses: DosePulses
}

public struct DosePulses: Sendable, Hashable, Codable {
    public let pulsesType: [DoseSetting]
    private enum CodingKeys: String, CodingKey { case pulsesType = "PulsesType" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pulsesType = (try? c.decode([DoseSetting].self, forKey: .pulsesType)) ?? []
    }
}

public struct DoseSetting: Sendable, Hashable, Codable {
    public let doseIndex: DoseIndex
    public let dose: Double
    public let doseMin: Double
    public let doseMax: Double
    public let doseStep: Double
}

public struct HotWaterDose: Sendable, Hashable, Codable {
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

public struct BrewByWeightDoses: Sendable, Hashable, Codable {
    public let scaleConnected: Bool
    public let mode: DoseMode?
    public let availableModes: [DoseMode]?
    public let doses: BrewByWeightDosePair
    private enum CodingKeys: String, CodingKey { case scaleConnected, mode, availableModes, doses }

    public init(scaleConnected: Bool, mode: DoseMode?, availableModes: [DoseMode]?, doses: BrewByWeightDosePair) {
        self.scaleConnected = scaleConnected
        self.mode = mode
        self.availableModes = availableModes
        self.doses = doses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scaleConnected = (try? c.decode(Bool.self, forKey: .scaleConnected)) ?? false
        mode = (try? c.decodeIfPresent(DoseMode.self, forKey: .mode)) ?? nil
        availableModes = (try? c.decodeIfPresent([DoseMode].self, forKey: .availableModes)) ?? nil
        doses = try c.decode(BrewByWeightDosePair.self, forKey: .doses)
    }
}

public struct BrewByWeightDosePair: Sendable, Hashable, Codable {
    public let dose1: BaseDose
    public let dose2: BaseDose
    private enum CodingKeys: String, CodingKey { case dose1 = "Dose1", dose2 = "Dose2" }
}

public struct BaseDose: Sendable, Hashable, Codable {
    public let dose: Double
    public let doseMin: Double
    public let doseMax: Double
    public let doseStep: Double
}

// MARK: - Misc

public struct NoWater: Sendable, Hashable, Codable {
    public let alarm: Bool
    private enum CodingKeys: String, CodingKey { case alarm = "allarm" }
}

public struct Scale: Sendable, Hashable, Codable {
    public let name: String
    public let connected: Bool
    public let batteryLevel: Double
    public let calibrationRequired: Bool
}

// MARK: - Grinder widgets

public struct GrinderMachineStatus: Sendable, Hashable, Codable {
    public let status: GrinderMode
    public let availableModes: [GrinderMode]
    public let mode: GrinderMode
    public let readyStartTime: Date?

    private enum CodingKeys: String, CodingKey { case status, availableModes, mode, readyStartTime }

    public init(status: GrinderMode, availableModes: [GrinderMode], mode: GrinderMode, readyStartTime: Date?) {
        self.status = status
        self.availableModes = availableModes
        self.mode = mode
        self.readyStartTime = readyStartTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(GrinderMode.self, forKey: .status)
        availableModes = (try? c.decode([GrinderMode].self, forKey: .availableModes)) ?? []
        mode = try c.decode(GrinderMode.self, forKey: .mode)
        readyStartTime = (try? c.decodeIfPresent(Date.self, forKey: .readyStartTime)) ?? nil
    }
}

public struct GrinderDoses: Sendable, Hashable, Codable {
    public let scaleConnected: Bool
    public let mode: GrinderDoseMode
    public let doses: GrinderDosesSettings
    public let speedLevelsSupported: Bool
    public let speedLevels: String?

    private enum CodingKeys: String, CodingKey {
        case scaleConnected, mode, doses, speedLevelsSupported, speedLevels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scaleConnected = (try? c.decode(Bool.self, forKey: .scaleConnected)) ?? false
        mode = try c.decode(GrinderDoseMode.self, forKey: .mode)
        doses = (try? c.decode(GrinderDosesSettings.self, forKey: .doses)) ?? GrinderDosesSettings()
        speedLevelsSupported = (try? c.decode(Bool.self, forKey: .speedLevelsSupported)) ?? false
        speedLevels = (try? c.decodeIfPresent(String.self, forKey: .speedLevels)) ?? nil
    }
}

public struct GrinderDosesSettings: Sendable, Hashable, Codable {
    /// Doses configured in time mode (seconds).
    public let timeType: [GrinderDoseSetting]
    /// Doses configured in mass mode (grams).
    public let massType: [GrinderDoseSetting]

    private enum CodingKeys: String, CodingKey { case timeType = "TimeType", massType = "MassType" }

    public init(timeType: [GrinderDoseSetting] = [], massType: [GrinderDoseSetting] = []) {
        self.timeType = timeType
        self.massType = massType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeType = (try? c.decode([GrinderDoseSetting].self, forKey: .timeType)) ?? []
        massType = (try? c.decode([GrinderDoseSetting].self, forKey: .massType)) ?? []
    }
}

public struct GrinderDoseSetting: Sendable, Hashable, Codable {
    public let doseIndex: DoseIndex
    public let dose: Double
    public let doseMin: Double
    public let doseMax: Double
    public let doseStep: Double
    public let speedAutoSupported: Bool
    public let speedAuto: String?

    private enum CodingKeys: String, CodingKey {
        case doseIndex, dose, doseMin, doseMax, doseStep, speedAutoSupported, speedAuto
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doseIndex = try c.decode(DoseIndex.self, forKey: .doseIndex)
        dose = try c.decode(Double.self, forKey: .dose)
        doseMin = (try? c.decode(Double.self, forKey: .doseMin)) ?? 0
        doseMax = (try? c.decode(Double.self, forKey: .doseMax)) ?? 0
        doseStep = (try? c.decode(Double.self, forKey: .doseStep)) ?? 0
        speedAutoSupported = (try? c.decode(Bool.self, forKey: .speedAutoSupported)) ?? false
        speedAuto = (try? c.decodeIfPresent(String.self, forKey: .speedAuto)) ?? nil
    }
}

public struct GrinderSingleDose: Sendable, Hashable, Codable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

public struct GrinderBaristaLight: Sendable, Hashable, Codable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}
