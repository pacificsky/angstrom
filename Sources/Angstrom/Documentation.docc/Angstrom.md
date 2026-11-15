# ``Angstrom``

A Swift library for the La Marzocco cloud API and Bluetooth, for iOS and macOS.

## Overview

Angstrom is an independent Swift port of the La Marzocco customer-app cloud
protocol and authentication scheme, and of the machine's Bluetooth protocol,
reimplemented from [`pylamarzocco`](https://github.com/zweckj/pylamarzocco) by
Josef Zweck — the Python library behind the Home Assistant integration.

The package ships three products:

- **``Angstrom``** — the stateless ``LaMarzoccoCloudClient`` actor. It owns the
  transport, token lifecycle, typed dashboard/settings/scheduling reads, the
  command surface, and a STOMP websocket for live updates. Usable standalone from
  a CLI or server.
- **`AngstromUI`** — an optional `@MainActor @Observable` device layer
  (`LaMarzoccoMachine`) that retains state, merges live pushes, and applies
  optimistic updates for SwiftUI, and routes the Bluetooth-capable commands over
  Bluetooth first when given a Bluetooth client.
- **`AngstromBluetooth`** — the CoreBluetooth transport
  (`BluetoothTransport.coreBluetooth(showPowerAlert:)`) for
  ``LaMarzoccoBluetoothClient``. It is the only product that imports
  CoreBluetooth, so cloud-only apps never link it. See <doc:Bluetooth>.

> Important: Unofficial. Not affiliated with, endorsed by, or sponsored by
> La Marzocco S.r.l. Trademarks belong to their respective owner and are used
> only to describe what this library talks to.

### Token storage is your responsibility

The client keeps access tokens in memory and never touches disk. Persist the
``InstallationKey`` (e.g. in the Keychain) and the `isRegistered` flag yourself,
and pass them back when constructing the client on the next launch.

The same applies to Bluetooth: the library never persists the
``BluetoothAuthToken`` or the ``BluetoothPeripheralID``. Keep the token's
`rawValue` in the Keychain and the peripheral identifier locally.

## Topics

### Essentials

- <doc:GettingStarted>
- ``LaMarzoccoCloudClient``
- ``InstallationKey``

### Machines & Power

- ``Machine``
- ``PowerState``
- ``Model``
- ``DeviceType``

### Dashboard & Widgets

- ``Dashboard``
- ``Widget``
- ``WidgetKind``
- ``DashboardUpdate``

### Settings & Scheduling

- ``MachineSettings``
- ``MachineSchedule``
- ``WakeUpSchedule``
- ``FirmwareInfo``

### Statistics

- ``ThingStatistics``
- ``StatWidget``
- ``CoffeeAndFlushTrend``
- ``LastCoffeeList``

### Commands

- ``CommandResponse``
- ``CommandStatus``

### Bluetooth

- <doc:Bluetooth>
- ``LaMarzoccoBluetoothClient``
- ``BluetoothTransport``
- ``BluetoothPeripheralID``
- ``BluetoothAuthToken``
- ``DiscoveredPeripheral``
- ``BluetoothAuthorization``
- ``BluetoothAvailability``
- ``BluetoothReadSetting``
- ``BluetoothMachineCapabilities``
- ``BluetoothBoilerType``
- ``BluetoothBoilerDetails``
- ``BluetoothSmartStandbyDetails``
- ``BluetoothCommandStatus``
- ``ShotCounterEvent``
- ``BluetoothShotCounterUpdate``
- ``BluetoothBrewingState``
- ``BluetoothBrewingData``
- ``BluetoothMachineTelemetry``
- ``BluetoothJSONValue``
- ``BluetoothDashboardState``
- ``RawBluetoothFrame``
- ``BluetoothGATTService``
- ``BluetoothGATTCharacteristic``

### Errors

- ``LaMarzoccoError``
