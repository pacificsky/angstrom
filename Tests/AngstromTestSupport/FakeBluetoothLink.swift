import Foundation
import Angstrom

/// Every op a FakeBluetoothLink performed, in order — the assertion surface.
package enum FakeOp: Equatable, Sendable {
    case discover(refresh: Bool)
    case read(GATTUUID)
    case write(GATTUUID, Data)
    case subscribe(GATTUUID)
    case unsubscribe(GATTUUID)
    case disconnect
}

/// One connection to a fake machine: the link half of upstream's `FakeBleakClient`
/// (`tests/test_bluetooth_client.py:157-292`).
///
/// Every seam op first awaits `beforeOp`, then appends its `FakeOp` to `recordedOps` (also after a drop,
/// so a failed attempt is still visible), then — once the link is down — throws `.notConnected`, else
/// throws `CancellationError` if the calling task is cancelled (also when it was cancelled while
/// `beforeOp` held it), as the real seam does (§5.3). `unsubscribe` and `disconnect` never throw.
/// `attMTU()` and `gattTable(timeout:)` are not recorded in `recordedOps`. The `timeout:` of every
/// discover / read / write / subscribe / gattTable call is appended to `requestedTimeouts` on entry,
/// before `beforeOp` is awaited, so it is kept in call order even when the op is held or then throws.
/// `events` is one ordered `.unbounded` stream that finishes after its single `.disconnected`.
package final class FakeBluetoothLink: BluetoothLink, @unchecked Sendable {
    private struct State {
        var present: Set<GATTUUID> = [
            BluetoothConstants.readCharacteristic, BluetoothConstants.writeCharacteristic,
            BluetoothConstants.tokenCharacteristic, BluetoothConstants.authCharacteristic,
            BluetoothConstants.shotCounterCharacteristic,
        ]
        var presentAfterRefresh: Set<GATTUUID>?
        var onRead: @Sendable (GATTUUID) throws -> Data = { throw BluetoothTransportError.characteristicNotFound($0) }
        var onWrite: @Sendable (GATTUUID, Data) throws -> Void = { _, _ in }
        var beforeOp: (@Sendable (FakeOp) async -> Void)?
        var replayOnSubscribe: [Data] = [BluetoothTestVectors.tick("3.34")]
        var now: @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
        var mtu: Int?
        var gatt: [BluetoothGATTService] = []
        var recordedOps: [FakeOp] = []
        var requestedTimeouts: [Duration] = []
        var isConnected = true
    }

    package let peripheralID: BluetoothPeripheralID
    package let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()
    private var state = State()

    package init(peripheralID: BluetoothPeripheralID = .fake) {
        self.peripheralID = peripheralID
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self, bufferingPolicy: .unbounded)
    }

    /// Characteristics `discover(_, refresh: false)` reports. Default: all five.
    package var present: Set<GATTUUID> {
        get { locked { state.present } }
        set { locked { state.present = newValue } }
    }

    /// If non-nil, what `discover(_, refresh: true)` reports (models a stale cache).
    package var presentAfterRefresh: Set<GATTUUID>? {
        get { locked { state.presentAfterRefresh } }
        set { locked { state.presentAfterRefresh = newValue } }
    }

    /// Answers `read`. Default: throws `.characteristicNotFound`.
    package var onRead: @Sendable (GATTUUID) throws -> Data {
        get { locked { state.onRead } }
        set { locked { state.onRead = newValue } }
    }

    /// Observes (or fails) `write`. Default: accepts everything.
    package var onWrite: @Sendable (GATTUUID, Data) throws -> Void {
        get { locked { state.onWrite } }
        set { locked { state.onWrite = newValue } }
    }

    /// Awaited before every op is recorded — hold an op in flight (serialisation, cancellation tests).
    /// Every throwing op throws `CancellationError` if the calling task is cancelled when `beforeOp`
    /// returns, as the real seam does (§5.3).
    package var beforeOp: (@Sendable (FakeOp) async -> Void)? {
        get { locked { state.beforeOp } }
        set { locked { state.beforeOp = newValue } }
    }

    /// Delivered as notifications, stamped `now()`, BEFORE `subscribe` returns (the machine's replay).
    /// Default mirrors upstream's fake (`self.replay = _tick(3.34)`, TBC:176): most upstream shot-counter
    /// tests rely on it consuming the client's replay flag. Set `[]` for no replay (upstream `replay = None`).
    package var replayOnSubscribe: [Data] {
        get { locked { state.replayOnSubscribe } }
        set { locked { state.replayOnSubscribe = newValue } }
    }

    /// Stamps replay notifications; set by the central on `connect`.
    package var now: @Sendable () -> Date {
        get { locked { state.now } }
        set { locked { state.now = newValue } }
    }

    /// What `attMTU()` returns.
    package var mtu: Int? {
        get { locked { state.mtu } }
        set { locked { state.mtu = newValue } }
    }

    /// What `gattTable(timeout:)` returns.
    package var gatt: [BluetoothGATTService] {
        get { locked { state.gatt } }
        set { locked { state.gatt = newValue } }
    }

    package var recordedOps: [FakeOp] { locked { state.recordedOps } }

    /// The `timeout:` of every discover / read / write / subscribe / gattTable call, in call order (D19).
    package var requestedTimeouts: [Duration] { locked { state.requestedTimeouts } }

    /// Yields one `.notification` (while the link is up; a finished stream drops it).
    package func notify(_ characteristic: GATTUUID, _ value: Data, at receivedAt: Date) {
        locked {
            guard state.isConnected else { return }
            continuation.yield(.notification(characteristic, GATTNotification(value: value, receivedAt: receivedAt)))
        }
    }

    /// Yields `.disconnected(error)` once and finishes `events`. Later ops throw `.notConnected`.
    package func drop(_ error: BluetoothTransportError?) {
        terminate(error)
    }

    /// Yields `.servicesInvalidated` (bleak/CoreBluetooth "services changed").
    package func invalidateServices() {
        locked {
            guard state.isConnected else { return }
            continuation.yield(.servicesInvalidated)
        }
    }

    /// A machine accepting `token`: auth reads return [0x01] from the `confirmOnRead`-th read after a
    /// matching auth write ([0x00] otherwise); reads of 0b0b… return `commandResponse`; reads of 0a0b…
    /// return `settingResponses[last setting written to 0a0b…] ?? Data("[]".utf8)`.
    ///
    /// Ports `FakeBleakClient._write_gatt_char`/`_read_gatt_char` (TBC:246-261): every auth write resets
    /// the read count and sets "authenticated" to `data == token`. Reads of any other characteristic
    /// throw `.characteristicNotFound`.
    package static func laMarzocco(token: String, confirmOnRead: Int = 1,
                                   commandResponse: Data = BluetoothTestVectors.commandSuccess,
                                   settingResponses: [BluetoothReadSetting: Data] = [:]) -> FakeBluetoothLink {
        let machine = ScriptedMachine(token: Data(token.utf8), confirmOnRead: confirmOnRead,
                                      commandResponse: commandResponse, settingResponses: settingResponses)
        let link = FakeBluetoothLink()
        link.onWrite = { characteristic, data in machine.write(characteristic, data) }
        link.onRead = { characteristic in try machine.read(characteristic) }
        return link
    }

    // MARK: - BluetoothLink

    package func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        requested(timeout)
        try await begin(.discover(refresh: refresh))
        let found = locked { refresh ? (state.presentAfterRefresh ?? state.present) : state.present }
        return wanted.intersection(found)
    }

    package func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data {
        requested(timeout)
        try await begin(.read(characteristic))
        let onRead = locked { state.onRead }
        return try onRead(characteristic)
    }

    package func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        requested(timeout)
        try await begin(.write(characteristic, data))
        let onWrite = locked { state.onWrite }
        try onWrite(characteristic, data)
    }

    package func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws {
        requested(timeout)
        try await begin(.subscribe(characteristic))
        let (replay, now) = locked { (state.replayOnSubscribe, state.now) }
        for value in replay {
            let receivedAt = now()
            locked {
                guard state.isConnected else { return }
                continuation.yield(.notification(characteristic, GATTNotification(value: value, receivedAt: receivedAt)))
            }
        }
    }

    package func unsubscribe(_ characteristic: GATTUUID) async {
        await record(.unsubscribe(characteristic))
    }

    /// Records `.disconnect`, then — like bleak, which reports a user disconnect through the
    /// disconnected callback (TBC:278-281) — yields `.disconnected(nil)` once and finishes `events`.
    package func disconnect() async {
        await record(.disconnect)
        terminate(nil)
    }

    package func attMTU() async -> Int? {
        locked { state.mtu }
    }

    package func gattTable(timeout: Duration) async throws -> [BluetoothGATTService] {
        let gatt = try locked {
            state.requestedTimeouts.append(timeout)
            guard state.isConnected else { throw BluetoothTransportError.notConnected }
            return state.gatt
        }
        try Task.checkCancellation()
        return gatt
    }

    // MARK: - Private

    private func requested(_ timeout: Duration) {
        locked { state.requestedTimeouts.append(timeout) }
    }

    /// Awaits `beforeOp`, records `op`, then throws `.notConnected` if the link is down, else
    /// `CancellationError` if the calling task is cancelled — the real adapter's
    /// `withTaskCancellationHandler` bridge (§5.3, §5.4), so a cancelled op held by `beforeOp` fails
    /// once released instead of completing (C41, `TBC:1197-1220`).
    private func begin(_ op: FakeOp) async throws {
        let connected = await record(op)
        if !connected { throw BluetoothTransportError.notConnected }
        try Task.checkCancellation()
    }

    /// Awaits `beforeOp`, records `op`; returns whether the link was up when the op was recorded.
    @discardableResult
    private func record(_ op: FakeOp) async -> Bool {
        if let beforeOp = locked({ state.beforeOp }) {
            await beforeOp(op)
        }
        return locked {
            state.recordedOps.append(op)
            return state.isConnected
        }
    }

    private func terminate(_ error: BluetoothTransportError?) {
        locked {
            guard state.isConnected else { return }
            state.isConnected = false
            continuation.yield(.disconnected(error))
            continuation.finish()
        }
    }

    private func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// The state of `FakeBluetoothLink.laMarzocco`'s scripted machine.
