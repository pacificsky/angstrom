## 3. Plan-level contracts (frozen by Wave 0)

These declarations are as binding as SPEC §6. The access rule for everything an agent adds is the
one in SPEC §6: `private`/`fileprivate` in library and test-support sources; internal `XCTestCase`
classes and `test…` methods (private helpers) in test files; internal command types and their
`@Option`/`@Flag`/`@Argument` properties in `cli/`.

### 3.0 Stub conventions

After Wave 0, **every** declaration of SPEC §6 and of §3.1–§3.3 below exists with its exact
signature, and the package builds. Bodies follow these rules:

- **Real in Wave 0:** every initialiser, every stored property, every constant, and the leaf
  value types (SPEC §6.1, §6.2, §6.3, §6.4, §6.5, §6.6 types, §6.7, §6.9 types incl.
  `isEmpty`/`merging`/subscript, §6.10, §6.12 `BluetoothDashboardState`, §6.15). Also
  `BluetoothCodec.readRequestFrame` and `BluetoothCodec.authFrame`, which are one-liners the client
  core needs in Wave 1.
- **Stub:** the body names its owner. A throwing function does
  `throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-09")`. A non-throwing one does
  `fatalError("unimplemented: BT-W1-09")`. A CLI `run()` does
  `throw CLIError("unimplemented: BT-W2-04")`.
- **Inert stubs.** These must not trap, because constructors or other packages' tests reach them
  before their owner lands:

| Declaration | Body until its owner lands | Owner |
|---|---|---|
| `LaMarzoccoBluetoothClient.init`, `isConnected` (`link != nil`), `shotCounterActive` (`shotCounterEnabled && shotCounterSubscribed && link != nil`), `authenticationFailed`, `setTimingForTesting` | real | BT-W0-01 |
| `LaMarzoccoBluetoothClient.disableShotCounter()` | `guard shotCounterEnabled else { return false }`, then the stub trap | BT-W2-02 |
| `LaMarzoccoBluetoothClient.stopNotifyInternal()` | trap if `shotCounterSubscribed && link != nil`, else `shotCounterSubscribed = false` | BT-W2-02 |
| `LaMarzoccoBluetoothClient.handleShotCounterNotification(_:)` | `guard shotCounterEnabled else { return }`, then the stub trap | BT-W2-02 |
| `BrewingTracker.init()` | real (empty data, nil start) | BT-W0-01 |
| `BluetoothOpTable.init()` | real (empty tables) | BT-W0-01 |
| `LaMarzoccoMachine` initialisers, `client` accessor, `hasCloudClient`, `hasBluetoothClient`, `setBaseDashboard`, `updateBaseDashboard`, `renderDashboard`, `setBluetoothBrewingExpiryForTesting` | real | BT-W0-02 |
| `LaMarzoccoMachine.startObservingBluetoothConnection()` | no-op | BT-W3-06 |
| `LaMarzoccoMachine.bluetoothFirst(bluetooth:cloud:)` | real when `bluetooth == nil` (`guard let cloud = cloudClient else { throw LaMarzoccoError.cloudOnlyFunctionality }; return try await cloudOperation(cloud)`), trap otherwise | BT-W3-07 |

Wave gates grep for markers (§1.5). Wave 0's gate also checks that every remaining marker names
one of the owners listed in §2.

### 3.1 `BluetoothOpTable` (`Sources/Angstrom/Bluetooth/BluetoothOpTable.swift`)

SPEC §6.10 leaves the exact generic signature to the adapter's owner. To let BT-W1-07 (the table)
and BT-W1-08 (the adapter) run in parallel, it is frozen here. It is note 06 Appendix B's
`OpTable`, generalised over the key:

```swift
/// Queue-confined table of in-flight operations (NOT thread-safe: adapter queue only).
/// Exactly-once: every completion path goes through `finish`, which removes the entry
/// BEFORE calling `complete`.
package final class BluetoothOpTable<Key: Hashable & Sendable> {
    package typealias Completion = (Result<any Sendable, any Error>) -> Void
    package init()
    /// Register an in-flight op. `isGATTRequest`: an abandoned op still owes one delegate callback.
    package func register(_ token: UInt64, key: Key, isGATTRequest: Bool, complete: @escaping Completion)
    /// Remove + complete. `abandoning: true` (timeout/cancel) records an owed reply for GATT requests.
    @discardableResult
    package func finish(_ token: UInt64, _ result: Result<any Sendable, any Error>, abandoning: Bool) -> Bool
    /// Delegate-callback path: swallow one owed reply for `key` if any, else finish the OLDEST op with `key`.
    @discardableResult
    package func finishOldest(_ key: Key, _ result: Result<any Sendable, any Error>) -> Bool
    /// A request was sent without anyone awaiting it (e.g. best-effort unsubscribe).
    package func owe(_ key: Key)
    /// An op or an owed reply is outstanding for `key`.
    package func isAwaiting(_ key: Key) -> Bool
    /// Fail every op whose key matches, and drop owed replies for matching keys.
    package func failAll(where match: (Key) -> Bool, _ error: any Error)
}
```

