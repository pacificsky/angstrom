# `cli/` — Angstrom debugging CLI (spec)

> Status: **built.** The `angcli` tool and the library raw-frame tap described
> here are implemented. `cd cli && swift build` / `swift test`; the v1 command
> surface (`listen` / `dump` / `machines`) is complete, and angcli 2.0.0 adds
> the [`ble` command tree](#bluetooth-angcli-ble) for the Bluetooth port. The
> deferred `watch` mode remains v2.

A small command-line tool for **learning and debugging the La Marzocco cloud API**
(and, since 2.0.0, the machine's **Bluetooth** protocol) through Angstrom. It
authenticates with a username/password, holds the websocket open like a real
client, and prints what the server sends — raw wire frames and Angstrom's decoded
view, side by side.

## Goals

- See **real, live** cloud traffic (not fixtures): raw STOMP frames in **both
  directions** (sent and received), raw JSON bodies, and the decoded
  `DashboardUpdate`.
- Be the instrument for open protocol questions — e.g. **is a dashboard push a
  full snapshot or a delta?** (subscribe, toggle one setting, watch the push).
- Dogfood Angstrom's full `auth → register → websocket` path end to end.
- Support ongoing parity/drift work: when upstream `pylamarzocco` moves past the
  watermark, capture live frames and confirm Angstrom still decodes them.
- Settle the Bluetooth port's hardware-only questions (GATT service layout,
  advertised names, shot-counter replay, token read outside pairing mode) with
  `angcli ble`.

Non-goals: a polished end-user app, config management, or anything that needs to
ship to non-developers.

## Packaging

A **separate SwiftPM package nested in this repo**, not part of the Angstrom
library build. Apps depending on `Angstrom` never see this package or its
dependencies.

```
angstrom/
  Package.swift                  # the library (unchanged, zero external deps)
  Sources/Angstrom, AngstromUI, AngstromBluetooth
  cli/
    Package.swift                # executableTarget, depends on Angstrom by path
    Sources/angcli/...
    Sources/angcli/Ble/...       # the `ble` command tree
    Support/Info.plist           # embedded into the binary (Bluetooth usage string)
    SPEC.md                      # this file
```

- `cli/Package.swift`: platforms macOS 14+, Swift 6. Dependencies:
  `.package(path: "..")` → the `Angstrom` and `AngstromBluetooth` products, plus
  `swift-argument-parser` (isolated here; does not touch Angstrom consumers).
- The `angcli` target embeds `Support/Info.plist` with
  `linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Support/Info.plist"])]`
  (the path is relative to the `cli/` package root). `unsafeFlags` is acceptable
  only because `cli/` is always a root package, never a dependency; the root
  `Package.swift` must not carry it. See [Bluetooth permission](#bluetooth-permission-tcc).
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
| `ble <subcommand>` | (2.0.0) Bluetooth: scan, GATT table, token, reads, commands, shot counter. See [Bluetooth](#bluetooth-angcli-ble). |

Flags: `--raw` / `--decoded` / `--both` (default `--both`); `--serial <SN>` to
pick a machine (else first, or prompt if multiple).

Deferred to v2: a `watch` mode that **sends a command and prints the resulting
push** (the direct cause→effect probe — answers full-vs-partial definitively),
plus richer filtering.

## Bluetooth (`angcli ble`)

`angcli ble <subcommand>` talks to a nearby machine over Bluetooth through
`LaMarzoccoBluetoothClient` and `BluetoothTransport.coreBluetooth()`. `Ble` is a
parent command registered in `AngCLI.swift`
(`subcommands: [Listen.self, Dump.self, Machines.self, Ble.self]`); each
subcommand lives in its own file under `cli/Sources/angcli/Ble/`. Shared
selection and output live in `BleSession.swift` and `BleOutput.swift`.

### Command tree

| Subcommand | Needs cloud? | Needs token? | Library surface | Output (stdout, one JSON object per line) |
|---|---|---|---|---|
| `ble scan [--duration <s>=5] [--all]` | no | no | `discoverMachines`; with `--all`, `scanAll` (unfiltered) and the count to stderr | `{"id","name","rssi"}` per peripheral (`name` may be null with `--all`) |
| `ble gatt --peripheral <uuid>` | no | no | `gattTable` | `{"service","characteristic","properties":[…]}` per characteristic |
| `ble token --peripheral <uuid> [--show-secret]` | no | — (pairing mode) | `readToken` | `{"token":"**REDACTED**","length":n}`. The real value only with `--show-secret`. |
| `ble read <setting\|all> [selection]` | optional | yes | `rawRead` + typed read | per setting: `{"ts","setting","raw","decoded"}` (`raw` = UTF-8 text of the verbatim bytes, or hex if not UTF-8) |
| `ble cmd power <on\|off>` / `steam <on\|off>` / `temp <coffee\|steam> <celsius>` / `standby --enabled <bool> --minutes <n> --mode <LastBrewing\|PowerOn>` + `--confirm` | optional | yes | client commands | `{"ts","command","status":{id,message,status},"success":bool}` |
| `ble listen [selection] [--raw\|--decoded]` | optional | yes | `rawFrames`, `connectionEvents`, `shotCounterEvents`, `startShotCounter` | raw frame lines and decoded event lines until SIGINT (or until the shot counter gives up: error on stderr, non-zero exit) |

`[selection]` is `--peripheral <uuid>`, `--serial <SN>` and `--ble-token <t>`
(`BleTargetOptions`, shared through `@OptionGroup`).

**`ble cmd` actuates hardware.** Like every command with side effects (see the
deferred `watch` mode under Caveats), it refuses to run without `--confirm`,
enforced in `validate()`.

`ble listen` registers `rawFrames()`, `connectionEvents()` and
`shotCounterEvents()` **before** `startShotCounter()`, so the authentication and
subscribe frames are captured. If `startShotCounter()` returns `false` it prints
`Shot counter not supported by this machine` to stderr and exits non-zero.

### Selection: peripheral and token

- **Peripheral:** `--peripheral <uuid>` (a CoreBluetooth identifier, not a MAC).
  Otherwise scan for 5 s and filter by name prefix (`MICRA`, `MINI`, `LINEA`,
  `GS3`). Exactly one match → use it. Several → interactive pick on stderr.
  None → `CLIError("No La Marzocco machine found nearby")`.
- **Token precedence:** `--ble-token <t>` (discouraged: it lands in shell history;
  the help text says so) → env `LAMARZOCCO_BLE_TOKEN` → cloud: `Bootstrap.connect()`
  + `MachineSelector` (`--serial`) + `bluetoothAuthToken(serial:)`. An empty flag
  or environment value falls through to the next source. A nil cloud token →
  `CLIError("The cloud has no Bluetooth token for <serial>. Use 'angcli ble token' in pairing mode or the QR label.")`.
- The token and the peripheral ID are **never persisted** by angcli. A
  `serial → peripheral` map in `installation.json` is deferred.

### Output

- Reuse `Stdout`/`Stderr` and the `{ts, dir, …}` line shape of the cloud
  `listen` (`FramePrinter`), with `>>` (outbound) / `<<` (inbound). A raw BLE line
  is `{"ts","dir":">>"|"<<","kind":"write|read|notification|event","char":"0b0b…","hex":"…","text":"…"}`.
  `text` is present when the bytes are valid UTF-8. For `event`, `text` is the
  marker (`[connecting]`, `[connected]`, `[authenticated]`, `[disconnected]`,
  `[subscribed]`, `[unsubscribed]`, `[replay dropped]`, `[services invalidated]`,
  `[mtu <n>]`).
- A decoded line is `{"ts","event":"connected|disconnected|subscribed|unsubscribed|brewing|telemetry|gaveUp","value":{…}}`.
  `value` uses a CLI-local `Encodable` mirror of `BluetoothShotCounterUpdate` /
  `BluetoothMachineTelemetry`.
- `ble listen` installs `SignalHandler` (SIGINT) → `stopShotCounter()` +
  `disconnect()`, then exits 0, mirroring the cloud `listen`. If the shot counter
  gives up (`ShotCounterEvent.gaveUp(error)`), `ble listen` prints the mapped
  error to stderr, disconnects and exits non-zero in every output mode, instead
  of sitting silent until SIGINT.
- Error texts (stderr):
  - `.bluetoothUnavailable(.unauthorized(_))` →
    `Bluetooth access denied. Grant it to your terminal app in System Settings › Privacy & Security › Bluetooth.`
  - `.bluetoothUnavailable(.poweredOff)` → `Bluetooth is off.`
  - anything else → the error's `errorDescription`.

### Redaction (normative)

- `Redact.bluetoothFrame(_ frame: RawBluetoothFrame) -> (hex: String, text: String?)`
  in `Output.swift`. If `frame.isSecret`, **both** become `"**REDACTED**"`
  (`Redact.placeholder`). This covers the auth write and the token read. Every
  raw BLE line goes through it; nothing bypasses it.
- Defence in depth: also redact any write to
  `0d0b7847-e12b-09a8-b04b-8e0922a9abab` (auth) and any read of
  `0c0b7847-e12b-09a8-b04b-8e0922a9abab` (token), whatever `isSecret` says.
- `ble token` masks by default. `--show-secret` prints the raw token, to stdout
  only.
- No error message, log line or `logHandler` output may contain the token.
  `BluetoothAuthToken`'s `description` is already redacted. Interpolating the
  token is a review-blocking bug.
- `Redact.secrets(in:)` stays as is (`bleAuthToken` JSON key + STOMP bearer).

### Bluetooth permission (TCC)

- `cli/Support/Info.plist` keys: `CFBundleIdentifier` = `angstrom.angcli`,
  `CFBundleName` = `angcli`, and `NSBluetoothAlwaysUsageDescription` =
  `angcli talks to your La Marzocco machine over Bluetooth for debugging.`. It is
  embedded into the Mach-O (`__TEXT,__info_plist`), readable via `Bundle.main`
  and bound by the code signature.
- TCC attribution from a terminal (Terminal, iTerm2, VS Code, ssh) is
  **unverified**. The expected behaviour is that the grant goes to the terminal
  app, and that under ssh/launchd access is unauthorized. Whether a grant
  survives a rebuild, and the behaviour without the usage string, are also
  unverified. angcli maps `.bluetoothUnavailable` to a clean `CLIError` with the
  guidance above.
- macOS 14 only (unchanged). No test constructs a `CBCentralManager`: the
  `ble` tests cover argument parsing, selection rules, output encoding and
  redaction only.

## Credentials & installation key

- **Username/password**: read from `LAMARZOCCO_USERNAME` / `LAMARZOCCO_PASSWORD`
  env vars, or interactive prompt. **Never persisted.**
- **InstallationKey + `isRegistered`**: persisted by the CLI (the caller's job
  per CLAUDE.md). First run generates a key and `register()`s; later runs reuse.
  Stored in `~/.config/angstrom/installation.json`, file mode `0600`.
  - The installation key contains a P-256 private-key scalar — treat as a secret.
    Keychain storage is a possible hardening follow-up.
- **Never print** access/refresh tokens or the signed proof headers. Every
  verbatim frame and REST payload passes through `Redact.secrets` before stdout:
  - the STOMP `CONNECT` frame's `Authorization: Bearer <accessToken>` header
    (the raw tap captures the handshake, and it repeats on every reconnect);
  - `bleAuthToken` — `Thing` payloads carry the machine's Bluetooth auth token
    (top-level and in `coffeeStation`); mirrors pylamarzocco v2.5.2's log
    masking.
- **Bluetooth token** (`angcli ble`): from `--ble-token`, `LAMARZOCCO_BLE_TOKEN`
  or the cloud; never persisted, and redacted in every printed frame (see
  [Redaction](#redaction-normative)).

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
  keep it gentle and clearly flagged. `ble cmd` already does, so it requires
  `--confirm`.
- The machine likely accepts only one Bluetooth central at a time: while
  `ble listen` holds the link, the La Marzocco phone app may not connect.
- One more target to keep green in CI (minor).
