# 05 — Angstrom seams for a Bluetooth port

> Research note for the BT-parity implementation plan. **Scope:** what in the
> existing Angstrom codebase (v1.7.0, `main` @ `e1bc403`) a Bluetooth port must
> integrate with, mirror, or edit. Upstream wire facts are cited only where they
> decide an Angstrom-side seam; the upstream BT protocol itself is covered by the
> other research notes.
>
> Citation conventions: Angstrom paths are repo-relative to
> `$REPO`. Upstream paths are relative to
> `…/scratchpad/upstream/pylamarzocco/` at `4c639ee` (v2.5.6), for example
> `src/pylamarzocco/devices/_machine.py:983`. Anything not settled by source is
> marked **UNVERIFIED**, with what would resolve it.
>
> **Verification pass (2026-11-13):** every Angstrom `path:line` in this note was
> re-checked against the working tree at `e1bc403`, and every upstream citation
> against the clone at `4c639ee`. That pass resolved three items that were
> previously UNVERIFIED: the BT status casing (§2.5), BT temperature rounding (§3.4)
> and the `lastShotTime` rule (§4.5). It also added §2.11 (exact-byte command
> encoding) and corrected the fixture token inventory (§3.5).

---

## 0. TL;DR (the eleven facts that shape the plan)

1. **One transport seam to copy.** `WebSocketChannel` (`Sources/Angstrom/WebSocket.swift:8-14`)
   plus an internal factory closure and a `…ForTesting` setter
   (`LaMarzoccoCloudClient.swift:52,542-544,746-749`) is the house pattern for
   "real I/O behind a protocol, scripted mock in tests". A BT GATT seam
   (`BluetoothTransport` or similar) should copy it one-for-one, so tests never touch
   CoreBluetooth.
2. **Multiplexed `AsyncStream`s are the house event API.** Every live feed is
   `[UUID: AsyncStream<T>.Continuation]` + `makeStream()` + `onTermination` removal
   (`LaMarzoccoCloudClient.swift:59-61,467-498,521-531`). The shot counter, telemetry,
   BT connection events and a BT raw tap should all use this shape. `ConnectionEvent`
   (`WebSocket.swift:72-75`) can be reused unchanged.
3. **No widget payload struct a BT dashboard needs has a public initializer.**
   `MachineStatus`, `CoffeeBoiler`, `SteamBoilerLevel`, `SteamBoilerTemperature`,
   `NoWater` (`Widgets.swift:219-225,234-269,603-606`) and `CommandResponse`
   (`Commands.swift:7-11`) only have the *internal* synthesized memberwise init.
   `DashboardUpdate` (`WebSocket.swift:84-131`) and `MachineSettings`
   (`Settings.swift:6-70`) have no memberwise init at all, because they declare
   `init(from:)` in the body. This decides where BT dashboard synthesis can live.
4. **`bleAuthToken` is deliberately not modelled** (`Models.swift:25-26`; absent from
   `CodingKeys` at `Models.swift:71-75`). `shotCounterSupported` *is* modelled
   (`Models.swift:29-32,96-98`). Adding the token to `Machine` would make
   `Machine.encode` write it, so it would land in every persisted `MachineSnapshot`
   (`MachineSnapshot.swift:13-40`). That is a security decision, not a mechanical edit.
5. **The BT model-family mapping must not reuse `Model(code:name:)`.** Upstream maps the
   BT capabilities family `"GS3"`→GS3 AV and `"LINEA"`→Linea Mini
   (`src/pylamarzocco/const.py:202-203,209-210`). Angstrom deliberately keeps
   `"GS3"`→`.gs3` for cloud names (`Enums.swift:64`; rationale at `UPSTREAM.md:94-100`).
   BT needs its own `Model(bluetoothFamily:)`.
6. **`LaMarzoccoMachine` cannot be extended from other files today.** `client`,
   `capturing`, `requireModel` and the `private(set)` setters of `dashboard`, `schedule`
   and the rest are `private` (`LaMarzoccoMachine.swift:21,26-49,752,764`), and stored
   properties cannot be added in extensions. A single "foundation" work package must
   first relax access and add all BT stored state to the class body. Only then can
   other packages work in `LaMarzoccoMachine+Bluetooth*.swift` files.
7. **The shot-counter overlay must sit *above* a cloud base dashboard.** Four sites
   replace `dashboard` wholesale: snapshot seed :74, `refreshDashboard` :154,
   `refreshAll` :194 and the websocket push :225. About 28 optimistic sites rewrite it.
   Upstream re-applies its overlay from the `_dashboard_config_updated` hook
   (`src/pylamarzocco/devices/_thing.py:169-182`, `_machine.py:316-323`). The Swift
   equivalent is one setter funnel plus a stored cloud base. The snapshot must persist
   the base, not the overlaid view.
8. **The repo's tests use XCTest only and are "deterministic" by polling.** All 177
   library `func test…` (plus 15 in `cli/`) are XCTest, with no swift-testing. Timing is tested by shrinking
   durations through internal setters and polling `waitUntil` (10 ms × 300). There is no
   virtual clock except `setClockForTesting` for token expiry
   (`LaMarzoccoCloudClient.swift:298-300`). AngstromUI has **no** timing seam, and the
   60 s `BLE_BREWING_STATE_TIMEOUT` (`_machine.py:88`) will need one.
9. **Test support code is duplicated, not shared.** `AngstromUITests` has byte-identical
   copies of `MockTransport.swift` and every fixture JSON, and a *reduced*
   `MockWebSocket.swift` with no ping behaviours. A BT mock needed by both test targets
   means either a third copy or a new shared test-support target. That is a
   `Package.swift` decision.
10. **"Bluetooth is out of scope" is written down in 8 places.** These are CLAUDE.md:12,
    121 and 154, README.md:22, UPSTREAM.md:24 and 26-28 and the runbook triage at
    253-255, `upstream-drift.yml:97`, `Angstrom.md` DocC :10-11, and `Models.swift:25-26`
    and 29-31. Each needs a coordinated edit, best done once by a single docs/meta work
    package.
11. **BT command bytes are pinned upstream, key order included.** For example,
    `{"minutes":42,"mode":"PowerOn","enabled":true}` at
    `tests/test_bluetooth_client.py:333`. Angstrom's cloud convention of
    `Encodable` bodies through `JSONEncoder` (`Commands.swift:97-157`) cannot guarantee
    that order, so BT needs an ordered byte writer (§2.11). BT replies use lowercase
    `"success"` (`:47`), which `CommandStatus(rawValue:)` would decode as `.other`
    (§2.5).

---

## 1. Inventory and line counts

`git ls-files … | xargs wc -l` at `e1bc403`:

| File | Lines | Role |
|---|---:|---|
| `Package.swift` | 33 | 2 products, 2 targets, 2 test targets, docc-plugin dep |
| `Sources/Angstrom/Widgets.swift` | **909** | Dashboard, Widget/WidgetKind union, all payloads |
| `Sources/Angstrom/LaMarzoccoCloudClient.swift` | **796** | actor: auth, REST, two-tier commands, STOMP websocket |
| `Sources/Angstrom/Enums.swift` | 558 | decoder factories, `Lenient`, Model/DeviceType, state enums |
| `Sources/Angstrom/Commands.swift` | 543 | CommandResponse/Status, command bodies + methods |
| `Sources/Angstrom/Settings.swift` | 488 | MachineSettings, MachineSchedule & co |
| `Sources/Angstrom/Optimistic.swift` | 419 | pure `Dashboard.setting…` transforms |
| `Sources/Angstrom/Models.swift` | 255 | Machine, CoffeeStation, PowerState, LaMarzoccoError |
| `Sources/Angstrom/Statistics.swift` | 228 | stats |
| `Sources/Angstrom/WebSocket.swift` | 174 | channel seam, ResumeOnce, ConnectionEvent, DashboardUpdate, `applying` |
| `Sources/Angstrom/InstallationKey.swift` | 68 | P-256 identity |
| `Sources/Angstrom/Diagnostics.swift` | 65 | RawFrame, RawEndpoint |
| `Sources/Angstrom/Stomp.swift` | 60 | STOMP codec |
| `Sources/Angstrom/Proof.swift` | 40 | request proof |
| `Sources/Angstrom/Documentation.docc/Angstrom.md` | 76 | DocC landing |
| `Sources/Angstrom/Documentation.docc/GettingStarted.md` | 101 | DocC article |
| `Sources/AngstromUI/LaMarzoccoMachine.swift` | **774** | @MainActor @Observable device layer |
| `Sources/AngstromUI/MachineSnapshot.swift` | 40 | persistable snapshot |
| `Sources/AngstromUI/Documentation.docc/AngstromUI.md` | 43 | DocC landing |
| `Tests/AngstromTests/WebSocketTests.swift` | 577 | 25 tests |
| `Tests/AngstromTests/DashboardTests.swift` | 433 | 28 tests |
| `Tests/AngstromTests/CommandTests.swift` | 397 | 30 tests |
| `Tests/AngstromTests/AuthTests.swift` | 295 | 14 tests |
| `Tests/AngstromTests/SettingsTests.swift` | 215 | 14 tests |
| `Tests/AngstromTests/StatisticsTests.swift` | 92 | 4 |
| `Tests/AngstromTests/ModelsTests.swift` | 91 | 9 |
| `Tests/AngstromTests/StompTests.swift` | 55 | 6 |
| `Tests/AngstromTests/InstallationKeyTests.swift` | 38 | 4 |
| `Tests/AngstromTests/ProofTests.swift` | 26 | 1 |
| `Tests/AngstromTests/Support/MockTransport.swift` | 140 | MockBackend, MockURLProtocol, TestClock |
| `Tests/AngstromTests/Support/MockWebSocket.swift` | 103 | LockedBox, MockWebSocketChannel (+PingBehavior) |
| `Tests/AngstromTests/Support/Fixtures.swift` | 14 | `Fixture.data(_:)` |
| `Tests/AngstromUITests/LaMarzoccoMachineTests.swift` | **897** | 42 tests |
| `Tests/AngstromUITests/MockTransport.swift` | 140 | byte-identical copy |
| `Tests/AngstromUITests/MockWebSocket.swift` | 62 | reduced copy (no PingBehavior/LockedBox) |
| `Tests/AngstromUITests/Fixtures.swift` | 14 | copy |
| `cli/Package.swift` | 33 | nested package, macOS-only |
| `cli/Sources/angcli/Output.swift` | 177 | Stdout/Stderr, FramePrinter, PrettyJSON, Redact |
| `cli/Sources/angcli/Bootstrap.swift` | 86 | CLIError, Session, Bootstrap.connect, MachineSelector |
| `cli/Sources/angcli/Listen.swift` | 62 | `listen` |
| `cli/Sources/angcli/InstallationStore.swift` | 49 | persisted key |
| `cli/Sources/angcli/Credentials.swift` | 48 | env/prompt creds |
| `cli/Sources/angcli/AngCLI.swift` | 45 | `@main`, subcommand registration |
| `cli/Sources/angcli/Dump.swift` | 30 | `dump` |
| `cli/Sources/angcli/SignalHandler.swift` | 29 | SIGINT via DispatchSource |
| `cli/Sources/angcli/Machines.swift` | 15 | `machines` |
| `cli/Tests/angcliTests/AngCLITests.swift` | 144 | XCTest, 15 tests (OutputMode, arrows, PrettyJSON, Redact, InstallationStore with an `XDG_CONFIG_HOME` temp-dir override) |
| `cli/SPEC.md` / `cli/README.md` | 130 / 239 | design + usage |
| `CLAUDE.md` / `README.md` / `UPSTREAM.md` | 154 / 136 / 269 | meta |
| `.github/workflows/ci.yml` / `upstream-drift.yml` / `docs.yml` | 41 / 164 / 60 | CI |

Test count: 177 `func test…` (per-file counts above). Fixtures: 15 JSON files under
`Tests/AngstromTests/Fixtures/`, all byte-identical to `Tests/AngstromUITests/Fixtures/`
(checked with `cmp`). There are **no BT fixtures** today. Upstream has
`tests/test_bluetooth_client.py` (1435 lines) and `tests/test_bluetooth_dashboard.py`
(689 lines) to port from. Neither uses a JSON fixture file: BT payloads are inline
byte constants (e.g. `COMMAND_SUCCESS`, `tests/test_bluetooth_client.py:47`). The
expected BT dashboards are syrupy snapshots in
`tests/__snapshots__/test_bluetooth_dashboard.ambr`, asserted at
`tests/test_bluetooth_dashboard.py:146,266,411,467,504`.

