import Foundation

/// What a read-setting request asks for (`const.py:322-330`).
public enum BluetoothReadSetting: String, Sendable, Hashable, CaseIterable {
    case machineCapabilities = "machineCapabilities"
    case machineMode = "machineMode"
    case tankStatus = "tankStatus"
    case boilers = "boilers"
    case smartStandBy = "smartStandBy"
    case isPlumbedIn = "isPlumbedIn"
}

/// Brewing states derived from shot-counter notifications (`const.py:333-339`).
public enum BluetoothBrewingState: String, Sendable, Hashable, Codable {
    case brewing = "Brewing"
    case brewingStopped = "BrewingStopped"
    case flushed = "Flushed"
    case backflushing = "Backflushing"
}

/// A boiler identifier on the BLE wire (`const.py:307-311`), tolerant of unknown values.
public enum BluetoothBoilerType: Sendable, Hashable {
    case coffee          // "CoffeeBoiler1"
    case steam           // "SteamBoiler"
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "CoffeeBoiler1": self = .coffee
        case "SteamBoiler": self = .steam
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .coffee: "CoffeeBoiler1"
        case .steam: "SteamBoiler"
        case .other(let raw): raw
        }
    }
}

extension Model {
    /// BLE `machineCapabilities.family` → model (`ModelName.from_string`, const.py:198-218):
    /// upper-case, strip ALL whitespace, then:
    /// "GS3"→.gs3AV, "GS3MP"→.gs3MP, "GS3AV"→.gs3AV, "LINEAMINI2023"→.lineaMiniR, "LINEAMICRA"→.lineaMicra,
    /// "LINEAMINI"→.lineaMini, "LINEA"→.lineaMini, "MICRA"→.lineaMicra, "STRADAX"→.stradaX,
    /// "PICOGRINDER"→.pico, "SWANGRINDER"→.swan; anything else → nil.
    ///
    /// Unlike the cloud parser (`Model(code:name:)`), `"GS3"` here is the GS3 AV and `"LINEA"` the
    /// original Linea Mini — the Bluetooth family strings those machines report (D8).
    public init?(bluetoothFamily: String) {
        // Python: `"".join(name.upper().split())`. `str.split()` splits on every character for
        // which `str.isspace()` is true: Unicode White_Space plus U+001C…U+001F.
        let scalars = bluetoothFamily.uppercased().unicodeScalars.filter { scalar in
            !(scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value))
        }
        switch String(String.UnicodeScalarView(scalars)) {
        case "GS3": self = .gs3AV
        case "GS3MP": self = .gs3MP
        case "GS3AV": self = .gs3AV
        case "LINEAMINI2023": self = .lineaMiniR
        case "LINEAMICRA": self = .lineaMicra
        case "LINEAMINI": self = .lineaMini
        case "LINEA": self = .lineaMini
        case "MICRA": self = .lineaMicra
        case "STRADAX": self = .stradaX
        case "PICOGRINDER": self = .pico
        case "SWANGRINDER": self = .swan
        default: return nil
        }
    }

    /// Models whose steam boiler is set by level (`STEAM_LEVEL_MODELS`, const.py:182).
    public static let steamLevelModels: Set<Model> = [.lineaMicra, .lineaMiniR]
    /// Models whose steam boiler is set by temperature (`MACH:823`).
    public static let steamTemperatureModels: Set<Model> = [.gs3, .gs3AV, .gs3MP, .stradaX]
}

extension MachineState {
    /// `BLE_MACHINE_STATE` (MACH:65-69): .brewing→.poweredOn, .eco→.eco, .standby→.standby, .other(x)→.other(x).
    public init(bluetoothMode mode: MachineMode) {
        switch mode {
        case .brewing: self = .poweredOn
        case .eco: self = .eco
        case .standby: self = .standby
        case .other(let raw): self = .other(raw)
        }
    }
}

extension BoilerStatus {
    /// `BLE_BOILER_STATUS` (MACH:71-75): .brewing→.ready, .eco→.eco, .standby→.standby, .other(x)→.other(x).
    public init(bluetoothMode mode: MachineMode) {
        switch mode {
        case .brewing: self = .ready
        case .eco: self = .eco
        case .standby: self = .standby
        case .other(let raw): self = .other(raw)
        }
    }
}

extension SteamLevel {
    /// `STEAM_LEVEL_MAPPING` (MACH:58-62): .level1→126, .level2→128, .level3→131 (°C).
    public var bluetoothTargetTemperature: Int {
        switch self {
        case .level1: 126
        case .level2: 128
        case .level3: 131
        }
    }

    /// `_steam_level_from_temperature` (MACH:78-84): 0 < t < 128 → .level1; 128 ≤ t ≤ 130 → .level2;
    /// otherwise (including t ≤ 0) → .level3.
    ///
    /// NaN fails both comparisons and maps to `.level3`, as in Python.
    public init(bluetoothTargetTemperature t: Double) {
        if 0 < t && t < 128 {
            self = .level1
        } else if 128 <= t && t <= 130 {
            self = .level2
        } else {
            self = .level3
        }
    }
}
