# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Angstrom is a Swift Package Manager library (macOS 14+ / iOS 17+, Swift 6 with strict
concurrency) for the **La Marzocco** customer-app cloud API and the machines' Bluetooth LE
protocol. It is an independent Swift port of the cloud and Bluetooth protocols and
authentication from
[`pylamarzocco`](https://github.com/zweckj/pylamarzocco) (Josef Zweck). When changing
auth, proof, or any wire-shape/decoding logic, the Python source is the reference of
record — match it. Bluetooth uses CoreBluetooth (`AngstromBluetooth`); the same
reference-of-record rule applies to `clients/_bluetooth.py`, `models/_bluetooth.py` and
the BT paths in `devices/`.

**Porting watermark:** [`UPSTREAM.md`](UPSTREAM.md) records the exact `pylamarzocco`
version + commit the port has been carried to. When porting newer upstream changes,
follow its "Syncing to a newer upstream" runbook and **bump the watermark markers in
the same PR**. A weekly CI job (`.github/workflows/upstream-drift.yml`) opens a
tracking issue when upstream moves past the watermark.

Three products: **`Angstrom`** — the stateless `actor` core (transport/protocol/typed
reads/commands/websocket, plus all Bluetooth protocol logic behind a `package` transport
seam), usable standalone by CLI/server consumers and CoreBluetooth-free — **`AngstromBluetooth`**
— the small CoreBluetooth adapter (the only target that does `import CoreBluetooth`), linked
only by apps that use Bluetooth — and **`AngstromUI`** — an optional `@MainActor @Observable`
device layer on top for SwiftUI (depends on `Angstrom` only, never on `AngstromBluetooth`).

## Commands

```bash
swift build                                   # build
swift test                                    # run all tests
swift test --filter ProofTests                # run one test case (by type name)
swift test --filter ProofTests/testRequestProofMatchesPythonReference   # one method
```

CI (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on macos-15, selecting
the newest installed Xcode so the SDK matches the package's deployment targets.

## Architecture

### `Sources/Angstrom/` — the stateless core

- **`InstallationKey.swift`** — the per-install cryptographic identity. A `Codable`/`Sendable`
  value type storing only the installation UUID and the raw 32-byte P-256 private-key
  scalar; everything else (public key DER, the 32-byte `secret`, the registration
  `baseString`, signatures) is *derived on demand*. Callers generate one with `.generate()`,
  persist it, and pass it back each launch.

- **`Proof.swift`** — La Marzocco's bespoke request-proof scheme. `requestProof` is a hand
  ported byte-mutation loop (XOR + rotate-left within a byte), finalized as
  `base64(sha256(work))`. `requestHeaders` builds the signed headers carried on signin and
  every authed request. The most fragile code in the repo — verified against fixed vectors
  in `ProofTests`.

- **`LaMarzoccoCloudClient.swift`** — the public `actor`. Owns the URLSession, the in-memory
  token lifecycle (refresh via `/auth/refreshtoken`, coalesced through one in-flight
  `tokenTask`), the typed reads (`machines`/`dashboard`/`settings`/`schedule`/`statistics`),
  `executeCommand` (two-tier: awaits websocket confirmation when connected, else
  fire-and-forget), and the STOMP websocket (connect/subscribe/heartbeat/reconnect →
  `AsyncStream<DashboardUpdate>`, plus `connectionEvents()` reporting every
  connect/disconnect transition — the push feed is change-only, so consumers re-fetch
  on `.connected`). STOMP `heart-beat` stays `0,0` (upstream parity); liveness is a
  websocket-level ping whose pong deadline (half the heartbeat interval, as in
  aiohttp) force-closes zombie sockets so the reconnect loop fires. Tokens are
  **never persisted** — persisting `installationKey` + `isRegistered` is the caller's job.

- **`Models.swift`** — `Machine`, `PowerState`, `LaMarzoccoError` (`LocalizedError`).
- **`Enums.swift`** — `Model`/`DeviceType` + machine/dose/boiler/grinder enums, the
  `JSONDecoder/Encoder.laMarzocco()` (ms-epoch) factories, and the `Lenient<T>` skip-on-fail wrapper.
- **`Widgets.swift`** — `Dashboard` + the `Widget`/`WidgetKind` discriminated union (keyed on
  widget `code`, demotes unknown/undecodable widgets to `.unknown`) + every payload struct
  (incl. grinder widgets). All payloads are `Codable` so a `Dashboard` round-trips for snapshots.
- **`Settings.swift`** — `MachineSettings`, `MachineSchedule`, `WakeUpSchedule`, firmware.
- **`Commands.swift`** — `CommandResponse`/`CommandStatus` + the command methods + firmware.
- **`Statistics.swift`** — `ThingStatistics` + the `StatWidget` union and `/stats` endpoints.
- **`Stomp.swift` / `WebSocket.swift`** — STOMP codec; `WebSocketChannel` seam,
  `DashboardUpdate`, and `Dashboard.applying(_:)` (wholesale widget replacement —
  pushes are full snapshots; upstream parity — except a widget-less push, which is
  a partial frame and keeps the last-known set while still applying connectivity).
- **`Optimistic.swift`** — pure `Dashboard.replacing(_:)` + `setting…(_:)` transforms used by
  the device layer for optimistic updates.
- **`Diagnostics.swift`** — opt-in debug surface for wire-tracing: `RawFrame` +
  `rawFrames() -> AsyncStream<RawFrame>` (multiplexed like `dashboardUpdates()`, taps both
  directions — inbound before `Stomp.decode`, outbound at `channel.send`, plus synthetic
  heartbeat ping/pong markers), and `RawEndpoint` + `rawRead(_:serial:) -> Data` for
  verbatim REST JSON. Zero cost
  when no `rawFrames()` listener is open. Consumed by the `cli/` tool below.
- **`LaMarzoccoCloudClient+BluetoothToken.swift`** — `bluetoothAuthToken(serial:)`: reads
  `bleAuthToken` from `GET /things` and wraps it in the opaque `BluetoothAuthToken` (nil when the
  cloud has none). The token is deliberately **not** a `Machine` field (D2 in `UPSTREAM.md`), so it
  never lands in a `MachineSnapshot` or encoded CLI output.

### `Sources/Angstrom/Bluetooth/` — the Bluetooth protocol (CoreBluetooth-free)

All BLE protocol logic lives in the core target, behind a `package` transport seam, so it is
unit-tested in CI with fakes and cloud-only consumers never link CoreBluetooth.

- **`BluetoothConstants.swift`** — the five GATT characteristic UUIDs (`0a0b…`–`0e0b…`), the
  discovery name prefixes, `authSuccess`, and `BluetoothTiming` (every timeout/count: 30 s idle,
  10 × 50 ms auth poll, 3 auth failures, 1→60 s reconnect backoff, 3 × 20 s connect attempts,
  20 s per GATT op, 10 s powered-on wait), overridable in tests via `setTimingForTesting(_:)`.
- **`BluetoothTransport.swift`** — the seam: `package` protocols `BluetoothCentral` (one connect
  attempt per call, scan, availability), `BluetoothLink` (one object per connection, compared by
  `===`; a single ordered `AsyncStream<LinkEvent>`), `BluetoothSleeper` (sleeps tagged by
  `SleepPurpose`), plus the public `BluetoothTransport` bundle (central + sleeper + `now`),
  `BluetoothPeripheralID` (the `CBPeer.identifier` UUID — not a MAC), `BluetoothAvailability`,
  `BluetoothAuthorization`, `DiscoveredPeripheral` and the GATT-table types (service and
  characteristic UUIDs are lowercase strings, always in the full 128-bit form — a 16- or 32-bit
  SIG UUID is expanded with the Bluetooth base, `"180a"` → `"0000180a-0000-1000-8000-00805f9b34fb"`).
- **`BluetoothAuthToken.swift`** — the opaque, non-`Codable` token whose `description`,
  `debugDescription` and mirror are redacted.
- **`BluetoothEnums.swift`** / **`BluetoothModels.swift`** — `BluetoothReadSetting`,
  `BluetoothBrewingState`, `BluetoothBoilerType`, `Model(bluetoothFamily:)` (upstream's
  `e0f0249` aliases), `Model.steamLevelModels`/`steamTemperatureModels`, the
  `MachineState`/`BoilerStatus(bluetoothMode:)` and `SteamLevel` BLE mappings, and the read/command
  result types (`BluetoothMachineCapabilities`, `BluetoothBoilerDetails`,
  `BluetoothSmartStandbyDetails`, `BluetoothCommandStatus`).
- **`BluetoothWireCoercion.swift`** — mashumaro-parity value coercion for responses and
  notifications, with the documented D5 differences (a)–(k) listed in `UPSTREAM.md` — among them
  `"false"` is false, unknown enum entries are `.other`, out-of-range/non-finite numbers fail
  instead of trapping or emitting NaN, and a list-typed field must be a JSON array.
- **`BluetoothCodec.swift`** — the **only** producer of BLE command/request/auth bytes: ordered
  keys, Python `json.dumps` spacing and `ensure_ascii`, the trailing NUL, response NUL truncation.
- **`BluetoothResponseDecoder.swift`** — read-setting and command-status decoding (tolerant parsing;
  failures are `LaMarzoccoError.decoding`).
- **`BluetoothShotCounterModels.swift`** / **`BrewingStateMachine.swift`** — the shot-counter
  notification models, `ShotCounterEvent`, `BluetoothJSONValue`, `deriveState`, the
  `BrewingTracker` (earliest-estimate `brewingStartTime`) and `ShotCounterNotificationDecoder`.
- **`BluetoothDiagnostics.swift`** — `RawBluetoothFrame` for the verbatim `rawFrames()` tap;
  frames carrying the token set `isSecret` so displays can redact. Today only the auth write
  reaches the tap (`readToken` is static and taps nothing); the rule stands for any token-read
  frame a later version emits.
- **`BluetoothOpTable.swift`** — the CB-free, exactly-once in-flight operation table the adapter
  uses (finish removes before resuming; abandoned ATT replies are counted and swallowed).
- **`LaMarzoccoBluetoothClient.swift`** (+`+Requests`, `+ShotCounter`, `+Discovery`) — the public
  `actor` (port of `LaMarzoccoBluetoothClient`): two FIFO gates, lazy connect with retry, the auth
  poll, the drop-on-error request wrapper, the 30 s idle auto-disconnect, `connectionEvents()`, the
  typed reads and commands (a non-success status is *returned*), the shot counter with its
  reconnect loop (`shotCounterEvents()`, terminal `.gaveUp`), `rawFrames()`/`rawRead(_:)`, and the
  static `scanAll`/`discoverMachines`/`readToken`/`gattTable`. `isConnected` means an
  **authenticated** link. `.subscribed` is emitted only if the counter is still enabled once the
  subscribe completes (a stop that lands mid-subscribe reports nothing). The reconnect loop creates
  its availability stream and reads availability once at loop start, before the first backoff
  sleep, so a power-off that caused the link loss still lets the next `.poweredOn` end the backoff
  early (D14). The idle task and link watcher hold the actor weakly, so the actor's `deinit` does
  the teardown when the client is released without `disconnect()`: it cancels the idle, link-watcher
  and reconnect tasks, closes a live link fire-and-forget, and finishes every listener stream
  (`connectionEvents()`, `shotCounterEvents()`, `rawFrames()`) without emitting an event. A
  running reconnect loop holds the client (upstream parity), so `deinit` waits for it to end.
- **`Dashboard+Bluetooth.swift`** — pure transforms: `upserting`, `removingWidgets(code:)`,
  `settingMachineState`, `applyingBluetoothState(_:model:)` (upstream's
  `get_dashboard_from_bluetooth` widget synthesis) and `overlayingBluetoothBrewing(_:)` (the
  shot-counter overlay on `CMMachineStatus`).

### `Sources/AngstromBluetooth/` — the CoreBluetooth adapter

The only target that imports CoreBluetooth (every file wrapped in `#if canImport(CoreBluetooth)`).
`CoreBluetoothCentral.swift` / `CoreBluetoothLink.swift` are `@unchecked Sendable` classes
confined to one private serial `DispatchQueue` (`"angstrom.bluetooth"`) that is both the
`CBCentralManager` delegate queue and the home of all adapter state. Async bridging goes through
`BluetoothOpTable`; every GATT op has a bounded timeout.
The central keeps a queue-confined `[UUID: CBPeripheral]` retention map: emptied when the state
drops to `.unknown`/`.resetting`/`.unsupported`/`.unauthorized`, and pruned at the start of every
scan (entries with no live link and no pending connect are dropped, and are re-resolved by
identifier on connect). `BluetoothTransport+CoreBluetooth.swift`
is the public surface: `BluetoothTransport.coreBluetooth(showPowerAlert:)` (manager allocated
lazily on first use; create once per process and share) and `BluetoothAuthorization.current`
(never prompts). Apps that link it need `NSBluetoothAlwaysUsageDescription` (and, if
App-Sandboxed on macOS, the `com.apple.security.device.bluetooth` entitlement).

### `Sources/AngstromUI/` — the observable device layer

- **`LaMarzoccoMachine.swift`** — `@MainActor @Observable`. Retains `dashboard`/`settings`/
  `schedule`/`statistics`, refreshes-and-stores, iterates the websocket `AsyncStream` (merging
  into `dashboard`), re-fetches the dashboard after every reconnect (change-only feed —
  transitions missed during a gap are never re-pushed), forwards commands with optimistic
  local updates, and gates model-specific commands (`LaMarzoccoError.unsupportedModel`).
  `isLive` tracks the *subscription* (start→stop) while `isConnected`/`lastUpdateAt` report
  actual socket health and freshness; `lastError` is cleared on the next success.
  Holds an optional cloud client and an optional `LaMarzoccoBluetoothClient`
  (`init(serialNumber:client:bluetooth:snapshot:)`; cloud-only calls throw
  `.cloudOnlyFunctionality` without a cloud client — cloud resolution is the first step, before
  model gating and argument guards, so a cloud-less machine always gets that error, as upstream's
  outermost `@cloud_only` does). The BLE-only operations and `startShotCounter()` run inside the same
  `lastError` capture as every other throwing operation: a failure (a missing BLE client included)
  is recorded, a success clears it. Every dashboard write goes through the
  `setBaseDashboard`/`updateBaseDashboard` funnel into `baseDashboard`; the public `dashboard` is
  rendered as `baseDashboard` + the BLE brewing overlay (what `refreshDashboard()` and
  `refreshDashboardFromBluetooth()` return), and snapshots persist the base only. Tasks that
  outlive one call (the connection observer, the shot-counter listener) capture `[weak self]` and
  hold only the stream, never the client, so releasing the machine and the client releases both.
- **`MachineBluetoothEvent.swift`** — the `bluetoothEvents()` stream's cases (`brewing`,
  `brewingCleared`, `telemetry`, Angstrom-only `shotCounterStopped`).
- **`LaMarzoccoMachine+BluetoothCommands.swift`** — `bluetoothFirst(bluetooth:cloud:)`: the six
  BLE-first commands try Bluetooth whenever a BLE client exists, fall back to the cloud (when there
  is a cloud client) on a BLE connection failure or a non-success status, and never fall back on
  `.bluetoothTimedOut` or any other error (upstream parity). A BLE success synthesizes a
  `CommandResponse`.
- **`LaMarzoccoMachine+BluetoothDashboard.swift`** — `refreshDashboardFromBluetooth()` and
  `refreshModelFromBluetooth()` (reads capabilities first when the model is unknown; no silent
  Linea Micra default; without a BLE client both throw
  `.bluetoothConnectionFailed("Bluetooth client not initialized")`).
- **`LaMarzoccoMachine+BluetoothConnection.swift`** — observes the BLE client's
  `connectionEvents()` into `isBluetoothConnected` (authenticated link);
  `bluetoothConnectionEvents()`.
- **`LaMarzoccoMachine+ShotCounter.swift`** — `startShotCounter()`/`stopShotCounter()`, the
  overlay state (`bluetoothBrewingUpdate`, `isShotCounterActive`, `lastShotTime`), the telemetry
  merge (`bluetoothTelemetry`), the 60 s brewing-state expiry, and `bluetoothEvents()`.
  `startShotCounter()` returns `false` without a BLE client; after a successful start
  `isShotCounterActive` is read from the client's live state (a stop that raced the start leaves
  it `false`).