---

## 2. Existing abstractions a BT port should mirror

### 2.1 Transport seam + factory injection (`WebSocketChannel`)

- **Protocol:** `protocol WebSocketChannel: AnyObject, Sendable { send(_:) async throws;
  receive() async throws -> String; sendPing() async throws; close() }`
  (`WebSocket.swift:8-14`). It is *internal*, not public.
- **Production impl:** `final class URLSessionWebSocketChannel: WebSocketChannel,
  @unchecked Sendable` (`WebSocket.swift:17-51`). It wraps a framework object and adapts
  callback APIs to `async` with `withCheckedThrowingContinuation`. It guards
  multi-firing framework callbacks with `ResumeOnce` (`WebSocket.swift:36-47,55-64`).
  This is exactly the shape a CoreBluetooth adapter needs:
  `CBPeripheralDelegate` callbacks become continuations, and duplicate or late
  callbacks must not double-resume.
- **Factory injection:** `private var webSocketFactory: (@Sendable (URLRequest) -> any
  WebSocketChannel)?` (`LaMarzoccoCloudClient.swift:52`). `makeChannel` uses the factory
  when set, else the real channel (`:746-749`). The test seam is
  `func setWebSocketFactoryForTesting(_:)` (`:542-544`): internal, reached through
  `@testable import Angstrom`.
- **Mock:** `MockWebSocketChannel` (`Tests/AngstromTests/Support/MockWebSocket.swift:15-103`)
  records `sent` frames and resolves a parked `receive()` from `push(_:)`. It has a
  `PingBehavior` enum `.succeed/.fail/.hang` (`:18-22`) to simulate healthy, broken and
  zombie sockets. `ChannelVendor` (`WebSocketTests.swift:44-51`) vends a sequence of
  channels for reconnect tests.

**BT analogue:** define an internal (or `package`, see §10) protocol at the GATT level.
Candidate operations: `connect()`, `discoverCharacteristic(uuid)`,
`write(uuid, data, withResponse)`, `read(uuid) -> Data`,
`setNotify(uuid, on) -> AsyncStream<Data>`, `disconnect()`, and a disconnection signal.
Include a scanner/central protocol too, so discovery is mockable. Inject both through
`set…FactoryForTesting`. Add a `MockBluetoothPeripheral` that records writes and lets
tests push reads and notifications, with failure modes mirroring `PingBehavior`
(succeed / throw / hang). Unit tests must never construct a real `CBCentralManager`
(see §6.6).

### 2.2 Test-only setters (clock, timing, factory)

| Setter | Location | Pattern |
|---|---|---|
| `setClockForTesting(_ clock: @escaping @Sendable () -> Date)` | `LaMarzoccoCloudClient.swift:298-300` | Replaces `private var clock: @Sendable () -> Date = { Date() }` (`:46`). Driven by `TestClock` (`Tests/AngstromTests/Support/MockTransport.swift:131-140`). |
| `setWebSocketTimingForTesting(commandTimeout:heartbeatInterval:reconnectBackoff:)` | `LaMarzoccoCloudClient.swift:459-463` | Overrides `private var commandTimeout = .seconds(10)`, `heartbeatInterval = .seconds(15)` and `reconnectBackoff = .seconds(2)` (`:66-68`). Tests pass milliseconds (e.g. `WebSocketTests.swift:139-141`). |
| `setWebSocketFactoryForTesting(_:)` | `:542-544` | See §2.1. |
| `clientForTesting` | `LaMarzoccoMachine.swift:81` | Exposes the underlying client to AngstromUI tests (`@testable import AngstromUI`). |

All are `internal` (no modifier) and named `…ForTesting`. Durations are `Duration`
values stored as actor state. **BT must follow this pattern.** Upstream BT timing
constants (`IDLE_TIMEOUT = 30`, `AUTH_SUCCESS = b"\x01"` (`:49`), `AUTH_READ_ATTEMPTS = 10`, `AUTH_READ_INTERVAL = 0.05`,
`MAX_AUTH_FAILURES = 3`, `RECONNECT_INITIAL_DELAY = 1`, `RECONNECT_MAX_DELAY = 60` at
`src/pylamarzocco/clients/_bluetooth.py:47-54`; `BLE_BREWING_STATE_TIMEOUT = 60` at
`src/pylamarzocco/devices/_machine.py:88`) should become private `Duration`/`Int` vars
with one `setBluetoothTimingForTesting(…)` per owning type. That means one on the BT
client and one on `LaMarzoccoMachine` for the 60 s brewing-state expiry. AngstromUI has
**no** timing seam today, so this would be its first.

### 2.3 `AsyncStream` multiplexing

The identical shape appears three times in `LaMarzoccoCloudClient`:

```swift
let id = UUID()
let (stream, continuation) = AsyncStream<T>.makeStream()
listeners[id] = continuation
continuation.onTermination = { [weak self] _ in Task { await self?.removeX(id) } }
return stream
```

- `dashboardUpdates()` — `LaMarzoccoCloudClient.swift:467-477`, store `:59`
- `connectionEvents()` — `:488-498`, store `:61`, fan-out through `setConnected` (`:503-508`), which emits **exactly one event per transition** (`guard isWebSocketConnected != connected`)
- `rawFrames()` — `:521-531`, store `:60`, zero-cost emit guard `emitRawFrame` (`:535-539`)
- All listeners are `finish()`ed on `disconnectWebSocket()` (`:449-454`).
- Consumers register **before** connecting so no early event is missed (`LaMarzoccoMachine.swift:217-220`, `cli/Sources/angcli/Listen.swift:28-31`).

**BT analogues (new):**

| Feed | Upstream source | Suggested stream |
|---|---|---|
| BT connection state | `register_connection_callback` / `_set_connected` (`clients/_bluetooth.py:188-214`), called with True once connected **and authenticated**, False on close/loss including idle disconnect (`:193-195`) | `bluetoothConnectionEvents() -> AsyncStream<ConnectionEvent>` (reuse `ConnectionEvent`, `WebSocket.swift:72-75`) |
| Shot-counter updates | `start_shot_counter(...)` callback (`clients/_bluetooth.py:327`), `BluetoothShotCounterUpdate` (`models/_bluetooth.py:166-188`) | `shotCounterUpdates() -> AsyncStream<BluetoothShotCounterUpdate>` |
| Telemetry | `telemetry_callback`, `BluetoothMachineTelemetry` (`models/_bluetooth.py:191-213`) | `telemetryUpdates()` or folded into the shot-counter stream as an enum |
| Raw GATT tap | none upstream (debug logging only) | `rawBluetoothFrames()`, see §2.6 |

Upstream's machine-level callback contract has a subtlety. A `None` shot-counter update
means "BT state dropped, fall back to cloud" (`devices/_machine.py:243-255`). An
`AsyncStream<Update?>` or an enum event with a `.cleared` case is needed to carry it.

### 2.4 Connection lifecycle (maintain/reconnect/teardown)

- `connectWebSocket` returns after the **first** connect, or throws its error
  (`LaMarzoccoCloudClient.swift:432-439`). It parks a `CheckedContinuation` in
  `firstConnect` (`:58`), resumed in `openAndRun` (`:610`) or in
  `maintainConnection`'s first-failure branch (`:556-561`).
- `maintainConnection` retries forever with linear backoff capped at 30 s:
  `min(.seconds(30), reconnectBackoff * reconnectAttempt)` (`:565-566`). Success resets
  `reconnectAttempt` (`:609`). This **deliberately diverges** from upstream, which stops
  (`UPSTREAM.md:158-163`).
- `openAndRun` stores the channel before the handshake so teardown can close a hung
  handshake (`:574-582`). Its `defer` closes, un-sets connected and stops the heartbeat.
- `teardownConnection` fails all pending command waits with `nil` so callers don't hang
  (`:659-665`).
- Liveness is a ping with a pong deadline of `heartbeatInterval / 2`. A silent ping
  force-closes the channel to unblock the read loop (`:683-724`).

**BT note:** upstream's BT reconnect is exponential, 1→60 s
(`clients/_bluetooth.py:53-54`), and only for the shot counter (`:488-521`). It stops
after `MAX_AUTH_FAILURES = 3` auth rejections (`:52`, handling at `:496`). Angstrom
should port that policy verbatim rather than reuse the websocket's forever-retry, or
record the divergence in UPSTREAM.md the way `:158-163` does for the websocket. Upstream
also auto-disconnects after `IDLE_TIMEOUT = 30` s of inactivity (`:47`,
`_reset_disconnect_timer`/`_auto_disconnect` at `:271-291`). The websocket has no
analogue, so this is new state.

### 2.5 Two-tier `executeCommand`

`executeCommand(serial:_:body:)` (`LaMarzoccoCloudClient.swift:351-376`) works like this:

1. It POSTs `/things/{serial}/command/{command}` and decodes `[CommandResponse]`, using
   `[0]` (`:353-363`).
2. If `isWebSocketConnected` is false, it returns that response
   (**fire-and-forget**, `:367`).
3. Otherwise it awaits the websocket `commands` entry with the same `id`
   (`awaitConfirmation`, `:726-735`, resolved in `handleFrame` `:641`). A timeout
   (`commandTimeout`, 10 s) throws `.commandTimedOut`. A non-`.success` status throws
   `.commandFailed(status:errorCode:)` (`:368-374`).

`executeCommand` is **internal**, and every public command method in `Commands.swift`
funnels through it.

**BT relationship:** BT commands have their own synchronous confirmation. The client
writes JSON `{"name","parameter"}` with compact separators to the write characteristic,
then reads a `BluetoothCommandStatus{id,message,status}` back from the same
characteristic (`clients/_bluetooth.py:702-710`; `models/_bluetooth.py:59-65`). The
cloud's two tiers don't apply on the BT path. On BT-first-with-cloud-fallback, the
fallback leg goes through `executeCommand` unchanged and keeps its two-tier semantics.

Three mismatches to resolve:

- **Status casing.** Upstream checks `result.status.lower() == "success"`
  (`_machine.py:1023`). Its own BT test reply is **lowercase**:
  `COMMAND_SUCCESS = b'{"id":"test-id","message":"Success","status":"success"}'`
  (`tests/test_bluetooth_client.py:47`). Angstrom's `CommandStatus(rawValue:)` is
  case-sensitive (`"Success"` → `.success`, `Commands.swift:24-33`), so it would decode
  that reply as `.other("success")`. A BT path that reuses `CommandStatus` must
  normalise case first (e.g. a `CommandStatus(bluetoothStatus:)` that lowercases and
  compares), or compare the raw string case-insensitively as upstream does. Do **not**
  change `CommandStatus.init(rawValue:)` itself, because the cloud path relies on its
  exact raw round-trip (`rawValue` re-encodes `.other(v)` verbatim, `:35-44`). What a
  real machine sends is still unconfirmed by capture, but the case-insensitive rule
  covers both spellings.
- **Failure semantics.** Upstream returns `bool`. A BT reply with a non-success status
  is not an error: it **falls through to cloud** (`_machine.py:1021-1024` returns True
  only on success, then continues at `:1039`). Only `BleakError` and
  `BluetoothConnectionFailed` are caught (`:1025`). Angstrom commands throw instead of
  returning `false`, so the Swift design must say which BT outcomes fall back and which
  throw.
- **No cloud client.** Upstream logs and returns False when BT fails with no cloud
  client (`:1028-1034`). In Swift, rethrowing the BT error is the natural choice.

### 2.6 Diagnostics tap (`RawFrame`, `rawRead`)

- `RawFrame { direction: .inbound/.outbound; text: String }` with synthetic
  `heartbeatMarker` / `pongMarker` strings (`Diagnostics.swift:11-44`). It is
  **text-only**.
- The frame is emitted at the send boundary (`sendFrame`, `LaMarzoccoCloudClient.swift:620-623`)
  and the receive boundary, **before decoding** (`receiveFrame`, `:628-632`).
- `rawRead(_ endpoint: RawEndpoint, serial:) -> Data` returns verbatim REST
  (`LaMarzoccoCloudClient.swift:161-163`). `RawEndpoint` is a `String`-raw
  `CaseIterable` enum (`Diagnostics.swift:52-65`) and is made `ExpressibleByArgument`
  only inside the CLI (`cli/Sources/angcli/AngCLI.swift:42-45`).