private final class ScriptedMachine: @unchecked Sendable {
    private let token: Data
    private let confirmOnRead: Int
    private let commandResponse: Data
    private let settingResponses: [BluetoothReadSetting: Data]
    private let lock = NSLock()
    private var authenticated = false
    private var authReads = 0
    private var lastSetting: BluetoothReadSetting?

    init(token: Data, confirmOnRead: Int, commandResponse: Data, settingResponses: [BluetoothReadSetting: Data]) {
        self.token = token
        self.confirmOnRead = confirmOnRead
        self.commandResponse = commandResponse
        self.settingResponses = settingResponses
    }

    func write(_ characteristic: GATTUUID, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if characteristic == BluetoothConstants.authCharacteristic {
            authenticated = data == token
            authReads = 0
        } else if characteristic == BluetoothConstants.readCharacteristic {
            let name = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
            lastSetting = BluetoothReadSetting(rawValue: name)
        }
    }

    func read(_ characteristic: GATTUUID) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        switch characteristic {
        case BluetoothConstants.authCharacteristic:
            authReads += 1
            return Data([authenticated && authReads >= confirmOnRead ? 0x01 : 0x00])
        case BluetoothConstants.writeCharacteristic:
            return commandResponse
        case BluetoothConstants.readCharacteristic:
            return lastSetting.flatMap { settingResponses[$0] } ?? Data("[]".utf8)
        default:
            throw BluetoothTransportError.characteristicNotFound(characteristic)
        }
    }
}