- **`MachineSnapshot.swift`** — `Codable {serialNumber, dashboard?, settings?, schedule?}` for
  stale-on-launch UI (recognized widgets round-trip losslessly; unknown widgets keep code/index
  but lose their raw payload). Unchanged by Bluetooth: no BLE state is persisted.

### `Tests/AngstromTestSupport/` — shared test fakes

A non-product target both test targets depend on (everything `package`): `FakeBluetoothCentral`
/ `FakeBluetoothLink` (scripted GATT behaviour; `FakeOp` is the ordered assertion surface),
`ManualBluetoothSleeper` (fire tagged sleeps by hand — no wall-clock sleeps in tests),
`BluetoothTestClock`, `BluetoothTransport.fake(_:sleeper:clock:)`, `BluetoothTestVectors`
(verbatim upstream constants) and `ShotCounterRecording` (the recorded Linea Micra session in
`Fixtures/`).

### `cli/` — the `angcli` wire-debugging tool

A **separate, nested SwiftPM package** (not part of the library build, so library consumers
never see it or its `swift-argument-parser` dependency). Depends on `Angstrom` by path. Builds
and tests independently: `cd cli && swift build` / `swift test` (also wired as its own CI step).
Authenticates, holds the websocket open, and prints raw STOMP frames (both directions) and the
decoded `DashboardUpdate` side by side. Commands: `listen` (default), `dump <dashboard|settings|
schedule>`, `machines`. Persists `InstallationKey` + `isRegistered` to
`~/.config/angstrom/installation.json` (mode `0600`); never persists/prints tokens or proof
headers, and masks `bleAuthToken` and the STOMP bearer token in printed output. See `cli/SPEC.md` for the full design.

