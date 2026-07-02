# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Angstrom is a Swift Package Manager library (macOS 14+ / iOS 17+, Swift 6 with strict
concurrency) for the **La Marzocco** customer-app cloud API. It is an independent Swift
port of the cloud protocol and authentication from
[`pylamarzocco`](https://github.com/zweckj/pylamarzocco) (Josef Zweck). When changing
auth, proof, or any wire-shape/decoding logic, the Python source is the reference of
record — match it. (Bluetooth is explicitly out of scope; cloud only.)

**Porting watermark:** [`UPSTREAM.md`](UPSTREAM.md) records the exact `pylamarzocco`
version + commit the port has been carried to. When porting newer upstream changes,
follow its "Syncing to a newer upstream" runbook and **bump the watermark markers in
the same PR**. A weekly CI job (`.github/workflows/upstream-drift.yml`) opens a
tracking issue when upstream moves past the watermark.

Two products: **`Angstrom`** — the stateless `actor` core (transport/protocol/typed
reads/commands/websocket), usable standalone by CLI/server consumers — and **`AngstromUI`**
— an optional `@MainActor @Observable` device layer on top for SwiftUI.

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
  `DashboardUpdate`, and `Dashboard.applying(_:)` merge.
- **`Optimistic.swift`** — pure `Dashboard.replacing(_:)` + `setting…(_:)` transforms used by
  the device layer for optimistic updates.
- **`Diagnostics.swift`** — opt-in debug surface for wire-tracing: `RawFrame` +
  `rawFrames() -> AsyncStream<RawFrame>` (multiplexed like `dashboardUpdates()`, taps both
  directions — inbound before `Stomp.decode`, outbound at `channel.send`, plus heartbeat
  pings), and `RawEndpoint` + `rawRead(_:serial:) -> Data` for verbatim REST JSON. Zero cost
  when no `rawFrames()` listener is open. Consumed by the `cli/` tool below.

### `Sources/AngstromUI/` — the observable device layer

- **`LaMarzoccoMachine.swift`** — `@MainActor @Observable`. Retains `dashboard`/`settings`/
  `schedule`/`statistics`, refreshes-and-stores, iterates the websocket `AsyncStream` (merging
  into `dashboard`), re-fetches the dashboard after every reconnect (change-only feed —
  transitions missed during a gap are never re-pushed), forwards commands with optimistic
  local updates, and gates model-specific commands (`LaMarzoccoError.unsupportedModel`).
  `isLive` tracks the *subscription* (start→stop) while `isConnected`/`lastUpdateAt` report
  actual socket health and freshness; `lastError` is cleared on the next success.
- **`MachineSnapshot.swift`** — `Codable {serialNumber, dashboard?, settings?, schedule?}` for
  stale-on-launch UI (recognized widgets round-trip losslessly; unknown widgets keep code/index
  but lose their raw payload).

### `cli/` — the `angcli` wire-debugging tool

A **separate, nested SwiftPM package** (not part of the library build, so library consumers
never see it or its `swift-argument-parser` dependency). Depends on `Angstrom` by path. Builds
and tests independently: `cd cli && swift build` / `swift test` (also wired as its own CI step).
Authenticates, holds the websocket open, and prints raw STOMP frames (both directions) and the
decoded `DashboardUpdate` side by side. Commands: `listen` (default), `dump <dashboard|settings|
schedule>`, `machines`. Persists `InstallationKey` + `isRegistered` to
`~/.config/angstrom/installation.json` (mode `0600`); never persists/prints tokens or proof
headers. See `cli/SPEC.md` for the full design.

### Conventions worth keeping

- Network responses are parsed defensively (`JSONSerialization` + shape checks, optional
  decodes) — the cloud API shape is only partially known, so prefer tolerant parsing and a
  `LaMarzoccoError.decoding(...)` over a hard typed-decode failure.
- All thrown errors are `LaMarzoccoError` cases; map new failures into that enum.
- The client is an `actor`; `installationKey` is `nonisolated let` so it can be read for
  persistence without `await`.

## Status

v1.2 — full cloud parity with `pylamarzocco` (Bluetooth excluded): auth + token refresh,
typed dashboard/settings/scheduling reads, the command surface with two-tier websocket
confirmation, live updates, statistics, grinder support, and the optional `AngstromUI`
observable device layer, plus the `angcli` wire-debugging tool, a porting-watermark +
drift-detection workflow, and a DocC documentation site. v1.2 adds websocket resilience
for connection gaps (sleep/network drops): enforced ping/pong liveness that self-heals
zombie sockets, `connectionEvents()` on the client, and automatic dashboard re-fetch on
reconnect + `isConnected`/`lastUpdateAt` in `AngstromUI`. Bluetooth remains out of scope.