### 3.2 angcli internal API (`cli/Sources/angcli/Ble/`)

Landed by BT-W1-12 as stubs (types and signatures exact). They are implemented by BT-W2-03 and
used by BT-W2-04/05/06.

```swift
// Ble.swift (complete in BT-W1-12)
struct Ble: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ble",
        abstract: "Talk to a nearby La Marzocco machine over Bluetooth (debugging).",
        subcommands: [BleScan.self, BleGatt.self, BleToken.self, BleRead.self, BleCmd.self, BleListen.self])
}

// BleSession.swift (BT-W2-03)
/// Options shared by every subcommand that talks to one machine (use with @OptionGroup).
struct BleTargetOptions: ParsableArguments {
    @Option(name: .long, help: "Peripheral identifier from `angcli ble scan` (a CoreBluetooth UUID, not a MAC).")
    var peripheral: String?
    @Option(name: .long, help: "Machine serial number; used to fetch the Bluetooth token from the cloud.")
    var serial: String?
    @Option(name: .customLong("ble-token"), help: "Bluetooth token. Discouraged: it lands in your shell history; prefer LAMARZOCCO_BLE_TOKEN.")
    var bleToken: String?
    init() {}
}
enum BleTokenSource: String, Equatable, Sendable { case flag, environment, cloud }
enum BleSession {
    static let tokenEnvironmentVariable = "LAMARZOCCO_BLE_TOKEN"
    /// `BluetoothTransport.coreBluetooth()`, created once per process.
    static func makeTransport() -> BluetoothTransport
    /// Pure precedence (SPEC §10.2): non-empty flag, then non-empty env var; nil → ask the cloud.
    static func localToken(flag: String?, environment: [String: String]) -> (token: BluetoothAuthToken, source: BleTokenSource)?
    /// localToken, else Bootstrap.connect() + MachineSelector.choose(serial:) + bluetoothAuthToken(serial:).
    static func resolveToken(_ options: BleTargetOptions,
                             environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> BluetoothAuthToken
    /// Pure rule: exactly one → it; none → throws CLIError("No La Marzocco machine found nearby"); several → nil (caller prompts).
    static func selectPeripheral(from found: [DiscoveredPeripheral]) throws -> DiscoveredPeripheral?
    /// --peripheral, else a 5 s discoverMachines scan + selectPeripheral + an interactive pick on stderr.
    static func resolvePeripheral(_ options: BleTargetOptions, transport: BluetoothTransport) async throws -> BluetoothPeripheralID
    static func makeClient(_ options: BleTargetOptions, transport: BluetoothTransport) async throws -> LaMarzoccoBluetoothClient
    /// SPEC §10.3 error texts for .bluetoothUnavailable; other errors → their errorDescription.
    static func cliError(_ error: any Error) -> CLIError
}

// BleOutput.swift (BT-W2-03). Every function returns one JSON line (SPEC §10.3) or nil if encoding fails.
enum BleOutput {
    static func rawLine(_ frame: RawBluetoothFrame, ts: String = Timestamp.now()) -> String?
    static func shotCounterLine(_ event: ShotCounterEvent, ts: String = Timestamp.now()) -> String?
    static func connectionLine(_ event: ConnectionEvent, ts: String = Timestamp.now()) -> String?
    static func peripheralLine(_ peripheral: DiscoveredPeripheral) -> String?
    static func gattLines(_ services: [BluetoothGATTService]) -> [String]
    static func readLine<D: Encodable>(setting: BluetoothReadSetting, raw: Data, decoded: D?,
                                       ts: String = Timestamp.now()) -> String?
    static func commandLine(command: String, status: BluetoothCommandStatus, ts: String = Timestamp.now()) -> String?
    /// {"token":"**REDACTED**","length":n} unless showSecret.
    static func tokenLine(_ token: BluetoothAuthToken, showSecret: Bool) -> String?
}

// Output.swift addition (complete in BT-W1-12): SPEC §10.4.
extension Redact {
    static func bluetoothFrame(_ frame: RawBluetoothFrame) -> (hex: String, text: String?)
}
```

