# Websocket push: wholesale widget replacement (upstream parity)

**Date:** 2026-07-08 · **Status:** approved · **Release:** v1.4.0 (semver minor)

## Problem

`Dashboard.applying(_:)` merges pushes incrementally: widgets are replaced by
`(code, index)`, `removedWidgets` entries are dropped, unmentioned widgets
survive. This was designed as a defensive improvement over pylamarzocco's
wholesale replacement, on the premise that pushes might be partial deltas and
that `removedWidgets` is a removal instruction.

Wire captures (122 pushes, `cli/debug.log`) disprove both premises:

1. **Every push is a full snapshot** — all 122 frames carry the machine's
   complete live widget set, identical every time.
2. **`removedWidgets` is not a delta** — every frame carries the same constant
   23 entries: the complement list of every widget code the machine *doesn't*
   have (GS3 widgets, grinder `G*` widgets, …). It never signals "this widget
   just went away".
3. pylamarzocco (`_websocket_dashboard_update_received`, v2.3.0) replaces
   `dashboard.widgets = config.widgets` unconditionally on **every** MESSAGE
   frame, including command-ack frames, and runs at Home Assistant scale
   without blank-dashboard reports — so even command frames carry the full set.

The merge therefore defends against a frame shape that doesn't exist while
letting push-merged state drift from REST state (e.g. the offline "husk":
REST collapses widgets to a lone frozen `CMMachineStatus`, the merge keeps
stale boiler widgets alive).

## Decision

**Strict replacement — bug-for-bug parity with pylamarzocco.** (Chosen over
"replacement with an empty-widgets guard" and "keep the merge".)

`Dashboard.applying(_:)` becomes:

1. Apply `update.connected` to `machine.isConnected`; apply
   `update.connectionDate` when present (v1.3 behavior — upstream gets this
   implicitly by replacing the whole config).
2. `widgets = update.widgets`, wholesale. No keying, no ordering, no
   `removedWidgets` handling.

`removedWidgets` stays decoded on `DashboardUpdate` (wire-shape parity +
angcli diagnostics); it just stops driving the merge. If the server ever sends
a zero-widget frame the dashboard empties until the next push or refresh —
identical to upstream, accepted knowingly.

## Test changes

- `testDashboardApplyingMerge` → `testDashboardApplyingReplacesWidgets`:
  micra base + single-widget push → the dashboard's widget set is exactly the
  push's set; a `removedWidgets` entry naming a pushed widget is ignored.
- `testDashboardApplyingPropagatesConnected` and the AngstromUI
  `testIsMachineConnectedTracksCloudReachability` currently push `widgets: []`
  and assert widgets survive — old semantics. Rewritten so the offline push
  carries the frozen `CMMachineStatus` husk widget (realistic per the captured
  husk), asserting widgets collapse to the husk and `powerState` still derives
  from it.

## Doc changes

- `applying(_:)` doc comment: now matches upstream; note the `removedWidgets`
  finding.
- UPSTREAM.md: the "Intentional divergences" merge entry is replaced by the
  capture-derived findings (full-snapshot pushes; `removedWidgets` = constant
  complement list). The open disconnect-push question stays.
- cli/README.md findings: add the `removedWidgets` discovery.
- CLAUDE.md: "merge" wording → replacement; status → v1.4.

## Release

v1.4.0: PR → CI → squash-merge → lightweight tag → GitHub release. Pronto
needs only a Package.resolved bump.
