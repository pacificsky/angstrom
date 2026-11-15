# ``AngstromUI``

An observable device layer over the Angstrom cloud and Bluetooth clients, for SwiftUI.

## Overview

`AngstromUI` wraps the stateless `Angstrom` core in a `@MainActor @Observable`
``LaMarzoccoMachine`` you can bind directly in SwiftUI. It retains
`dashboard`/`settings`/`schedule`/`statistics`, iterates the live websocket and
merges pushes into `dashboard` (re-fetching the dashboard after every reconnect,
since the push feed is change-only), forwards commands with optimistic local
updates, and gates model-specific commands behind
`LaMarzoccoError.unsupportedModel`. `isConnected` and `lastUpdateAt` report
actual socket health and data freshness, alongside `isLive`'s
subscription intent.

```swift
import AngstromUI

let machine = LaMarzoccoMachine(
    serialNumber: serial,
    client: client,
    snapshot: loadSnapshot()   // optional: render stale state instantly on launch
)

try await machine.refreshAll()     // populate dashboard / settings / schedule
try await machine.start()          // live websocket; merges pushes into `dashboard`

try await machine.setPower(on: true)
try await machine.setSteamTargetLevel(.level3)   // throws .unsupportedModel off-model

persist(machine.snapshot)          // Codable; reload next launch
```

The core `Angstrom` client remains usable on its own (CLI/server) — this layer is
purely additive.

### Bluetooth

Give the machine a `LaMarzoccoBluetoothClient` with
``LaMarzoccoMachine/init(serialNumber:client:bluetooth:snapshot:)``. The machine
owns no transport: the app builds the transport (from `AngstromBluetooth`) and the
client, and persists the peripheral identifier and the token itself. Either client
may be `nil`; ``LaMarzoccoMachine/init(serialNumber:client:snapshot:)`` keeps
today's cloud-only behaviour. `AngstromUI` never imports CoreBluetooth.

```swift
import Angstrom
import AngstromBluetooth
import AngstromUI

let transport = BluetoothTransport.coreBluetooth()            // create once per process and share
let token = try await cloud.bluetoothAuthToken(serial: serial) // or a Keychain copy / QR label
let ble = LaMarzoccoBluetoothClient(transport: transport, peripheral: storedPeripheralID, token: token!)
let machine = LaMarzoccoMachine(serialNumber: serial, client: cloud, bluetooth: ble, snapshot: saved)
```

`bluetoothAuthToken(serial:)` returns `nil` when the cloud has no token; a real app
falls back to a Keychain copy, the pairing-mode read or the QR label instead of
force-unwrapping.

**Bluetooth-first commands.** With a Bluetooth client, six commands try Bluetooth
first: ``LaMarzoccoMachine/setPower(on:)``, ``LaMarzoccoMachine/setSteam(on:)``,
``LaMarzoccoMachine/setSteamTargetLevel(_:)``,
``LaMarzoccoMachine/setCoffeeTargetTemperature(celsius:)``,
``LaMarzoccoMachine/setSteamTargetTemperature(celsius:)`` and
``LaMarzoccoMachine/setSmartStandby(enabled:minutes:after:)`` (cloud-only on
machines that report auto standby). The Bluetooth attempt connects lazily; it does
not wait for ``LaMarzoccoMachine/isBluetoothConnected``.

- On success the command returns a `CommandResponse` with status `.success` and
  applies the same optimistic update as the cloud path (if the command has one).
- If Bluetooth fails to connect, the token is rejected or Bluetooth is unavailable
  (`LaMarzoccoError.isBluetoothConnectionFailure`), or the machine answers with a
  non-success status, the command goes to the cloud. Without a cloud client the
  Bluetooth error is thrown, and a non-success status throws
  `LaMarzoccoError.commandFailed(status:errorCode:)`.
- `LaMarzoccoError.bluetoothTimedOut`, decoding errors and cancellation are thrown
  without fallback.
- With neither client, and for every cloud-only operation without a cloud client,
  the machine throws `LaMarzoccoError.cloudOnlyFunctionality`.

Model-gated commands stay gated: until the model is known (from the cloud, or from
``LaMarzoccoMachine/refreshModelFromBluetooth()``), they throw
`LaMarzoccoError.unsupportedModel`. There is no silent default model.

**Dashboard from Bluetooth.** ``LaMarzoccoMachine/refreshDashboardFromBluetooth()``
reads the machine mode, plumb-in state, water tank and boilers over Bluetooth and
updates the machine status, coffee and steam boiler, and no-water widgets of
`dashboard`. When the model is unknown it reads the machine's capabilities first.
A failed read changes nothing and never falls back to the cloud. It doesn't stamp
`lastUpdateAt`, which stays a cloud freshness signal.

**The shot counter.** ``LaMarzoccoMachine/startShotCounter()`` subscribes to the
machine's real-time brewing notifications. It returns `false` without a Bluetooth
client or when the machine doesn't support them, and throws connect and
authentication errors. While it runs:

- `dashboard`'s machine status shows `.brewing` with the Bluetooth
  `brewingStartTime` during a shot, about 4 seconds before the cloud would. The
  overlay is cleared when the link is lost or 60 seconds after the last brewing
  update. It is never written into ``LaMarzoccoMachine/snapshot``.
- ``LaMarzoccoMachine/bluetoothBrewingUpdate`` holds the latest brewing update,
  ``LaMarzoccoMachine/lastShotTime`` the last finished shot's duration, and
  ``LaMarzoccoMachine/bluetoothTelemetry`` the merged live values (boiler
  temperatures, machine mode, statistics) until the shot counter stops or
  disconnects. A machine mode from telemetry is applied to `dashboard` right away.
- ``LaMarzoccoMachine/isShotCounterActive`` reports whether the subscription is up.
  The connection stays open and reconnects automatically (backing off up to
  60 seconds).

``LaMarzoccoMachine/stopShotCounter()`` unsubscribes silently (no event is sent;
refresh afterwards if needed). The link stays up and disconnects after 30 seconds
idle.

**Events.** ``LaMarzoccoMachine/bluetoothEvents()`` streams
``MachineBluetoothEvent`` values, sent after the machine's state has been updated:
`.brewing(_:)` for each applied brewing update, `.brewingCleared` when the
Bluetooth brewing state is dropped (link lost, or 60 seconds without a brewing
update; not on `stopShotCounter()`), `.telemetry(_:)` with each notification's values, and
`.shotCounterStopped(_:)` when the reconnect loop gives up (for example after 3
failed logins with a wrong token; the error is also stored in `lastError`).

**Connection state.** ``LaMarzoccoMachine/isBluetoothConnected`` is `true` while
an **authenticated** Bluetooth link is up. It is independent of the websocket's
`isConnected`. ``LaMarzoccoMachine/bluetoothConnectionEvents()`` exposes the
underlying `.connected`/`.disconnected` transitions.

## Topics

### Device Layer

- ``LaMarzoccoMachine``
- ``MachineSnapshot``

### Bluetooth

- ``MachineBluetoothEvent``
