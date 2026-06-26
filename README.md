# Angstrom

A Swift library for the **La Marzocco** cloud API, for iOS and macOS.

Angstrom borrows heavily from [`pylamarzocco`](https://github.com/zweckj/pylamarzocco)
by **Josef Zweck** — the Python library behind the Home Assistant La Marzocco
integration. The cloud protocol and authentication scheme are ported from that
work; full credit and thanks to Josef. Angstrom is an independent Swift
reimplementation, not a binding.

> **Unofficial.** Not affiliated with, endorsed by, or sponsored by La Marzocco
> S.r.l. "La Marzocco" and machine names are trademarks of their respective
> owner, used only to describe what this library talks to.

## Status

v0.1 covers the cloud essentials: authentication, listing machines, reading
power state, and turning a machine on/off. More of the `pylamarzocco` surface
(live status websocket, additional commands, Bluetooth) may follow.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/pacificsky/angstrom.git", from: "0.1.0")
```

Then add `"Angstrom"` to your target's dependencies. Requires macOS 13+ / iOS 16+.

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

## License

MIT — see [LICENSE](LICENSE). Includes the original `pylamarzocco` copyright
(Josef Zweck) alongside this port's.
