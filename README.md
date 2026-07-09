# Angstrom

[![Docs](https://img.shields.io/badge/docs-DocC-blue)](https://pacificsky.github.io/angstrom/documentation/angstrom/)

A Swift library for the **La Marzocco** cloud API, for iOS and macOS.

📖 **[API documentation](https://pacificsky.github.io/angstrom/documentation/angstrom/)** — generated with DocC, hosted on GitHub Pages.

Angstrom borrows heavily from [`pylamarzocco`](https://github.com/zweckj/pylamarzocco)
by **Josef Zweck** — the Python library behind the Home Assistant La Marzocco
integration. The cloud protocol and authentication scheme are ported from that
work; full credit and thanks to Josef. Angstrom is an independent Swift
reimplementation, not a binding.

> **Unofficial.** Not affiliated with, endorsed by, or sponsored by La Marzocco
> S.r.l. "La Marzocco" and machine names are trademarks of their respective
> owner, used only to describe what this library talks to.

## Status

v1.5 covers the full La Marzocco **cloud** surface at parity with
`pylamarzocco` v2.4.2 (Bluetooth is out of scope). Supported hardware: Linea
Micra, Linea Mini / Mini R, GS3 (AV/MP), **Strada X**, and the Pico and
**Swan** grinders.

- **Auth** — installation registration, sign-in, token refresh, retry-on-401.
- **Typed reads** — a polymorphic dashboard widget model (machine/group status,
  coffee & steam boilers, pre-extraction, group/hot-water/brew-by-weight doses,
  brewing profiles & pressure, flushes, scale, grinder speed/dose), plus
  `/settings` and `/scheduling` (incl. auto on/off and eco mode).
- **Commands** — the full `pylamarzocco` command surface: power & machine/group
  modes, steam, boiler temperatures & enables, steam level, smart standby, auto
  on/off, wake-up schedules, pre-extraction, group/hot-water/brew-by-weight
  doses, brewing pressure, flushes, plumb-in, cup warmer, backflush, grinder
  wake/dose/speed/light, firmware install — with two-tier websocket
  confirmation and client-side model gating.
- **Live updates** — a STOMP websocket exposed as an `AsyncStream<DashboardUpdate>`
  with auto-reconnect, enforced ping/pong liveness (zombie sockets self-heal),
  and a `connectionEvents()` stream for reconnect-aware consumers. Each push is
  a full snapshot and replaces the dashboard's widgets, matching `pylamarzocco`.
- **Offline detection** — when a machine drops off the cloud the server serves a
  frozen "husk" dashboard; the authoritative `connected` flag is surfaced as
  `Machine.isConnected` and flows through both REST reads and pushes.
- **Statistics** — coffee/flush trend, last coffees, lifetime counters.
- **AngstromUI** — an optional `@Observable` device layer (`LaMarzoccoMachine`)
  for SwiftUI: retained state, live updates, optimistic command updates, model
  gating, connection/staleness signals, and a persistable snapshot for
  stale-on-launch UI.

The repo also ships [`angcli`](cli/README.md), a wire-debugging CLI that streams
raw STOMP frames next to Angstrom's decoded view, and
[`UPSTREAM.md`](UPSTREAM.md), which records exactly which `pylamarzocco`
version the port has been carried to (a weekly CI job flags upstream drift).

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/pacificsky/angstrom.git", from: "1.5.0")
```

Add `"Angstrom"` for the stateless core client, and/or `"AngstromUI"` for the
observable device layer, to your target's dependencies. Requires macOS 14+ / iOS 17+.

## Usage

```swift
import Angstrom

// Generate an identity once and persist it (it's Codable); reuse it after.
let key = loadStoredKey() ?? .generate()

let client = LaMarzoccoCloudClient(
    username: email,
    password: password,
    installationKey: key,
    registered: wasRegistered   // persist `await client.isRegistered` after first connect
)

let machines = try await client.connect()
persist(client.installationKey, registered: await client.isRegistered)

let serial = machines[0].serialNumber
let state = try await client.powerState(serial: serial)   // .on / .off / .other / .unknown
try await client.setPower(serial: serial, on: true)       // BrewingMode
```

### Storage is your responsibility

The library keeps access tokens in memory and never touches disk. Persist the
`installationKey` (e.g. in the Keychain) and the `isRegistered` flag yourself,
and pass them back when constructing the client on the next launch.

### SwiftUI: the observable device layer

`AngstromUI` wraps the core client in a `@MainActor @Observable`
`LaMarzoccoMachine` you can bind directly in SwiftUI:

```swift
import AngstromUI

let machine = LaMarzoccoMachine(
    serialNumber: serial,
    client: client,
    snapshot: loadSnapshot()   // optional: render stale state instantly on launch
)

try await machine.refreshAll()     // populate dashboard / settings / schedule
try await machine.start()          // live websocket; pushes update `dashboard`

// Commands forward to the client and update `dashboard` optimistically.
try await machine.setPower(on: true)
try await machine.setSteamTargetLevel(.level3)   // throws .unsupportedModel off-model

persist(machine.snapshot)          // Codable; reload next launch
```

When a machine is physically off or has lost Wi-Fi, the cloud keeps serving its
last-known state — `powerState` (and every widget) is frozen at whatever the
machine last reported. Gate status displays on `machine.isMachineConnected`
(`nil` until the first dashboard loads) so an offline machine isn't shown as
"on"; `machineLastConnectionDate` says how stale the frozen state is.

The core `LaMarzoccoCloudClient` remains usable on its own (CLI/server) — the
device layer is purely additive.

## License

MIT — see [LICENSE](LICENSE). Includes the original `pylamarzocco` copyright
(Josef Zweck) alongside this port's.
