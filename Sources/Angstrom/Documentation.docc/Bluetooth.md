# Bluetooth

Talk to a nearby machine directly over Bluetooth Low Energy: tokens, discovery,
the connection lifecycle, the shot counter, errors, and app requirements.

## Overview

``LaMarzoccoBluetoothClient`` is a port of `pylamarzocco`'s Bluetooth client. It
speaks the machine's Bluetooth protocol byte for byte: it authenticates with the
machine's Bluetooth token, reads settings, sends the Bluetooth commands, and runs
the real-time shot counter.

The work is split across products so that cloud-only apps never link
CoreBluetooth:

- **`Angstrom`** holds all the protocol logic: ``LaMarzoccoBluetoothClient``, the
  Bluetooth models, ``BluetoothAuthToken``, ``BluetoothPeripheralID`` and
  ``LaMarzoccoCloudClient/bluetoothAuthToken(serial:)``. It never imports
  CoreBluetooth.
- **`AngstromBluetooth`** adds `BluetoothTransport.coreBluetooth(showPowerAlert:)`,
  the CoreBluetooth ``BluetoothTransport`` the client talks through, and
  `BluetoothAuthorization.current`. It is the only product that imports
  CoreBluetooth.
- **`AngstromUI`** lets `LaMarzoccoMachine` take an optional Bluetooth client and
  route commands over Bluetooth first (see the AngstromUI documentation).

Bluetooth covers the Linea Micra, Linea Mini, Linea Mini R and GS3 (AV and MP).
The grinders (Pico, Swan) and the Strada X have no Bluetooth path upstream, so
they stay cloud-only.

## Getting the Bluetooth token

The machine only answers an authenticated link, and authenticating needs the
machine's Bluetooth token. Angstrom treats it as an opaque string. There are
three sources:

- **The cloud.** ``LaMarzoccoCloudClient/bluetoothAuthToken(serial:)`` reads the
  `bleAuthToken` of that machine from `GET /things`. It returns `nil` when the
  cloud has no token (a `null`, missing or empty value), and throws
  ``LaMarzoccoError/decoding(_:)`` when the account has no machine with that
  serial.

  ```swift
  let machines = try await cloud.connect()
  let token = try await cloud.bluetoothAuthToken(serial: machines[0].serialNumber)
  ```

- **The machine, in pairing mode.** Put the machine in pairing mode (see its
  manual), then call ``LaMarzoccoBluetoothClient/readToken(transport:peripheral:)``.
  It makes one connection attempt, reads the token without authenticating, and
  always disconnects. If the machine refuses the read with an ATT permission
  error, it throws ``LaMarzoccoError/bluetoothConnectionFailed(_:)`` with the hint
  "Is the machine in pairing mode?". No cloud account is needed.

  ```swift
  let token = try await LaMarzoccoBluetoothClient.readToken(transport: transport,
                                                            peripheral: peripheralID)
  ```

- **The QR label.** The token is printed as a QR code on a label inside the
  machine's chassis. Scan it with any QR reader; the scanned value is the token.
  Wrap it with ``BluetoothAuthToken/init(_:)``.

``BluetoothAuthToken`` is built to stay out of logs: its `description` and
`debugDescription` show `**REDACTED**`, its mirror has no children, and it is not
`Codable`. The library never persists, logs or prints it. Persist
``BluetoothAuthToken/rawValue`` in the Keychain yourself.

## Discovery and identity

``LaMarzoccoBluetoothClient/discoverMachines(transport:duration:)`` scans for
5 seconds by default, with no service filter, and keeps every peripheral whose
name starts (case-sensitively) with one of
``LaMarzoccoBluetoothClient/machineNamePrefixes`` (`MICRA`, `MINI`, `LINEA`,
`GS3`). It returns ``DiscoveredPeripheral`` values, de-duplicated, in the order
they were first seen. ``LaMarzoccoBluetoothClient/scanAll(transport:duration:)``
returns every peripheral without the name filter, for diagnostics.

