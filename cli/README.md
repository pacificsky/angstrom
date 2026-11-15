# `angcli` — Angstrom cloud-API and Bluetooth debugging CLI

A small command-line tool for **learning and debugging the La Marzocco cloud
API and Bluetooth protocol** through [Angstrom](..). It authenticates with your
account, holds the dashboard websocket open like a real client, and prints what
the server sends — raw STOMP frames in both directions and Angstrom's decoded
view, side by side. With [`angcli ble`](#ble-subcommand--bluetooth) it talks to
a nearby machine over Bluetooth instead and prints raw Bluetooth frames next to
the decoded shot-counter events.

This is a **separate, nested SwiftPM package**. It depends on the in-repo
`Angstrom` library by path and is *not* part of the library build, so apps that
depend on `Angstrom` never pull in this tool or its `swift-argument-parser`
dependency. See [`SPEC.md`](SPEC.md) for the full design rationale.

> ⚠️ This talks to the **real** La Marzocco cloud with **real** credentials.
> Mind rate limits and the La Marzocco ToS. `angcli ble cmd` **actuates your
> real machine** and refuses to run without `--confirm`.

## Build & run

```bash
cd cli
swift build                       # binary at .build/debug/angcli
swift run angcli --help           # rebuilds if needed, then runs
./.build/debug/angcli --help      # or invoke the built binary directly
```

All examples below use `swift run angcli …`; you can swap in the built binary
anywhere. Run them from inside the `cli/` directory (or add
`--package-path cli` from the repo root).

## Authentication

Credentials are read from environment variables, or prompted for interactively
if unset. **They are never persisted.**

```bash
export LAMARZOCCO_USERNAME='you@example.com'
export LAMARZOCCO_PASSWORD='…'
swift run angcli machines
```

Without the env vars you'll be prompted (the password input is hidden):

```
La Marzocco email: you@example.com
Password:
```

On first run the CLI generates a per-install key, registers it with the cloud,
and saves it to `~/.config/angstrom/installation.json` (mode `0600`); later runs
reuse it. Only that key and the `isRegistered` flag are persisted — **tokens and
signed proof headers are never written to disk or printed.** Printed frames and
payloads have the STOMP `CONNECT` bearer token and the machine's `bleAuthToken`
replaced with `**REDACTED**`, so `dump`/`listen` output is safe to paste.

## Commands

| Command | What it does |
|---|---|
| [`listen`](#listen-default) (default) | Hold the websocket open and stream frames until Ctrl-C. |
| [`dump`](#dump-endpoint) `<endpoint>` | One-shot REST read, printed as pretty JSON. |
| [`machines`](#machines) | List the machines on the account. |
| [`ble`](#ble-subcommand--bluetooth) `<subcommand>` | Talk to a nearby machine over Bluetooth: scan, GATT table, token, reads, commands, live shot counter. |

If you run `angcli` with no subcommand, it runs `listen`.

A machine is selected with `--serial <SN>`; if omitted, the only machine is used,
or you're prompted to choose when the account has several. `machines` lists the
serials. (`ble` selects a peripheral differently; see
[Selecting the machine and the token](#selecting-the-machine-and-the-token).)

---

### `listen` (default)

Authenticate, connect the dashboard websocket, and stream frames until Ctrl-C
(which cleanly unsubscribes and disconnects). This is the instrument for open
protocol questions — e.g. *is a dashboard push a full snapshot or a delta?*
Subscribe, toggle one setting on the machine, and watch the push.

**Parameters**

| Flag | Default | Meaning |
|---|---|---|
| `--serial <SN>` | first / prompt | Which machine to listen to. |
| `--raw` | — | Print only verbatim STOMP frames. |
| `--decoded` | — | Print only Angstrom's decoded `DashboardUpdate`. |
| `--both` | ✅ (default) | Print both raw and decoded frames. |

`--raw`, `--decoded`, and `--both` choose the output view; with none given (or
`--both`) you get both. See [Output format](#output-format) below.

**Examples**

Stream everything (raw + decoded) from the only/selected machine:

```bash
swift run angcli listen
```

Watch only the verbatim wire frames for a specific machine:

```bash
swift run angcli listen --serial MR013437 --raw
```

Watch only Angstrom's decoded view, pretty-printed with `jq`:

```bash
swift run angcli listen --decoded | jq .decoded
```

**Findings & open questions** (from captures with this tool):

- **A dashboard push is a full snapshot, not a delta.** Across 122 captured
  pushes, every frame carried the machine's complete live widget set —
  identical codes every time. This is why Angstrom (like pylamarzocco)
  replaces the widget set wholesale on push.
- **`removedWidgets` is a constant complement list, not a removal delta.**
  Every push carries the same entries: all the widget codes the machine
  *doesn't* have (GS3-only widgets on a Micra, grinder `G*` codes, …). It
  never signals "this widget just went away".
- Every routine dashboard push carries top-level `"connected": true`. When a
  machine drops off the cloud (switched off / lost Wi-Fi), REST `dump dashboard`
  serves a "husk": `"connected": false`, `connectionDate` frozen at the last
  connect, and the widget list reduced to a single stale `CMMachineStatus`.
- **Open:** does the server *push* a frame at the moment a machine disconnects
  (e.g. `connected: false` with `removedWidgets` for the live widgets), or does
  the topic just go silent? No disconnect push has been observed in captures.
  To settle it, run `listen` while flipping the machine's power switch and
  watch for a frame; record the answer here and in [`UPSTREAM.md`](../UPSTREAM.md).
  Until confirmed, consumers should assume offline is only discoverable via a
  REST re-read of the dashboard.

---

### `dump <endpoint>`

A single REST read of one endpoint, printed as pretty, **verbatim** JSON (exactly
what the server returned, keys sorted). Useful for diffing the REST shape against
the websocket push shape.

**Parameters**

| Argument / flag | Values | Meaning |
|---|---|---|
| `<endpoint>` | `dashboard` \| `settings` \| `schedule` | Which REST endpoint to read. |
| `--serial <SN>` | first / prompt | Which machine to read. |

**Examples**

```bash
swift run angcli dump dashboard                    # full dashboard JSON
swift run angcli dump settings --serial MR013437   # wifi / plumb-in / firmware
swift run angcli dump schedule | jq '.smartStandBy'   # already pretty; refine with jq
```

---

### `machines`

List the machines registered to the account, one per line, tab-separated as
`serial`, `model`, `type`.

**Parameters:** none.

**Example**

```bash
swift run angcli machines
```

```
MR013437	Linea Micra	CoffeeMachine
PC004077	Pico	Grinder
```

---

### `ble <subcommand>` — Bluetooth

`angcli ble` talks to a nearby machine directly over Bluetooth Low Energy,
through Angstrom's `LaMarzoccoBluetoothClient` and the CoreBluetooth transport
from `AngstromBluetooth`. It needs no cloud connection when you pass the
peripheral and the token yourself. It's the instrument for the hardware
questions the Bluetooth port leaves open (which GATT service hosts the
characteristics, the advertised name format, the shot-counter replay, …).

| Subcommand | Needs cloud? | Needs token? | Output (stdout, one JSON object per line) |
|---|---|---|---|
| `ble scan [--duration <s>] [--all]` | no | no | `{"id","name","rssi"}` per peripheral |
| `ble gatt --peripheral <uuid>` | no | no | `{"service","characteristic","properties":[…]}` per characteristic |
| `ble token --peripheral <uuid> [--show-secret]` | no | — (pairing mode) | `{"token":"**REDACTED**","length":n}` |
| `ble read <setting\|all> [selection]` | optional | yes | `{"ts","setting","raw","decoded"}` per setting |
| `ble cmd <power\|steam\|temp\|standby> … --confirm [selection]` | optional | yes | `{"ts","command","status":{id,message,status},"success":bool}` |
| `ble listen [selection] [--raw\|--decoded]` | optional | yes | raw frame lines and decoded event lines until Ctrl-C (or until the shot counter gives up: error on stderr, non-zero exit) |

`[selection]` is `--peripheral <uuid>`, `--serial <SN>` and `--ble-token <t>`,
described next.

#### Selecting the machine and the token

**Peripheral.** Pass `--peripheral <uuid>` (an `id` printed by `ble scan`; it's
a CoreBluetooth identifier for your Mac, **not** a MAC address). Without it,
angcli scans for 5 seconds and keeps the La Marzocco machines (names starting
with `MICRA`, `MINI`, `LINEA` or `GS3`):

- exactly one match → it's used;
- several → you pick one on stderr;
- none → `No La Marzocco machine found nearby`.

**Token**, first match wins:

1. `--ble-token <t>`. **Discouraged:** it lands in your shell history.
2. The `LAMARZOCCO_BLE_TOKEN` environment variable.
3. The cloud: angcli signs in (as for the cloud commands), picks the machine with
   `--serial` (or the only one / a prompt) and reads its Bluetooth token. If the
   cloud has none, it fails with `The cloud has no Bluetooth token for <serial>.
   Use 'angcli ble token' in pairing mode or the QR label.`

The token can also be read from the machine in pairing mode (`ble token`) or
from the QR label inside the machine's chassis. angcli **never persists** the
token or the peripheral identifier: pass `--peripheral` again, or let it rescan.

```bash
export LAMARZOCCO_BLE_TOKEN='**REDACTED**'     # your token; never commit it
swift run angcli ble read all --peripheral 2B9C4F0E-7A31-4D6B-9E0C-5F1A8D3C7B20
```

#### Bluetooth permission (macOS TCC)

macOS asks for Bluetooth access on the first `ble` command. `angcli` embeds an
Info.plist in its binary (`cli/Support/Info.plist`, linked into the
`__TEXT,__info_plist` section) with the usage description *"angcli talks to your
La Marzocco machine over Bluetooth for debugging."*

- Run from a terminal, the grant is expected to go to the **terminal app**
  (Terminal, iTerm2, VS Code, …), not to angcli. Over ssh or under launchd,
  Bluetooth access is expected to be unauthorized. (Not yet verified on hardware.)
- Access denied → `Bluetooth access denied. Grant it to your terminal app in
  System Settings › Privacy & Security › Bluetooth.`
- Bluetooth off → `Bluetooth is off.`
- Whether a grant survives rebuilding the binary is not yet verified; if access
  stops working after a rebuild, check the Bluetooth list in System Settings.

#### `ble scan`

Scan and print one line per peripheral. Without `--all`, only La Marzocco
machines (the name-prefix filter above) are printed. `--all` prints every
peripheral seen, unfiltered (`name` may be `null`), and the count to stderr — use
it to learn the real advertised names.

| Flag | Default | Meaning |
|---|---|---|
| `--duration <s>` | `5` | Scan time in seconds. |
| `--all` | off | Don't filter by name. |

```bash
swift run angcli ble scan
swift run angcli ble scan --all --duration 10
```

```json
{"id":"2B9C4F0E-7A31-4D6B-9E0C-5F1A8D3C7B20","name":"MICRA…","rssi":-58}
```

#### `ble gatt`

Connect (no authentication) and print the full GATT table: one line per
characteristic with its service and properties. Use it to see which service
hosts the La Marzocco characteristics (`0a0b7847-…` to `0e0b7847-…`). Every
UUID is printed in lowercase, full 128-bit form; a short SIG UUID is expanded
(`180a` prints as `0000180a-0000-1000-8000-00805f9b34fb`).

```bash
swift run angcli ble gatt --peripheral 2B9C4F0E-7A31-4D6B-9E0C-5F1A8D3C7B20
```

#### `ble token`

Read the Bluetooth token from a machine **in pairing mode** (see its manual). By
default the token is masked and only its length is printed:

```json
{"token":"**REDACTED**","length":n}
```

`--show-secret` prints the real token, to stdout only. If the machine refuses
the read (expected outside pairing mode), the error carries an "Is the machine in
pairing mode?" hint.

#### `ble read <setting|all>`

Read one setting, or all six, over an authenticated link. Settings:
`machineCapabilities`, `machineMode`, `tankStatus`, `boilers`, `smartStandBy`,
`isPlumbedIn`. Each line carries the verbatim reply (`raw`: its UTF-8 text, or
hex when it isn't UTF-8) next to Angstrom's decoded value (`decoded`).

```bash
swift run angcli ble read machineMode --serial MR013437
swift run angcli ble read all --peripheral 2B9C4F0E-7A31-4D6B-9E0C-5F1A8D3C7B20 | jq .
```

#### `ble cmd` (actuates hardware)

Send a command over Bluetooth. **It changes your real machine**, so every
`ble cmd` refuses to run without `--confirm`.

| Command | Effect |
|---|---|
| `ble cmd power <on\|off> --confirm` | Power on, or standby. |
| `ble cmd steam <on\|off> --confirm` | Enable or disable the steam boiler. |
| `ble cmd temp <coffee\|steam> <celsius> --confirm` | Set a boiler's target temperature. |
| `ble cmd standby --enabled <bool> --minutes <n> --mode <LastBrewing\|PowerOn> --confirm` | Configure smart standby. |

Each prints the machine's command status and `success` (`true` only for a
`success` status):

```bash
swift run angcli ble cmd power on --confirm --serial MR013437
```

#### `ble listen`

Connect, authenticate, start the shot counter and stream until Ctrl-C (which
stops the shot counter, disconnects and exits 0). The streams are registered
before the shot counter starts, so the authentication and subscribe frames are
captured too. `--raw` prints only raw frames, `--decoded` only decoded events;
both are shown by default. If the machine has no shot counter, angcli prints
`Shot counter not supported by this machine` to stderr and exits non-zero. If
the shot counter gives up (3 rejected logins while reconnecting, or the
shot-counter characteristic disappearing), angcli prints the error to stderr, disconnects and exits
non-zero, in every output mode.

```bash
swift run angcli ble listen --serial MR013437
swift run angcli ble listen --peripheral 2B9C4F0E-7A31-4D6B-9E0C-5F1A8D3C7B20 --decoded | jq .
```

Remember the first notification after every subscribe is the machine's replay of
its last one, and Angstrom drops it (the raw view still shows it).

#### Bluetooth output format

Raw lines reuse the `{ts, dir, …}` shape of `listen`, with `>>` for writes and
`<<` for reads, notifications and lifecycle events:

```json
{"ts":"2026-11-14T09:12:03.101Z","dir":">>","kind":"write","char":"0d0b7847-e12b-09a8-b04b-8e0922a9abab","hex":"**REDACTED**","text":"**REDACTED**"}
{"ts":"2026-11-14T09:12:03.512Z","dir":">>","kind":"write","char":"0a0b7847-e12b-09a8-b04b-8e0922a9abab","hex":"6d616368696e654d6f646500","text":"machineMode\u0000"}
```

`kind` is `write`, `read`, `notification` or `event`; `text` is present when the
bytes are valid UTF-8, and for `event` it's the marker (`[connecting]`,
`[authenticated]`, `[subscribed]`, `[replay dropped]`, …). Decoded lines are
`{"ts","event","value"}` with `event` one of `connected`, `disconnected`,
`subscribed`, `unsubscribed`, `brewing`, `telemetry`, `gaveUp`.

#### Redaction

The token never reaches your terminal unless you ask for it:

- Every frame the library flags as secret — the authentication write and the
  token read — prints `**REDACTED**` for **both** `hex` and `text`.
- As a second line of defence, any write to the auth characteristic
  `0d0b7847-e12b-09a8-b04b-8e0922a9abab` and any read of the token
  characteristic `0c0b7847-e12b-09a8-b04b-8e0922a9abab` is redacted whatever the
  flag says.
- `ble token` masks the token unless `--show-secret` is given (stdout only).
- No error message or log line contains the token.
- The existing masking of `bleAuthToken` and the STOMP bearer token in
  `dump`/`listen` is unchanged.

## Output format

`listen` writes **one JSON object per line** to **stdout** (jq-friendly), each
tagged with an ISO-8601 `ts` and a `dir`:

- `>>` — **outbound** (client → server): the STOMP `CONNECT` / `SUBSCRIBE` /
  `UNSUBSCRIBE` handshake and websocket heartbeat pings.
- `<<` — **inbound** (server → client): `CONNECTED`, dashboard `MESSAGE` pushes,
  and anything else the server sends.

`--raw` lines carry the verbatim frame text under `raw`; `--decoded` lines carry
Angstrom's parsed push under `decoded`:

```json
{"ts":"2026-06-29T00:47:50.327Z","dir":">>","raw":"SUBSCRIBE\ndestination:/ws/sn/MR013437/dashboard\nack:auto\nid:21A2…\ncontent-length:0\n\n\u0000"}
{"ts":"2026-06-29T00:47:51.612Z","dir":"<<","decoded":{"connected":true,"widgets":[ … ],"removedWidgets":[ … ],"commands":[]}}
```

Status, connection lifecycle, and errors go to **stderr**, so stdout stays a
clean stream you can pipe:

```
Authenticating as you@example.com…
Listening on MR013437 (Linea Micra) — raw + decoded. Ctrl-C to stop.
· websocket dropped: Connection reset by peer        # logged, then auto-reconnects
```

(The websocket auto-reconnects on drops — the La Marzocco cloud recycles idle
connections periodically; this is expected.)

### Pretty-printing the incoming JSON

The stream is compact-one-line-per-frame by design. Pipe through `jq` to expand:

```bash
# Angstrom's decoded view of each push, pretty-printed:
swift run angcli listen --decoded | jq .decoded

# The verbatim server JSON body out of each inbound MESSAGE frame:
swift run angcli listen --raw \
| jq -r 'select(.dir=="<<" and (.raw|startswith("MESSAGE"))) | .raw | split("\n\n")[1] | rtrimstr("\u0000")' \
| jq .
```

## Files & environment

| | |
|---|---|
| `LAMARZOCCO_USERNAME` / `LAMARZOCCO_PASSWORD` | Credentials (else prompted). Never persisted. |
| `LAMARZOCCO_BLE_TOKEN` | Bluetooth token for `ble`, used when `--ble-token` is not given (else the cloud). Never persisted. |
| `~/.config/angstrom/installation.json` | Per-install key + `isRegistered`, mode `0600`. Honors `XDG_CONFIG_HOME`. |

The installation key embeds a P-256 private-key scalar — **treat the file as a
secret.**

## Global options

| Flag | Meaning |
|---|---|
| `-h`, `--help` | Show help (works on any subcommand: `angcli help listen`). |
| `--version` | Print the version. |

## Tests

```bash
cd cli && swift test
```
