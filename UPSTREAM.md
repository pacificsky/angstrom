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

<!-- upstream-version: v2.4.3 -->
<!-- upstream-sha: 1f43ae0 -->

| | |
|---|---|
| **Upstream** | https://github.com/zweckj/pylamarzocco |
| **Version** | `v2.4.3` |
| **Commit** | [`1f43ae0`](https://github.com/zweckj/pylamarzocco/commit/1f43ae0) |
| **Ported** | 2026-07-28 |
| **Scope** | Cloud protocol, auth/proof, models, websocket, commands, statistics. Includes Strada X + Swan grinder support (v2.4.x). Bluetooth is excluded by design and is **not** tracked here. |

As of this watermark the full cloud surface of `v2.4.3` is ported — there is no
known cloud gap below this line. (Bluetooth-only changes upstream are out of
scope and never advance this watermark.) Notes carried from earlier ports:
upstream's pending-command leak fix (pylamarzocco #155, v2.4.2) needed no port —
Angstrom's `executeCommand` already checked the websocket before registering
the pending wait.

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
git -C /tmp/pylamarzocco log --oneline 1f43ae0..v2.5.0                # replace with target tag
git -C /tmp/pylamarzocco diff 1f43ae0..v2.5.0 -- pylamarzocco/        # the review surface

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

> Verify the SHA matches the tag: `1f43ae0` should be the commit that
> `v2.4.3` points to (`git -C /tmp/pylamarzocco rev-parse v2.4.3`). Always record
> the **tagged release** commit, not an arbitrary `main` SHA, so the watermark
> corresponds to a real upstream version.