```swift
import Angstrom
import AngstromBluetooth

let transport = BluetoothTransport.coreBluetooth()   // create once per process and share
let found = try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport)
for machine in found {
    print(machine.id, machine.name ?? "?", machine.rssi ?? 0)
}
```

A ``BluetoothPeripheralID`` is CoreBluetooth's identifier for the peripheral. It
is **not** a MAC address:

- It is specific to the Apple device (and possibly to the app). It can't be
  derived from cloud data, and it must not be synced through iCloud or the
  La Marzocco cloud.
- Persist it locally (it is `Codable`) and reuse it on the next launch. If a
  connect fails with "Unknown peripheral … scan again", run discovery again.
- How long the identifier stays stable across apps, reboots and Bluetooth resets
  is not yet verified on hardware.

The advertised name format is not yet verified either, so Angstrom doesn't map a
peripheral to a cloud serial number. Let the user pick their machine from the
discovery results.

## The connection lifecycle

```swift
let ble = LaMarzoccoBluetoothClient(transport: transport,
                                    peripheral: storedPeripheralID,
                                    token: token)
```

Creating a client opens nothing. The lifecycle follows `pylamarzocco`:

- **Lazy connect.** The first request connects (up to 3 attempts of 20 seconds
  each), discovers the machine's characteristics and authenticates by writing the
  token and polling for the machine's confirmation. A link that fails
  authentication is closed at once; Angstrom never keeps an unauthenticated link.
- **Serialised requests.** Each read or command is a write followed by a read on
  the same characteristic. Requests run one at a time.
- **Idle disconnect.** After 30 seconds without a request the client disconnects.
  The next request reconnects.
- **Drop on error.** A connection failure, authentication failure, unavailable
  Bluetooth or timeout in a request closes the link, unless the shot counter is
  running (one failed command must not kill it). A characteristic that is still
  missing after a fresh discovery always closes it. A decoding failure never
  does. Requests never reconnect by themselves; the next request reconnects.
- ``LaMarzoccoBluetoothClient/isConnected`` is `true` only for an
  **authenticated** link. ``LaMarzoccoBluetoothClient/connectionEvents()``
  reports `.connected` after authentication and `.disconnected` for every close,
  including the idle disconnect.
- ``LaMarzoccoBluetoothClient/disconnect()`` stops the shot counter (if any) and
  closes the link. It never throws and is idempotent.

The reads are ``LaMarzoccoBluetoothClient/machineMode()``,
``LaMarzoccoBluetoothClient/machineCapabilities()``,
``LaMarzoccoBluetoothClient/tankStatus()``,
``LaMarzoccoBluetoothClient/isPlumbedIn()``,
``LaMarzoccoBluetoothClient/boilers()`` and
``LaMarzoccoBluetoothClient/smartStandby()``. The commands are
``LaMarzoccoBluetoothClient/setPower(on:)``,
``LaMarzoccoBluetoothClient/setSteam(on:)``,
``LaMarzoccoBluetoothClient/setTemperature(boiler:celsius:)`` and
``LaMarzoccoBluetoothClient/setSmartStandby(enabled:mode:minutes:)``. A command
**returns** the machine's ``BluetoothCommandStatus``; a non-success status is not
thrown, so check ``BluetoothCommandStatus/isSuccess``.

```swift
let mode = try await ble.machineMode()          // connects and authenticates on first use
let status = try await ble.setPower(on: true)
if !status.isSuccess { print(status.status, status.message) }
```

### The shot counter

Newer firmware pushes brewing events over Bluetooth in real time, without the
roughly 4-second delay of the cloud websocket for shot start and stop. It needs a
Linea Micra, Linea Mini, Linea Mini R or GS3 with shot-counter firmware, a valid
token, and a free, persistent Bluetooth connection slot.