`BleScan`, `BleGatt`, `BleToken`, `BleRead`, `BleCmd` and `BleListen` are `AsyncParsableCommand`
structs, each in its own file. Their options belong to their implementing package (SPEC §10.1).

### 3.3 UI test harness (`Tests/AngstromUITests/Bluetooth/BluetoothMachineHarness.swift`)

Landed complete by BT-W0-04 and used by every AngstromUI Bluetooth test. It builds a **real**
`LaMarzoccoBluetoothClient` over the AngstromTestSupport fakes (SPEC §9.2: no mocked client), and
optionally a cloud client over the existing `MockBackend`/`MockURLProtocol`
(`Tests/AngstromUITests/MockTransport.swift`, unchanged).

```swift
@MainActor
final class BluetoothMachineHarness {
    enum Seed { case standard, empty, none, custom(Dashboard) }
    enum BluetoothFailure: Equatable {
        case none
        case connect                                   // every connect attempt fails .disconnected(code: 7) — via central.connectFailure
        case commandWrite                              // writes to 0b0b… throw .gatt(domain: "CBATTErrorDomain", code: 14)
        case commandTimeout                            // writes to 0b0b… throw .timedOut("write")
        case unavailable(BluetoothAvailability)        // central reports this availability
    }
    static let serial: String                         // "MR123456"
    let central: FakeBluetoothCentral
    let sleeper: ManualBluetoothSleeper               // manual: [.idleDisconnect]
    let clock: BluetoothTestClock                     // starts 2026-01-01T12:00:00Z
    let backend: MockBackend?                         // nil when cloud == false
    let bluetooth: LaMarzoccoBluetoothClient?         // nil when bluetooth == false
    let machine: LaMarzoccoMachine
    /// `.standard` seeds BT-DASH-SEED-001 (SPEC §9.3.6) for `model` through a MachineSnapshot;
    /// `.empty` seeds Dashboard(machine: Machine(serialNumber:, model:), widgets: []); `.none` seeds nothing.
    init(model: Model = .lineaMicra, seed: Seed = .standard, cloud: Bool = true, bluetooth: Bool = true,
         token: String = "token", settingResponses: [BluetoothReadSetting: Data] = [:],
         commandResponse: Data = BluetoothTestVectors.commandSuccess, failure: BluetoothFailure = .none)
    /// BT-DASH-SEED-001: CMMachineStatus(standby,[brewing,standby],standby), CMCoffeeBoiler(standby, enabled,
    /// enabledSupported false, 93.0, 80…100 step 0.1), CMSteamBoilerLevel(standby, enabled, true, level1, true),
    /// CMSteamBoilerTemperature(standby, enabled, false, 126.0, 126…131 step 1.0, true); all index 1.
    static func seedDashboard(model: Model) -> Dashboard
    var links: [FakeBluetoothLink] { get }                          // central.links
    func bluetoothWrites(to characteristic: GATTUUID) -> [Data]     // across all links, in order
    func cloudCommandCount(_ name: String) -> Int                   // backend path suffix "/command/<name>"
    func cloudCommandBody(_ name: String) throws -> [String: Any]?  // JSON body of the last such command
}
```

The cloud backend answers `/auth/init`, `/auth/signin`, `/dashboard`, `/settings`,
`/scheduling` and `/stats` from the existing `Tests/AngstromUITests/Fixtures`, and acknowledges
every `/command/` with `[{"id":"cmd1","status":"Pending"}]`. That mirrors `fixtureBackend()` in
`LaMarzoccoMachineTests.swift:14-33`.

### 3.4 Test-file inventory

BT-W0-03 creates every library file below as a placeholder (imports plus an empty
`final class <Name>: XCTestCase {}` whose doc comment names the owner), BT-W0-04 every UI file,
and BT-W1-12 every CLI file. The owner replaces the placeholder. The manifest lists each file under
its owner's `owns.modify`.

