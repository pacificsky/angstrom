import Foundation

/// BLE client for one La Marzocco machine (port of pylamarzocco's LaMarzoccoBluetoothClient).
///
/// Build it with a ``BluetoothTransport`` (from `BluetoothTransport.coreBluetooth()` in
/// `AngstromBluetooth`), the machine's ``BluetoothPeripheralID`` and its ``BluetoothAuthToken``.
/// The client connects on demand, authenticates, serialises requests, and closes an idle link
/// after 30 s unless the shot counter is running.
public actor LaMarzoccoBluetoothClient {
    /// Name prefixes kept by discovery (`BT_MODEL_PREFIXES`).
    public static let machineNamePrefixes: [String] = BluetoothConstants.machineNamePrefixes
    /// The peripheral this client talks to (upstream `address`; a CoreBluetooth UUID, not a MAC).
    public nonisolated let peripheral: BluetoothPeripheralID

    // MARK: Internal state (frozen, SPEC §6.11)

    let central: any BluetoothCentral
    let sleeper: any BluetoothSleeper
    let now: @Sendable () -> Date
    let token: BluetoothAuthToken
    let log: (@Sendable (String) -> Void)?
    var timing: BluetoothTiming
    var link: (any BluetoothLink)?
    var linkWatcher: Task<Void, Never>?
    var discovered: Set<GATTUUID>
    var needsRediscovery: Bool
    var reportedConnected: Bool
    var idleTask: Task<Void, Never>?
    var gateBusy: Set<BluetoothGate>
    var gateWaiters: [BluetoothGate: [CheckedContinuation<Void, Never>]]
    var shotCounterEnabled: Bool
    var shotCounterSubscribed: Bool
    var replayPending: Bool
    var tracker: BrewingTracker
    var reconnectTask: Task<Void, Never>?
    var connectionListeners: [UUID: AsyncStream<ConnectionEvent>.Continuation]
    var shotCounterListeners: [UUID: AsyncStream<ShotCounterEvent>.Continuation]
    var rawFrameListeners: [UUID: AsyncStream<RawBluetoothFrame>.Continuation]
    var backgroundTasks: [UUID: Task<Void, Never>]

    /// The two FIFO gates: `.request` serialises whole requests, `.connection` serialises
    /// connect/auth/teardown/subscribe. Lock order is always request → connection.
    enum BluetoothGate: Hashable { case connection, request }
    /// Which step a transport error came from (selects the §4.4.1 mapping column).
    enum BluetoothErrorPhase { case connect, authenticate, request }

    // MARK: Public surface

    public init(transport: BluetoothTransport, peripheral: BluetoothPeripheralID,
                token: BluetoothAuthToken, logHandler: (@Sendable (String) -> Void)? = nil) {
        self.peripheral = peripheral
        self.central = transport.central
        self.sleeper = transport.sleeper
        self.now = transport.now
        self.token = token
        self.log = logHandler
        self.timing = BluetoothTiming()
        self.link = nil
        self.linkWatcher = nil
        self.discovered = []
        self.needsRediscovery = false
        self.reportedConnected = false
        self.idleTask = nil
        self.gateBusy = []
        self.gateWaiters = [:]
        self.shotCounterEnabled = false
        self.shotCounterSubscribed = false
        self.replayPending = false
        self.tracker = BrewingTracker()
        self.reconnectTask = nil
        self.connectionListeners = [:]
        self.shotCounterListeners = [:]
        self.rawFrameListeners = [:]
        self.backgroundTasks = [:]
        self.authenticationFailed = false
    }

    /// An authenticated link is up.
    public var isConnected: Bool { link != nil }
    /// The last auth read was not 0x01 — usually a wrong token.
    public internal(set) var authenticationFailed: Bool
    /// Shot counter enabled ∧ subscribed ∧ connected.
    public var shotCounterActive: Bool { shotCounterEnabled && shotCounterSubscribed && link != nil }

    /// Edge-triggered `.connected` (after auth) / `.disconnected` (any close, incl. idle).
    public func connectionEvents() -> AsyncStream<ConnectionEvent> {
        fatalError("unimplemented: BT-W1-09")
    }

    /// Stop the shot counter (if any) and close the link. Never throws; idempotent.
    public func disconnect() async {
        fatalError("unimplemented: BT-W1-09")
    }

    /// Multiplexed raw BLE frames (writes, reads, notifications, lifecycle markers). Free without listeners.
    public func rawFrames() -> AsyncStream<RawBluetoothFrame> {
        fatalError("unimplemented: BT-W1-09")
    }

    // MARK: Internal helpers [main]

    /// FIFO acquire of `gate`.
    func acquire(_ gate: BluetoothGate) async {
        fatalError("unimplemented: BT-W1-09")
    }

    func release(_ gate: BluetoothGate) {
        fatalError("unimplemented: BT-W1-09")
    }

    /// §4.2.
    func ensureConnected(refresh: Bool = false) async throws -> any BluetoothLink {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-09")
    }

    /// §3.4.
    func authenticate(_ link: any BluetoothLink) async throws {
        throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-09")
    }

    /// §4.6.
    func resetIdleTimer() {
        fatalError("unimplemented: BT-W1-09")
    }

    /// The caller holds `.connection`.
    func disconnectInternal(fromIdleTimer: Bool = false) async {
        fatalError("unimplemented: BT-W1-09")
    }

    func dropConnection(fromIdleTimer: Bool = false) async {
        fatalError("unimplemented: BT-W1-09")
    }

    /// Runs `dropConnection()` in a tracked background `Task`.
    func dropConnectionInBackground() {
        fatalError("unimplemented: BT-W1-09")
    }

    /// §4.13.
    func handleConnectionLost() {
        fatalError("unimplemented: BT-W1-09")
    }

    /// Edge-triggered connection-event emission.
    func setConnected(_ connected: Bool) {
        fatalError("unimplemented: BT-W1-09")
    }

    /// §4.7.
    func handleLinkEvent(_ event: LinkEvent, from source: any BluetoothLink) {
        fatalError("unimplemented: BT-W1-09")
    }

    /// No-op without listeners.
    func emitRaw(_ kind: RawBluetoothFrame.Kind, _ direction: RawBluetoothFrame.Direction,
                 characteristic: GATTUUID?, data: Data, isSecret: Bool) {
        fatalError("unimplemented: BT-W1-09")
    }

    func emitRawEvent(_ marker: String) {
        fatalError("unimplemented: BT-W1-09")
    }

    func emitShotCounter(_ event: ShotCounterEvent) {
        fatalError("unimplemented: BT-W1-09")
    }

    /// §4.4.1.
    nonisolated static func mapTransportError(_ error: any Error,
                                              phase: BluetoothErrorPhase) -> any Error {
        fatalError("unimplemented: BT-W1-09")
    }

    // MARK: Test seams

    package func setTimingForTesting(_ timing: BluetoothTiming) {
        self.timing = timing
    }

    /// Awaits every tracked background task (drops, reconnect loop, idle task excluded).
    package func drainBackgroundWorkForTesting() async {
        fatalError("unimplemented: BT-W1-09")
    }

    /// Any tracked background work is pending, including the idle task and the reconnect loop.
    package var hasBackgroundWorkForTesting: Bool {
        fatalError("unimplemented: BT-W1-09")
    }
}
