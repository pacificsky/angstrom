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
    /// Per-group machine status (`CMMachineGroupStatus`). The Strada X reports
    /// this *instead of* ``machineStatus``; the payload shape is identical.
    public var machineGroupStatus: MachineStatus? { first { if case .machineGroupStatus(let v) = $0 { return v }; return nil } }
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
    public var autoFlush: AutoFlush? { first { if case .autoFlush(let v) = $0 { return v }; return nil } }
    public var steamFlush: SteamFlush? { first { if case .steamFlush(let v) = $0 { return v }; return nil } }
    public var noWater: NoWater? { first { if case .noWater(let v) = $0 { return v }; return nil } }
    public var scale: Scale? { first { if case .scale(let v) = $0 { return v }; return nil } }
    public var grinderStatus: GrinderMachineStatus? { first { if case .grinderStatus(let v) = $0 { return v }; return nil } }
    public var grinderDoses: GrinderDoses? { first { if case .grinderDoses(let v) = $0 { return v }; return nil } }
    public var grinderSingleDose: GrinderSingleDose? { first { if case .grinderSingleDose(let v) = $0 { return v }; return nil } }
    public var grinderBaristaLight: GrinderBaristaLight? { first { if case .grinderBaristaLight(let v) = $0 { return v }; return nil } }
    public var grinderSpeed: GrinderSpeed? { first { if case .grinderSpeed(let v) = $0 { return v }; return nil } }
    public var grinderMoreDose: GrinderMoreDose? { first { if case .grinderMoreDose(let v) = $0 { return v }; return nil } }
    public var grinderGrindWith: GrinderGrindWith? { first { if case .grinderGrindWith(let v) = $0 { return v }; return nil } }

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
        case .machineGroupStatus(let v): try c.encode(v, forKey: .output)
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
        case .autoFlush(let v): try c.encode(v, forKey: .output)
        case .steamFlush(let v): try c.encode(v, forKey: .output)
        case .noWater(let v): try c.encode(v, forKey: .output)
        case .scale(let v): try c.encode(v, forKey: .output)
        case .grinderStatus(let v): try c.encode(v, forKey: .output)
        case .grinderDoses(let v): try c.encode(v, forKey: .output)
        case .grinderSingleDose(let v): try c.encode(v, forKey: .output)
        case .grinderBaristaLight(let v): try c.encode(v, forKey: .output)
        case .grinderSpeed(let v): try c.encode(v, forKey: .output)
        case .grinderMoreDose(let v): try c.encode(v, forKey: .output)
        case .grinderGrindWith(let v): try c.encode(v, forKey: .output)
        case .unknown: break
        }
    }

    private static func decodeKind(code: String, from c: KeyedDecodingContainer<CodingKeys>) -> WidgetKind {
        func output<T: Decodable>(_ type: T.Type) -> T? { try? c.decode(T.self, forKey: .output) }
        switch code {
        case "CMMachineStatus": if let v = output(MachineStatus.self) { return .machineStatus(v) }
        case "CMMachineGroupStatus": if let v = output(MachineStatus.self) { return .machineGroupStatus(v) }
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
        case "CMAutoFlush": if let v = output(AutoFlush.self) { return .autoFlush(v) }
        case "CMSteamFlush": if let v = output(SteamFlush.self) { return .steamFlush(v) }
        case "CMNoWater": if let v = output(NoWater.self) { return .noWater(v) }
        case "ThingScale": if let v = output(Scale.self) { return .scale(v) }
        case "GMachineStatus": if let v = output(GrinderMachineStatus.self) { return .grinderStatus(v) }
        case "GDoses": if let v = output(GrinderDoses.self) { return .grinderDoses(v) }
        case "GSingleDoseMode": if let v = output(GrinderSingleDose.self) { return .grinderSingleDose(v) }
        case "GBaristaLight": if let v = output(GrinderBaristaLight.self) { return .grinderBaristaLight(v) }
        case "GSpeed": if let v = output(GrinderSpeed.self) { return .grinderSpeed(v) }
        case "GMoreDose": if let v = output(GrinderMoreDose.self) { return .grinderMoreDose(v) }
        case "GGrindWith": if let v = output(GrinderGrindWith.self) { return .grinderGrindWith(v) }
        default: break
        }
        return .unknown(code: code)
    }
}