| File | Owner |
|---|---|
| `Tests/AngstromTests/Bluetooth/FakeBluetoothTests.swift` | BT-W0-03 (creates, complete) |
| `Tests/AngstromTests/Bluetooth/BluetoothEnumsTests.swift`, `BluetoothWireCoercionTests.swift`, `BluetoothModelsTests.swift` | BT-W1-01 |
| `…/BluetoothCodecTests.swift` | BT-W1-02 |
| `…/BluetoothResponseDecoderTests.swift` | BT-W1-03 |
| `…/BrewingStateMachineTests.swift`, `ShotCounterNotificationDecoderTests.swift` | BT-W1-04 |
| `…/DashboardBluetoothTests.swift` | BT-W1-05 |
| `…/BluetoothTokenTests.swift` | BT-W1-06 |
| `…/BluetoothOpTableTests.swift` | BT-W1-07 |
| `…/BluetoothClientCoreTests.swift` | BT-W1-09 |
| `…/BluetoothDiscoveryTests.swift` | BT-W1-10 |
| `…/BluetoothClientRequestsSmokeTests.swift` | BT-W2-01 |
| `…/BluetoothClientShotCounterSmokeTests.swift` | BT-W2-02 |
| `…/BluetoothConnectionTests.swift`, `BluetoothAuthTests.swift` | BT-W3-01 |
| `…/BluetoothRequestTests.swift`, `BluetoothDiagnosticsTests.swift` | BT-W3-02 |
| `…/ShotCounterLifecycleTests.swift` | BT-W3-03 |
| `…/ShotCounterNotificationTests.swift`, `ShotCounterRecordedSessionTests.swift` | BT-W3-04 |
| `…/ShotCounterReconnectTests.swift` | BT-W3-05 |
| `Tests/AngstromUITests/Bluetooth/BluetoothMachineHarness.swift`, `BluetoothMachineHarnessTests.swift` | BT-W0-04 (creates, complete) |
| `Tests/AngstromUITests/Bluetooth/MachineTransportRoutingTests.swift` | BT-W1-11 |
| `…/BluetoothDeviceStateTests.swift` | BT-W3-06 |
| `…/BluetoothFallbackTests.swift`, `BluetoothCommandSideEffectTests.swift` | BT-W3-07 |
| `…/BluetoothDashboardRefreshTests.swift` | BT-W3-08 |
| `…/ShotCounterOverlayTests.swift` | BT-W3-09 |
| `cli/Tests/angcliTests/BleSessionTests.swift`, `BleOutputTests.swift` | BT-W2-03 |
| `cli/Tests/angcliTests/BleDiscoveryCommandTests.swift` | BT-W2-04 |
| `cli/Tests/angcliTests/BleRequestCommandTests.swift` | BT-W2-05 |
| `cli/Tests/angcliTests/BleListenTests.swift` | BT-W2-06 |

No existing test file changes (SPEC §7.1).

### 3.5 Test conventions and the gap-test glossary

- XCTest only. `final class …Tests: XCTestCase`. AngstromUITests classes are `@MainActor`. Use
  `@testable import Angstrom` (and `@testable import AngstromUI`) and `import AngstromTestSupport`.
- **Doc-comment header (checked mechanically by BT-W5-01):**
  - A parity test starts with `/// Upstream: <test function> (<path>:<line>) [<case ids>]`, for
    example `/// Upstream: test_ble_set_power (tests/test_bluetooth_client.py:295) [C01]`. The
    path is relative to `$UPSTREAM`. The line is the `def` line listed in §7.2.
  - An Angstrom-only test starts with `/// Angstrom-only: <G-… or D… id> — <one line>`. Where no
    G-/D- id applies (test-support self-tests, and tests a brief names without an id), the id is the
    SPEC section the test pins: `/// Angstrom-only: §6.17 — <one line>`.
- Timing comes only from `ManualBluetoothSleeper`, `BluetoothTestClock` and
  `setBluetoothBrewingExpiryForTesting`. Await background work with
  `drainBackgroundWorkForTesting()`, and await stream events by iterating the stream (with a
  bounded `XCTestExpectation` timeout of ≤ 5 s as a hang guard only).
- **Gap-test glossary.** These are upstream behaviours that no upstream test covers (research note
  04 §4), restated for Swift. Every id has exactly one owner.

