# `cli/` — Angstrom debugging CLI (spec)

> Status: **built.** The `angcli` tool and the library raw-frame tap described
> here are implemented. `cd cli && swift build` / `swift test`; the v1 command
> surface (`listen` / `dump` / `machines`) is complete. The deferred `watch`
> mode remains v2.

A small command-line tool for **learning and debugging the La Marzocco cloud API**
through Angstrom. It authenticates with a username/password, holds the websocket
open like a real client, and prints what the server sends — raw wire frames and
Angstrom's decoded view, side by side.

## Goals

- See **real, live** cloud traffic (not fixtures): raw STOMP frames in **both
  directions** (sent and received), raw JSON bodies, and the decoded
  `DashboardUpdate`.
- Be the instrument for open protocol questions — e.g. **is a dashboard push a
  full snapshot or a delta?** (subscribe, toggle one setting, watch the push).
- Dogfood Angstrom's full `auth → register → websocket` path end to end.
- Support ongoing parity/drift work: when upstream `pylamarzocco` moves past the
  watermark, capture live frames and confirm Angstrom still decodes them.

Non-goals: a polished end-user app, config management, or anything that needs to
ship to non-developers.

## Packaging

A **separate SwiftPM package nested in this repo**, not part of the Angstrom
library build. Apps depending on `Angstrom` never see this package or its
dependencies.

```
angstrom/
  Package.swift                  # the library (unchanged, zero external deps)
  Sources/Angstrom, AngstromUI
  cli/
    Package.swift                # executableTarget, depends on Angstrom by path
    Sources/angcli/...
    SPEC.md                      # this file
```

- `cli/Package.swift`: platforms macOS 14+, Swift 6. Dependencies:
  `.package(path: "..")` → the `Angstrom` product, plus
  `swift-argument-parser` (isolated here; does not touch Angstrom consumers).
- Executable name: **`angcli`**.
- The path dependency means the CLI always builds against the in-repo working
  tree — no version pin, no publish dance.
- Promotion to a standalone `angstrom-cli` repo later is cheap: flip the path
  dependency to a URL pin and `git subtree split` the folder.

## Required library change (prerequisite)

Angstrom currently surfaces **only** decoded updates
(`dashboardUpdates() -> AsyncStream<DashboardUpdate>`). The receive loop
(`LaMarzoccoCloudClient.handleFrame`) discards the raw STOMP framing, the raw
JSON body, and — via a `try?` — any frame it can't decode. Outbound frames (the
STOMP `CONNECT`/`SUBSCRIBE`/heartbeats and command sends) aren't exposed either.
For a wire-debugging tool, those are the most valuable things to see.

Add a small, opt-in **raw-frame tap** to the library that captures **both
directions, clearly differentiated**:

- Proposed API: `public func rawFrames() -> AsyncStream<RawFrame>`, multiplexed to
  listeners exactly like `dashboardUpdates()`, where
  `RawFrame { direction: .inbound | .outbound; text: String }`.
- **Inbound**: the raw text of every received frame, emitted before
  `Stomp.decode`, so heartbeats, non-`MESSAGE` frames (CONNECTED/ERROR/receipts),
  and bodies that fail to decode all surface.
- **Outbound**: the raw text of every frame the client sends (handshake,
  subscribe, heartbeats, command sends), emitted at `channel.send`.
- Zero cost when unused; clearly marked debug/diagnostic.

This change lives in `Sources/Angstrom` (the library); the CLI consumes it and
prints each frame tagged with its direction (`>>` outbound / `<<` inbound). The
packaging and the raw-tap are independent decisions — we want both.

## Command surface (v1)

| Command | Behavior |
|---|---|
| `listen` (default) | Auth → connect websocket → stream frames until Ctrl-C. Clean SIGINT → `disconnectWebSocket()`. |
| `dump <dashboard\|settings\|schedule>` | One-shot REST read, printed as pretty JSON. Lets you diff REST shape vs WS shape. |
| `machines` | List the account's machines (serial, model, type). |

Flags: `--raw` / `--decoded` / `--both` (default `--both`); `--serial <SN>` to
pick a machine (else first, or prompt if multiple).

Deferred to v2: a `watch` mode that **sends a command and prints the resulting
push** (the direct cause→effect probe — answers full-vs-partial definitively),
plus richer filtering.

## Credentials & installation key

- **Username/password**: read from `LAMARZOCCO_USERNAME` / `LAMARZOCCO_PASSWORD`
  env vars, or interactive prompt. **Never persisted.**
- **InstallationKey + `isRegistered`**: persisted by the CLI (the caller's job
  per CLAUDE.md). First run generates a key and `register()`s; later runs reuse.
  Stored in `~/.config/angstrom/installation.json`, file mode `0600`.
  - The installation key contains a P-256 private-key scalar — treat as a secret.
    Keychain storage is a possible hardening follow-up.
- **Never print** access/refresh tokens or the signed proof headers. Websocket
  message bodies are safe to dump.

## Output

- **stdout**: one frame per line as JSON (jq-friendly), each tagged with a
  timestamp and direction (`>>` outbound / `<<` inbound). `--raw` adds the
  verbatim STOMP/JSON text.
- **stderr**: status, connection lifecycle, errors.

## Build & CI

- Builds independently: `cd cli && swift build` / `swift test`.
- CI gains a second step that builds (and tests, if any) the `cli/` package after
  the library. The root `swift build && swift test` is unchanged.
- Editor: open the `cli/` package directly, or add both to a workspace.

## Caveats

- Talks to the **real** La Marzocco cloud with real credentials — mind rate
  limits and ToS.
- The deferred `watch` mode **actuates real hardware** (toggles your machine) —
  keep it gentle and clearly flagged.
- One more target to keep green in CI (minor).