/// The decoded payload of a ``Widget``.
public enum WidgetKind: Sendable, Hashable {
    case machineStatus(MachineStatus)
    /// `CMMachineGroupStatus` — same payload shape as ``machineStatus``, reported
    /// per group (the Strada X sends this instead of `CMMachineStatus`).
    case machineGroupStatus(MachineStatus)
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
    case autoFlush(AutoFlush)
    case steamFlush(SteamFlush)
    case noWater(NoWater)
    case scale(Scale)
    case grinderStatus(GrinderMachineStatus)
    case grinderDoses(GrinderDoses)
    case grinderSingleDose(GrinderSingleDose)
    case grinderBaristaLight(GrinderBaristaLight)
    case grinderSpeed(GrinderSpeed)
    case grinderMoreDose(GrinderMoreDose)
    case grinderGrindWith(GrinderGrindWith)
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

/// Automatic group flushing (`CMAutoFlush`, Strada X).
public struct AutoFlush: Sendable, Hashable, Codable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Automatic steam-wand flushing (`CMSteamFlush`, Strada X).
public struct SteamFlush: Sendable, Hashable, Codable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

// MARK: - Doses

public struct GroupDoses: Sendable, Hashable, Codable {
    public let availableModes: [DoseMode]
    /// Delivery mode. Defaults to ``DoseMode/pulses`` when the key is absent,
    /// matching pylamarzocco's `GroupDosesSettings.mode` default of `PulsesType`.
    public let mode: DoseMode
    public let doses: DosePulses
    /// The selected brewing profile, in ``DoseMode/profile`` mode (Strada X).
    public let profile: ProfileSettings?
    /// Whether this group can mirror group 1's settings, and its current target.
    public let mirrorWithGroup1Supported: Bool
    public let mirrorWithGroup1: String?
    public let mirrorWithGroup1NotEffective: Bool
    /// Continuous-dose capability/value.
    public let continuousDoseSupported: Bool
    public let continuousDose: String?
    /// Brewing-pressure capability/value.
    public let brewingPressureSupported: Bool
    public let brewingPressure: BrewingPressureSettings?

    private enum CodingKeys: String, CodingKey {
        case availableModes, mode, doses, profile
        case mirrorWithGroup1Supported, mirrorWithGroup1, mirrorWithGroup1NotEffective
        case continuousDoseSupported, continuousDose, brewingPressureSupported, brewingPressure
    }

    public init(
        availableModes: [DoseMode] = [],
        mode: DoseMode = .pulses,
        doses: DosePulses,
        profile: ProfileSettings? = nil,
        mirrorWithGroup1Supported: Bool = false,
        mirrorWithGroup1: String? = nil,
        mirrorWithGroup1NotEffective: Bool = false,
        continuousDoseSupported: Bool = false,
        continuousDose: String? = nil,
        brewingPressureSupported: Bool = false,
        brewingPressure: BrewingPressureSettings? = nil
    ) {
        self.availableModes = availableModes
        self.mode = mode
        self.doses = doses
        self.profile = profile
        self.mirrorWithGroup1Supported = mirrorWithGroup1Supported
        self.mirrorWithGroup1 = mirrorWithGroup1
        self.mirrorWithGroup1NotEffective = mirrorWithGroup1NotEffective
        self.continuousDoseSupported = continuousDoseSupported
        self.continuousDose = continuousDose
        self.brewingPressureSupported = brewingPressureSupported
        self.brewingPressure = brewingPressure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        availableModes = (try? c.decode([DoseMode].self, forKey: .availableModes)) ?? []
        mode = (try? c.decode(DoseMode.self, forKey: .mode)) ?? .pulses
        doses = (try? c.decode(DosePulses.self, forKey: .doses)) ?? DosePulses()
        profile = (try? c.decodeIfPresent(ProfileSettings.self, forKey: .profile)) ?? nil
        mirrorWithGroup1Supported = (try? c.decode(Bool.self, forKey: .mirrorWithGroup1Supported)) ?? false
        mirrorWithGroup1 = (try? c.decodeIfPresent(String.self, forKey: .mirrorWithGroup1)) ?? nil
        mirrorWithGroup1NotEffective = (try? c.decode(Bool.self, forKey: .mirrorWithGroup1NotEffective)) ?? false
        continuousDoseSupported = (try? c.decode(Bool.self, forKey: .continuousDoseSupported)) ?? false
        continuousDose = (try? c.decodeIfPresent(String.self, forKey: .continuousDose)) ?? nil
        brewingPressureSupported = (try? c.decode(Bool.self, forKey: .brewingPressureSupported)) ?? false
        brewingPressure = (try? c.decodeIfPresent(BrewingPressureSettings.self, forKey: .brewingPressure)) ?? nil
    }
}

/// The per-mode dose lists of a group. Historically only `PulsesType`; the
/// Strada X adds manual/mass/brew-ratio/profile lists.
public struct DosePulses: Sendable, Hashable, Codable {
    public let pulsesType: [DoseSetting]
    public let manualType: [DoseSetting]
    public let massType: [DoseSetting]
    public let brewRatioType: [DoseSetting]
    public let profileType: [DoseSetting]