- The library tap is **verbatim and unredacted**. Redaction happens at the CLI display
  boundary (`cli/Sources/angcli/Output.swift:128-177`; rationale at `UPSTREAM.md:140-150`).

**BT analogue:** BT traffic is bytes, addressed to a characteristic UUID: read, write,
notify, and the auth write. Reusing `RawFrame` would force hex or UTF-8 text and lose
the characteristic. Two options are open:
- (a) a new `RawBluetoothFrame { direction; characteristic: String; data: Data;
  kind: .read/.write/.notify }`;
- (b) reuse `RawFrame` with `text` = `"<uuid> <hex|utf8>"`.

Option (a) is cleaner. Either way, the tap must stay verbatim in the library and be
redacted in angcli. Upstream's auth write sends the token as plain UTF-8 bytes to the
auth characteristic (`clients/_bluetooth.py:636-640`), and the GET_TOKEN read returns
it (`:540-547`), so `Redact` needs a BT rule (§7.4). A diagnostic `rawBluetoothRead`
mirroring `rawRead` fits `BluetoothReadSetting`
(`const.py:322-330`: `machineCapabilities`, `machineMode`, `tankStatus`, `boilers`,
`smartStandBy`, `isPlumbedIn`), with `CaseIterable` for CLI parsing.

### 2.7 Defensive decoding conventions

From CLAUDE.md "Conventions worth keeping": tolerant parsing, every error a
`LaMarzoccoError`, and an actor with a `nonisolated let installationKey`. Concretely:

- **`Lenient<T>`** (`Enums.swift:31-34`) is an **internal** struct whose
  `init(from:)` does `value = try? T(from: decoder)`. It decodes arrays as
  `[Lenient<T>]` + `compactMap(\.value)`. Uses: `Models.swift:141`,
  `Settings.swift:50,401`, `WebSocket.swift:110-113`, `Statistics.swift:145`.
- **Per-field `try?` with defaults** in hand-written `init(from:)`, e.g.
  `Machine` (`Models.swift:77-99`) and `GroupDoses` (`Widgets.swift:413-426`).
- **Open enums with `.other(String)`** for status and mode values: `MachineState`,
  `MachineMode`, `BoilerStatus` (`Enums.swift:151-267`), `CommandStatus`
  (`Commands.swift:14-52`). Strict `String`-raw enums are used only for "feature" values
  whose unknown value should **demote the widget** (`Enums.swift:269-276`, comment
  `// MARK: - Feature enums (strict …)`).
- **Widget demotion:** an unknown code or an undecodable payload becomes
  `.unknown(code:)` instead of failing the dashboard (`Widgets.swift:148-179`).
- **Raw `JSONSerialization` shape checks** where only one field matters:
  `parsePowerState` (`LaMarzoccoCloudClient.swift:178-195`) and `forbiddenError` (`:416-421`).
- **Decode failure wrapping:** `catch { throw LaMarzoccoError.decoding("<endpoint>: \(error)") }`
  (e.g. `:126-130`).

**BT relevance:** BT reads return NUL-terminated UTF-8 JSON. Upstream splits on the
first `\x00` (`clients/_bluetooth.py:659-671`) and appends `\x00` to writes
(`:689-690`). BT model decoding should follow these conventions: `Lenient` for the
`boilers` array, `.other` for modes, and `.decoding("bluetooth <setting>: …")`. Upstream
already drops unknown telemetry modes to `None` (`_known_machine_mode`,
`models/_bluetooth.py:68-70`). Angstrom's `MachineMode` keeps `.other(raw)`, so the BT
mapping must decide whether `.other` maps to "ignore", which is upstream parity.

### 2.8 `JSONDecoder/JSONEncoder.laMarzocco()`

`Enums.swift:5-26`: `public static func laMarzocco()` with
`.millisecondsSince1970`. It is used for every cloud decode, for snapshot
encoding (`MachineSnapshot.swift:32-39`) and for CLI output (`Output.swift:75`). BT
payloads carry no `Date` fields in the upstream models (`models/_bluetooth.py:22-65`).
`BluetoothShotCounterUpdate.received_at` / `brewing_start_time` are computed locally
(`:161,180-188`). Using `.laMarzocco()` for BT decoding is harmless and consistent.
Any BT type that a snapshot or the CLI must round-trip should be encoded with
`.laMarzocco()`.

### 2.9 Concurrency patterns to copy

- The core client is a `public actor` (`LaMarzoccoCloudClient.swift:22`). Persistable
  identity is a `public nonisolated let` (`:27`), so it can be read without `await`.
- `Task {}` inherits actor isolation, so mutations of actor state inside the task body
  stay isolated (comment at `:245-247`).
- Framework adapters are `final class …: @unchecked Sendable` (`WebSocket.swift:17`,
  `:55`, and the mocks).
- `ResumeOnce` (`WebSocket.swift:55-64`) is an internal NSLock latch. CoreBluetooth
  delegate callbacks need it, since disconnects can fire several callbacks.
- An optional `logHandler: (@Sendable (String) -> Void)?` is injected through `init`
  (`LaMarzoccoCloudClient.swift:32,83,89`) and is the only logging. The library never
  prints. The BT client should take the same parameter, and angcli wires it to stderr
  (`Bootstrap.swift:36`).
- Swift 6 strict concurrency comes from `swift-tools-version: 6.0` (`Package.swift:1`)
  with no per-target `swiftSettings`. CoreBluetooth types (`CBPeripheral`,
  `CBCharacteristic`) are not `Sendable`. The adapter must confine them to one
  `DispatchQueue` (the queue passed to `CBCentralManager`) and expose only `Sendable`
  values (`Data`, `UUID`, `String`) across the seam.

### 2.10 Access-control reality (decides target layout)

These symbols are internal to the `Angstrom` target today:

- `Lenient`
- `WebSocketChannel` and `ResumeOnce`
- `executeCommand`, `authed`, `authedJSON`
- `Stomp`
- every widget struct's memberwise init, except those listed below
- `CommandResponse`'s memberwise init
- `MachineSchedule`'s memberwise init (`Settings.swift:123`)
- `RawEndpoint.path` (`Diagnostics.swift:58`)

A few memberwise inits are **public**: `Dashboard`, `Widget`, `GroupDoses`,
`DosePulses`, `HotWaterDose`, `BrewByWeightDoses`, `GrinderMachineStatus`,
`GrinderDoses`, `GrinderDosesSettings`, `GrinderDoseSetting`, `GrinderSpeed`,
`GrinderSpeedAuto`, `GrinderSpeedDose`, the `…(enabled:)` single-field widgets,
`Machine`, `SmartWakeUpSleep`, `SmartStandby`, `WakeUpSchedule`,
`AutoStandBySettings` and `ThingStatistics`.

AngstromUI imports `Angstrom` without `@testable` in source, so it sees only `public`
API. Its tests use `@testable import Angstrom` and `@testable import AngstromUI`
(`LaMarzoccoMachineTests.swift:2-3`).

Consequence: **if** BT code lives in a separate target (§10), it can't use `Lenient`,
`ResumeOnce` or the internal widget inits unless they are widened. Widening to `public`
grows the API surface. Widening to **`package`** (Swift 5.9+, available under tools 6.0)
keeps them invisible to consumers and to the nested `cli/` package, which is a different
package.

### 2.11 BT command payloads must be byte-exact (key order)

Upstream builds every BT command as
`json.dumps({"name": name, "parameter": parameter}, separators=(",", ":"))` plus a
trailing `\x00` (`clients/_bluetooth.py:702-708`, `:689-690`). Python keeps dict
**insertion order**, and the upstream tests pin the exact written bytes, including a
non-alphabetical key order:

| Test (`tests/test_bluetooth_client.py`) | Pinned bytes (verbatim) |
|---|---|
| `:304` | `b'{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}\x00'` |
| `:319` | `b'{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":90}}\x00'` |
| `:333` | `b'{"name":"SettingSmartStandby","parameter":{"minutes":42,"mode":"PowerOn","enabled":true}}\x00'` |

Angstrom's existing body convention is `private struct …Body: Encodable` encoded
with `JSONEncoder.laMarzocco()` (`Commands.swift:97-157`, `LaMarzoccoCloudClient.swift:326-328`).
That is fine for the cloud, where the server parses JSON. It is **not** safe for BT
parity:

- `JSONEncoder` documents no key-order guarantee, and `.sortedKeys` would emit
  `{"enabled":true,"minutes":42,"mode":"PowerOn"}`, which differs from `:333`.
- **UNVERIFIED:** whether the machine firmware is order-sensitive at all. Either way,
  byte-identical tests are only portable if the order is under our control.

**Convention for the BT WP:** build BT payload bytes with an explicit, ordered
writer: a hand-assembled string from `JSONSerialization`-escaped scalars, or a tiny
ordered-pairs encoder. Port the three byte vectors above as tests, the way
`ProofTests` pins the proof vectors. Also note the numeric rendering: upstream sends
the steam-level temperature as a Python `int` (`"value":90`, and `126/128/131` from
`STEAM_LEVEL_MAPPING`, `devices/_machine.py:59-63`). Python renders an `int` as
`90` but a `float` as `90.0` (a coffee/steam target passed as `float`, per
`set_temp(..., temperature: float)` at `clients/_bluetooth.py:621`). Swift's
`JSONEncoder` writes `Double(90)` as `90`. The writer should emit `Int` sources
without a fraction. Whether a `Double` with no fractional part should render as `90`
or `90.0` is **UNVERIFIED** (firmware tolerance unknown; no upstream test pins a float
case). Pick one and record it as a divergence if it is not `90.0`.

Reads are the mirror image. Upstream splits the reply on the first `\x00` and decodes
UTF-8 (`clients/_bluetooth.py:669-671`), then `json.loads`. Plain `Data` → split →
`JSONSerialization`/`JSONDecoder` works there, since read order doesn't matter.

---

## 3. Existing types the BT layer must reuse or map onto

Rule: **do not invent duplicates.** Each row gives the upstream BT concept, the
Angstrom type it maps onto, and whether that type is sufficient.

### 3.1 Enums