| Id | Behaviour to assert (Swift terms) | Owner |
|---|---|---|
| G-CODEC-1 | `readToken`: one connect attempt (10 s), no auth, reads `0c0b…`, strict UTF-8, **no** NUL stripping, always disconnects | BT-W1-10 |
| G-CODEC-2 | Bytes of `setSteam(on:)` and `setPower(on: false)` (BT-REQ-005, BT-REQ-002) | BT-W1-02 |
| G-CODEC-3 | Coercion rules of SPEC §3.10, incl. `"false"` → false (D5a), container truthiness, required-string `null` → `"None"`, container → JSON text (D5c), int truncation and range (D5d), non-finite and `_` strings rejected (D5e/f), numeric strings | BT-W1-01 |
| G-CODEC-4 | Reads cut at the first NUL. Notifications strip NULs at both ends only; an inner NUL drops the notification | BT-W1-02 (reads), BT-W1-04 (notifications) |
| G-CODEC-5 | Malformed read responses (`[]` capabilities, unknown mode, non-JSON) throw `.decoding`, do **not** drop the link | BT-W3-02 |
| G-CODEC-6 | Command status with a missing key or non-object → `.decoding("bluetooth command: …")` | BT-W1-03 |
| G-CODEC-7 | `MachineStatistics`: absent or `null` → unset and the rest of the notification is processed; a JSON string → its parsed content, a parsed `null` → unset; any other value, or an unparseable string, drops the whole notification, brewing keys included (BT-NTF-COERCE-002…005) | BT-W1-04 |
| G-CODEC-8 | Discovery skips a peripheral whose name is nil or empty | BT-W1-10 |
| G-AUTH-1 | A transport error during the auth write or read → `.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: …")`, not the auth case | BT-W3-01 |
| G-AUTH-2 | Auth poll interval: 9 `.authPoll` sleeps of 50 ms for 10 reads | BT-W3-01 |
| G-AUTH-3 | `authenticationFailed` reflects the last auth read and is unchanged by a pre-auth connect failure | BT-W3-01 |
| G-CONN-1 | Connect: 3 attempts, 20 s timeout each, backoff 0.25 s after `.timedOut`, else 0.1 s | BT-W1-09 |
| G-CONN-2 | A characteristic found by the in-place rediscovery serves the request on the same link (D7b) | BT-W3-01 |
| G-CONN-3 | Teardown completes and emits its events on every path when the link is already dead (its ops throw `.notConnected`). The seam's `disconnect()`/`unsubscribe` are non-throwing, so there is nothing to swallow | BT-W1-09 |
| G-CONN-4 | The idle timer is re-armed on a reused link, armed only after auth, and requests 30 s | BT-W3-01 |
| G-CONN-5 | With the shot counter enabled but no link, a failed request **does** drop (schedules `dropConnectionInBackground`) | BT-W3-01 |
| G-CONN-6 | A missing characteristic drops the link even while the shot counter runs, which then starts the reconnect loop | BT-W3-03 |
| G-CONN-7 | A link loss cancels the idle task (D16) | BT-W3-01 |
| G-CONN-8 | A link drop between a request's write and read fails the request; no silent reconnect (D7a) | BT-W3-01 |
| G-RC-1 | Reconnect backoff `1,2,4,8,16,32,60,60` s, doubling only after connection-class failures | BT-W3-05 |
| G-RC-2 | Auth failures are cumulative per loop run: auth, conn, auth, auth → gives up | BT-W3-05 |
| G-RC-3 | The characteristic disappears during a reconnect → give up, idle timer re-armed, no second `.unsubscribed` | BT-W3-05 |
| G-RC-4 | `startShotCounter()` throws when the first connect/auth fails, disables the counter, starts no loop | BT-W3-03 |
| G-RC-5 | An idle or error-path drop while the counter is enabled starts the reconnect loop | BT-W3-05 |
| G-SC-1 | `stopShotCounter()` with no counter running only re-arms the idle timer | BT-W3-03 |
| G-SC-2 | (callbacks) not applicable (D4). Covered by C31 restated | BT-W3-04 |
| G-SC-3 | The tracker resets on every successful subscribe | BT-W3-04 |
| G-SC-4 | A notification after `stopShotCounter()` is silently dropped | BT-W3-03 |
| G-SC-5 | A second start while subscribed: no resubscribe, no `.subscribed`, tracker and replay flag kept | BT-W3-03 |
| G-SC-6 | `startShotCounter()` while a reconnect is pending: both serialise on the connection gate; one subscribe | BT-W3-03 |
| G-SC-7 | The reconnect loop sleeps before its first attempt | BT-W3-05 |
| G-DEV-1 | A non-success BLE status falls through to the cloud when a cloud client exists | BT-W3-07 |
| G-DEV-2 | `.bluetoothTimedOut` and `.decoding` from BLE propagate with no cloud call | BT-W3-07 |
| G-DEV-3 | BLE widget defaults (Mini vs others), coffee never `.off`, missing steam entry keeps stale steam widgets, duplicate ids: last wins | BT-W1-05 |
| G-DEV-4 | Steam-level edges: 130.5 → level3, −1 → level3, 127.99 → level1 (on `Double` targets; the upstream decode path truncates first, D9) | BT-W1-01 |
| G-DEV-5 | A REST `refreshDashboard()` during an active overlay re-applies the overlay to the new widget | BT-W3-09 |
| G-DEV-6 | `.subscribed` after a reconnect does not clear the overlay; only expiry or loss does | BT-W3-09 |
| G-DEV-7 | Telemetry `MachineMode` also updates `CMMachineGroupStatus.mode` | BT-W3-09 |
| G-DEV-8 | Auto-standby `"HH:MM"`: 1440 → `"24:00"`, 61 → `"01:01"`, 0 → `"00:00"` | BT-W3-07 |
| G-DEV-9 | `isBluetoothConnected` follows the real client's connection events | BT-W3-06 |
| G-DEV-10 | A created `CMMachineStatus` gets `[brewing, standby]`; an existing one keeps `availableModes`/`brewingStartTime` | BT-W1-05 |
| G-DEV-11 | `setSteam` updates both steam widgets when both exist | BT-W3-07 |
| G-DEV-12 | Device state is mutated **before** the `bluetoothEvents()` event is emitted | BT-W3-09 |
| G-DEV-13 | Every client event is handled on the MainActor before widgets or the expiry are touched (design check) | BT-W4-03 |