`angcli ble <scan|gatt|token|read|cmd|listen>` (`cli/Sources/angcli/Ble/`, links
`AngstromBluetooth`; an embedded `cli/Support/Info.plist` carries the Bluetooth usage string)
is the BLE counterpart: scan for machines (`--all` unfiltered), dump the GATT table, read the
token in pairing mode (masked unless `--show-secret`), raw + decoded reads, commands (which
actuate hardware and refuse to run without `--confirm`), and `listen` for raw frames plus
decoded connection/shot-counter events until SIGINT (if the shot counter gives up, `listen`
prints the mapped error to stderr, disconnects and exits non-zero in every output mode). `ble`
JSON lines are printed with sorted keys (key order is not part of the contract). The peripheral comes from `--peripheral`
or a scan; the token from `--ble-token`, `LAMARZOCCO_BLE_TOKEN`, or the cloud. Neither is ever
persisted, and every secret frame (`isSecret`, plus any `0d0b…` write or `0c0b…` read) is
printed as `**REDACTED**`.

### Conventions worth keeping

- Network responses are parsed defensively (`JSONSerialization` + shape checks, optional
  decodes) — the cloud API shape is only partially known, so prefer tolerant parsing and a
  `LaMarzoccoError.decoding(...)` over a hard typed-decode failure.
