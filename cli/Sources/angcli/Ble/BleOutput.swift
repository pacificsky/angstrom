import Foundation
import Angstrom

/// Every function returns one JSON line (SPEC §10.3) or nil if encoding fails.
enum BleOutput {
    static func rawLine(_ frame: RawBluetoothFrame, ts: String = Timestamp.now()) -> String? {
        fatalError("unimplemented: BT-W2-03")
    }

    static func shotCounterLine(_ event: ShotCounterEvent, ts: String = Timestamp.now()) -> String? {
        fatalError("unimplemented: BT-W2-03")
    }

    static func connectionLine(_ event: ConnectionEvent, ts: String = Timestamp.now()) -> String? {
        fatalError("unimplemented: BT-W2-03")
    }

    static func peripheralLine(_ peripheral: DiscoveredPeripheral) -> String? {
        fatalError("unimplemented: BT-W2-03")
    }

    static func gattLines(_ services: [BluetoothGATTService]) -> [String] {
        fatalError("unimplemented: BT-W2-03")
    }

    static func readLine<D: Encodable>(setting: BluetoothReadSetting, raw: Data, decoded: D?,
                                       ts: String = Timestamp.now()) -> String? {
        fatalError("unimplemented: BT-W2-03")
    }

    static func commandLine(command: String, status: BluetoothCommandStatus, ts: String = Timestamp.now()) -> String? {
        fatalError("unimplemented: BT-W2-03")
    }

    /// {"token":"**REDACTED**","length":n} unless showSecret.
    static func tokenLine(_ token: BluetoothAuthToken, showSecret: Bool) -> String? {
        fatalError("unimplemented: BT-W2-03")
    }
}
