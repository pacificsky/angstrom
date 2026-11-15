# Upstream porting watermark

Angstrom is an independent Swift port of the **cloud and Bluetooth** protocols and
authentication from [`pylamarzocco`](https://github.com/zweckj/pylamarzocco) by Josef Zweck.
The Python source is the reference of record — see [CLAUDE.md](CLAUDE.md). This
file records exactly how far that port has been carried, so we can tell what is
already ported from what still needs picking up.

## Ported through

<!-- The two markers below are parsed by .github/workflows/upstream-drift.yml.
     Keep the format `key: value` on a single line; update both in the same PR
     that lands the port. -->

<!-- upstream-version: v2.5.6 -->
<!-- upstream-sha: 4c639ee -->

| | |
|---|---|
| **Upstream** | https://github.com/zweckj/pylamarzocco |
| **Version** | `v2.5.6` |
| **Commit** | [`4c639ee`](https://github.com/zweckj/pylamarzocco/commit/4c639ee) |
| **Ported** | 2026-11-08 |
| **Scope** | Cloud **and** Bluetooth parity. Cloud: protocol, auth/proof, models, websocket, commands, statistics, including Strada X + Swan grinder support (v2.4.x). Bluetooth (Angstrom v2.0.0): `clients/_bluetooth.py`, `models/_bluetooth.py`, the BLE enums/exceptions, the cloud `bleAuthToken`, and the Bluetooth paths in `devices/` — see [Bluetooth port (v2.0.0)](#bluetooth-port-v200). |

As of this watermark the full cloud **and** Bluetooth surface of `v2.5.6` is
ported — the watermark now means "cloud and Bluetooth parity at `v2.5.6`", and
there is no known gap below this line other than the intentional divergences
(D1–D22) and the hardware-unverified items listed under
[Bluetooth port (v2.0.0)](#bluetooth-port-v200). Bluetooth changes upstream are
now in scope and advance this watermark like cloud changes do. (The Bluetooth
port was built against the same `4c639ee` commit, so the markers did not move.)
Notes carried from earlier ports:
upstream's pending-command leak fix (pylamarzocco #155, v2.4.2) needed no port —
Angstrom's `executeCommand` already checked the websocket before registering
the pending wait.

### v2.5.3 – v2.5.6 port notes

Twenty-two commits over `v2.5.2` (sixteen plus six merges), spanning v2.5.3,
v2.5.4, v2.5.5, and v2.5.6. Unlike the previous range, this one is mostly
cloud work:

- **403 handling** (`3e109ea`, v2.5.3; extended to auth calls by `d0a2d78`,
  v2.5.5) — ported. A 403 whose JSON body has `code: USER_MUST_ACCEPT_POLICY`
  throws the new `LaMarzoccoError.policyAcceptanceRequired`, and any other 403
  throws `.authenticationFailed` (upstream's `PolicyAcceptanceRequired` /
  `AuthFail`). It used to be `.requestFailed(status: 403, …)`. Angstrom's
  single `send()` already served `auth/init`, sign-in, refresh, and REST,
  which is the consolidation upstream reached in `d0a2d78`, so every call path
  is covered. A 403 is never retried. Angstrom's pre-existing
  retry-once-with-a-fresh-token divergence still applies only to a 401.
- **`accept_privacy_policy`** (`76d6bce`, v2.5.3) — ported as
  `acceptPrivacyPolicy(profilePolicy:commercialPolicy:)`:
  `PUT /users/policy` with `{"profilePolicy", "commercialPolicy"}`, both
  defaulting to `false`. Upstream also stopped JSON-decoding empty success
  bodies. Angstrom's `send()` returns raw `Data` and only endpoints that need
  a body decode it, so that needed no change. The policy call ignores its
  (possibly empty) body.
- **Grinder functionality** (`06717ca`, v2.5.4) — ported:
  - Every grinder payload drops `index`. `setGrinderBaristaLight(serial:on:)`
    keeps a deprecated `index:` overload that ignores it.
  - The dose speed level is its own command, `GrinderSettingSpeedForDose`
    (`setGrinderSpeed`). `setGrinderDose` no longer sends `speedLevel`; a
    deprecated overload taking `speedLevel:` sends the speed command, then the
    dose. In `AngstromUI`, `setGrinderDose(…speedLevel:)` does the same, and
    the speed half is Swan-gated (upstream `set_speed` is
    `@models_supported(SWAN)`).
  - New commands: single-dose mode, mirror doses, auto speed (enable per dose
    and the reference extraction; the reference sends explicit JSON `null`s,
    as upstream does), and grinder auto standby. All are in `AngstromUI` with
    upstream's optimistic updates. The auto-speed commands are Swan-gated, as
    upstream's are; single-dose, mirror, and auto-standby are ungated.
  - `AngstromUI.setSmartStandby` now throws `unsupportedModel` on a grinder,
    instead of sending the coffee-machine auto-standby command. Upstream
    defines `set_smart_standby` only on its machine class. This became
    reachable once grinders reported `autoStandBySupported`.
  - Models: `GrinderMachineStatus.status` is now a `GrinderStatus` (`Off` and
    `Drying` added) rather than a `GrinderMode`. `GSpeed.speedAuto` is a typed
    `GrinderSpeedAuto` (it was a `String?` that couldn't decode the wire
    object). New `GMirrorDoses` and `GHopperOpened` widgets. Scheduling's
    `autoStandBy` is now an `AutoStandBy` union (a mode string on machines, an
    `AutoStandBySettings` object on grinders), like `AutoOnOff`.
  - Upstream moved `schedule`/`get_schedule` from its machine class to the
    base thing. That needs no port: `LaMarzoccoMachine` already serves every
    device type.
- **`CommandStatus.FAILED`** (`ca13462`, v2.5.5) — ported as `.failed`.
  Upstream's strict enum failed the whole websocket message on `"Failed"`,
  dropping the push and leaving the command to time out (pylamarzocco #170).
  Angstrom's enum already degraded unknown values to `.other`, so it never had
  that bug. The new case is for parity, and a websocket test pins that a
  `Failed` confirmation rejects promptly.
- **Refactors with no behaviour change** — no port: the `ef0e947` cleanup
  (`_widget()`, the `_ModeStatus` base, whose field set is identical, shared
  widget filtering, `STEAM_LEVEL_MODELS`), the rest of `d0a2d78` (one request
  helper, pending-command cleanup in `finally`, `MachineMode.from_power`, a
  shared target-temperature setter), and `5be847f` (unreachable aiohttp
  websocket error branches).
- **`e0f0249` model-name aliases** (v2.5.6) — no port. Upstream adds
  `"GS3"` → GS3 AV and `"LINEA"` → Linea Mini to `ModelName.from_string`. The
  aliases target Bluetooth `machineCapabilities` family names, but that
  function also deserializes cloud `modelName`. Angstrom resolves `modelCode`
  first and only falls back to the name. Before v2.5.6, upstream *rejected*
  these names (a `ValueError`), so the cloud evidently doesn't send them.
  Angstrom's `"GS3"` → `.gs3` stays. **Update (v2.0.0):** the Bluetooth port
  needs upstream's mapping, so the BLE aliases now live in
  `Model(bluetoothFamily:)` (`"GS3"` → `.gs3AV`, `"LINEA"` → `.lineaMini`), used
  only for the BLE `machineCapabilities` family; the cloud parser `Model.match`
  still maps `"GS3"` → `.gs3` (divergence D8 below).
- **Tooling** — no action: test-suite rewrites, version bumps.

**Source-breaking for consumers (shipped as v1.7.0, following the 1.5.0/1.6.0
precedent):**
- `GrinderMachineStatus.status` is now `GrinderStatus`, not `GrinderMode`.
- `GrinderSpeed.speedAuto` is now `GrinderSpeedAuto?`, not `String?`.
- `MachineSchedule.autoStandBy` is now `AutoStandBy?`, not `String?`. Use
  `.modeString`.
- New enum cases break exhaustive `switch`es:
  `LaMarzoccoError.policyAcceptanceRequired`, `CommandStatus.failed`,
  `WidgetKind.grinderMirrorDoses` / `.grinderHopperOpened`. Code matching
  `CommandStatus.other("Failed")` no longer matches.
- A 403 now throws `.authenticationFailed` / `.policyAcceptanceRequired`
  instead of `.requestFailed(status: 403, …)`.

The two removed upstream parameters (barista light `index:`, dose
`speedLevel:`) keep deprecated overloads, so those call sites still compile.

### v2.4.4 – v2.5.2 port notes

Sixteen commits over `v2.4.3` (ten plus six merges), spanning v2.4.4, v2.5.0,
v2.5.1, and v2.5.2. The bulk is Bluetooth (shot counter, live
telemetry, connection callbacks, `BluetoothAuthenticationFailed`) — out of
scope — plus a Python 3.12 drop, a test-harness migration, and a **move to a
`src/` layout** (`pylamarzocco/` → `src/pylamarzocco/`; the runbook below now
diffs that path). The cloud-relevant remainder:

- **`MachineState.ECO_MODE` / `BoilerStatus.ECO_MODE`** (`"EcoMode"`, v2.5.0)
  — ported as `MachineState.eco` / `BoilerStatus.eco` (spelled like the
  existing `MachineMode.eco`). Upstream added them only as targets of its
  Bluetooth→widget maps (`BLE_MACHINE_STATE` / `BLE_BOILER_STATUS`); there's no
  evidence yet that the cloud itself sends `"EcoMode"` for these fields. They're
  ported for enum parity, and Angstrom previously decoded the value as
  `.other("EcoMode")`. **Source-breaking** for exhaustive `switch`es over
  either enum.
- **`Thing.shotCounterSupported`** (v2.5.0) — ported as
  `Machine.shotCounterSupported`. Upstream coerces with `bool(v)`; Angstrom
  accepts a Bool or a number (`0` → `false`) and treats missing/`null`/anything
  else as `false`. Already present in the real `dashboard_micra_offline` capture.
- **`_mask_bluetooth_token`** (`83289c6`, v2.5.2) — upstream masks
  `bleAuthToken` (top-level and nested, any truthy value) in its debug response
  logs. Angstrom's
  library never logs and doesn't model the token, but `angcli dump` and
  `angcli listen` printed it verbatim to stdout; both now mask it at the
  display boundary (`Redact` in `cli/Sources/angcli/Output.swift`, non-empty
  strings only — upstream types the field `str | None`). The library's
  `rawRead`/`rawFrames` stay verbatim, as upstream's client still returns the
  token. The same review found raw `listen` also printed the STOMP `CONNECT`
  frame's `Authorization: Bearer` access token (a pre-existing angcli leak, not
  an upstream change); `Redact` masks that too.
- **`_dashboard_config_updated` hook / "override widget status" (`6520af7`)**
  — no port: both exist only to overlay Bluetooth shot-counter state onto the
  cloud `CMMachineStatus` widget.
- **Websocket error logging** (`msg.data` instead of `ws.exception()`,
  dropping the unused `ws` parameter) — no port: an aiohttp logging detail
  with no wire effect; Angstrom's `URLSessionWebSocketTask` error path is
  unrelated.
- **Websocket connect tests** (`a763fa2`, `tests/test_websocket_connect.py`) —
  no code change upstream, but they pin a policy Angstrom deliberately differs
  on: upstream's loop *ends* on a rejected handshake, a non-`CONNECTED` reply,
  or a callback error, whereas Angstrom's `maintainConnection` surfaces only
  the *first* connect's failure and otherwise retries every drop forever with
  capped backoff (the v1.2 self-healing design for sleep/network gaps).

> **Superseded (v2.0.0):** the "out of scope" / "no port" calls above for the
> Bluetooth work in this range (shot counter, live telemetry, connection
> callbacks, `BluetoothAuthenticationFailed`, the `_dashboard_config_updated`
> overlay hook) are historical. All of it is now ported; see
> [Bluetooth port (v2.0.0)](#bluetooth-port-v200) for how, and for every
> intentional divergence.

### v2.4.3 port notes

`v2.4.3` is three commits over `v2.4.2`, eight changed lines:

- **`ee6dfc7` "Guard partial WS updates"** — ported. Upstream's
  `_websocket_dashboard_update_received` now gates its wholesale assignment on
  `if config.widgets:`, so a push carrying no widgets no longer empties the
  dashboard. `Dashboard.applying(_:)` does the same, and this also covers the
  case where the `widgets` array fails to decode (`DashboardUpdate.init(from:)`
  degrades that to an empty list). **Intentional divergence:** upstream's guard
  covers `dashboard.config` too and skips the frame entirely, which it can
  afford because it never stores `connected` on the dashboard — the whole
  `ThingDashboardWebsocketConfig` reaches its update callback regardless, so
  Home Assistant still sees connectivity on a partial frame. Angstrom folds
  connectivity into `Machine` (see v1.3 below), so the guard covers **only**
  the widget replacement; `isConnected`/`connectionDate` are applied on every
  frame. Skipping them would drop the authoritative offline signal exactly when
  a frame arrives partial.
- **`1f43ae0` "Add CMMaintenanceStatus widget"** — no code port; see below.
- **`7d2bddf` "Clarify unofficial status … README"** — no action; Angstrom's
  README already carries an equivalent "Unofficial" disclaimer.

### `CMMaintenanceStatus` — known code, unknown payload

Upstream v2.4.3 added `CM_MAINTENANCE_STATUS = "CMMaintenanceStatus"` to its
`WidgetType` enum **and nothing else** — there is no `BaseWidgetOutput`
subclass, no fixture, and no test for it anywhere in the v2.4.3 tree (the
string appears exactly once, in `const.py`). Upstream cannot decode the payload
either; it only stops discarding the widget.

Angstrom needs no change to stay safe: an unrecognized code decodes to
`WidgetKind.unknown(code:)` rather than failing the dashboard, and shows up in
`Dashboard.unknownWidgetCodes`. Typing it would mean inventing a shape.

To type it once a machine reports one, capture the payload first — `.unknown`
keeps the code and index but drops the raw `output`, so read it off the wire:

```bash
swift run angcli listen     # raw STOMP frames, both directions, verbatim JSON
```

Then add the payload struct in `Widgets.swift`, a case to `WidgetKind`, a
branch in `Widget.decodeKind`, an accessor on `Dashboard`, and a fixture-backed
test — the same shape as every other widget.

### Websocket push semantics (wire findings)

`Dashboard.applying(_:)` replaces the widget set wholesale on every push that
carries widgets — parity with pylamarzocco's
`_websocket_dashboard_update_received` (`if config.widgets: dashboard.widgets =
config.widgets`), with `connected`/`connectionDate` flowing onto `Machine`
(upstream gets that implicitly by replacing the whole config). A push with an
empty widget list is a partial frame and leaves the widget set alone (see the
v2.4.3 port notes above). An earlier incremental merge keyed on `(code, index)`
that honored `removedWidgets` was removed after wire captures (122 pushes, see
`cli/README.md`) disproved its premises:

- **Every push is a full snapshot** — each frame carries the machine's
  complete live widget set.
- **`removedWidgets` is not a delta** — it is the constant complement list of
  widget codes the machine *doesn't* have (GS3-only widgets on a Micra,
  grinder `G*` codes, …), never an incremental removal instruction. Both
  libraries ignore it for state; Angstrom keeps decoding it for diagnostics.

The `connected` flag is the authoritative offline signal — when a machine
drops off the cloud the server serves a "husk" dashboard (`connected: false`,
widgets reduced to a frozen `CMMachineStatus`), and pylamarzocco/Home
Assistant derive entity availability from it. **Open question (unverified):**
whether the server pushes a frame at the moment a machine disconnects, or the
topic just goes silent — routine pushes all carry `connected: true` and no
disconnect push has been observed in wire captures. To settle it:
`swift run angcli listen` while flipping the machine's power switch, then
record the finding here and in `cli/README.md`.

## Bluetooth port (v2.0.0)

Angstrom v2.0.0 ports upstream's Bluetooth surface at the same watermark
(`v2.5.6`, `4c639ee`): `LaMarzoccoBluetoothClient` (`clients/_bluetooth.py`), its
models (`models/_bluetooth.py`), the BLE enums and exceptions, the cloud
`bleAuthToken` field, and the Bluetooth paths of the device layer
(`devices/_thing.py`, `devices/_machine.py`). Every upstream behaviour either
has a byte-for-byte / state-for-state Swift counterpart or is one of the
intentional divergences below. The full design is
[`docs/bluetooth/SPEC.md`](docs/bluetooth/SPEC.md) (§12 is the normative source
of this list, §14.2 of the UNVERIFIED list). Line citations use that spec's
abbreviations: `BT` = `src/pylamarzocco/clients/_bluetooth.py`, `MBT` =
`src/pylamarzocco/models/_bluetooth.py`, `MACH` = `src/pylamarzocco/devices/_machine.py`,
`TBC` = `tests/test_bluetooth_client.py`, `README` = upstream `README.md`,
`B-SC`/`B-PD` = bleak 1.1.1's CoreBluetooth backend; IDs such as `BT-COERCE` or
`G-DEV-4` name spec test vectors and gap tests.

Layout: all protocol logic is in the CoreBluetooth-free `Angstrom` target
(`Sources/Angstrom/Bluetooth/`) behind a `package` transport seam; the new
`AngstromBluetooth` product is the only code that imports CoreBluetooth;
`AngstromUI` gains an optional `LaMarzoccoBluetoothClient`. Shipped as a
**major** release (an owner decision — not the 1.5.0/1.6.0/1.7.0 minor-bump
precedent): the new `LaMarzoccoError` cases (`bluetoothConnectionFailed`,
`bluetoothAuthenticationFailed`, `bluetoothUnavailable`, `bluetoothTimedOut`,
`cloudOnlyFunctionality`) break exhaustive `switch`es; nothing else is
source-breaking, and cloud-only behaviour is unchanged.

Not ported (no Apple equivalent or made unnecessary): `BleakClientWithServiceCache`
/ `clear_cache()` (its intent — rediscovery — is ported, D7), `ble_device_callback`
(D3), `_safe_call` and the `eager_start` re-entrancy semantics (D4: streams, not
callbacks), the legacy gen-1 GATT layout, bleak `pair()`, and the synthesized
`ThingDashboardWebsocketConfig` for listeners (D13).

### Intentional divergences (D1–D22)

- **D1 — Transport.** The transport is CoreBluetooth instead of bleak +
  bleak-retry-connector. Connect retry approximates `establish_connection`
  (3 attempts, 20 s each, 0.25/0.1 s backoff) without its transient-error
  counter (`MAX_TRANSIENT_ERRORS = 9`) or its 4 s not-found backoff.
  *Rationale:* platform. The visible semantics (3 attempts, a typed final error)
  are kept.
- **D2 — The token is not a `Machine` field.** `bleAuthToken` is read by
  `LaMarzoccoCloudClient.bluetoothAuthToken(serial:)` and wrapped in the opaque,
  redacting, non-`Codable` `BluetoothAuthToken`. *Rationale:* a field would land
  in every persisted `MachineSnapshot` and in CLI-encoded output, and would break
  `Machine` round-trip equality for fixtures carrying the placeholder. The house
  rule says tokens are never persisted or logged.
- **D3 — Peripheral identity.** Identity is the `CBPeer.identifier` UUID
  (`BluetoothPeripheralID`), not a MAC. `ble_device_callback` is not ported; the
  adapter re-resolves by identifier on every connect. Discovery also accepts the
  advertised local name when `CBPeripheral.name` is nil, and returns first-seen
  order. *Rationale:* Apple exposes no MAC. bleak on macOS already reports the
  UUID as `address` (`B-SC:160`).
- **D4 — Streams, not callbacks.** `AsyncStream`s replace callbacks
  (`connectionEvents`, `shotCounterEvents`, `bluetoothEvents`). A second
  `startShotCounter` cannot "replace the callbacks". Re-entrant-stop recursion
  cannot happen. `_safe_call` is unnecessary. *Rationale:* house pattern
  (`dashboardUpdates()`/`connectionEvents()`); Swift concurrency.
- **D5 — Coercion differences from mashumaro 3.17** (SPEC §3.10; all executed against
  `4c639ee`; vectors BT-COERCE / BT-NTF-COERCE):
  - (a) String booleans use `_parse_bool` (`"false"` → false; upstream
    `bool("false")` is `True`), so `{"BrewingUpdateGroup1Ev":"false",…}` stops a
    shot instead of continuing it.
  - (b) Unknown boiler ids and `machineModes` entries become `.other` instead of
    failing the read.
  - (c) An array/object in a string field becomes its compact JSON text instead
    of Python `repr` (`["a"]` vs `"['a']"`): only the text differs, because no
    logic compares these strings except `status` against `"success"`, which
    neither form can equal.
  - (d) An int outside `Int` range, or from a non-finite value, is an error
    (`.decoding` in a read, drop in a notification) where Python's `int` is
    unbounded.
  - (e) A non-finite double (string `"nan"`/`"inf"`; the bare literals
    `NaN`/`Infinity` and out-of-range literals such as `1e400`, which
    `JSONSerialization` rejects outright) drops the notification or fails the
    read, where upstream emits `nan`/`inf` telemetry, or for a brewing time
    raises `ValueError` from `derive_state` after merging `nan` into the tracker.
  - (f) Numeric strings with `_` digit separators (`"1_0"`) are an error, where
    Python's `float()`/`int()` accept them.
  - (g) A number literal with more significant digits than a double holds, or an
    integer literal outside the 64-bit range, arrives from `JSONSerialization` as
    an `NSDecimalNumber` and is handled from its **exact decimal value**: the int
    rule truncates it exactly (`3.9999999999999999999999` → 3, where Python's
    `int(float(…))` gives 4; `9223372036854775807.0` → `Int.max`, where Python
    gives 2⁶³), and the string rule renders any integral one as bare digits
    (`5.00000000000000000000` → `"5"`, where Python gives `"5.0"`;
    `100000000000000000000.0` → `"100000000000000000000"`, where Python gives
    `"1e+20"`), because the parsed number no longer records whether the literal
    had a fraction.
  - (h) Numeric strings written with non-ASCII Unicode digits (`"١"`, full-width
    `"３.5"`) are an error, where Python accepts them.
  - (i) A JSON object with a duplicate key keeps the **first** value
    (`JSONSerialization`), where Python keeps the last.
  - (j) A lone surrogate escape (`"\ud800"`) makes the whole payload
    unparseable, where Python's `json.loads` accepts it.
  - (k) A list-typed field (`boilers`, `machineModes`) must be a JSON array: an
    object or a string there is `.decoding`, where upstream iterates whatever it
    gets (`{}` and `""` become an empty list, a dict yields its keys).

  *Rationale:* (a) latent upstream bug; (b) tolerant-parsing convention;
  (c)–(f) Swift has no unbounded int, no Python `repr`, and `JSONSerialization`
  has no NaN literals; failing a value is safer than trapping or emitting NaN.
  None of these inputs has been observed on the wire.
- **D6 — Integral temperatures.** Integral temperatures are encoded without a
  fraction (`93`), where Python sends `93.0` for a float. *Rationale:* Swift has
  one numeric type here. Every upstream test vector passes ints, so all pinned
  bytes match. Firmware tolerance is UNVERIFIED (U7).
- **D7 — Request robustness:**
  - (a) A link drop between a request's write and read fails the request
    instead of silently reconnecting and reading a stale value.
  - (b) A missing characteristic triggers one real rediscovery on the live link
    before dropping (upstream's `clear_cache` is a no-op on macOS).
  - (c) `didModifyServices` forces rediscovery.
  - (d) Cancellation inside a request is drop-class.
  - (e) `ensureConnected` trusts the stored `link` (SPEC §4.1 invariant I1): a request that starts after
    the peripheral dropped but before the actor processed `.disconnected` fails
    with `.bluetoothConnectionFailed` (drop-class; the device layer falls back to
    the cloud) instead of reconnecting, which upstream does because it checks
    bleak's live `is_connected` (`BT:183-186,236`). The next request reconnects.

  *Rationale:* correctness on Apple. Upstream's behaviour in (a)–(d) is either a
  no-op or a misread response. (e) keeps link state single-sourced in the actor;
  the window is one event hop and the outcome is a clean, retryable failure.
- **D8 — BLE model aliases.** `Model(bluetoothFamily:)` implements the
  `e0f0249` aliases (`"GS3"` → GS3 AV, `"LINEA"` → Linea Mini). The cloud parser
  `Model.match` keeps `"GS3"` → `.gs3`. *Rationale:* already-documented cloud
  divergence (the `e0f0249` note above). BLE needs upstream's mapping.
- **D9 — Boiler temperatures are `Double`.** `BluetoothBoilerDetails.target/current`
  are `Double` (upstream `int`, truncating). Identical for integral wire values.
  For others the derived steam level changes (`MACH:78-84,436-438`): `130.5` →
  upstream `int` 130 → `.level2`, Angstrom `.level3` (G-DEV-4, BT-DASH-STEAMLVL);
  `0.5` → upstream 0 → `.level3`, Angstrom `.level1`. A string target that
  `float()` can parse but `int()` cannot (`"127.5"`, `"1e2"`) fails the upstream
  read (`int("127.5")` raises, BT-COERCE-007); Angstrom accepts it (`127.5`,
  `100.0`). *Rationale:* tolerant parsing, and no loss for fractional targets.
- **D10 — Error taxonomy.** Swift enum cases (`.bluetoothConnectionFailed`,
  `.bluetoothAuthenticationFailed`, `.bluetoothUnavailable`, `.bluetoothTimedOut`,
  `.cloudOnlyFunctionality`) with `isBluetoothConnectionFailure` standing in for
  the subclass relation. Unavailable states fail fast instead of burning connect
  attempts. *Rationale:* no subclassing in Swift enums. The convention is that
  every error is a `LaMarzoccoError`. Fallback behaviour is unchanged
  (unavailable ⇒ fall back, like `BleakError`).
- **D11 — "Connected" means authenticated.** `isConnected` (client) and
  `isBluetoothConnected` (machine) mean an **authenticated** link. Upstream's
  `is_connected` is briefly true before auth. *Rationale:* observable state
  should not report a link that can't serve requests.
- **D12 — Overlay as base + render.** The overlay is base + render on value
  types, replacing Python object identity (`is widget`). Removing the opposite
  steam widget removes it from the `widgets` list (upstream pops only `config`,
  leaving `widgets` stale). *Rationale:* Angstrom widgets are immutable values in
  a list. The vectors prove equivalence (SPEC §9.3.8).
- **D13 — No synthesized websocket config.** No synthesized
  `ThingDashboardWebsocketConfig` is sent to the websocket update callback when
  there is no shot-counter or telemetry callback. Consumers observe `dashboard`
  (`@Observable`) or `bluetoothEvents()`. *Rationale:* AngstromUI has no update
  callback. Observation covers it.
- **D14 — Reconnect on power-on.** The reconnect backoff ends early (and resets)
  when Bluetooth returns to `.poweredOn` (wake, toggle). *Rationale:* otherwise
  the shot counter can stay dark for up to 60 s after a Mac wakes.
- **D15 — Reconnect give-up is observable; auth failures are cumulative.** The
  reconnect loop emits a terminal `ShotCounterEvent.gaveUp(error)` (and
  `MachineBluetoothEvent.shotCounterStopped`). Errors other than auth failure and
  cancellation take the connection-error branch, where upstream lets non-Bleak
  exceptions kill the task. Auth failures are counted **cumulatively** per loop
  run, matching the code (`BT:491,497`), not the README's "in a row"
  (`README:269`). *Rationale:* observable state must learn of the give-up.
  Robustness. The code is the reference of record.
- **D16 — Link loss cancels the idle timer.** A link loss cancels the idle timer
  task. *Rationale:* upstream lets it fire against a dead link, which is harmless
  but noisy (G-CONN-7).
- **D17 — No silent Linea Micra default.** `refreshDashboardFromBluetooth()`
  reads capabilities first when the model is unknown. Model-gated commands throw
  `.unsupportedModel` until the model is known. *Rationale:* sending
  Micra-specific commands (steam levels) to an unidentified machine is unsafe.
- **D18 — BLE-first commands return `CommandResponse`.** A BLE success
  synthesizes `CommandResponse(id: status.id, status: .success, errorCode: nil)`.
  With no cloud client, a BLE connection failure **rethrows** and a non-success
  status throws `.commandFailed(status:errorCode: message)`, where upstream
  returns `False`. With neither client: `.cloudOnlyFunctionality`.
  *Rationale:* Angstrom commands signal failure by throwing (existing API).
- **D19 — Bounded timeouts.** Every GATT operation has a bounded timeout (20 s).
  Bluetooth waits up to 10 s for `.poweredOn`. Disconnect is bounded at 5 s.
  Request-phase timeouts are `.bluetoothTimedOut` (drop-class, **no** cloud
  fallback, parity with a bare `TimeoutError`). *Rationale:* bleak has no timeout
  on writes, notify or discovery. CoreBluetooth gives no guarantee that a lost
  reply ever errors.
- **D20 — `readToken` diagnostics.** `readToken` maps ATT permission errors to a
  "pairing mode?" message and always disconnects. Upstream surfaces the raw
  `BleakError`. *Rationale:* diagnosability. The semantics are otherwise
  identical (one attempt, no auth, no NUL strip).
- **D21 — Finite temperatures only.** `setTemperature` rejects NaN/±∞ with
  `.operationNotAvailable("temperature must be finite")` before any I/O.
  Upstream `json.dumps` (default `allow_nan=True`, `BT:707`) writes
  `NaN`/`Infinity` to the machine. *Rationale:* never send a value the firmware
  cannot parse.
- **D22 — Auto-standby without a cloud client.** `setSmartStandby` on an
  auto-standby machine (`schedule.autoStandBySupported == true`) without a cloud
  client throws `.cloudOnlyFunctionality`. Upstream fails
  `assert self._cloud_client` (`MACH:875`) with an `AssertionError` (or, under
  `python -O`, an `AttributeError`). *Rationale:* every error is a
  `LaMarzoccoError`. Same outcome: the command is not sent.

### UNVERIFIED items (need hardware or upstream input)

Each has a default the implementation uses now; changing one later is a
follow-up, not a blocker. `H…` IDs are the hardware checklist in SPEC §9.6
(run via `angcli ble …`); `X…` IDs are the maintainer checks in
[`docs/bluetooth/PLAN.md`](docs/bluetooth/PLAN.md) §6.1.

| ID | Item | Default until settled | Settle with |
|---|---|---|---|
| U1 | GATT service UUID hosting `0a0b…`–`0e0b…`; property flags | `discoverServices(nil)` and match by characteristic | H1 |
| U2 | Encryption or bonding requirements (OS pairing prompt) | none assumed | H1, H16 |
| U3 | Advertised name format; MINI vs LINEA prefix per model; whether `0x2A25` gives the serial | user picks from the scan | H10 |
| U4 | Token format, length, meaning of `null` | opaque string; null → nil | a real `/things` (length only) |
| U5 | `0c0b` behaviour outside pairing mode | ATT errors → "pairing mode?" message | H17 |
| U6 | Response ready immediately after the write ack; max response size | single read (parity) | H27 |
| U7 | Firmware accepts `93` vs `93.0` | integral → `93` (D6) | H23 |
| U8 | Failure status strings and casing | case-insensitive `"success"` | H24 |
| U9 | Reply to an unknown read setting | `.decoding`; plumb-in → false | H25 |
| U10 | mashumaro 3.17 coercion edge cases | **Settled** (executed against `4c639ee`): SPEC §3.10 and the BT-COERCE / BT-NTF-COERCE vectors record the results; D5 lists the differences | re-check with X3 (PLAN §6.1) if `uv.lock` moves past mashumaro 3.17 |
| U11 | Whether the `TBC`/`CONF` example payloads are real captures | treated as normative vectors | X6 (PLAN §6.1): ask the upstream author |
| U12 | Single central per machine | assumed true | H8 |
| U13 | `family` strings of the GS3 MP / Mini R / original GS3 | the full `from_string` table | H22 |
| U14 | Apple-negotiated MTU ≥ 421 for the 418-byte telemetry frame | parse-or-drop (parity) | H2, H14 (iOS: only if an iOS app is available, SPEC §9.6) |
| U15 | Replay always sent on subscribe | always drop the first (parity) | H13 |
| U16 | TCC attribution for angcli; grant persistence across rebuilds; missing-usage-string behaviour | plist embedded anyway | H5–H7 |
| U17 | Whether the 10 s `poweredOnWait` covers the first-run prompt | 10 s | H3 |
| U18 | `CBPeer.identifier` scope across apps and resets | rescan on unknown peripheral | H9 |
| U19 | App Store flagging of CB symbols without a usage string (justifies the leaf product) | leaf product | TestFlight upload |
| U20 | Build with the Swift **6.0** compiler (the tools floor); only 6.4.2 was available to research | use only 5.9/6.0-era features (`package`, `withTaskCancellationHandler`, `AsyncStream.makeStream`, `OSAllocatedUnfairLock`) | CI's selected Xcode |
| U21 | Upstream's 123 BLE test cases pass at `4c639ee` (not re-run in research) | assumed | `uv run --frozen --extra dev pytest tests/test_bluetooth_client.py tests/test_bluetooth_dashboard.py tests/test_machine.py` |
| U22 | Per-line `brewingStartTime` golden values (hand-traced and simulated, not run against upstream) | SPEC §9.3.4 golden with ≤ 1 ms tolerance; assertions 1–6 are authoritative | run upstream's recorded-session test with prints |

## Syncing to a newer upstream

When `pylamarzocco` publishes changes past the watermark above (the drift-check
workflow opens a tracking issue when it does), follow this runbook:

```bash
# 1. Get upstream locally (clone once, or `git fetch` an existing checkout).
git clone https://github.com/zweckj/pylamarzocco /tmp/pylamarzocco   # first time
git -C /tmp/pylamarzocco fetch --tags origin                          # thereafter

# 2. See what landed since the watermark.
git -C /tmp/pylamarzocco log --oneline 4c639ee..v2.6.0                # replace with target tag
git -C /tmp/pylamarzocco diff 4c639ee..v2.6.0 -- src/pylamarzocco/    # the review surface (src/ layout since v2.5.2)
# The Bluetooth part of that surface, on its own (all of devices/ — the BT paths live in
# _thing.py and _machine.py alongside the cloud ones):
git -C /tmp/pylamarzocco diff 4c639ee..v2.6.0 -- src/pylamarzocco/clients/_bluetooth.py \
    src/pylamarzocco/models/_bluetooth.py src/pylamarzocco/devices/

# 3. Triage each change:
#    - cloud / auth / proof / models / websocket / commands / stats  -> port to Swift
#    - bluetooth (clients/_bluetooth.py, models/_bluetooth.py,
#      BT paths in devices/)                                          -> port to Swift
#      (record any new intentional divergence next to D1–D22 in the
#      "Bluetooth port (v2.0.0)" section above)
```

Then, **in the same PR that lands the port**:

1. Port the relevant changes, matching the Python wire-shape/decoding exactly.
2. Bump **both** `upstream-version` and `upstream-sha` markers above, and the
   table (Version / Commit / Ported / Scope notes), to the new target.
3. `swift build && swift test` must pass.
4. Close the drift tracking issue (or let the next bump's PR reference it).

> Verify the SHA matches the tag: `4c639ee` should be the commit that
> `v2.5.6` points to (`git -C /tmp/pylamarzocco rev-parse v2.5.6`). Always record
> the **tagged release** commit, not an arbitrary `main` SHA, so the watermark
> corresponds to a real upstream version.