| Upstream (cite) | Angstrom | Sufficient? / addition |
|---|---|---|
| `MachineMode` `"BrewingMode"/"EcoMode"/"StandBy"` (`const.py:11-16`); `from_power` (`:18-21`) | `MachineMode` `.brewing/.eco/.standby/.other` (`Enums.swift:192-223`) | Sufficient. `setPower` already maps `on ? .brewing : .standby` (`Commands.swift:177`). BT telemetry's `_known_machine_mode` returns `None` for unknown (`models/_bluetooth.py:68-70`), so the BT decoder should drop `.other`. |
| `MachineState` incl. `ECO_MODE` (`const.py:24-31`) | `MachineState` incl. `.eco` (`Enums.swift:151-189`). It was ported *for* BT maps (`UPSTREAM.md:128-135`). | Sufficient. |
| `BoilerStatus` incl. `ECO_MODE` (`const.py:267-275`) | `BoilerStatus` (`Enums.swift:226-267`) | Sufficient. |
| `BLE_MACHINE_STATE` / `BLE_BOILER_STATUS` maps (`devices/_machine.py:65-75`) | none | **Add** as static functions, e.g. `MachineState(bluetoothMode:)` / `BoilerStatus(bluetoothMode:)`. Exact pairs: Brewing→PoweredOn/Ready, Eco→EcoMode/EcoMode, StandBy→StandBy/StandBy. |
| `BoilerType` `COFFEE="CoffeeBoiler1"`, `STEAM="SteamBoiler"` (`const.py:307-311`) | **none** (no `BoilerType` anywhere in `Sources/`) | **Add.** Make it tolerant (`.other(String)`) per §2.7, because it decodes the BT `boilers[].id` (`models/_bluetooth.py:46`). |
| `SmartStandByType` `"LastBrewing"/"PowerOn"` (`const.py:260-264`) | `SmartStandbyAfter` `.lastBrewing="LastBrewing"`, `.powerOn="PowerOn"` (`Enums.swift:514-517`) | **Reuse** (identical raw values). It is strict `String`-raw, so an unknown value fails the BT smart-standby decode. Accept that or add tolerance. |
| `SteamTargetLevel` (`const.py:141`) + `STEAM_LEVEL_MAPPING` 1→126, 2→128, 3→131 (`devices/_machine.py:59-63`) and the inverse `_steam_level_from_temperature` (`:78-84`: `0<t<128`→1, `128≤t≤130`→2, else 3) | `SteamLevel` `.level1/2/3` (`Enums.swift:272-276`) | Reuse the enum. **Add** the two mappings, e.g. `SteamLevel.bluetoothTemperature` and `SteamLevel(bluetoothTemperature:)`. |
| `BluetoothReadSetting` (`const.py:322-330`) | none | **Add** (internal or `package`). Optionally `CaseIterable` to drive a CLI `ble read <setting>`. |
| `BluetoothBrewingState` `"Brewing"/"BrewingStopped"/"Flushed"/"Backflushing"` (`const.py:333-339`) | none | **Add** (public: it surfaces in shot-counter updates). |
| `ModelName.from_string` BT families: `"GS3"`→GS3 AV (`const.py:202-203`), `"LINEA"`→Linea Mini (`:209-210`), plus `"GS3MP"`, `"GS3AV"`, `"LINEAMINI2023"`, `"LINEAMICRA"`, `"LINEAMINI"`, `"MICRA"`, `"STRADAX"`, `"PICOGRINDER"`, `"SWANGRINDER"` (`:201-215`); raises on unknown (`:216-217`) | `Model` (`Enums.swift:39-117`). `Model.match` maps `"GS3"`→**`.gs3`** (`:64`) and has **no `"LINEA"`** case, so it would yield `.unknown("LINEA")`. | **Add a separate `Model(bluetoothFamily:)`.** Do *not* change `Model.match`: that is an intentional cloud divergence (`UPSTREAM.md:94-100`). Upstream then derives the model code from the enum *name* (`devices/_machine.py:341-348`). |
| `STEAM_LEVEL_MODELS = (LINEA_MICRA, LINEA_MINI_R)` (`const.py:181-182`) | `LaMarzoccoMachine.steamLevelModels: Set<Model> = [.lineaMicra, .lineaMiniR]` (`LaMarzoccoMachine.swift:744`). It is **internal to AngstromUI**. | Dashboard-from-BT synthesis in the core needs this set (`_machine.py:419`). **Move** the model-gating sets to `Model` in `Enums.swift`, e.g. `Model.controlsSteamByLevel` / `static let steamLevelModels`, and have AngstromUI reference them. This is a shared-file edit (§5). |
| `DeviceType` (`const.py:160-164`) | `DeviceType` (`Enums.swift:120-146`) | Sufficient. BT applies only to coffee machines: the grinder device has no BT calls (`grep` of `devices/_grinder.py` shows none). |

### 3.2 Widget payloads (dashboard-from-Bluetooth)

Upstream `get_dashboard_from_bluetooth` (`devices/_machine.py:350-485`) creates or
updates exactly these widgets:

| Upstream widget + defaults used when absent | Angstrom struct | Init today | Needed |
|---|---|---|---|
| `CMMachineStatus`: `status=STANDBY`, `available_modes=[BREWING_MODE, STANDBY]`, `mode=machine_mode`, `next_status=None` (`:379-393`) | `MachineStatus {status, availableModes, mode, nextStatus, brewingStartTime}` (`Widgets.swift:219-225`) | internal memberwise (used by `Optimistic.swift:35`) | `package` or `public init` |
| `CMCoffeeBoiler`: `status=STAND_BY`, `enabled`, `enabled_supported=False`, `target_temperature=float(target)`, `min=80`, `max=110`, `step=0.1` (`:398-416`) | `CoffeeBoiler` (`Widgets.swift:234-246`), which also has `readyStartTime: Date?` | internal | same |
| `CMSteamBoilerLevel` (steam-level models): `status=STAND_BY`, `enabled`, `enabled_supported=True`, `target_level=LEVEL_1`, `target_level_supported=True` (`:421-441`), and **removes** `CMSteamBoilerTemperature` (`:443-445`) | `SteamBoilerLevel` (`Widgets.swift:248-255`) | internal | same |
| `CMSteamBoilerTemperature` (other models): `enabled_supported=False`, `min=95 if mini else 20`, `max=140 if mini else 134`, `step=0.1`, `target_temperature_supported=not is_mini` (`:447-470`), and **removes** `CMSteamBoilerLevel` (`:472`) | `SteamBoilerTemperature` (`Widgets.swift:257-269`) | internal | same |
| `CMNoWater`: `allarm = not water_ok` (`:474-483`) | `NoWater {alarm}` with key `"allarm"` (`Widgets.swift:603-606`) | internal | same |

Additional gaps:

- **Upsert and remove are missing.** `Dashboard.replacing(_:)` is a *no-op when the
  widget is absent* (`Optimistic.swift:18-25`), by design for optimistic updates. BT
  synthesis needs `upserting(_:)`, i.e. insert when absent (upstream
  `self.dashboard.config[...] = widget`), and `removingWidgets(code:)` (upstream
  `config.pop`). Put these in a **new** file, e.g. `Dashboard+Bluetooth.swift`, not in
  `Optimistic.swift`.
- **`Dashboard.machine` is `let`** (`Widgets.swift:14`), but `Machine`'s fields are
  `var` (`Models.swift:10-32`). Updating the model from BT capabilities
  (`_machine.py:341-348`) means rebuilding `Dashboard(machine:widgets:)`. That works
  with today's public API.
- **A BT-only dashboard needs an identity.** Upstream always holds a dashboard seeded
  with the serial (`devices/_thing.py:87`). Its model defaults to `LINEA_MICRA`
  (`models/_general.py:98-106`). Angstrom's `dashboard` is `nil` until a refresh
  (`LaMarzoccoMachine.swift:26`). `Machine(serialNumber:)` defaults `model` to
  `.unknown("")` (`Models.swift:41-45`). BT synthesis on a nil dashboard must build
  `Dashboard(machine: Machine(serialNumber: serial, model: <from BT capabilities or
  .unknown>), widgets: [])`. **Decision:** whether to copy upstream's Micra default or
  keep `.unknown`. `.unknown` makes `requireModel` throw (`LaMarzoccoMachine.swift:752-757`)
  until capabilities are read.
- **New transforms.** Telemetry `machine_mode` sets the mode on both status widgets
  *and* sets `CMMachineStatus.status` through `BLE_MACHINE_STATE` (`_machine.py:233-236`,
  `_update_machine_mode_widgets` `:487-492`). `settingMachineMode` (`Optimistic.swift:31-48`)
  covers the mode half only. Add `settingMachineState(_:)` plus a shot-counter overlay
  transform that sets `status` and `brewingStartTime` on `CMMachineStatus` only.
  Upstream `_widget(MachineStatus)` resolves `CMMachineStatus`, not the group status
  (`_machine.py:287-314`; `_thing.py:184-186`).
- **`DashboardUpdate` has no memberwise init.** Its body declares `init(from:)`
  (`WebSocket.swift:106-116`). Upstream synthesises a websocket config to notify
  listeners after BT changes (`_machine.py:257-271`). Angstrom's AngstromUI publishes
  through `@Observable` instead, so this is probably unnecessary. If a core-level "BT
  dashboard changed" stream reuses `DashboardUpdate`, add an init.

### 3.3 Settings / schedule

| Upstream BT read | Angstrom home | Notes |
|---|---|---|
| `get_plumbed_in() -> bool` (`clients/_bluetooth.py:578`) | `MachineSettings.isPlumbedIn` (`Settings.swift:11`) | `MachineSettings` has **no** memberwise init (`init(from:)` in body, `:34`). Upstream uses plumb-in only to compute `water_ok` (`_machine.py:358-369`), so no settings write is needed. |
| `get_smart_standby_settings() -> BluetoothSmartStandbyDetails{mode, minutes, enabled}` (`clients/_bluetooth.py:591`; `models/_bluetooth.py:51-57`) | `SmartStandby {enabled, minutes, minutesMin…, after}` with a **public** init (`Settings.swift:406-437`), and `SmartWakeUpSleep` (public init, `:374-390`) | Mappable without new API. Upstream's dashboard-from-BT explicitly excludes standby settings (`_machine.py:351`). Whether `MachineSchedule` should be patched from BT is a design choice. `MachineSchedule`'s init is internal (`Settings.swift:123`). |
| `get_machine_capabilities()` (`models/_bluetooth.py:22-39`): `family`, `groupsNumber`, `coffeeBoilersNumber`, `hasCupWarmer`, `steamBoilersNumber`, `teaDosesNumber`, `machineModes`, `schedulingType` | none | New public `BluetoothMachineCapabilities`. Only `family` feeds existing state (`Machine.model`). |
| `get_boilers()` → `[BluetoothBoilerDetails{id: BoilerType, isEnabled, target: int, current: int}]` (`models/_bluetooth.py:42-49`) | maps into `CoffeeBoiler` / `SteamBoiler*` widgets | `current` (actual temperature) has **no home** in any widget struct: they hold only target values (`Widgets.swift:234-269`). Telemetry `CoffeeBoiler1UpdateTemperature` / `SteamBoilerUpdateTemperature` (`models/_bluetooth.py:198-203`) is likewise new data. Surface it on new BT types, not by adding fields to cloud widget structs. |

### 3.4 Commands

- `CommandResponse {id, status: CommandStatus, errorCode: String?}` (`Commands.swift:7-11`)
  has only an internal memberwise init. Every AngstromUI command method returns
  `CommandResponse` (e.g. `LaMarzoccoMachine.swift:285`). For a BT-first method to keep
  its signature, it must fabricate a `CommandResponse` from
  `BluetoothCommandStatus{id, message, status}` (`models/_bluetooth.py:59-65`). That
  needs a `package`/`public` init, plus a mapping decision: `message` → `errorCode`?
- `CommandStatus` (`Commands.swift:14-52`) is reusable for BT status strings if the
  comparison is case-insensitive (§2.5).
- Cloud command methods reached by BT fallback all exist: `setPower` (`Commands.swift:176-178`),
  `setSteam` (`:182-185`), `setSteamTargetLevel` (`:189-192`),
  `setCoffeeTargetTemperature` (`:196-199`, which rounds via file-private `round1`
  `:160`), `setSteamTargetTemperature` (`:203-206`) and `setSmartStandby` (`:236-239`).
  `round1` is `private`. **Resolved: BT does not round.** `set_temp` sends
  `{"identifier": boiler.value, "value": temperature}` unchanged
  (`clients/_bluetooth.py:621-626`), and the device layer passes the caller's value
  straight through on both legs (`devices/_machine.py:807-815,827-835`). So the BT leg
  must **not** call `round1`, while the cloud fallback leg keeps rounding inside
  `Commands.swift` as today. The optimistic widget update uses the unrounded value
  upstream (`float(temperature)`, `:819`), which matches
  `settingCoffeeTargetTemperature(celsius)` today.

### 3.5 `Machine`

- `bleAuthToken`: **not modelled** (`Models.swift:25-26`, `CodingKeys` `:71-75`).
  Upstream: `ble_auth_token: str | None` alias `"bleAuthToken"`, default `None`
  (`models/_general.py:128-130`). Real fixtures carry it as `null` (Micra, Mini, Mini R,
  GS3 AV, Pico, schedule.json, settings_micra) or as a 64-char string of zeros
  (Strada X, Swan, settings_strada, schedule_strada). It also appears nested in
  `coffeeStation` payloads (`cli/Tests/angcliTests/AngCLITests.swift:57-68`; upstream
  masks nested too, `clients/_cloud.py:84-92`). `CoffeeStation` intentionally skips the
  nested machine and grinder payloads (`Models.swift:120-123`).
  - **Fixture inventory, verified per file:**
    - `null` in `dashboard_gs3av`, `dashboard_micra`, `dashboard_micra_offline` (×3),
      `dashboard_mini` (×2), `dashboard_minir`, `dashboard_pico`, `schedule`,
      `settings_micra` and `statistics`;
    - a 64-char string of `0`s in `dashboard_strada_profile` (×2), `dashboard_stradax`,
      `dashboard_swan`, `schedule_strada` and `settings_strada` (×2);
    - **absent** in `dashboard_strada`.

    Every non-null value is the all-zeros placeholder, so a decode-only field would hold
    `"000…0"` for those fixtures. A test asserting round-trip equality on them would
    fail under Option A unless the field is excluded from `==`/`hash` or the test
    compares re-decoded values.
  - **Option A:** add `public var bleAuthToken: String?` to `Machine`, decode it, and
    **do not encode it**. This keeps snapshots and CLI-encoded output secret-free. The
    cost is that `Machine` stops round-tripping exactly. `DashboardTests.testMachineCodableRoundTrip`
    (`DashboardTests.swift:265`) and the snapshot tests (`LaMarzoccoMachineTests.swift:589,845,854`)
    assert round-trip equality, and `Machine` is synthesized `Hashable`
    (`Models.swift:8`). Nil tokens in fixtures keep those tests green, but Strada and
    Swan fixtures carry non-nil tokens.
  - **Option B:** leave `Machine` alone and add a dedicated read, e.g.
    `LaMarzoccoCloudClient.bluetoothToken(serial:) -> String?`. It parses `/things` or
    `/dashboard` with `JSONSerialization`, following the `parsePowerState` pattern
    (`LaMarzoccoCloudClient.swift:178-195`).
  - Either way, CLAUDE.md's "never persist tokens" stance (CLAUDE.md:58-62,
    `README.md:94-98`) should be extended to the BT token in docs.
