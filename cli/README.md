# `angcli` — Angstrom cloud-API debugging CLI

A small command-line tool for **learning and debugging the La Marzocco cloud
API** through [Angstrom](..). It authenticates with your account, holds the
dashboard websocket open like a real client, and prints what the server sends —
raw STOMP frames in both directions and Angstrom's decoded view, side by side.

This is a **separate, nested SwiftPM package**. It depends on the in-repo
`Angstrom` library by path and is *not* part of the library build, so apps that
depend on `Angstrom` never pull in this tool or its `swift-argument-parser`
dependency. See [`SPEC.md`](SPEC.md) for the full design rationale.

> ⚠️ This talks to the **real** La Marzocco cloud with **real** credentials.
> Mind rate limits and the La Marzocco ToS.

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
signed proof headers are never written to disk or printed.**

## Commands

| Command | What it does |
|---|---|
| [`listen`](#listen-default) (default) | Hold the websocket open and stream frames until Ctrl-C. |
| [`dump`](#dump-endpoint) `<endpoint>` | One-shot REST read, printed as pretty JSON. |
| [`machines`](#machines) | List the machines on the account. |

If you run `angcli` with no subcommand, it runs `listen`.

A machine is selected with `--serial <SN>`; if omitted, the only machine is used,
or you're prompted to choose when the account has several. `machines` lists the
serials.

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
