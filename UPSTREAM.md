# Upstream porting watermark

Angstrom is an independent Swift port of the **cloud** protocol and authentication
from [`pylamarzocco`](https://github.com/zweckj/pylamarzocco) by Josef Zweck.
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
| **Scope** | Cloud protocol, auth/proof, models, websocket, commands, statistics. Includes Strada X + Swan grinder support (v2.4.x). Bluetooth is excluded by design and is **not** tracked here. |

As of this watermark the full cloud surface of `v2.5.6` is ported — there is no
known cloud gap below this line. (Bluetooth-only changes upstream are out of
scope and never advance this watermark.) Notes carried from earlier ports:
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
  is covered. **Divergence (pre-existing policy):** like a 401, a non-policy
  403 on an authenticated request is retried once with a fresh token.
  Upstream never retries. A policy 403 is never retried.
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
    upstream's optimistic updates and Swan gating.
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
- **Bluetooth / tooling** — no action: `e0f0249` (BLE `machineCapabilities`
  family names `LINEA`/`GS3`), test-suite rewrites, version bumps.

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

# 3. Triage each change:
#    - cloud / auth / proof / models / websocket / commands / stats  -> port to Swift
#    - Bluetooth-only                                                 -> skip (out of scope)
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