- `shotCounterSupported`: **modelled** (`Models.swift:29-32`; tolerant Bool-or-number
  decode `:94-98`; encoded `:116`). Its doc comment says the BT data is out of scope and
  must be reworded. It is the natural gate for offering the shot counter.
- `isConnected` / `connectionDate` describe *cloud* reachability (`Models.swift:17-18`).
  They must **not** be overloaded with BT connectivity. BT connectivity needs separate
  state (AngstromUI `isBluetoothConnected`), mirroring how `isConnected` (our socket)
  is distinct from `isMachineConnected` (`LaMarzoccoMachine.swift:38-42,95-108`).

### 3.6 `LaMarzoccoError` (`Models.swift:191-224`, descriptions `:226-255`)

It is `Error, Sendable, Equatable`, so every new payload must be `Equatable`.
`errorDescription` is an **exhaustive switch**, so each new case must be added there in
the same edit. Upstream exceptions needing a home:

| Upstream | Proposed case |
|---|---|
| `BluetoothConnectionFailed` (`exceptions.py:20-21`) | `.bluetoothConnectionFailed(String)` |
| `BluetoothAuthenticationFailed(BluetoothConnectionFailed)` (`exceptions.py:46-47`), a *subclass* | `.bluetoothAuthenticationFailed`. Swift has no subclassing, so every "catch BT connection failure" site (e.g. the fallback, `_machine.py:1025`) must match both cases. Consider an `isBluetoothConnectionFailure` helper. |
| `CloudOnlyFunctionality` (`exceptions.py:28-35`) | `.cloudOnlyFunctionality`. Needed only if `LaMarzoccoMachine` gains a BT-only (no cloud client) mode (`devices/_thing.py:27-38`). |
| (no upstream) CoreBluetooth `poweredOff` / `unauthorized` / `unsupported` | Fold into `.bluetoothConnectionFailed(String)`, or add `.bluetoothUnavailable(String)`. Owner decision. |

Adding cases is **source-breaking** for exhaustive `switch`es. Precedent: such ports ship
as a minor bump (`UPSTREAM.md:103-114`, "following the 1.5.0/1.6.0 precedent").

---

## 4. `AngstromUI.LaMarzoccoMachine` in detail and its BT hook points

### 4.1 Today's command flow (no rollback)

The pattern, e.g. `setPower` (`LaMarzoccoMachine.swift:285-289`):

```swift
let response = try await capturing { try await client.setPower(serial: serialNumber, on: on) }
dashboard = dashboard?.settingMachineMode(on ? .brewing : .standby)
return response
```

- Gating and validation run **inside** `capturing` before the network call, e.g.
  `requireModel` (`:301`) and `operationNotAvailable` checks (`:469-475,489-500,515-518`).
- The "optimistic" update is applied **only after the call returns**. With a live socket
  that means after websocket confirmation (§2.5). On throw it is skipped, so **there is
  no rollback path**. This is upstream parity: `if result:` then mutate
  (`_machine.py:504-507`).
- `capturing` (`:764-773`) records `lastError` on failure and clears it on success.
  `setSmartStandby`'s grinder guard sets `lastError` manually (`:700-705`).
- Methods with no optimistic update forward only: `startBackflush`, `setCupWarmer`,
  `setPlumbIn`, `setContinuousDose*`, `setMirrorGroup1`, `setPreExtraction*`,
  `setAutoStandby`, wake-up schedules and firmware (`:353-356,431-441,525-552,681-729,733-740`).

### 4.2 Model gating

- `model` resolves from `dashboard ?? settings ?? schedule` identity (`:91-93`). That is
  a deliberate divergence from upstream, which uses dashboard-only (`devices/_thing.py:58`).
- Sets live at `:744-750`: `steamLevelModels`, `steamTemperatureModels`,
  `brewByWeightModels`, `stradaXModels`, `groupDoseModels`, `swanGrinderModels`.
- `requireModel` throws `.unsupportedModel("<what> is only supported on <names>")`
  when the model is unknown **or** unsupported (`:752-757`).

**BT impact:** in BT-only mode, `model` must also be resolvable from BT capabilities,
either through a synthesized dashboard identity or a new `bluetoothCapabilities?.family`
fallback in `model`.

### 4.3 Push merge, reconnect re-fetch, snapshot

- `start()` (`:210-268`) registers `dashboardUpdates()` and `connectionEvents()`
  **before** connecting (`:217-220`).
- **Push merge** (`:221-233`): `if let current = self.dashboard { self.dashboard =
  current.applying(update); self.lastUpdateAt = Date() }`. Pushes are dropped while
  `dashboard == nil`. `applying` replaces widgets wholesale except on a widget-less
  partial frame, and always applies `connected`/`connectionDate` (`WebSocket.swift:167-173`).
- **Reconnect re-fetch** (`:235-255`): on every `.connected` after the first, it calls
  `refreshDashboard()` (`:245-247`), because the feed is change-only.
- Session ownership uses `isStarting` (`:58`) and `liveGeneration` (`:61,213-214,230,253,272`)
  so a superseded task can't clobber state.
- **Snapshot:** `snapshot` = `MachineSnapshot(serialNumber, dashboard, settings, schedule)`
  (`:143-146`). The init seeds from a snapshot only if the serial matches (`:73-77`).

### 4.4 Where each BT feature hooks in

#### (a) BT-first with cloud fallback

Upstream routes exactly these through `__bluetooth_command_with_cloud_fallback`
(`devices/_machine.py:983-1049`):

| AngstromUI method (today) | Upstream BT path |
|---|---|
| `setPower(on:)` `:285-289` | `set_power` BT `set_power(enabled)` (`_machine.py:494-509`) |
| `setSteam(on:)` `:292-296` | `set_steam` (`:764-782`) |
| `setSteamTargetLevel(_:)` `:299-306` (gated `steamLevelModels`) | BT `set_temp(boiler=STEAM, temperature=STEAM_LEVEL_MAPPING[level])`; cloud `set_steam_target_level` (`:784-802`) |
| `setCoffeeTargetTemperature(celsius:)` `:309-313` | BT `set_temp(COFFEE, t)` (`:804-821`) |
| `setSteamTargetTemperature(celsius:)` `:316-323` (gated) | BT `set_temp(STEAM, t)` (`:823-841`) |
| `setSmartStandby(enabled:minutes:after:)` `:697-711` | If `schedule.autoStandBySupported`, cloud-only auto-standby (`:874-878`). Otherwise BT `set_smart_standby(enabled, mode, minutes)` with cloud fallback (`:880-892`). |

Every other machine command is `@cloud_only` upstream (`_machine.py:511-962`), and
grinders have no BT path.

**Hook:** add one private helper in `LaMarzoccoMachine`, used by these six methods:
`bluetoothFirst(bt: () async throws -> BluetoothCommandStatus, cloud: () async throws -> CommandResponse) async throws -> CommandResponse`.
It sits inside the existing `capturing { … }`, so gating, `lastError` and optimistic
updates stay as they are. The helper:

- tries BT if a BT client is attached;
- treats BT success (case-insensitive) as done;
- on a BT connection or auth failure, or a non-success status, falls through to cloud;
- with no cloud client, rethrows.

#### (b) Dashboard from Bluetooth

Upstream has public `get_dashboard_from_bluetooth()` (`_machine.py:350-485`) and
`get_model_info_from_bluetooth()` (`:325-348`). The AngstromUI equivalent is a
`refreshDashboardFromBluetooth()` beside `refreshDashboard()` (`:151-158`). It:

1. reads mode, plumb-in (tolerating older firmware, `:357-362`), tank and boilers over BT;
2. calls a pure core function, e.g.
   `Dashboard.applyingBluetooth(mode:plumbedIn:tankOK:boilers:model:)` or
   `Dashboard.fromBluetooth(…)`, which upserts and removes the widgets in §3.2;
3. assigns through the setter funnel in (c).

**Decision:** whether BT-sourced refreshes stamp `lastUpdateAt`, which is documented as
"changed from the cloud" (`:43-46`).

#### (c) Shot-counter overlay that survives wholesale replacement

Upstream mechanics:

- It remembers the *cloud* `(widget, status, brewing_start_time)` of `CMMachineStatus`
  (`_machine.py:126-129,293-303`).
- While a BT brewing update is held, it overrides `status=BREWING` and
  `brewing_start_time` (BREWING), or restores the cloud status, mapping a cloud
  `BREWING` to `POWERED_ON` (`:305-314`).
- It re-applies after every dashboard replacement through `_dashboard_config_updated`.
  That hook runs from the websocket handler (`_thing.py:173-176`), from `get_dashboard`
  (`_thing.py:141`) and from BT telemetry and refresh (`_machine.py:237,485`).
- The state expires after `BLE_BREWING_STATE_TIMEOUT = 60` s with no notification
  (`:88,215-220`), is dropped on BT disconnect (`:223-228`), and restores the cloud
  values on clear (`:273-285`).

Swift design implied by today's code:

- **Keep a cloud base.** Add `private var cloudDashboard: Dashboard?` (or rename
  internally) and make `public private(set) var dashboard` the *rendered* value.
  Upstream mutates the widget in place and keeps the original values on the side.
  Angstrom's pure, value-typed transforms make "base + overlay → view" the cleaner
  equivalent.
- **Funnel every assignment** through one `setBaseDashboard(_:)` that recomputes
  `dashboard = overlay(base, bluetoothBrewing)`. The four wholesale sites are :74, :154,
  :194 and :225. The ~28 optimistic sites (`:287…:665`) should transform the base and
  re-render. Upstream applies optimistic mutations to the same widget objects the
  overlay remembers (`_machine.py:316-323` re-snapshots the status after in-place
  refreshes).
- **Snapshot from the base**: `:143-146` must use `cloudDashboard`. Otherwise a
  persisted snapshot captures a transient "Brewing" and a BT-derived `brewingStartTime`.
- `powerState`, `isMachineConnected` and `machineLastConnectionDate` (`:108-140`) keep
  reading `dashboard`, the rendered view. That is correct: the overlay changes only
  `status`/`brewingStartTime`, never `mode` or `connected`.
- **Telemetry `machine_mode`** is *not* an overlay upstream. It mutates the widget's
  mode and status (`_machine.py:230-241`), so it belongs on the base, via
  `settingMachineMode` + `settingMachineState`. The next websocket push overwrites it
  either way, as upstream does.
- **Expiry timer:** a `Task` sleeping a `Duration` (default 60 s) that is overridable
  through a new `setBluetoothTimingForTesting` (§2.2), and cancelled on each update and
  on stop.

#### (d) Optional cloud client / BT-only mode

`client: LaMarzoccoCloudClient` is non-optional (`:21,68`). Upstream allows
`cloud_client=None` and raises `CloudOnlyFunctionality` (`devices/_thing.py:27-38,73-83`).
To support BT-only:

- add a second `init(serialNumber:bluetooth:client: LaMarzoccoCloudClient? = nil, snapshot:)`
  (additive);
- make the stored client optional;
- guard all ~45 cloud-only methods.

This touches nearly every method body in the file, so it is a single-owner,
sequence-first work package. **Owner decision:** in scope or not. Pronto (cloud
account) doesn't need it, and full upstream parity does.

### 4.5 State to add to the class body

Stored properties can't live in extensions, and `@Observable` tracks only class-body
stored properties. **Add all of these in one edit:**

