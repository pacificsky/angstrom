# Angstrom

[![Docs](https://img.shields.io/badge/docs-DocC-blue)](https://pacificsky.github.io/angstrom/documentation/angstrom/)

A Swift library for the **La Marzocco** cloud API **and Bluetooth**, for iOS and macOS.

📖 **[API documentation](https://pacificsky.github.io/angstrom/documentation/angstrom/)** — generated with DocC, hosted on GitHub Pages.

Angstrom borrows heavily from [`pylamarzocco`](https://github.com/zweckj/pylamarzocco)
by **Josef Zweck** — the Python library behind the Home Assistant La Marzocco
integration. The cloud protocol, its authentication scheme, and the Bluetooth
protocol are ported from that work; full credit and thanks to Josef. Angstrom is an independent Swift
reimplementation, not a binding.

> **Unofficial.** Not affiliated with, endorsed by, or sponsored by La Marzocco
> S.r.l. "La Marzocco" and machine names are trademarks of their respective
> owner, used only to describe what this library talks to.

## Status

v2.0.0 covers the full La Marzocco **cloud and Bluetooth** surface at parity
with `pylamarzocco` v2.5.6. Supported hardware: Linea Micra, Linea Mini / Mini R,
GS3 (AV/MP), **Strada X**, and the Pico and **Swan** grinders over the cloud;
the Linea Micra, Linea Mini / Mini R and GS3 (AV/MP) also over Bluetooth (the
grinders and the Strada X have no Bluetooth path upstream).

- **Auth** — installation registration, sign-in, token refresh, retry-on-401,
  and privacy-policy acceptance (`policyAcceptanceRequired` / `acceptPrivacyPolicy`).
- **Typed reads** — a polymorphic dashboard widget model (machine/group status,
  coffee & steam boilers, pre-extraction, group/hot-water/brew-by-weight doses,
  brewing profiles & pressure, flushes, scale, grinder speed/auto-speed/dose/
  mirror/hopper), plus
  `/settings` and `/scheduling` (incl. auto on/off, auto standby and eco mode).
- **Commands** — the full `pylamarzocco` command surface: power & machine/group
  modes, steam, boiler temperatures & enables, steam level, smart standby, auto
  on/off, wake-up schedules, pre-extraction, group/hot-water/brew-by-weight
  doses, brewing pressure, flushes, plumb-in, cup warmer, backflush, grinder
  wake/dose/speed/auto-speed/single-dose/mirror/light/auto-standby, firmware
  install — with two-tier websocket
  confirmation and client-side model gating.
- **Live updates** — a STOMP websocket exposed as an `AsyncStream<DashboardUpdate>`
  with auto-reconnect, enforced ping/pong liveness (zombie sockets self-heal),
  and a `connectionEvents()` stream for reconnect-aware consumers. Each push is
  a full snapshot and replaces the dashboard's widgets, matching `pylamarzocco`;
  a push carrying no widgets is treated as a partial frame and keeps the
  last-known set.
- **Offline detection** — when a machine drops off the cloud the server serves a
  frozen "husk" dashboard; the authoritative `connected` flag is surfaced as
  `Machine.isConnected` and flows through both REST reads and pushes.
- **Statistics** — coffee/flush trend, last coffees, lifetime counters.
- **AngstromUI** — an optional `@Observable` device layer (`LaMarzoccoMachine`)
  for SwiftUI: retained state, live updates, optimistic command updates, model
  gating, connection/staleness signals, and a persistable snapshot for
  stale-on-launch UI.
- **Bluetooth** — a CoreBluetooth transport (`AngstromBluetooth`) and a
  `LaMarzoccoBluetoothClient` actor: discovery, pairing-mode token read,
  authenticated reads and commands, and the real-time **shot counter**. In
  `AngstromUI`, the six Bluetooth-capable commands go over Bluetooth first and
  fall back to the cloud. See [Bluetooth](#bluetooth) below.

The repo also ships [`angcli`](cli/README.md), a wire-debugging CLI that streams
raw STOMP frames next to Angstrom's decoded view (and, with `angcli ble`, raw
Bluetooth frames next to the decoded shot-counter events), and
[`UPSTREAM.md`](UPSTREAM.md), which records exactly which `pylamarzocco`
version the port has been carried to (a weekly CI job flags upstream drift).

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/pacificsky/angstrom.git", from: "2.0.0")
```

Add `"Angstrom"` for the stateless core client, and/or `"AngstromUI"` for the
observable device layer, to your target's dependencies. Add `"AngstromBluetooth"`
only if you use Bluetooth: it is the one product that imports CoreBluetooth, so
cloud-only apps never link it. Requires macOS 14+ / iOS 17+.

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

## Bluetooth

Angstrom talks to the machine directly over Bluetooth Low Energy, as the
La Marzocco app does when you're nearby. The protocol logic is a port of
`pylamarzocco`'s `LaMarzoccoBluetoothClient`; the transport is CoreBluetooth.
The full guide is the [Bluetooth article](https://pacificsky.github.io/angstrom/documentation/angstrom/bluetooth)
in the API docs.

### Products

| Product | What it adds for Bluetooth |
|---|---|
| `Angstrom` | `LaMarzoccoBluetoothClient` (an `actor`: discovery, token read, reads, commands, shot counter), the Bluetooth models, `BluetoothAuthToken`, `BluetoothPeripheralID`, and `LaMarzoccoCloudClient.bluetoothAuthToken(serial:)`. It never imports CoreBluetooth. |
| `AngstromBluetooth` | `BluetoothTransport.coreBluetooth(showPowerAlert:)`, the CoreBluetooth transport the client talks through, and `BluetoothAuthorization.current`. The only product that imports CoreBluetooth. |
| `AngstromUI` | `LaMarzoccoMachine` takes an optional Bluetooth client: Bluetooth-first commands with cloud fallback, `refreshDashboardFromBluetooth()`, the shot counter, `bluetoothEvents()`, `isBluetoothConnected`. It never imports CoreBluetooth either. |

Bluetooth covers the Linea Micra, Linea Mini / Mini R and GS3 (AV/MP). Discovery
keeps peripherals whose name starts (case-sensitively) with `MICRA`, `MINI`,
`LINEA` or `GS3`.

### The Bluetooth token

The machine only answers an authenticated link, and authenticating needs the
machine's Bluetooth token. There are three ways to get it:

1. **From the cloud.** After `connect()`, ask the cloud client. It returns `nil`
   when the cloud has no token for that machine.

   ```swift
   let token = try await cloud.bluetoothAuthToken(serial: serial)   // BluetoothAuthToken?
   ```

2. **From the machine, in pairing mode.** Put the machine in pairing mode first
   (see its manual), then read the token over Bluetooth. No cloud account is
   needed.

   ```swift
   let transport = BluetoothTransport.coreBluetooth()
   let found = try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport)
   let token = try await LaMarzoccoBluetoothClient.readToken(transport: transport, peripheral: found[0].id)
   ```

   If the machine refuses the read (expected when it isn't in pairing mode), it
   throws `.bluetoothConnectionFailed` with an "Is the machine in pairing mode?"
   hint.

3. **From the QR label.** The token is printed as a QR code on a label inside
   the machine's chassis. Scan it with any QR reader and wrap the scanned
   string: `BluetoothAuthToken(scannedValue)`.

`BluetoothAuthToken` is opaque: its `description` and `debugDescription` show
`**REDACTED**`, its mirror has no children (so `dump` reveals nothing), and it is
deliberately not `Codable`. The
library never persists, logs or prints it. Store `token.rawValue` in the
Keychain yourself.

### Identity: what you persist

| Value | Persist it? |
|---|---|
| `BluetoothPeripheralID` (from `discoverMachines`) | Yes, **locally** (it's `Codable`). It is CoreBluetooth's per-device identifier, not a MAC address: it can't be derived from cloud data and must not be synced through iCloud or the La Marzocco cloud. If `connect` fails with "Unknown peripheral", scan again. |
| `BluetoothAuthToken.rawValue` | Yes, in the **Keychain**. It's a secret. |

The advertised name format is not yet verified on hardware, so Angstrom doesn't
map a peripheral to a cloud serial: let the user pick their machine from the
`discoverMachines` results.

### Using the client

```swift
import Angstrom
import AngstromBluetooth

let transport = BluetoothTransport.coreBluetooth()   // create once per process and share
let ble = LaMarzoccoBluetoothClient(transport: transport, peripheral: storedPeripheralID, token: token)

let mode = try await ble.machineMode()                // connects + authenticates lazily
let status = try await ble.setPower(on: true)         // a non-success status is returned, not thrown
print(status.isSuccess)
await ble.disconnect()
```

The client connects on the first request, authenticates, and disconnects after
30 s without a request. Commands return a `BluetoothCommandStatus`.

### The shot counter

Newer firmware pushes brewing events over Bluetooth in real time, without the
~4 s delay of the cloud websocket for shot start/stop. Requirements:

- a Linea Micra, Linea Mini, Linea Mini R or GS3 AV/MP with shot-counter
  firmware. `startShotCounter()` returns `false` otherwise.
  `Machine.shotCounterSupported` says whether the cloud reports support; it is
  informational only, and nothing gates on it;
- a Bluetooth client with a valid token;
- a free, persistent Bluetooth connection slot (see the caveat below).

```swift
let events = await ble.shotCounterEvents()   // register before starting
if try await ble.startShotCounter() {
    for await event in events {
        switch event {
        case .brewing(let update): print(update.state, update.timerValue as Any, update.brewingStartTime as Any)
        case .telemetry(let t):    print(t.steamBoilerTemperature as Any, t.machineMode as Any)
        case .subscribed, .unsubscribed: break
        case .gaveUp(let error):   print("shot counter stopped:", error)
        }
    }
}
// Later: unsubscribes; the link stays up and idle disconnect resumes.
await ble.stopShotCounter()
```

With `AngstromUI`, `machine.startShotCounter()` does this for you and keeps
`machine.dashboard` updated in real time.

- A shot or flush is reported as `Brewing` right away when the machine sends
  its start event, with a timer of 0. A flush only differs from a shot once it
  stops. When connecting during a shot, `Brewing` follows with the next timer
  notification.
- `brewingStartTime` is the earliest estimate of the running shot, so late
  notifications don't move it.
- When subscribing, the machine first replays its last notification, which can
  be hours old. The first notification of every subscription is discarded.
- Most notifications carry telemetry (boiler temperatures, the machine mode,
  statistics). Telemetry never changes the brewing state.
- While the shot counter runs, the connection stays open and reconnects
  automatically; idle disconnects are paused. Reconnects back off from 1 s up to
  60 s, and restart at once when Bluetooth powers back on (for example after the
  Mac wakes). They stop after 3 failed logins (counted across the whole
  reconnect run, as upstream's code does); `authenticationFailed` then reports
  the likely wrong token, and the stream ends the run with `.gaveUp(error)`.

### Single-central caveat

The machine likely accepts **only one Bluetooth central at a time**. A
persistent shot-counter link from your app can lock out the La Marzocco app on
your phone (and vice versa). Make the shot counter opt-in, and stop it (or
`disconnect()`) when you don't need it.

### App requirements

| Item | Who needs it |
|---|---|
| `NSBluetoothAlwaysUsageDescription` (Info.plist string) | Every app or tool that uses `AngstromBluetooth`, on macOS and iOS. On iOS a missing key terminates the app at first CoreBluetooth use. |
| `com.apple.security.device.bluetooth` (entitlement) | Only App-Sandboxed macOS apps. |
| `UIBackgroundModes` → `bluetooth-central` | iOS apps that want Bluetooth while in the background (your decision). |

Creating the transport touches no Bluetooth API: the system permission prompt
appears on the first Bluetooth operation. Read `BluetoothAuthorization.current`
to gate your UI without prompting. On iOS the library is foreground-only and
takes no app-lifecycle actions.

### With the device layer

```swift
import Angstrom
import AngstromBluetooth
import AngstromUI

let transport = BluetoothTransport.coreBluetooth()            // create once per process and share
let ble = LaMarzoccoBluetoothClient(transport: transport, peripheral: storedPeripheralID, token: token)
let machine = LaMarzoccoMachine(serialNumber: serial, client: cloud, bluetooth: ble, snapshot: saved)

try await machine.setPower(on: true)   // Bluetooth first; falls back to the cloud on a connection failure
try await machine.refreshDashboardFromBluetooth()
try await machine.startShotCounter()
```

Either client may be `nil`. The Bluetooth-first commands are `setPower`,
`setSteam`, `setSteamTargetLevel`, `setCoffeeTargetTemperature`,
`setSteamTargetTemperature` and `setSmartStandby` (cloud-only on machines that
report auto standby). If the Bluetooth attempt fails
to connect, authenticate, or finds Bluetooth unavailable, or the machine answers
with a non-success status, the command goes to the cloud; without a cloud client
the error is thrown. A Bluetooth timeout is thrown without fallback. Every other
operation is cloud-only and throws `.cloudOnlyFunctionality` without a cloud
client.

**Upgrading from 1.x:** v2.0.0 adds `LaMarzoccoError` cases
(`bluetoothConnectionFailed`, `bluetoothAuthenticationFailed`,
`bluetoothUnavailable`, `bluetoothTimedOut`, `cloudOnlyFunctionality`), which
breaks exhaustive `switch`es. Nothing else changes for cloud-only users.

## License

MIT — see [LICENSE](LICENSE). Includes the original `pylamarzocco` copyright
(Josef Zweck) alongside this port's.