    private enum CodingKeys: String, CodingKey {
        case pulsesType = "PulsesType"
        case manualType = "ManualType"
        case massType = "MassType"
        case brewRatioType = "BrewRatioType"
        case profileType = "ProfileType"
    }

    public init(
        pulsesType: [DoseSetting] = [],
        manualType: [DoseSetting] = [],
        massType: [DoseSetting] = [],
        brewRatioType: [DoseSetting] = [],
        profileType: [DoseSetting] = []
    ) {
        self.pulsesType = pulsesType
        self.manualType = manualType
        self.massType = massType
        self.brewRatioType = brewRatioType
        self.profileType = profileType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pulsesType = (try? c.decode([DoseSetting].self, forKey: .pulsesType)) ?? []
        manualType = (try? c.decode([DoseSetting].self, forKey: .manualType)) ?? []
        massType = (try? c.decode([DoseSetting].self, forKey: .massType)) ?? []
        brewRatioType = (try? c.decode([DoseSetting].self, forKey: .brewRatioType)) ?? []
        profileType = (try? c.decode([DoseSetting].self, forKey: .profileType)) ?? []
    }
}

/// The selected brewing profile of a group (`CMGroupDoses.profile`, Strada X).
public struct ProfileSettings: Sendable, Hashable, Codable {
    public let selectedProfile: Int
    public let numberOfProfiles: Int
    public let mass: Double
    public let time: Double
    public let graph: ProfileGraph?

    private enum CodingKeys: String, CodingKey {
        case selectedProfile, numberOfProfiles, mass, time, graph
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedProfile = try c.decode(Int.self, forKey: .selectedProfile)
        numberOfProfiles = try c.decode(Int.self, forKey: .numberOfProfiles)
        mass = try c.decode(Double.self, forKey: .mass)
        time = try c.decode(Double.self, forKey: .time)
        graph = (try? c.decodeIfPresent(ProfileGraph.self, forKey: .graph)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedProfile, forKey: .selectedProfile)
        try c.encode(numberOfProfiles, forKey: .numberOfProfiles)
        try c.encode(mass, forKey: .mass)
        try c.encode(time, forKey: .time)
        try c.encodeIfPresent(graph, forKey: .graph)
    }
}

/// Pressure/flow profile graph data points.
public struct ProfileGraph: Sendable, Hashable, Codable {
    public let x: [Double]
    public let y: [Double]

    private enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = (try? c.decode([Double].self, forKey: .x)) ?? []
        y = (try? c.decode([Double].self, forKey: .y)) ?? []
    }
}

/// Brewing-pressure configuration (`CMGroupDoses.brewingPressure`, Strada X).
public struct BrewingPressureSettings: Sendable, Hashable, Codable {
    public let pressure: Double
    public let pressureMin: Double
    public let pressureMax: Double
    public let pressureStep: Double
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

    public init(enabled: Bool, enabledSupported: Bool, doses: [DoseSetting]) {
        self.enabled = enabled
        self.enabledSupported = enabledSupported
        self.doses = doses
    }

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
    /// Per-dose speed levels (Swan).
    public let speedLevels: [GrinderSpeedLevelSetting]?

    private enum CodingKeys: String, CodingKey {
        case scaleConnected, mode, doses, speedLevelsSupported, speedLevels
    }

    public init(scaleConnected: Bool, mode: GrinderDoseMode, doses: GrinderDosesSettings,
                speedLevelsSupported: Bool = false, speedLevels: [GrinderSpeedLevelSetting]? = nil) {
        self.scaleConnected = scaleConnected
        self.mode = mode
        self.doses = doses
        self.speedLevelsSupported = speedLevelsSupported
        self.speedLevels = speedLevels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scaleConnected = (try? c.decode(Bool.self, forKey: .scaleConnected)) ?? false
        mode = try c.decode(GrinderDoseMode.self, forKey: .mode)
        doses = (try? c.decode(GrinderDosesSettings.self, forKey: .doses)) ?? GrinderDosesSettings()
        speedLevelsSupported = (try? c.decode(Bool.self, forKey: .speedLevelsSupported)) ?? false
        speedLevels = (try? c.decodeIfPresent([GrinderSpeedLevelSetting].self, forKey: .speedLevels)) ?? nil
    }
}

