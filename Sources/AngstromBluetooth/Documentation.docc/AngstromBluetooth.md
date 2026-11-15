# ``AngstromBluetooth``

The CoreBluetooth transport for Angstrom's La Marzocco Bluetooth client.

## Overview

`AngstromBluetooth` is the only Angstrom module that imports CoreBluetooth. It adds two public
symbols to types that live in the core `Angstrom` module:

- `BluetoothTransport.coreBluetooth(showPowerAlert:)` builds the transport that
  `LaMarzoccoBluetoothClient` (and the `AngstromUI` device layer) talks to the machine through.
- `BluetoothAuthorization.current` reads the app's Bluetooth authorization without prompting.

Apps that use only the cloud API never link this module, so they never link CoreBluetooth and
never need a Bluetooth usage description.

```swift
import Angstrom
import AngstromBluetooth

// Create once per process and share it between clients.
let transport = BluetoothTransport.coreBluetooth()

let machines = try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport)
```

### Creating the transport

`BluetoothTransport.coreBluetooth(showPowerAlert: Bool = false)` returns an opaque
`BluetoothTransport`. Creating it touches no Bluetooth API. The `CBCentralManager`, and with it
the system's Bluetooth permission prompt, is allocated by the first Bluetooth operation (a scan,
a connect, or an availability check), so a process that never uses Bluetooth never prompts.

`showPowerAlert` maps to `CBCentralManagerOptionShowPowerAlertKey`: when `true`, the system
offers to turn Bluetooth on if it is off when the manager is created.

Each call creates an independent central with its own manager, so create one transport per
process and pass it to every client.

The transport scans in the foreground with no service filter, connects without system
auto-reconnect (the client owns reconnection and re-authentication), and bounds every
operation with the client's own timeouts.

### Checking authorization

`BluetoothAuthorization.current` mirrors `CBManager.authorization`. It is a class property that
allocates no manager, so reading it never shows the permission prompt. Use it to gate Bluetooth
UI before the first Bluetooth operation:

```swift
switch BluetoothAuthorization.current {
case .notDetermined: showExplainerBeforeFirstUse()
case .denied, .restricted: showBluetoothDisabledHint()
case .allowedAlways: break
}
```

Once Bluetooth is in use, a denied or restricted authorization, a powered-off radio, or an
unsupported device surfaces as `LaMarzoccoError.bluetoothUnavailable(_:)`. While the state is
still settling (`unknown`, `resetting`, or a prompt that has not been answered yet) the client
waits up to 10 seconds for Bluetooth to power on before failing.

### App requirements

| Item | Who needs it |
|---|---|
| `NSBluetoothAlwaysUsageDescription` (Info.plist string) | Every app or tool that uses `AngstromBluetooth`, on macOS and iOS. On iOS a missing key terminates the app at first CoreBluetooth use. |
| `com.apple.security.device.bluetooth` (entitlement) | Only App-Sandboxed macOS apps. |
| `UIBackgroundModes` → `bluetooth-central` | iOS apps that want Bluetooth while in the background (the app's decision). |

On iOS the library is foreground-only: background scanning needs a service filter, and the
service hosting the machine's characteristics is not yet verified. An app that declares
`bluetooth-central` keeps receiving shot-counter notifications while in the background; the
library takes no app-lifecycle actions.