- All thrown errors are `LaMarzoccoError` cases; map new failures into that enum.
- The client is an `actor`; `installationKey` is `nonisolated let` so it can be read for
  persistence without `await`.
- Never construct `CBCentralManager` in tests (no Bluetooth hardware exists in CI); drive the
  BLE client through the `AngstromTestSupport` fakes behind the `package` seam.
- BLE command bytes only via `BluetoothCodec` — never hand-assemble a frame elsewhere.
- The BLE token never in logs or errors: keep it wrapped in `BluetoothAuthToken` (redacted
  `description`), never interpolate `rawValue`, and mark token-carrying raw frames `isSecret`.

## Status

v2.0.0 — full cloud **and Bluetooth** parity with `pylamarzocco` v2.5.6 (the watermark stays
`v2.5.6`/`4c639ee`: the BLE port is built against the same commit). A major release by owner
decision, not the minor-bump precedent: it adds a second transport, a new product
(`AngstromBluetooth`), and new `LaMarzoccoError` cases (`bluetoothConnectionFailed`,
`bluetoothAuthenticationFailed`, `bluetoothUnavailable`, `bluetoothTimedOut`,
`cloudOnlyFunctionality`) that break exhaustive `switch`es — nothing else is source-breaking, and
cloud-only behaviour is unchanged. The Bluetooth surface: `LaMarzoccoBluetoothClient` (lazy
authenticated connect, 30 s idle disconnect, typed reads, power/steam/temperature/smart-standby
commands, discovery, pairing-mode token read, the real-time shot counter with live telemetry and
a backoff reconnect loop, a verbatim raw-frame tap), `LaMarzoccoCloudClient.bluetoothAuthToken(serial:)`,
the `Dashboard` BLE transforms, and in `AngstromUI` BLE-first commands with cloud fallback,
`refreshDashboardFromBluetooth()`, the shot-counter overlay with a 60 s expiry,
`isBluetoothConnected`/`isShotCounterActive` and `bluetoothEvents()`, plus `angcli ble` (angcli
2.0.0). Every intentional divergence from upstream (D1–D22) and the hardware-unverified items are
recorded in `UPSTREAM.md` under "Bluetooth port (v2.0.0)".