```swift
let events = await ble.shotCounterEvents()      // register before starting
if try await ble.startShotCounter() {           // false: no shot-counter characteristic
    for await event in events {
        switch event {
        case .subscribed, .unsubscribed:
            break
        case .brewing(let update):
            print(update.state, update.timerValue ?? 0, update.brewingStartTime as Any)
        case .telemetry(let telemetry):
            print(telemetry.coffeeBoilerTemperature as Any, telemetry.machineMode as Any)
        case .gaveUp(let error):
            print("shot counter stopped:", error.localizedDescription)
        }
    }
}
```

- ``LaMarzoccoBluetoothClient/startShotCounter()`` returns `false` when the
  machine has no shot-counter characteristic, and throws connect or
  authentication errors. Support is detected on the machine; the cloud's
  ``Machine/shotCounterSupported`` flag is informational only.
- A shot or flush is reported as ``BluetoothBrewingState/brewing`` as soon as the
  machine sends its start event, with a timer of 0. A flush only differs from a
  shot once it stops. ``BluetoothShotCounterUpdate/brewingStartTime`` is the
  earliest estimate of the running shot's start, so late notifications don't move
  it.
- On every subscription the machine first replays its last notification, which
  can be hours old. The first notification of every subscription is discarded.
- Most notifications carry ``BluetoothMachineTelemetry`` (boiler temperatures, the
  machine mode, statistics). A ``ShotCounterEvent/telemetry(_:)`` event holds only
  the values present in that notification, and telemetry never changes the
  brewing state.