### 3.6 Refinements of SPEC §7 (file map and work packages)

| # | Refinement | Why |
|---|---|---|
| R1 | No `Sources/AngstromBluetooth/Placeholder.swift`. BT-W0-01 instead creates `BluetoothTransport+CoreBluetooth.swift` with the two §6.14 public declarations as stubs. BT-W1-08 adds the adapter files. | The target compiles from Wave 0, and no file is created only to be deleted. |
| R2 | `BluetoothOpTable`'s generic signature is frozen in §3.1 instead of being left to the adapter's owner. | It lets the table and the adapter be built in parallel. |
| R3 | The SPEC's "U1" splits into BT-W0-02 (declarations), BT-W1-11 (the dashboard funnel and the BLE-first routing of the six methods in `LaMarzoccoMachine.swift`), and BT-W3-06/07/08 (one extension file each). `LaMarzoccoMachine.swift` has exactly one owner after Wave 0. | Parallelism without sharing the main file. |
| R4 | The SPEC's "T5/T6" suites are owned by the UI packages that implement the behaviour. | Avoids a sixth wave. Independence comes from BT-W4-02. |
| R5 | `BluetoothClientSmokeTests.swift` becomes `BluetoothClientCoreTests.swift` (W1-09), `BluetoothClientRequestsSmokeTests.swift` (W2-01) and `BluetoothClientShotCounterSmokeTests.swift` (W2-02). | One test file per client file owner. |
| R6 | C51 (`test_ble_device_callback`) moves from `BluetoothDiscoveryTests` to `BluetoothConnectionTests` (BT-W3-01). M15 moves from `ShotCounterOverlayTests` to `BluetoothDeviceStateTests` (BT-W3-06). | Each test needs code from its new owner's wave. |
| R7 | Upstream `test_cloud_only_without_cloud_client` (`tests/test_thing.py:29`) is added to the matrix as **T00**, owned by BT-W1-11. | The SPEC matrix omitted it, but it pins the `@cloud_only` behaviour (Q3). |
| R8 | `cli/Tests/angcliTests/BleTests.swift` is split into five files (§3.4). | One file per CLI package. |
| R9 | The UI test harness (§3.3) and the angcli internal API (§3.2) are frozen by the plan. | Shared helpers without shared ownership. |
| R10 | Gates G5/G5' (no warnings, from-scratch build) and the doc-comment headers (§3.5) are plan rules. | They make "no orphan test" and "Swift 6 clean" mechanical. |
| R11 | The SPEC's "T0" splits into BT-W0-03 (AngstromTestSupport and the library placeholders, needs only BT-W0-01) and BT-W0-04 (the UI harness and UI placeholders, needs BT-W0-02). Wave 0 runs as a dag, so BT-W0-02 and BT-W0-03 run side by side. | Shortens the critical path by one package. |

---