| Property | Public? | Purpose / upstream |
|---|---|---|
| `bluetooth: <BT client>?` (or a protocol existential) | private/internal | `_bluetooth_client` (`_thing.py:83`) |
| `isBluetoothConnected: Bool` | `public private(set)` | `bluetooth_connected` (`_thing.py:110-114`), fed by the BT connection stream |
| `isShotCounterActive: Bool` | public | `bluetooth_shot_counter_active` (`_machine.py:151-156`) |
| `bluetoothBrewingUpdate: BluetoothShotCounterUpdate?` | public | `ble_brewing_update` (`:133-135`) |
| `bluetoothTelemetry: BluetoothMachineTelemetry` | public | merged telemetry (`:138-143,232`) |
| `lastShotTime: TimeInterval?` | public | `last_shot_time` (`:146-149`). Rule (verified): set to `update.final_shot_time` whenever that is non-nil (`_machine.py:211-213`). It is **never** reset: not by the 60 s expiry (`_drop_ble_brewing_state`, `:243-246`), a BT disconnect (`:223-228`), `_clear_ble_brewing_state` (`:273-285`) or `disconnect_bluetooth_shot_counter` (`:193-207`). |
| `cloudDashboard: Dashboard?` | private | overlay base (§4.4c) |
| `brewingExpiryTask`, `shotCounterTask`, `bluetoothConnectionTask: Task<Void, Never>?` | private | timer + stream consumers, like `updateTask`/`connectionTask` (`:51-55`) |
| `bluetoothBrewingTimeout: Duration = .seconds(60)` | private + `…ForTesting` setter | `BLE_BREWING_STATE_TIMEOUT` (`_machine.py:88`) |

### 4.6 Access-control obstacle to splitting work across files

`private` members can't be reached from an extension in another file. Blockers include
`client` (:21), the `private(set)` setters at :26-49, `updateTask`/`connectionTask` (:51-55),
`requireModel` (:752) and `capturing` (:764).

**Foundation WP:** change these to `internal` / `internal(set)`. Public API is unaffected
(`public internal(set) var dashboard` is still read-only to consumers). Add §4.5's state.
Introduce `setBaseDashboard`. After that, BT work packages can each own a new file:

- `LaMarzoccoMachine+BluetoothCommands.swift`
- `LaMarzoccoMachine+BluetoothDashboard.swift`
- `LaMarzoccoMachine+ShotCounter.swift`

---

## 5. Shared files and the edit each BT work package would need

These drive the file-ownership rules. "Owner" is a recommendation: one work package per
shared file, landing early, with the others depending on it.

| File (lines) | Why it's shared | Specific BT edit | Recommended ownership |
|---|---|---|---|
| `Package.swift` (33) | Every new target or test target | **Either** add a `.target(name: "AngstromBluetooth", dependencies: ["Angstrom"])`, a product, and `.testTarget(name: "AngstromBluetoothTests", …, resources: [.copy("Fixtures")])` **or** nothing, if BT lives in `Angstrom`. Optionally add a shared non-product test-support target to end the mock duplication (§6.3). If AngstromUI must see BT, add the dependency on line 21. CoreBluetooth needs no `linkerSettings`: it autolinks via `import`. | **Foundation WP (single owner), first.** |
| `Sources/Angstrom/Models.swift` (255) | `LaMarzoccoError` (+ exhaustive `errorDescription`), `Machine` | Add the BT error cases + descriptions (§3.6). Decide `bleAuthToken` (§3.5), then add the field, `CodingKeys` and decode (and a deliberate non-encode). Reword doc comments at `:25-26`, `:29-31`. | **Foundation WP.** Every BT WP throws these errors, so all depend on it. |
| `Sources/Angstrom/Enums.swift` (558) | Shared enums, `Lenient`, `Model` | Add `BoilerType`, `BluetoothBrewingState`, `BluetoothReadSetting`, `Model(bluetoothFamily:)`, `MachineState/BoilerStatus(bluetoothMode:)`, `SteamLevel` ↔ BT temperature, and move the model-gating sets here from AngstromUI. Widen `Lenient` to `package` if a separate target needs it. | Prefer **new files** (`Sources/Angstrom/Bluetooth/BluetoothEnums.swift`, `Model+Bluetooth.swift`) over growing Enums.swift. Only the `Lenient` access change and the model-set move touch Enums.swift (foundation WP). |
| `Sources/Angstrom/Widgets.swift` (909) | Payload structs | Add explicit `package`/`public` memberwise inits to `MachineStatus`, `CoffeeBoiler`, `SteamBoilerLevel`, `SteamBoilerTemperature`, `NoWater` (and `NextStatus` if needed). Explicit inits must not break `Optimistic.swift`'s internal calls: keep the same labels and order. | **Foundation WP** (tiny, mechanical). No other WP edits this file. |
| `Sources/Angstrom/Commands.swift` (543) | `CommandResponse` | Add a `package`/`public init(id:status:errorCode:)` (and maybe widen `round1`). | Foundation WP. |
| `Sources/Angstrom/Optimistic.swift` (419) | Dashboard transforms | **Do not extend.** New transforms (`upserting`, `removingWidgets`, `settingMachineState`, shot-counter overlay, `fromBluetooth`) go in a new `Dashboard+Bluetooth.swift`. | Owned by the dashboard-from-BT WP (new file only). |
| `Sources/Angstrom/WebSocket.swift` (174) | `ConnectionEvent`, `ResumeOnce` | Reuse `ConnectionEvent` unchanged. Widen `ResumeOnce` to `package` if a separate target needs it. Optionally move `ResumeOnce` to its own file. | Foundation WP (access change only). |
| `Sources/Angstrom/Diagnostics.swift` (65) | Raw tap types | Either add `RawBluetoothFrame` here or (better) in a new BT diagnostics file. | BT-diagnostics WP (new file). |
| `Sources/Angstrom/LaMarzoccoCloudClient.swift` (796) | The cloud actor | **Avoid editing.** BT should be a separate actor (e.g. `LaMarzoccoBluetoothClient`), as upstream separates `clients/_bluetooth.py` from `_cloud.py`. Only edit it if Option B for the token read (§3.5) is chosen: one small method, ideally in a new `LaMarzoccoCloudClient+Bluetooth.swift` extension file. | Token WP, new file. |
| `Sources/AngstromUI/LaMarzoccoMachine.swift` (774) | Device layer | Access relaxations, BT stored state, `setBaseDashboard` funnel, snapshot-from-base, optional cloud client (if in scope), the six BT-first method bodies (or a call into the helper) (§4). | **Foundation WP for the class-body edits**, then **one** "BT commands" WP for the six method bodies. All other BT UI logic goes in `LaMarzoccoMachine+*.swift` files. |
| `Sources/AngstromUI/MachineSnapshot.swift` (40) | Persisted shape | Probably unchanged (persist the base dashboard). If BT state such as the peripheral identifier is to be persisted, add optional fields: Codable-compatible, since synthesized decode treats a missing optional as nil. | Snapshot WP if needed. |
| `Sources/Angstrom/Documentation.docc/Angstrom.md` (76) | Topics index | Rewrite `:7-11` ("Bluetooth is out of scope; this is a cloud-only client"). Add a `### Bluetooth` topic group listing the new public types. Add a BT article (`Bluetooth.md`) referenced from Essentials. | **Docs WP (last).** |
| `Sources/Angstrom/Documentation.docc/GettingStarted.md` (101) | Article | Optional "Bluetooth" section. The install snippet still says `from: "1.0.0"` (`:19`). | Docs WP. |
| `Sources/AngstromUI/Documentation.docc/AngstromUI.md` (43) | Overview | Mention BT-first commands, shot counter and `isBluetoothConnected`. | Docs WP. |
| `CLAUDE.md` (154) | Agent instructions | `:12` "(Bluetooth is explicitly out of scope; cloud only.)". Architecture lists (`:38-108`) need the new files. Conventions (`:110-117`) gain BT conventions such as "never construct CBCentralManager in tests". Status (`:119-154`). | Docs/meta WP (last). |
| `README.md` (136) | Public face | `:5` "A Swift library for the La Marzocco **cloud** API", `:19-58` Status (`:22` "(Bluetooth is out of scope)"), Install version `:65`, usage section, BT permission/entitlement requirements for apps. | Docs/meta WP. |
| `UPSTREAM.md` (269) | Watermark + runbook | See §8. | Docs/meta WP. **Never** touch the two markers (`:15-16`) except in a deliberate watermark bump. |
| `.github/workflows/ci.yml` (41) | CI | If a new test target is added, `swift test` (`:31-32`) already covers it. No change unless BT tests need a different runner. Hardware-free mocks need none. | No owner needed (verify only). |
| `.github/workflows/docs.yml` (60) | DocC build | If a new target `AngstromBluetooth` is added, add `--target AngstromBluetooth` beside `:38-39`. | Docs WP. |
| `.github/workflows/upstream-drift.yml` (164) | Drift issue body | `:97` text "port cloud-relevant changes (skip Bluetooth-only)". The comment at `:60` says "(cloud-relevant paths only)", but the compare at `:61` is unfiltered. See §8. | Docs/meta WP. |
| `cli/Package.swift` (33) | CLI build | Possibly `linkerSettings` to embed an Info.plist (§7.3). If BT is a separate product, add `.product(name: "AngstromBluetooth", package: "Angstrom")` at `:23-26`. | CLI-foundation WP. |
| `cli/Sources/angcli/AngCLI.swift` (45) | Subcommand registration | `subcommands: [Listen.self, Dump.self, Machines.self]` (`:19`) → add a `Ble.self` group. Update the `abstract`/`discussion` (`:8-17`). Bump `version` (`:18`). | CLI-foundation WP. Each `ble` subcommand then lives in its own file under `cli/Sources/angcli/Ble/`, registered in `Ble.swift`'s own `subcommands:`. That way subcommand WPs only ever edit `Ble.swift`'s list, or the foundation pre-registers stubs. |
| `cli/Sources/angcli/Output.swift` (177) | `Redact`, printers | `Redact.secrets` (`:151-153`) composes `bleAuthToken` + `bearerToken`. Add a BT rule for the auth-characteristic write payload and the GET_TOKEN read, plus a printer for `RawBluetoothFrame`. | CLI-foundation WP adds the redaction. The BT `listen` WP adds the printer, preferably in a new `BleOutput.swift`. |
| `cli/SPEC.md` (130), `cli/README.md` (239) | CLI docs | New "ble" section, permission notes, findings. `SPEC.md:43-46` says "platforms macOS 14+" and `:102-108` lists the redaction rules. | CLI docs WP. |
| `cli/Sources/angcli/Bootstrap.swift` (86) | Cloud session + machine picker | `ble` commands that need the cloud token reuse `Bootstrap.connect()` (`:22-58`) and `MachineSelector` (`:63-86`). A BT-only `ble scan` must **not** call Bootstrap. | Read-only for BT WPs. A BT session helper goes in a new file. |
| `cli/Sources/angcli/InstallationStore.swift` (49) | Persisted file | Only if peripheral identifiers are persisted (§7.2). | CLI-foundation WP, if at all. |
| `Tests/*/Support` mocks, `Tests/*/Fixtures` | Duplicated support | New BT fixtures and mocks (§6.3). | Test-infra WP. |

---

## 6. Test conventions

### 6.1 Framework and naming

- **XCTest only.** Every test file starts with `import XCTest` and
  `@testable import Angstrom` (plus `@testable import AngstromUI` in UI tests). There
  are no `import Testing`, `@Test` or `@Suite` anywhere (`grep`). The CLI tests are
  XCTest too (`cli/Tests/angcliTests/AngCLITests.swift:1-4`).
- Classes are `final class <Area>Tests: XCTestCase` with `func test<Behaviour>()`, and
  `async throws` where needed. AngstromUI tests are annotated `@MainActor` at class level
  (`LaMarzoccoMachineTests.swift:8`).
- Helpers are `private func` inside the test class: per-file backends (`authBackend`,
  `commandBackend`, `fixtureBackend`) and client factories (`makeClient`, `connect`)
  (`WebSocketTests.swift:8-56`, `CommandTests.swift:9-33`,
  `LaMarzoccoMachineTests.swift:14-91`).
- `// MARK: -` sections group tests by feature.
- Upstream test names are cited in comments, and upstream behaviour is "pinned" in tests
  (e.g. `UPSTREAM.md:82-87`).

### 6.2 Fixtures

- `Fixture.data(_ name:)` loads `Bundle.module` `Fixtures/<name>.json`, failing the test
  through `XCTFail` when missing (`Tests/AngstromTests/Support/Fixtures.swift:6-14`).
