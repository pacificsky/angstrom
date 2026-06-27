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

v1.0 covers the full La Marzocco **cloud** surface (Bluetooth is out of scope):

- **Auth** — installation registration, sign-in, token refresh, retry-on-401.
- **Typed reads** — a polymorphic dashboard widget model (machine status, coffee
  & steam boilers, pre-extraction, doses, brew-by-weight, scale, grinder), plus
  `/settings` and `/scheduling`.
- **Commands** — power, steam, boiler temperatures, steam level, smart standby,
  auto on/off, wake-up schedules, pre-extraction, brew-by-weight, backflush,
  grinder light, firmware install — with two-tier websocket confirmation.
- **Live updates** — a STOMP websocket exposed as an `AsyncStream<DashboardUpdate>`
  with auto-reconnect and heartbeats.
- **Statistics** — coffee/flush trend, last coffees, lifetime counters.
- **AngstromUI** — an optional `@Observable` device layer (`LaMarzoccoMachine`)
  for SwiftUI: retained state, live merge, optimistic updates, model gating, and
  a persistable snapshot for stale-on-launch UI.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/pacificsky/angstrom.git", from: "1.0.0")
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
try await machine.start()          // live websocket; merges pushes into `dashboard`

// Commands forward to the client and update `dashboard` optimistically.
try await machine.setPower(on: true)
try await machine.setSteamTargetLevel(.level3)   // throws .unsupportedModel off-model

persist(machine.snapshot)          // Codable; reload next launch
```

The core `LaMarzoccoCloudClient` remains usable on its own (CLI/server) — the
device layer is purely additive.

## License

MIT — see [LICENSE](LICENSE). Includes the original `pylamarzocco` copyright
(Josef Zweck) alongside this port's.
