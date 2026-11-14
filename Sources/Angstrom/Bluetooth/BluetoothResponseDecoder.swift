import Foundation

/// Decoders for read/command responses (§3.6, §3.10). Input is the NUL-truncated UTF-8 text.
/// Every failure throws `LaMarzoccoError.decoding("bluetooth <setting|command>: <detail>")`.
package enum BluetoothResponseDecoder {
    package static func machineMode(_ text: String) throws -> MachineMode {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-03")
    }

    package static func capabilities(_ text: String) throws -> BluetoothMachineCapabilities {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-03")
    }

    /// `parseBool` on the decoded JSON value.
    package static func bool(_ text: String, setting: BluetoothReadSetting) throws -> Bool {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-03")
    }

    package static func boilers(_ text: String) throws -> [BluetoothBoilerDetails] {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-03")
    }

    package static func smartStandby(_ text: String) throws -> BluetoothSmartStandbyDetails {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-03")
    }

    package static func commandStatus(_ text: String) throws -> BluetoothCommandStatus {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-03")
    }
}