- Resources are declared with `resources: [.copy("Fixtures")]` (`Package.swift:25,30`),
  so a new fixture dropped in the folder needs **no** `Package.swift` edit.
- Fixtures are real captures "ported from pylamarzocco's test suite"
  (`Fixtures.swift:4-5`). **Upstream BT tests use no fixture files** (verified: no
  `load_fixture` or `.json` reference in `tests/test_bluetooth_*.py`;
  `tests/fixtures/` holds only `grinder/` and `machine/`). Their inputs are inline
  byte constants (`tests/test_bluetooth_client.py:47`, the mock characteristic store at
  `:171`). Their expected dashboards are syrupy snapshots
  (`tests/__snapshots__/test_bluetooth_dashboard.ambr`). A Swift port should therefore:
  - keep BT inputs inline in the test files, as upstream does;
  - transcribe each `.ambr` snapshot it relies on into explicit `XCTAssertEqual`s, or
    into a JSON fixture (`bt_dashboard_<case>.json`) decoded with `JSONDecoder.laMarzocco()`.

  Snapshot `connection_date` is pinned in upstream setup
  (`tests/test_bluetooth_dashboard.py:64`).
- Name pattern: `<endpoint>_<model>[_variant].json`.

### 6.3 Mocks and duplication

- `MockBackend` + `MockURLProtocol` (`Support/MockTransport.swift:7-128`) route each
  `URLSession` to its own backend through a unique `X-Mock-Backend` header, so tests run
  in parallel without cross-talk (`:59-64,120-127`). The backend records path, method
  and body for assertions (`count(pathSuffix:)`, `body(pathSuffix:)`).
- `MockWebSocketChannel` (§2.1) and `LockedBox<T>` (`Support/MockWebSocket.swift:5-11`)
  provide thread-safe cross-task assertions.
- **Duplication:** `Tests/AngstromUITests/MockTransport.swift` is byte-identical to the
  core copy (`diff` clean). `Tests/AngstromUITests/MockWebSocket.swift` (62 lines) is a
  reduced copy with no `PingBehavior` and no `LockedBox`. `Tests/AngstromUITests/Fixtures.swift`
  and all 15 fixture JSONs are duplicated too. SwiftPM test targets can't share sources.
  A BT mock needed by both `AngstromTests` (BT client) and `AngstromUITests` (device
  layer) will be copied again, or the plan adds a shared support target such as
  `.target(name: "AngstromTestSupport", dependencies: ["Angstrom"], path: "Tests/Support")`.
  That target can't use `@testable` across targets cleanly. It would need the `package`
  access route (§2.10). **Decision for the plan.**

### 6.4 Async/actor/timer determinism

- **Shrink-and-poll.** Real timers stay, but durations are cut to milliseconds through
  `setWebSocketTimingForTesting` (e.g. heartbeat `.milliseconds(20)`, backoff `.milliseconds(10)`;
  `WebSocketTests.swift:139-141`, `LaMarzoccoMachineTests.swift:432-434`). Results are
  awaited with `waitUntil(_:_:)`: 300 iterations × `Task.sleep(.milliseconds(10))`,
  then `XCTFail` (`WebSocketTests.swift:35-41`; `@MainActor` variant at
  `LaMarzoccoMachineTests.swift:874-880`).
- **Explicit ordering through stream iterators:** `var it = stream.makeAsyncIterator();
  await it.next()` (`WebSocketTests.swift:90-93,111-121`).
- **Scripted I/O:** the test pushes a `CONNECTED` frame *before* `connectWebSocket` so
  the handshake resolves (`WebSocketTests.swift:24-25`). `ChannelVendor` scripts
  reconnects.
- **Clock injection** is used only for token expiry (`TestClock` +
  `setClockForTesting`; `AuthTests.swift`).
- AngstromUI's `Date()` stamps (`LaMarzoccoMachine.swift:155,197,226`) are not
  injectable. Tests assert only ordering and non-nil-ness (`testLastUpdateAtStampsRefreshAndPush`,
  `:525`).
- **BT implication:** BT client tests (auth retries at 50 ms intervals, idle disconnect
  30 s, reconnect 1→60 s) and the 60 s overlay expiry all need `…ForTesting` duration
  setters in this style. Upstream shrinks time the same way: it patches the module
  constant (`patch("pylamarzocco.clients._bluetooth.IDLE_TIMEOUT", IdleTimer.TIMEOUT)`,
  `tests/test_bluetooth_client.py:152`; rationale comment at `:111`). Its tests
  therefore translate naturally into "set a short duration via `…ForTesting`, then
  `waitUntil`".

### 6.5 CI commands

- Root: `swift build` then `swift test` on `macos-15` with the newest Xcode selected
  (`ci.yml:17-32`).
- CLI: `swift build --package-path cli` and `swift test --package-path cli` (`ci.yml:37-41`).
- Docs: `swift package … generate-documentation --target Angstrom --target AngstromUI …`
  (`docs.yml:34-44`).
- Local equivalents are in CLAUDE.md "Commands" (`swift test --filter ProofTests` and so
  on).

### 6.6 CoreBluetooth on CI and in tests

- GitHub's `macos-15` runners have no usable Bluetooth radio. Tests must run entirely
  against the mock seam.
- **UNVERIFIED (macOS TCC):** constructing a `CBCentralManager` in an `xctest` host
  without an `NSBluetoothAlwaysUsageDescription` may abort the process or block on a
  permission prompt. Resolve by running a throwaway test on a dev Mac. Until then, the
  plan's rule should be: **no test constructs `CBCentralManager`/`CBPeripheral`**. The
  CoreBluetooth adapter file is excluded from unit coverage and exercised manually
  through angcli.

---

## 7. angcli: structure, persistence, redaction, and where `ble` fits

### 7.1 Command structure today

- `@main struct AngCLI: AsyncParsableCommand` with
  `subcommands: [Listen.self, Dump.self, Machines.self]` and
  `defaultSubcommand: Listen.self` (`AngCLI.swift:4-22`).
- Each command is one file with its own `configuration.abstract`.
- `Bootstrap.connect()` (`Bootstrap.swift:22-58`) does key load/generate → credentials →
  `client.connect()` → persist key + registered.
- `MachineSelector.choose` picks the machine by `--serial`, by being the only one, or by
  interactive prompt (`:63-86`).
- `CLIError` prints a clean message (`:5-10`).
- stdout carries one JSON object per line (`Stdout`, `Output.swift:8-15`). stderr carries
  status and prompts (`Stderr`, `:19-28`).
- `FramePrinter` writes `{ts, dir, raw|decoded}` lines (`:50-106`) with `>>`/`<<` arrows
  (`:64-67`).
- `SignalHandler` turns SIGINT into a clean disconnect (`SignalHandler.swift:18-26`;
  `Listen.swift:34-38`). It explicitly avoids the main queue: "the main queue isn't
  reliably serviced under an async `@main`" (`SignalHandler.swift:15-17`).

### 7.2 Persistence

- `StoredInstallation { installationKey, isRegistered }` (`InstallationStore.swift:7-10`)
  is stored at `$XDG_CONFIG_HOME|~/.config` + `/angstrom/installation.json`, with the
  directory at `0700` and the file clamped to `0600` after an atomic write (`:16-48`).
- It uses a vanilla `JSONEncoder` with sorted keys, not `.laMarzocco()`, because it holds
  no dates.
- Credentials are never persisted (`Credentials.swift:6-7`). Tokens are never persisted
  or printed (`AngCLI.swift:10-13`).
- **BT considerations:**
  - CoreBluetooth exposes no MAC address. Peripherals are identified by a per-central
    `CBPeripheral.identifier` (UUID), while upstream keys on the MAC (`address`,
    `clients/_bluetooth.py:549-553`).
  - To avoid rescanning, the CLI could persist a `serial → peripheral UUID` map. Adding
    an **optional** field to `StoredInstallation` keeps old files decodable.
  - The `bleAuthToken` is a secret. CLI policy so far persists no tokens. Recommended:
    fetch it fresh from the cloud each run (needs §3.5), or accept
    `--ble-token` / `LAMARZOCCO_BLE_TOKEN` for BT-only use. **Never** write it to
    `installation.json` without an explicit owner decision.

### 7.3 Running CoreBluetooth from a command-line process

These are requirements and risks the CLI-foundation WP must handle:

1. **Delegate queue.** Create `CBCentralManager(delegate:queue:)` with a dedicated serial
   `DispatchQueue`, not `nil` (the main queue). This follows the same reasoning as
   `SignalHandler.swift:15-17`.
2. **Bluetooth permission (TCC).** macOS requires `NSBluetoothAlwaysUsageDescription` in
   the *process's* Info.plist. A SwiftPM `executableTarget` has none. Common practice is
   to embed one in the Mach-O. In `cli/Package.swift` that means `linkerSettings:
   [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker",
   "__info_plist", "-Xlinker", "<path>/Info.plist"])]`. `unsafeFlags` is allowed here
   because `cli/` is always a root package and never a dependency (`cli/Package.swift:4-10`).
   **UNVERIFIED:** whether TCC instead attributes the request to the responsible
   terminal app, and whether an embedded plist is required or sufficient on macOS 14 and
   15. Resolve by running `angcli ble scan` from Terminal on a clean machine and
   checking System Settings › Privacy › Bluetooth.
3. **Adapter readiness.** Wait for `centralManagerDidUpdateState == .poweredOn` before
   scanning. Map `.unauthorized` / `.poweredOff` / `.unsupported` to a clear `CLIError`
   (and to the library error chosen in §3.6).
4. **Lifetime.** Long-running `ble listen` (shot counter) needs the SIGINT path to stop
   notifications and disconnect, mirroring `Listen.swift:34-38`.
5. **Platforms.** `cli/Package.swift:13-15` is macOS 14 only, which is fine. CoreBluetooth
   on macOS 14 supports everything needed.

### 7.4 Redaction

`Redact.secrets(in:)` = `bearerToken(in: bleAuthToken(in: text))` (`Output.swift:151-153`).
The JSON-key regex for `bleAuthToken` is at `:155-160` and the STOMP `Authorization`
header regex at `:162-167`. Both are tested (`AngCLITests.swift:57-111`). BT adds:

- the auth write payload (token bytes, `clients/_bluetooth.py:636-640`);
- the `GET_TOKEN_CHARACTERISTIC` read (`:540-547`; UUID `0c0b7847-e12b-09a8-b04b-8e0922a9abab`, `:42`);
- the token in any `ble token` output.

`ble token` exists *to* print the token, so it should require an explicit flag
(e.g. `--show-secret`), print to stdout only on request, and mask by default. Masking
must apply to the raw BT tap printer, keyed on the characteristic rather than a JSON key.

### 7.5 Where `ble` subcommands slot in

Add a parent command `struct Ble: AsyncParsableCommand` with
`subcommands: [BleScan, BleToken, BleRead, BleCommand, BleListen]`, registered in
`AngCLI.swift:19`.

| Subcommand | Needs cloud? | Library surface used | Upstream analogue |
|---|---|---|---|
| `ble scan` | no | scanner seam; filter by name prefixes `("MICRA", "MINI", "LINEA", "GS3")` (`clients/_bluetooth.py:46,523-537`) | `discover_devices` |
| `ble token` | no (machine in pairing mode) | read `GET_TOKEN_CHARACTERISTIC` | `read_token` (`:539-547`) |
| `ble read <setting>` | token: cloud (§3.5) or flag/env | `BluetoothReadSetting` (`const.py:322-330`) → raw + decoded | `get_machine_mode`/`capabilities`/`tank`/`boilers`/`smart standby`/`plumbed-in` (`clients/_bluetooth.py:556-595`) |
| `ble command <power\|steam\|temp\|standby>` | token | BT command methods (`:597-626`) | actuates hardware. Flag it as SPEC.md does for `watch` (`cli/SPEC.md:128-129`) |
| `ble listen` (shot counter + telemetry) | token | shot-counter + telemetry streams + raw BT tap | `start_shot_counter` (`:327`) |

Output should reuse the `{ts, dir, raw|decoded}` line convention. `dir` arrows carry
over, and `raw` would be hex or UTF-8 text plus the characteristic.

---

## 8. `UPSTREAM.md` and the drift workflow: what assumes "Bluetooth excluded"