v1.7.0 was full cloud parity with `pylamarzocco` v2.5.6: auth + token refresh,
typed dashboard/settings/scheduling reads, the command surface with two-tier websocket
confirmation, live updates, statistics, grinder support, and the optional `AngstromUI`
observable device layer, plus the `angcli` wire-debugging tool, a porting-watermark +
drift-detection workflow, and a DocC documentation site. v1.2 added websocket resilience
for connection gaps (sleep/network drops): enforced ping/pong liveness that self-heals
zombie sockets, `connectionEvents()` on the client, and automatic dashboard re-fetch on
reconnect + `isConnected`/`lastUpdateAt` in `AngstromUI`. v1.3 propagated the machine's
cloud-reachability (`connected`/`connectionDate`) through websocket pushes — when a
machine drops off the cloud the server serves a frozen "husk" dashboard, and the
`connected` flag is the authoritative offline signal — and added
`isMachineConnected`/`machineLastConnectionDate` to `AngstromUI` so UIs can gate the
otherwise-stale `powerState`. v1.4 replaces the incremental push merge with wholesale
widget replacement (upstream parity): wire captures showed every push is a full
snapshot and `removedWidgets` is a constant complement list, not a delta (see
UPSTREAM.md). v1.5 ports upstream v2.4.2: Strada X support (`CMMachineGroupStatus`,
auto/steam/rinse-flush widgets, group mode/dose/pressure commands, profile + brew-ratio
dosing, `AutoOnOff`/`EcoMode` scheduling) and the Swan grinder (`GSpeed`/`GMoreDose`/
`GGrindWith`, rev-based dosing, grinder wake/standby), with model gating and optimistic
updates in `AngstromUI`. v1.5.1 ports upstream v2.4.3: a push carrying no widgets is a
partial frame and keeps the last-known widget set (connectivity still applies — an
intentional divergence, since Angstrom stores `connected` on `Machine` where upstream
doesn't store it at all); upstream's new `CMMaintenanceStatus` code ships no payload
class, so it stays `.unknown(code:)` here until a real payload is captured (see
UPSTREAM.md). v1.6.0 ports upstream v2.5.2, which is mostly Bluetooth (shot counter,
telemetry): the cloud remainder is `MachineState`/`BoilerStatus.eco` (source-breaking for exhaustive switches),
`Machine.shotCounterSupported`, and — mirroring upstream's log masking — `angcli` now
redacts `bleAuthToken` (and the STOMP `CONNECT` bearer token) in `dump`/`listen` output.
v1.7.0 ports upstream v2.5.6: 403 handling (`USER_MUST_ACCEPT_POLICY` →
`LaMarzoccoError.policyAcceptanceRequired`, any other 403 → `.authenticationFailed`) plus
`acceptPrivacyPolicy`, `CommandStatus.failed`, and the extended grinder surface (index-free
payloads, a separate speed command, single-dose/mirror/auto-speed/auto-standby commands,
`GrinderStatus`, typed `speedAuto`, `GMirrorDoses`/`GHopperOpened`, the `AutoStandBy`
schedule union).
