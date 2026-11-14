import Foundation

extension LaMarzoccoBluetoothClient {
    // MARK: Reads

    public func machineMode() async throws -> MachineMode {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    public func machineCapabilities() async throws -> BluetoothMachineCapabilities {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    public func tankStatus() async throws -> Bool {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    public func isPlumbedIn() async throws -> Bool {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    public func boilers() async throws -> [BluetoothBoilerDetails] {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    public func smartStandby() async throws -> BluetoothSmartStandbyDetails {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    // MARK: Commands — a non-success status is RETURNED, not thrown.

    @discardableResult public func setPower(on: Bool) async throws -> BluetoothCommandStatus {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    @discardableResult public func setSteam(on: Bool) async throws -> BluetoothCommandStatus {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    @discardableResult public func setSmartStandby(enabled: Bool, mode: SmartStandbyAfter,
                                                   minutes: Int) async throws -> BluetoothCommandStatus {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    /// Throws `.operationNotAvailable("temperature must be finite")` for NaN/∞ (D21). No rounding.
    @discardableResult public func setTemperature(boiler: BluetoothBoilerType,
                                                  celsius: Double) async throws -> BluetoothCommandStatus {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    // MARK: Diagnostics

    /// Verbatim response bytes (before NUL truncation) of one read-setting request.
    public func rawRead(_ setting: BluetoothReadSetting) async throws -> Data {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    // MARK: Internal helpers [+Requests]

    /// §4.4.
    func request(_ characteristic: GATTUUID, frame: Data) async throws -> Data {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    /// §4.5.
    func resolve(_ characteristic: GATTUUID, on link: any BluetoothLink) async throws {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    func readSetting(_ setting: BluetoothReadSetting) async throws -> String {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }

    func sendCommand(_ frame: Data) async throws -> BluetoothCommandStatus {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W2-01")
    }
}