| Location | Current text (abridged) | Required change |
|---|---|---|
| `UPSTREAM.md:3-4` | "an independent Swift port of the **cloud** protocol and authentication" | Add Bluetooth. |
| `UPSTREAM.md:24` (Scope row) | "… Bluetooth is excluded by design and is **not** tracked here." | New scope: cloud + Bluetooth (CoreBluetooth). |
| `UPSTREAM.md:26-31` | "full cloud surface … (Bluetooth-only changes upstream are out of scope and never advance this watermark.)" | Rewrite. Once BT is in, BT changes **do** advance the watermark, and the watermark must mean "cloud **and** BT parity at vX". |
| `UPSTREAM.md:119-163` (v2.4.4–v2.5.2 notes) | Lists BT items as "out of scope", "no port": shot counter, telemetry, connection callbacks, `BluetoothAuthenticationFailed` (`:122-126`); `_dashboard_config_updated` / override widget status "no port" (`:151-153`) | Add a new "Bluetooth port" section recording that these are now ported and which divergences remain. Don't rewrite history: the notes describe what each past port did. |
| `UPSTREAM.md:94-100` (`e0f0249` aliases) | Explains why `"GS3"`/`"LINEA"` BT family aliases were not ported to `Model` | Keep `Model.match` as is. Document the new `Model(bluetoothFamily:)` that *does* implement them. |
| `UPSTREAM.md:253-255` (runbook triage) | `cloud / auth / proof / models / websocket / commands / stats -> port`; `Bluetooth-only -> skip (out of scope)` | Change to `bluetooth (clients/_bluetooth.py, models/_bluetooth.py, BT paths in devices/) -> port`. Point the review-surface diff (`:251`) at the BT files too. |
| `UPSTREAM.md:15-16` markers | `upstream-version: v2.5.6`, `upstream-sha: 4c639ee` | **Do not change** unless the BT PR is itself a watermark bump. BT parity is being built against the same `4c639ee`, so the markers stay. Update only the Scope/notes. |
| `.github/workflows/upstream-drift.yml:97` | "port cloud-relevant changes (skip Bluetooth-only)" | "port cloud and Bluetooth changes". |
| `.github/workflows/upstream-drift.yml:60` | Comment "(cloud-relevant paths only)". The `gh api …/compare` at `:61` is **not** path-filtered, and the commit list at `:72` is the whole range. | Fix the comment, or add path filtering if desired. Parsing of the markers (`:39-40`) is unaffected. |
| `CLAUDE.md:12` | "(Bluetooth is explicitly out of scope; cloud only.)" | Replace with "Bluetooth uses CoreBluetooth; same reference-of-record rule". |
| `CLAUDE.md:121`, `:145`, `:154` | Status lines say BT excluded / remains out of scope | New status paragraph. |
| `README.md:5`, `:21-24` | "cloud API", "(Bluetooth is out of scope)" | Update. Add an app-integration note for `NSBluetoothAlwaysUsageDescription` and, for sandboxed macOS apps, the `com.apple.security.device.bluetooth` entitlement (see §10 and Open Questions). |
| `Sources/Angstrom/Documentation.docc/Angstrom.md:10-11` | "Bluetooth is out of scope; this is a **cloud-only** client." | Update. |
| `Sources/Angstrom/Models.swift:25-26`, `:29-31` | Doc comments say BT is out of scope | Update with the `bleAuthToken` decision. |
| `cli/SPEC.md`, `cli/README.md` | Cloud-only framing ("Debug the La Marzocco cloud API", `AngCLI.swift:8`) | Add BT. |

---

## 9. Size pressure: files to split rather than extend

| File | Lines now | BT pressure if extended in place | Recommendation |
|---|---:|---|---|
| `Widgets.swift` | 909 | +5 explicit inits (~60 lines) | Accept the inits only. Put all BT dashboard logic in `Dashboard+Bluetooth.swift`. Longer term, a split such as `Widgets+Grinder.swift` is worth considering but out of BT scope. |
| `LaMarzoccoCloudClient.swift` | 796 | A whole BT client would roughly double it | **Do not touch.** A separate actor gets its own file set: `Bluetooth/LaMarzoccoBluetoothClient.swift` (connection/auth/reconnect), `+Reads.swift`, `+Commands.swift`, `+ShotCounter.swift`, `BluetoothTransport.swift` (seam), `CoreBluetoothTransport.swift` (adapter). |
| `LaMarzoccoMachine.swift` | 774 | Overlay + BT-first + dashboard-from-BT + state ≈ 250-350 lines | **Split.** Class-body edits only (§4.5-4.6) in the main file. Everything else in `LaMarzoccoMachine+Bluetooth*.swift`. |
| `LaMarzoccoMachineTests.swift` | 897 | BT device-layer tests would push it past 1200 | **New test files**: `LaMarzoccoMachineBluetoothTests.swift`, `ShotCounterOverlayTests.swift`. |
| `WebSocketTests.swift` | 577 | not touched | BT client tests in `BluetoothClientTests.swift`, `BluetoothShotCounterTests.swift`, `BluetoothDashboardTests.swift`, mirroring upstream's `test_bluetooth_client.py` / `test_bluetooth_dashboard.py`. |
| `Enums.swift` | 558 | +4 enums, mappings | New `BluetoothEnums.swift` (or `Bluetooth/Models.swift`). Only the `Lenient` access change and the model-set move touch Enums.swift. |
| `Commands.swift` | 543 | +1 init | In place (tiny). |
| `Optimistic.swift` | 419 | +4-5 transforms | New file instead. |
| `Models.swift` | 255 | +3-4 error cases + descriptions, maybe `bleAuthToken` | In place. It is the error enum's home, and splitting `LaMarzoccoError` out is optional. |
| `cli/Sources/angcli/Output.swift` | 177 | Redact rule + BT printer | Redact rule in place. BT printer in a new `BleOutput.swift`. |

Suggested new layout, if BT lives in the `Angstrom` target. Under the separate-target
option, the same files go under `Sources/AngstromBluetooth/`.

```
Sources/Angstrom/Bluetooth/
  BluetoothTransport.swift          # seam protocols (GATT peripheral + scanner)
  CoreBluetoothTransport.swift      # the only file importing CoreBluetooth
  BluetoothConstants.swift          # characteristic UUIDs, prefixes, timings (cited)
  BluetoothModels.swift             # capabilities, boiler details, command status, smart standby
  BluetoothShotCounter.swift        # brewing data/tracker/derive_state, telemetry, update
  BluetoothEnums.swift              # BoilerType, BluetoothBrewingState, BluetoothReadSetting, Model(bluetoothFamily:)
  LaMarzoccoBluetoothClient.swift   # actor: connect/auth/idle/reconnect, streams, test seams
  LaMarzoccoBluetoothClient+Reads.swift
  LaMarzoccoBluetoothClient+Commands.swift
  BluetoothDiagnostics.swift        # RawBluetoothFrame + tap
  Dashboard+Bluetooth.swift         # upsert/remove, fromBluetooth, overlay, settingMachineState
Sources/AngstromUI/
  LaMarzoccoMachine+BluetoothCommands.swift
  LaMarzoccoMachine+BluetoothDashboard.swift
  LaMarzoccoMachine+ShotCounter.swift
cli/Sources/angcli/Ble/
  Ble.swift  BleScan.swift  BleToken.swift  BleRead.swift  BleCommand.swift  BleListen.swift  BleOutput.swift
```

---

## 10. Cross-cutting decision: where does BT code live?

| | **A. Inside `Angstrom`** | **B. New `AngstromBluetooth` target/product** |
|---|---|---|
| Access to `Lenient`, `ResumeOnce`, internal inits | direct | needs widening to `package` (preferred) or `public` |
| Consumers that don't want BT | still link CoreBluetooth (autolinked by `import`) | unaffected |
| App Store risk | **UNVERIFIED:** whether App Store processing flags a missing purpose string (ITMS-90683-style) for apps whose binary references CoreBluetooth symbols they never call. Resolve with Apple docs or a test upload. | none for non-BT consumers |
| AngstromUI integration | AngstromUI imports Angstrom and gets BT for free | AngstromUI must depend on AngstromBluetooth (pulling CoreBluetooth into all UI consumers) **or** take BT through a protocol defined in core `Angstrom` and implemented in `AngstromBluetooth` |
| DocC / CI | no workflow change | `docs.yml` `--target AngstromBluetooth`, new test target |
| Pronto | gets CoreBluetooth linked whether or not it uses BT | opt-in |

A middle path is **B with a core protocol**:
- `Angstrom` holds the pure, CoreBluetooth-free parts: models, enums, the shot-counter
  state machine, dashboard synthesis, the transport *protocol* and the BT client actor
  written against the protocol.
- `AngstromBluetooth` holds only `CoreBluetoothTransport` (the CBCentralManager adapter)
  and a convenience factory.
- AngstromUI depends only on `Angstrom`.

This keeps CoreBluetooth out of every consumer that doesn't opt in. It needs no
`package`-access widening for the bulk of the code, and it isolates the one
hardware-only file from unit tests. **Owner decision; recommended.**

---

## 11. Open questions and UNVERIFIED items

1. **Target layout** (§10): A, B, or B-with-core-protocol?
2. **`bleAuthToken` modelling** (§3.5): field on `Machine` (decode-only, not encoded) or
   a separate token read? This affects snapshot round-trip tests and the
   persisted-secret risk for Pronto.
3. **BT-only mode** (§4.4d): should `LaMarzoccoMachine` accept a nil cloud client, with
   `.cloudOnlyFunctionality`? It is large and touches nearly every method.
4. **Return type of BT-first commands:** keep `CommandResponse` (needs a public/package
   init and a `BluetoothCommandStatus` → `CommandResponse` mapping), or change the
   signatures? Which BT outcomes fall back and which throw (§2.5)?
5. **BT status-string casing.** *Resolved for design:* upstream's test reply is
   lowercase `"success"` (`tests/test_bluetooth_client.py:47`) and the check is
   case-insensitive (`_machine.py:1023`). Compare case-insensitively and leave
   `CommandStatus.init(rawValue:)` unchanged (§2.5). Real-device casing still has no
   capture, which is low risk under the case-insensitive rule.
6. **Does BT `set_temp` round?** *Resolved:* no (`clients/_bluetooth.py:621-626`;
   §3.4). Only the cloud leg rounds (`Commands.swift:160`).
7. **`lastShotTime` rules.** *Resolved:* set from `final_shot_time` when non-nil and
   never reset (`_machine.py:211-213`; §4.5).
7a. **BT payload key order** (§2.11). Is the firmware order-sensitive? UNVERIFIED and
   only resolvable on hardware. The plan should not depend on the answer: emit
   upstream's exact bytes and pin them in tests.
8. **BT reconnect policy:** port upstream's exponential 1→60 s with the 3-auth-failure
   stop verbatim (`clients/_bluetooth.py:52-54,488-521`), or unify with the websocket's
   forever-retry? A divergence must be recorded in UPSTREAM.md.
9. **Dashboard model default for BT-only synthesis:** upstream's `LINEA_MICRA` default
   (`models/_general.py:98-106`) or Angstrom's `.unknown("")` (`Models.swift:44`)?
10. **Should BT-sourced dashboard refreshes stamp `lastUpdateAt`?** It is documented as
    cloud-only (`LaMarzoccoMachine.swift:43-46`).
11. **Test-support sharing:** a third copy of the mocks or a shared support target (§6.3)?
12. **macOS TCC for `xctest` and for the CLI.** UNVERIFIED (§6.6, §7.3). Run a throwaway
    `CBCentralManager` instantiation under `swift test` and under `angcli` on a dev Mac.
13. **Peripheral identity in angcli:** rescan each run by name prefix, or persist
    `serial → CBPeripheral.identifier`? Upstream's legacy notes list a GATT
    "Serial Number String" characteristic `00002a25-…` (`docs/legacy/bluetooth_characteristics.md:21`)
    that might map a peripheral to a serial. UNVERIFIED whether it returns the cloud serial.
14. **Pronto entitlements:** whether Pronto is App-Sandboxed. If so, it needs
    `com.apple.security.device.bluetooth` plus `NSBluetoothAlwaysUsageDescription`.
    Unknown from this repo. Ask the owner.
15. **Version number:** new `LaMarzoccoError` cases are source-breaking. By precedent
    that is a minor bump (`UPSTREAM.md:103-104`), e.g. 1.8.0. Does a feature this large
    warrant 2.0.0 instead?