- While the shot counter runs, idle disconnects are paused and a lost link
  reconnects automatically. Reconnects back off from 1 second, doubling up to
  60 seconds, and restart at once when Bluetooth powers back on (for example after
  the Mac wakes). The loop gives up after 3 authentication failures (counted
  across the whole reconnect run, as upstream's code does) or when the
  shot-counter characteristic disappears; it then emits
  ``ShotCounterEvent/gaveUp(_:)``. After authentication failures,
  ``LaMarzoccoBluetoothClient/authenticationFailed`` reports the likely wrong
  token.
- ``LaMarzoccoBluetoothClient/stopShotCounter()`` unsubscribes. The link stays up
  and the idle disconnect resumes.

> Important: The machine likely accepts only **one Bluetooth central at a time**.
> A persistent shot-counter link from your app can lock out the La Marzocco app
> on the owner's phone. Make the shot counter opt-in, and stop it or disconnect
> when you don't need it.

### Diagnostics

``LaMarzoccoBluetoothClient/rawFrames()`` streams every write, read and
notification verbatim, plus lifecycle markers, as ``RawBluetoothFrame`` values.
It costs nothing while nobody listens.
``LaMarzoccoBluetoothClient/rawRead(_:)`` returns the verbatim response bytes of
one read. Frames that carry the token (the authentication write and the token
read) have ``RawBluetoothFrame/isSecret`` set: redact their bytes before you
display or log them. The `angcli ble` tool does exactly that.

## Errors and fallback

Every Bluetooth failure is a ``LaMarzoccoError`` (cancellation stays a
`CancellationError`):

| Error | When |
|---|---|
| ``LaMarzoccoError/bluetoothConnectionFailed(_:)`` | All 3 connect attempts failed, discovery or a GATT operation failed, the link dropped mid-request, a required characteristic is missing, or the peripheral is unknown. |
| ``LaMarzoccoError/bluetoothAuthenticationFailed`` | The machine never confirmed the token. The token is likely wrong. |
| ``LaMarzoccoError/bluetoothUnavailable(_:)`` | Bluetooth is off, unauthorized, unsupported, or did not become ready within 10 seconds. Carries the ``BluetoothAvailability``. |
| ``LaMarzoccoError/bluetoothTimedOut(_:)`` | A read or write in a request did not complete within 20 seconds. |
| ``LaMarzoccoError/decoding(_:)`` | The machine's reply could not be parsed. The link stays up. |
| ``LaMarzoccoError/cloudOnlyFunctionality`` | (`AngstromUI`) The operation needs the cloud, but the machine has no cloud client. |

``LaMarzoccoError/isBluetoothConnectionFailure`` is `true` for the first three.
It decides the fallback in `AngstromUI`: a Bluetooth-first command whose
Bluetooth attempt fails that way, or whose status is not a success, goes to the
cloud. Without a cloud client the Bluetooth error is thrown (a non-success status
becomes ``LaMarzoccoError/commandFailed(status:errorCode:)``). A
``LaMarzoccoError/bluetoothTimedOut(_:)``, a decoding error or a cancellation is
thrown without fallback, as upstream does.

## Platform requirements

| Item | Who needs it |
|---|---|
| `NSBluetoothAlwaysUsageDescription` (Info.plist string) | Every app or tool that uses `AngstromBluetooth`, on macOS and iOS. On iOS a missing key terminates the app at first CoreBluetooth use. |
| `com.apple.security.device.bluetooth` (entitlement) | Only App-Sandboxed macOS apps. |
| `UIBackgroundModes` → `bluetooth-central` | iOS apps that want Bluetooth while in the background (the app's decision). |

How the client behaves for each Bluetooth state:

| State | Behaviour |
|---|---|
| Unknown, resetting, or the permission prompt not answered yet | Waits up to 10 seconds for Bluetooth to power on, then throws ``LaMarzoccoError/bluetoothUnavailable(_:)``. |
| Access denied or restricted | Fails at once with ``LaMarzoccoError/bluetoothUnavailable(_:)``. |
| Powered off | Fails at once with ``LaMarzoccoError/bluetoothUnavailable(_:)``. |
| Unsupported | Fails at once with ``LaMarzoccoError/bluetoothUnavailable(_:)``. |
| Powered on and allowed | Proceeds. |

Creating the transport touches no Bluetooth API. The system's permission prompt
appears on the first Bluetooth operation. Read `BluetoothAuthorization.current`
(from `AngstromBluetooth`) to gate your UI; it never prompts. On iOS the library
is foreground-only: background scanning needs a service filter, and the service
that hosts the machine's characteristics is not yet verified. An app that
declares `bluetooth-central` keeps receiving shot-counter notifications in the
background; the library takes no app-lifecycle actions.

## Putting it together with AngstromUI

`LaMarzoccoMachine` owns no transport. The app builds the Bluetooth client, and
persists its identity, then hands both clients to the machine:

```swift
import Angstrom
import AngstromBluetooth
import AngstromUI

let transport = BluetoothTransport.coreBluetooth()            // create once per process and share
let token = try await cloud.bluetoothAuthToken(serial: serial) // or a Keychain copy / QR label
let ble = LaMarzoccoBluetoothClient(transport: transport, peripheral: storedPeripheralID, token: token!)
let machine = LaMarzoccoMachine(serialNumber: serial, client: cloud, bluetooth: ble, snapshot: saved)
```

``LaMarzoccoCloudClient/bluetoothAuthToken(serial:)`` returns `nil` when the
cloud has no token. In a real app, fall back to a Keychain copy, the pairing-mode
read or the QR label instead of force-unwrapping.

Either client may be `nil`. With a Bluetooth client, `setPower(on:)`,
`setSteam(on:)`, `setSteamTargetLevel(_:)`, `setCoffeeTargetTemperature(celsius:)`,
`setSteamTargetTemperature(celsius:)` and `setSmartStandby(enabled:minutes:after:)`
try Bluetooth first and fall back to the cloud (on machines that report auto
standby, `setSmartStandby` is cloud-only). `refreshDashboardFromBluetooth()` and
`startShotCounter()` keep `dashboard` current without the cloud. These
Bluetooth-only operations (with `refreshModelFromBluetooth()` and
`stopShotCounter()`) never need a cloud client; without a Bluetooth client the
two refreshes throw ``LaMarzoccoError/bluetoothConnectionFailed(_:)`` and
`startShotCounter()` returns `false`. Every other operation is cloud-only and
throws ``LaMarzoccoError/cloudOnlyFunctionality`` without a cloud client, even
where it is also model-gated. `stop()` is a no-op without a cloud client.