/// A grinder dose's speed level (`GDoses.speedLevels` entries, Swan).
public struct GrinderSpeedLevelSetting: Sendable, Hashable, Codable {
    public let doseIndex: DoseIndex
    public let level: GrinderSpeedLevel
}

public struct GrinderDosesSettings: Sendable, Hashable, Codable {
    /// Doses configured in time mode (seconds).
    public let timeType: [GrinderDoseSetting]
    /// Doses configured in mass mode (grams).
    public let massType: [GrinderDoseSetting]
    /// Doses configured in revolution mode (Swan).
    public let revType: [GrinderDoseSetting]

    private enum CodingKeys: String, CodingKey {
        case timeType = "TimeType", massType = "MassType", revType = "RevType"
    }

    public init(timeType: [GrinderDoseSetting] = [], massType: [GrinderDoseSetting] = [], revType: [GrinderDoseSetting] = []) {
        self.timeType = timeType
        self.massType = massType
        self.revType = revType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeType = (try? c.decode([GrinderDoseSetting].self, forKey: .timeType)) ?? []
        massType = (try? c.decode([GrinderDoseSetting].self, forKey: .massType)) ?? []
        revType = (try? c.decode([GrinderDoseSetting].self, forKey: .revType)) ?? []
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

    public init(doseIndex: DoseIndex, dose: Double, doseMin: Double = 0, doseMax: Double = 0,
                doseStep: Double = 0, speedAutoSupported: Bool = false, speedAuto: String? = nil) {
        self.doseIndex = doseIndex
        self.dose = dose
        self.doseMin = doseMin
        self.doseMax = doseMax
        self.doseStep = doseStep
        self.speedAutoSupported = speedAutoSupported
        self.speedAuto = speedAuto
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

/// Grinder motor speed per dose (`GSpeed`, Swan). ``doses`` is keyed by the
/// dose-index string (`"DoseA"`, …), as on the wire.
public struct GrinderSpeed: Sendable, Hashable, Codable {
    public let doses: [String: GrinderSpeedDose]
    public let groupsNumber: Int
    public let speedAutoSupported: Bool
    public let speedAuto: String?

    private enum CodingKeys: String, CodingKey {
        case doses, groupsNumber, speedAutoSupported, speedAuto
    }

    public init(doses: [String: GrinderSpeedDose], groupsNumber: Int = 1,
                speedAutoSupported: Bool = false, speedAuto: String? = nil) {
        self.doses = doses
        self.groupsNumber = groupsNumber
        self.speedAutoSupported = speedAutoSupported
        self.speedAuto = speedAuto
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doses = (try? c.decode([String: GrinderSpeedDose].self, forKey: .doses)) ?? [:]
        groupsNumber = (try? c.decode(Int.self, forKey: .groupsNumber)) ?? 1
        speedAutoSupported = (try? c.decode(Bool.self, forKey: .speedAutoSupported)) ?? false
        speedAuto = (try? c.decodeIfPresent(String.self, forKey: .speedAuto)) ?? nil
    }
}

/// One dose's speed configuration inside ``GrinderSpeed``.
public struct GrinderSpeedDose: Sendable, Hashable, Codable {
    public let level: GrinderSpeedLevel
    public let autoEnabled: Bool
    public let groupIndex: Int?

    private enum CodingKeys: String, CodingKey { case level, autoEnabled, groupIndex }

    public init(level: GrinderSpeedLevel, autoEnabled: Bool = false, groupIndex: Int? = nil) {
        self.level = level
        self.autoEnabled = autoEnabled
        self.groupIndex = groupIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decode(GrinderSpeedLevel.self, forKey: .level)
        autoEnabled = (try? c.decode(Bool.self, forKey: .autoEnabled)) ?? false
        groupIndex = (try? c.decodeIfPresent(Int.self, forKey: .groupIndex)) ?? nil
    }
}

/// Additional "more dose" revolutions (`GMoreDose`, Swan).
public struct GrinderMoreDose: Sendable, Hashable, Codable {
    public let revolutions: Double
    public let revolutionsMin: Double
    public let revolutionsMax: Double
    public let revolutionsStep: Double
}

/// How the grinder is triggered (`GGrindWith`, Swan).
public struct GrinderGrindWith: Sendable, Hashable, Codable {
    public let mode: GrinderGrindWithMode
    public init(mode: GrinderGrindWithMode) { self.mode = mode }
}
