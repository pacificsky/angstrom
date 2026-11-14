# Angstrom Bluetooth — compatibility specification

> **Status:** frozen specification for the Bluetooth (BLE) port. **Target release:** Angstrom
> **v2.0.0**. **Reference of record:** `pylamarzocco` **v2.5.6, commit `4c639ee`** — the same
> watermark as the cloud port (`UPSTREAM.md`). Angstrom baseline: `main` @ `e1bc403` (v1.7.0).
>
> **Amended 2026-11-14** (orchestrator, from the BT-W0-01 reviews): §3.10 int, double and string
> rules; §7.1 `Placeholder.swift` row. From the BT-W0-03 reviews: §4.13 (availability stream created
> at loop start), §6.17 (fake hooks `connectPeripheralIDs`, `connectFailure`,
> `availabilitySubscriberCount`, `requestedTimeouts`; cancellation rule), §9.4 C51.
>
> This document is the single source of truth for every implementation agent. Agents work in
> parallel and do not talk to each other, so:
>
> - **§6 (Public API contracts) and the internal signatures marked _frozen_ are binding.** An agent
>   may add `private`/`fileprivate` helpers and extra tests. It may **not** rename, re-type,
>   re-order parameters of, or change the access level of any frozen declaration. If a contract
>   cannot be implemented as written, the agent stops and reports. It does not improvise.
> - **§7 (File map) is binding for ownership.** An agent edits only the files its work package owns.
>   Edits to shared existing files are exactly the edits listed there.
> - Behaviour comes from §3 and §4. Where they say "parity", the upstream line cited is the
>   reference. Where they say "**divergence D*n***", §12 has the rationale.
> - **MUST / MUST NOT / SHOULD / MAY** are used in the RFC 2119 sense.
> - **UNVERIFIED** marks a fact the upstream source cannot settle. Each one names what would settle
>   it, and §14 gives the default to implement until then.

## 0. Conventions

### 0.1 Citation abbreviations

Upstream paths are relative to the clone of `pylamarzocco` at `4c639ee`. Line numbers are
**verbatim** for that commit.

| Abbrev | Upstream path |
|---|---|
| `BT` | `src/pylamarzocco/clients/_bluetooth.py` (747 lines) |
| `MBT` | `src/pylamarzocco/models/_bluetooth.py` (213 lines) |
| `MACH` | `src/pylamarzocco/devices/_machine.py` |
| `THING` | `src/pylamarzocco/devices/_thing.py` |
| `CONST` | `src/pylamarzocco/const.py` |
| `EXC` | `src/pylamarzocco/exceptions.py` |
| `GEN` | `src/pylamarzocco/models/_general.py` |
| `CLOUD` | `src/pylamarzocco/clients/_cloud.py` |
| `README` | `README.md` |
| `LEG` | `docs/legacy/bluetooth_characteristics.md` |
| `TBC` | `tests/test_bluetooth_client.py` |
| `TBD` | `tests/test_bluetooth_dashboard.py` |
| `TM` | `tests/test_machine.py` |
| `TT` / `TMO` / `TCC` | `tests/test_thing.py` / `tests/test_models.py` / `tests/test_cloud_client.py` |
| `CONF` | `tests/conftest.py` |
| `SNAP` | `tests/__snapshots__/test_bluetooth_dashboard.ambr` |
| `REC` | `tests/fixtures/machine/shot_counter_2026-10-05.txt` (85 lines) |
| `BRC` | `bleak_retry_connector/__init__.py` **4.4.4** (locked dependency, `uv.lock:163-164`) |
| `BLEAK` / `B-CL` / `B-PD` / `B-CM` / `B-SC` | `bleak` **1.1.1** (`uv.lock:140-141`): `__init__.py` / `backends/corebluetooth/client.py` / `…/PeripheralDelegate.py` / `…/CentralManagerDelegate.py` / `…/scanner.py` |

Angstrom paths are repo-relative (e.g. `Sources/Angstrom/Models.swift:191`).

### 0.2 Research inputs

This spec consolidates six research notes, kept in the planning scratchpad: `01-protocol`,
`02-shot-counter`, `03-device-layer`, `04-tests`, `05-angstrom-seams`, `06-corebluetooth`. Where
the notes disagreed, the upstream source was re-read and the source won. The disagreements and how
they were resolved are listed in §14.3. The notes are **not** in the repository and are not needed
to implement this spec: every normative fact is stated here. References to them ("note 06 §3.3")
are provenance only.

### 0.3 Glossary

- **Link**: one live BLE connection to one machine. A reconnect creates a new link object.
- **Authenticated link**: a link whose token write was confirmed by an `0x01` auth read (§3.4).
- **Request**: one write→read pair: a read-setting or a command (§3.5–§3.7).
- **Shot counter (SC)**: the persistent notification subscription on `0e0b…` (§3.8).
- **Overlay**: the BLE brewing state that AngstromUI renders on top of the cloud `CMMachineStatus`
  widget (§4.19).
- **Base dashboard**: AngstromUI's dashboard *without* the overlay. It holds cloud data, in-place BLE
  refreshes, telemetry mode changes and optimistic updates.

---

## 1. Scope

### 1.1 What "full Bluetooth compatibility with pylamarzocco v2.5.6" means

Every behaviour of upstream's `LaMarzoccoBluetoothClient` (`BT`), its models (`MBT`), the BLE
enums and exceptions, the cloud `bleAuthToken` field, and the Bluetooth paths of the device layer
(`THING`, `MACH`) has a Swift counterpart in Angstrom. That counterpart either reproduces the
upstream semantics byte-for-byte on the wire and state-for-state in the logic, or is an **explicit,
documented divergence** (§12). The parity inventory (§2) lists every symbol, and nothing may be
silently missing.

Goals:

1. **Wire parity.** Identical GATT operations, byte-identical request frames (including JSON key
   order), identical response parsing, identical auth handshake (§3).
2. **Lifecycle parity.** Lazy connect, request serialisation, 30 s idle disconnect, drop-on-error,
   shot-counter reconnect with 1→60 s backoff and the 3-auth-failure cut-off (§4).
3. **Shot-counter parity.** The same brewing state machine, replay drop, telemetry routing and
   start-time estimate. Upstream's recorded Linea Micra session must reproduce exactly (§9).
4. **Device-layer parity.** The same six BLE-first commands with the same cloud-fallback rules,
   dashboard-from-Bluetooth, model-from-Bluetooth, and the shot-counter overlay with its 60 s
   expiry, composed with Angstrom's wholesale widget replacement (§4.15–§4.20).
5. **Angstrom conventions.** Every thrown error is a `LaMarzoccoError` (with the one existing
   exception of `CancellationError`, §6.4). Parsing is tolerant. The core client is an `actor`. The
   library never persists or logs the BLE token. Swift 6 strict concurrency. Zero runtime
   dependencies.
6. **Testability without hardware.** All protocol logic runs against an in-memory fake transport
   in CI. Only one thin CoreBluetooth adapter is hardware-only (§5, §9).

### 1.2 Non-goals

| Non-goal | Why |
|---|---|
| The legacy (gen-1, pre-2025) BLE protocol (`050b…`/`090b…`, base64 auth) | Upstream removed it in `0ad74e2`. `LEG` is history only. |
| Home Assistant adapter or proxy switching (`ble_device_callback`, `BT:146,245-246`) | Apple has one adapter. The adapter re-resolves the peripheral by identifier on every connect (§2.1, D3). |
| Bluetooth for grinders (Pico, Swan) and the Strada X | Upstream has no BLE path: every grinder method is `@cloud_only` (`src/pylamarzocco/devices/_grinder.py:32-248`), and `BT_MODEL_PREFIXES` has no grinder or Strada prefix (`BT:46`). |
| Multi-group BLE keys (`…Group2…`) | Upstream models only `Group1` (`MBT:94-123`). |
| OS-level pairing or bonding | Upstream never calls `pair()`, and CoreBluetooth cannot pair explicitly (`B-CL:97-98,205`). |
| Linux support | The core is already Apple-only (CryptoKit, `URLSessionWebSocketTask`). |
| iOS background scanning, state restoration, `bluetooth-central` lifecycle management | Background scanning needs a service UUID, which is UNVERIFIED (U1). Deferred: §8.6, Q14. |
| Mapping the BLE smart-standby read into `MachineSchedule` | Upstream never does it (`MACH:351` "excluding standby settings"). The read is exposed on the client only. |
| Persisting the BLE token or peripheral identity in the library | House rule. Persistence belongs to the consumer (§8.7). |

### 1.3 Supported machines

| Model | BLE name prefix (discovery) | BLE `machineCapabilities.family` → `Model` | Shot counter | Evidence |
|---|---|---|---|---|
| Linea Micra | `MICRA` | `"MICRA"` → `.lineaMicra` | yes (recorded) | `REC:1`, `TBC:342`, `TMO:412` |
| Linea Mini (original) | `MINI` or `LINEA` (UNVERIFIED, U3) | `"LINEA"` → `.lineaMini` | per README | `CONST:209-210`, `TMO:410`, `README:229` |
| Linea Mini R | `MINI` or `LINEA` (UNVERIFIED) | `"LINEAMINI2023"` → `.lineaMiniR` | per README | `CONST:206`, `TMO:411`, `README:229` |
| GS3 AV | `GS3` | `"GS3"` → `.gs3AV` | per README | `CONST:202-203`, `TMO:413`, `README:229` |
| GS3 MP | `GS3` | `"GS3MP"` → `.gs3MP` (whether MP reports `GS3` or `GS3MP` is UNVERIFIED, U13) | per README | `CONST:204`, `README:229` |
| GS3 (cloud `modelCode: "GS3"`) | `GS3` | BLE `"GS3"` maps to `.gs3AV`, **not** `.gs3` (parity with `e0f0249`) | — | `CONST:202-203` |
| Strada X, Pico, Swan | none | `STRADAX`/`PICOGRINDER`/`SWANGRINDER` map, but no BLE path is used | no | `BT:46` |

Shot-counter support is detected at runtime by the presence of characteristic `0e0b…` (§4.9).
The cloud flag `Machine.shotCounterSupported` (already ported, `Sources/Angstrom/Models.swift:32`)
is **informational only**. Nothing gates on it (parity: `TM:745-762`).

### 1.4 Capability matrix (operation × transport)

Legend: **BT→C** = Bluetooth first, cloud fallback (§4.16). **C** = cloud only (throws
`.cloudOnlyFunctionality` without a cloud client). **BT** = Bluetooth only (throws
`.bluetoothConnectionFailed("Bluetooth client not initialized")` without a BLE client).

| Operation (AngstromUI `LaMarzoccoMachine`) | Bluetooth wire op | Cloud command | Routing | Gate | Upstream |
|---|---|---|---|---|---|
| `setPower(on:)` | `MachineChangeMode` | `CoffeeMachineChangeMode` | BT→C | — | `MACH:494-509` |
| `setSteam(on:)` | `SettingBoilerEnable` | `CoffeeMachineSettingSteamBoilerEnabled` | BT→C | — | `MACH:764-782` |
| `setSteamTargetLevel(_:)` | `SettingBoilerTarget` with 126/128/131 | `CoffeeMachineSettingSteamBoilerTargetLevel` | BT→C | `Model.steamLevelModels` | `MACH:784-802` |
| `setCoffeeTargetTemperature(celsius:)` | `SettingBoilerTarget` (`CoffeeBoiler1`) | `CoffeeMachineSettingCoffeeBoilerTargetTemperature` | BT→C | — | `MACH:804-821` |
| `setSteamTargetTemperature(celsius:)` | `SettingBoilerTarget` (`SteamBoiler`) | `CoffeeMachineSettingSteamBoilerTargetTemperature` | BT→C | `Model.steamTemperatureModels` | `MACH:823-841` |
| `setSmartStandby(enabled:minutes:after:)` when `schedule.autoStandBySupported != true` | `SettingSmartStandby` | `CoffeeMachineSettingSmartStandBy` | BT→C | — | `MACH:880-892` |
| `setSmartStandby(…)` when `schedule.autoStandBySupported == true` | — | `CoffeeMachineSettingAutoStandBy` | C | — | `MACH:874-878` |
| `refreshDashboardFromBluetooth()` | reads `machineMode`, `isPlumbedIn`, `tankStatus`, `boilers` | — | BT | — | `MACH:350-485` |
| `refreshModelFromBluetooth()` | reads `machineCapabilities` | — | BT | — | `MACH:325-348` |
| `startShotCounter()` / `stopShotCounter()` and shot-counter state | notify `0e0b…` | — | BT | — | `MACH:158-207` |
| Every other command, `refresh*`, `start()`/`stop()` (websocket), statistics, firmware, schedules, grinders | — | yes | C | as today | `MACH:511-981,1051-1092`, `_grinder.py` |

| Data | Bluetooth | Cloud |
|---|---|---|
| Machine mode → `CMMachineStatus.mode/status` | yes (never `Brewing`, `Off`, `nextStatus`, `brewingStartTime`) | yes |
| `CMMachineGroupStatus` | only `mode`, via telemetry and the `setPower` optimistic update | yes |
| Coffee and steam boiler enabled/target, steam level | yes | yes |
| Boiler *current* temperature | `BluetoothBoilerDetails.current` (read, not written to widgets, parity) and telemetry | no |
| Water alarm `CMNoWater` | yes (tank OR plumbed-in) | not in fixtures |
| Plumb-in | read (only feeds the water alarm) | `settings.isPlumbedIn` |
| Model family / capabilities | yes | dashboard identity |
| Smart standby | client read only | `schedule` |
| Live brewing start/stop, timer | shot counter | websocket (~4 s later, `README:225`) |
| Live boiler temperatures, mode, statistics counters | shot-counter telemetry | partially, via websocket |

---

## 2. Parity inventory

Every upstream Bluetooth symbol and behaviour, mapped to its Angstrom counterpart or to an explicit
"not ported" with a reason. Files are in §7. "UI" = `Sources/AngstromUI`. "BT/" =
`Sources/Angstrom/Bluetooth/`.

### 2.1 Client `LaMarzoccoBluetoothClient` (`BT`)

| Upstream (`BT` line) | Angstrom counterpart | File |
|---|---|---|
| `__init__(ble_device, ble_token, ble_device_callback=None)` (`142-181`) | `init(transport:peripheral:token:logHandler:)`. `ble_device_callback`: **not ported**. The adapter re-resolves the `CBPeripheral` from the identifier on every connect (D3). | BT/LaMarzoccoBluetoothClient.swift |
| `is_connected` (`183-186`) | `var isConnected: Bool` (actor-isolated). True only after authentication (D11). | same |
| `register_connection_callback(cb) -> unregister` (`188-206`) | `connectionEvents() -> AsyncStream<ConnectionEvent>`. Cancelling the iteration unregisters (D4). | same |
| `_set_connected` (`208-214`) edge-triggered | `setConnected(_:)`, edge-triggered (§4.8) | same |
| `authentication_failed` (`216-222`) | `var authenticationFailed: Bool` | same |
| `shot_counter_active` (`224-231`) | `var shotCounterActive: Bool` | same |
| `_ensure_connected(use_services_cache)` (`233-269`) | `ensureConnected(refresh:)` (frozen internal, §4.2) | same |
| `_reset_disconnect_timer` / `_auto_disconnect` (`271-291`) | `resetIdleTimer()` + idle task (§4.6) | same |
| `_disconnect_internal` (`293-311`) | `disconnectInternal(fromIdleTimer:)` | same |
| `_drop_connection` (`313-317`) | `dropConnection(fromIdleTimer:)` / `dropConnectionInBackground()` | same |
| `disconnect()` (`319-325`) | `disconnect() async` | same |
| `start_shot_counter(callback, connection_callback, telemetry_callback) -> bool` (`327-362`) | `startShotCounter() async throws -> Bool` + `shotCounterEvents() -> AsyncStream<ShotCounterEvent>` (D4) | BT/LaMarzoccoBluetoothClient+ShotCounter.swift |
| `stop_shot_counter()` (`364-371`) | `stopShotCounter() async` | same |
| `_disable_shot_counter` (`373-394`) | `disableShotCounter() -> Bool` (returns "was subscribed") | same |
| `_stop_notify_internal` (`396-401`) | `stopNotifyInternal() async` | same |
| `_subscribe_shot_counter` (`403-439`) | `subscribeShotCounter() async throws -> Bool` | same |
| `_handle_shot_counter_notification` (`441-465`) | `handleShotCounterNotification(_:)` | same |
| `_on_bleak_disconnected` (`467-473`) | `handleLinkEvent(.disconnected, from:)` with a link-identity guard | BT/LaMarzoccoBluetoothClient.swift |
| `_handle_connection_lost` (`475-486`) | `handleConnectionLost()` | same |
| `_reconnect_shot_counter` (`488-520`) | `reconnectLoop()` (§4.13) | +ShotCounter |
| `discover_devices(scanner=None)` (`522-537`) | `static discoverMachines(transport:duration:)` (+ Angstrom-only unfiltered `scanAll`, §4.14) | BT/LaMarzoccoBluetoothClient+Discovery.swift |
| `read_token(address_or_ble_device)` (`539-547`) | `static readToken(transport:peripheral:) -> BluetoothAuthToken` | same |
| `address` (`549-553`) | `nonisolated let peripheral: BluetoothPeripheralID`. It is a CoreBluetooth UUID, **not** a MAC (D3). | main |
| `get_machine_mode` (`555-560`) | `machineMode() -> MachineMode` | BT/LaMarzoccoBluetoothClient+Requests.swift |
| `get_machine_capabilities` (`562-568`) | `machineCapabilities() -> BluetoothMachineCapabilities` | same |
| `get_tank_status` (`570-575`) | `tankStatus() -> Bool` | same |
| `get_plumbed_in` (`577-582`) | `isPlumbedIn() -> Bool` | same |
| `get_boilers` (`584-588`) | `boilers() -> [BluetoothBoilerDetails]` | same |
| `get_smart_standby_settings` (`590-594`) | `smartStandby() -> BluetoothSmartStandbyDetails` | same |
| `set_power(enabled)` (`596-600`) | `setPower(on:) -> BluetoothCommandStatus` | same |
| `set_steam(enabled)` (`602-608`) | `setSteam(on:) -> BluetoothCommandStatus` | same |
| `set_smart_standby(enabled, mode, minutes)` (`610-618`) | `setSmartStandby(enabled:mode:minutes:)` | same |
| `set_temp(boiler, temperature)` (`620-626`) | `setTemperature(boiler:celsius:)` | same |
| `_authenticate` (`628-653`) | `authenticate(_:)` (frozen internal, §4.3) | main |
| `__read_value_from_machine` (`655-657`) | `readSetting(_:) -> String` | +Requests |
| `_read_bluetooth_message` (`659-671`) / `__write_bluetooth_message` (`674-700`) | `request(_:frame:)` + `BluetoothCodec` (§3.5) | +Requests, BT/BluetoothCodec.swift |
| `__send_command` (`702-710`) | `sendCommand(_:)` | +Requests |
| `_resolve_characteristic` (`712-747`) | `resolve(_:on:)` (§4.5, D7) | +Requests |
| `disconnect_on_exception` decorator (`114-136`) | the request wrapper `request(_:frame:)` (§4.4) | +Requests |
| `_BrewingTracker` (`77-111`) | `package struct BrewingTracker` | BT/BrewingTracker.swift |
| `_parse_bool` (`62-64`) | `BluetoothWireCoercion.parseBool(_:)` | BT/BluetoothWireCoercion.swift |
| `_safe_call` (`67-74`) | not needed: there are no user callbacks; stream consumers can't throw into the client (D4) | — |
| `_utcnow` (`57-59`) | `BluetoothTransport.now` (injected clock) | BT/BluetoothTransport.swift |
| logging (`_logger.*`) | optional `logHandler`. Messages are informative, not contract, and **never contain the token** | main |

### 2.2 Constants (`BT:40-54`)

| Upstream (verbatim) | Angstrom | File |
|---|---|---|
| `READ_CHARACTERISTIC = "0a0b7847-e12b-09a8-b04b-8e0922a9abab"` | `BluetoothConstants.readCharacteristic` | BT/BluetoothConstants.swift |
| `WRITE_CHARACTERISTIC = "0b0b7847-e12b-09a8-b04b-8e0922a9abab"` | `.writeCharacteristic` | same |
| `GET_TOKEN_CHARACTERISTIC = "0c0b7847-e12b-09a8-b04b-8e0922a9abab"` | `.tokenCharacteristic` | same |
| `AUTH_CHARACTERISTIC = "0d0b7847-e12b-09a8-b04b-8e0922a9abab"` | `.authCharacteristic` | same |
| `SHOT_COUNTER_CHARACTERISTIC = "0e0b7847-e12b-09a8-b04b-8e0922a9abab"` | `.shotCounterCharacteristic` | same |
| `BT_MODEL_PREFIXES = ("MICRA", "MINI", "LINEA", "GS3")` | `LaMarzoccoBluetoothClient.machineNamePrefixes` (public) | same + main |
| `IDLE_TIMEOUT = 30  # seconds` | `BluetoothTiming.idleTimeout = .seconds(30)` | same |
| `AUTH_SUCCESS = b"\x01"` | `BluetoothConstants.authSuccess = Data([0x01])` | same |
| `AUTH_READ_ATTEMPTS = 10` | `BluetoothTiming.authReadAttempts = 10` | same |
| `AUTH_READ_INTERVAL = 0.05  # seconds` | `BluetoothTiming.authReadInterval = .milliseconds(50)` | same |
| `MAX_AUTH_FAILURES = 3` | `BluetoothTiming.maxAuthFailures = 3` | same |
| `RECONNECT_INITIAL_DELAY = 1  # seconds` | `BluetoothTiming.reconnectInitialDelay = .seconds(1)` | same |
| `RECONNECT_MAX_DELAY = 60  # seconds` | `BluetoothTiming.reconnectMaxDelay = .seconds(60)` | same |
| `establish_connection(..., max_attempts=3)` (`BT:252`) | `BluetoothTiming.connectAttempts = 3` | same |
| `BLEAK_TIMEOUT = 20.0` (`BRC:102`) | `BluetoothTiming.connectTimeout = .seconds(20)` | same |

### 2.3 Models (`MBT`) and enums (`CONST`)

| Upstream | Angstrom | File |
|---|---|---|
| `BluetoothMachineCapabilities` (`MBT:22-39`) | `public struct BluetoothMachineCapabilities` | BT/BluetoothModels.swift |
| `BluetoothBoilerDetails` (`MBT:42-49`) | `public struct BluetoothBoilerDetails` (`target`/`current` are `Double`, D9) | same |
| `BluetoothSmartStandbyDetails` (`MBT:51-57`) | `public struct BluetoothSmartStandbyDetails` | same |
| `BluetoothCommandStatus` (`MBT:59-65`) | `public struct BluetoothCommandStatus` + `isSuccess` | same |
| `_known_machine_mode` (`MBT:68-70`) | telemetry decoder drops `MachineMode.other` (→ `nil`) | BT/BluetoothShotCounterModels.swift |
| `_PartialNotification` (`MBT:73-87`): `is_empty`, `merge` | `isEmpty` / `merging(_:)` on both partial types | same |
| `BluetoothBrewingData` + `derive_state` (`MBT:90-163`) | `public struct BluetoothBrewingData` + `deriveState(receivedAt:)` | same |
| `BluetoothShotCounterUpdate` (`MBT:166-188`) | `public struct BluetoothShotCounterUpdate` | same |
| `BluetoothMachineTelemetry` (`MBT:191-213`) | `public struct BluetoothMachineTelemetry` (`machineStatistics: BluetoothJSONValue?`) | same |
| `BluetoothReadSetting` (`CONST:322-330`) | `public enum BluetoothReadSetting: String, CaseIterable` | BT/BluetoothEnums.swift |
| `BluetoothBrewingState` (`CONST:333-339`) | `public enum BluetoothBrewingState: String` | same |
| `BoilerType` (`CONST:307-311`) | `public enum BluetoothBoilerType` (`.coffee`, `.steam`, `.other`) | same |
| `SmartStandByType` (`CONST:260-264`) | **reuse** `SmartStandbyAfter` (identical raw values, `Sources/Angstrom/Enums.swift:514-517`) | — |
| `MachineMode` / `MachineState` / `BoilerStatus` (`CONST:11-31,267-275`) | **reuse** existing enums (`Enums.swift:151-267`) | — |
| `SteamTargetLevel` (`CONST:141-146`) | **reuse** `SteamLevel` | — |
| `STEAM_LEVEL_MAPPING` (`MACH:58-62`) | `SteamLevel.bluetoothTargetTemperature: Int` | BT/BluetoothEnums.swift |
| `_steam_level_from_temperature` (`MACH:78-84`) | `SteamLevel.init(bluetoothTargetTemperature: Double)` | same |
| `BLE_MACHINE_STATE` (`MACH:65-69`) | `MachineState.init(bluetoothMode:)` | same |
| `BLE_BOILER_STATUS` (`MACH:71-75`) | `BoilerStatus.init(bluetoothMode:)` | same |
| `ModelName.from_string` BLE aliases (`CONST:198-218`) | `Model.init?(bluetoothFamily:)`. `Model.match` (cloud) is **unchanged** (D8). | same |
| `ModelCode[family.name]` (`MACH:344`) | not needed: `Model` is both name and code in Angstrom | — |
| `STEAM_LEVEL_MODELS` (`CONST:182`) | `Model.steamLevelModels` (moved from AngstromUI to core) | same |
| `models_supported((GS3, GS3_AV, GS3_MP, STRADA_X))` (`MACH:823`) | `Model.steamTemperatureModels` (moved to core) | same |

### 2.4 Exceptions (`EXC`)

| Upstream | Angstrom |
|---|---|
| `BluetoothConnectionFailed(LaMarzoccoError)` (`EXC:20-21`) | `LaMarzoccoError.bluetoothConnectionFailed(String)`, plus `.bluetoothUnavailable(BluetoothAvailability)` (D10) |
| `BluetoothAuthenticationFailed(BluetoothConnectionFailed)` (`EXC:46-47`) | `LaMarzoccoError.bluetoothAuthenticationFailed`. The subclass relation is modelled by `isBluetoothConnectionFailure` (§6.4). |
| `bleak.exc.BleakError` (third party) | `.bluetoothConnectionFailed(String)` |
| bare `TimeoutError` from a request-phase GATT op | `LaMarzoccoError.bluetoothTimedOut(String)` |
| `CloudOnlyFunctionality` (`EXC:28-35`) | `LaMarzoccoError.cloudOnlyFunctionality` |
| `UnsupportedModel` (`EXC:38-39`) | existing `.unsupportedModel(String)` |
| `ValueError` / `JSONDecodeError` / `UnicodeDecodeError` / `IndexError` / mashumaro errors from decoding | existing `.decoding(String)` |

### 2.5 Device layer (`THING`, `MACH`)

| Upstream | Angstrom (`LaMarzoccoMachine`, UI) | File |
|---|---|---|
| `LaMarzoccoThing.__init__(serial, cloud_client=None, bluetooth_client=None)` (`THING:73-90`) | new `init(serialNumber:client:bluetooth:snapshot:)` with an optional cloud client. The existing `init(serialNumber:client:snapshot:)` is kept. | UI/LaMarzoccoMachine.swift |
| `bluetooth_client_available` (`THING:99-102`) | `var hasBluetoothClient: Bool` | same |
| `cloud_client_available` (`THING:104-107`) | `var hasCloudClient: Bool` | same |
| `bluetooth_connected` (`THING:109-114`) | `isBluetoothConnected: Bool` (observable, D11) | same |
| `register_bluetooth_connection_callback` (`THING:116-126`) | `bluetoothConnectionEvents() async -> AsyncStream<ConnectionEvent>` (an already-finished stream without a client) | UI/LaMarzoccoMachine+BluetoothConnection.swift |
| `cloud_only` decorator (`THING:27-38`) | throwing `client` accessor → `.cloudOnlyFunctionality` | UI/LaMarzoccoMachine.swift |
| `models_supported` (`THING:41-67`) | existing `requireModel` | same |
| `_dashboard_config_updated` hook (`THING:181-182`, `MACH:316-323`) | `setBaseDashboard`/`updateBaseDashboard` + `renderDashboard()` (base + overlay, D12) | same |
| `_widget(cls)` (`THING:184-186`) | `Dashboard.machineStatus` etc. (existing accessors) | — |
| `get_model_info_from_bluetooth` (`MACH:325-348`) | `refreshModelFromBluetooth()` | UI/LaMarzoccoMachine+BluetoothDashboard.swift |
| `get_dashboard_from_bluetooth` (`MACH:350-485`) | `refreshDashboardFromBluetooth()` + pure `Dashboard.applyingBluetoothState(_:model:)` | same + BT/Dashboard+Bluetooth.swift |
| `_update_machine_mode_widgets` (`MACH:487-492`) | existing `Dashboard.settingMachineMode(_:)` (`Sources/Angstrom/Optimistic.swift:31`) | — |
| `set_power` / `set_steam` / `set_steam_level` / `set_coffee_target_temperature` / `set_steam_target_temperature` / `set_smart_standby` (`MACH:494-509,764-841,870-892`) | the existing six methods, routed through `bluetoothFirst` | UI/LaMarzoccoMachine.swift + UI/LaMarzoccoMachine+BluetoothCommands.swift |
| `__bluetooth_command_with_cloud_fallback` (`MACH:983-1049`) | `bluetoothFirst(bluetooth:cloud:)` (frozen internal, §4.16) | +BluetoothCommands |
| `BLE_BREWING_STATE_TIMEOUT = 60  # seconds` (`MACH:88`) | `bluetoothBrewingStateTimeout = .seconds(60)` | UI main |
| `ble_brewing_update` (`MACH:132-135`) | `bluetoothBrewingUpdate: BluetoothShotCounterUpdate?` | UI main |
| `bluetooth_telemetry` (`MACH:137-143`) | `bluetoothTelemetry: BluetoothMachineTelemetry` | UI main |
| `last_shot_time` (`MACH:145-148`) | `lastShotTime: TimeInterval?` | UI main |
| `bluetooth_shot_counter_active` (`MACH:150-156`) | `isShotCounterActive: Bool` | UI main |
| `connect_bluetooth_shot_counter(update_callback, telemetry_callback) -> bool` (`MACH:158-191`) | `startShotCounter() async throws -> Bool` + `bluetoothEvents()` | +ShotCounter |
| `disconnect_bluetooth_shot_counter()` (`MACH:193-207`) | `stopShotCounter() async` | +ShotCounter |
| `_on_shot_counter_update` / `_on_shot_counter_connection` / `_on_bluetooth_telemetry` (`MACH:209-241`) | `handleShotCounterEvent(_:)` | +ShotCounter |
| `_drop_ble_brewing_state` / `_clear_ble_brewing_state` / `_apply_ble_brewing_state` (`MACH:243-246,273-314`) | `clearBluetoothBrewingState(notify:)` + `Dashboard.overlayingBluetoothBrewing(_:)` | +ShotCounter, BT/Dashboard+Bluetooth.swift |
| `_notify_shot_counter_listeners` / `_notify_dashboard_listeners` (`MACH:248-271`) | `bluetoothEvents()` stream + `@Observable` state. The synthesized websocket-config fallback is **not ported** (D13). | +ShotCounter |
| `LaMarzoccoGrinder` accepts `bluetooth_client` and never uses it | grinders use `LaMarzoccoMachine`; no grinder method routes through Bluetooth (parity) | — |

### 2.6 Cloud side

| Upstream | Angstrom | File |
|---|---|---|
| `Thing.ble_auth_token` (`GEN:128-130`), on every Thing payload | `LaMarzoccoCloudClient.bluetoothAuthToken(serial:) async throws -> BluetoothAuthToken?`. **Not** a field on `Machine` (D2). | Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift |
| `_mask_bluetooth_token` (`CLOUD:84-92`), debug log masking | the library never logs response bodies. `angcli` already redacts `bleAuthToken` (`cli/Sources/angcli/Output.swift:155-160`) and gains a BLE-frame rule (§10.4) | cli |
| `Thing.shot_counter_supported` (`GEN:131-136`) | existing `Machine.shotCounterSupported` (doc comment reworded) | Models.swift |

### 2.7 Not ported, with reasons

| Upstream | Reason |
|---|---|
| `BleakClientWithServiceCache`, `use_services_cache`, `clear_cache()` | No app-visible GATT cache on Apple. bleak 1.1.1 makes `clear_cache` a no-op that logs `"clear_cache not implemented in bleak version"` (`BRC:198-203`). The *intent* (rediscover) is ported as `discover(…, refresh: true)` (§4.5, §4.9). |
| `ble_device_callback` | D3 |
| `_safe_call` | D4: streams, not callbacks |
| `asyncio.Task(eager_start=True)` re-entrancy semantics (`TBC:1125-1180`) | There are no synchronous callbacks, so re-entrancy cannot happen. The tests are restated in §9. |
| Legacy GATT layout (`LEG`) | §1.2 |
| bleak `pair()` | §1.2 |
| `ThingDashboardWebsocketConfig` synthesis for listeners | D13 |

---

## 3. Wire protocol

Everything in this section is **byte-exact parity**. The golden vectors in §9.3 are normative.

### 3.1 GATT layout

All five characteristics share the suffix `-e12b-09a8-b04b-8e0922a9abab` (`BT:40-44`).
`GATTUUID` normalises them to lowercase.

| Role | UUID (verbatim) | Upstream ops | Write type |
|---|---|---|---|
| Read-setting channel | `0a0b7847-e12b-09a8-b04b-8e0922a9abab` | write `"<setting>\0"`, then read (`BT:655-657`) | with response |
| Command channel | `0b0b7847-e12b-09a8-b04b-8e0922a9abab` | write `json\0`, then read the status from **the same** characteristic (`BT:702-710`) | with response |
| Token (pairing mode) | `0c0b7847-e12b-09a8-b04b-8e0922a9abab` | read once, unauthenticated (`BT:539-547`) | — |
| Auth | `0d0b7847-e12b-09a8-b04b-8e0922a9abab` | write the token, then read 1–10× (`BT:628-653`) | with response |
| Shot counter | `0e0b7847-e12b-09a8-b04b-8e0922a9abab` | subscribe / unsubscribe; never read or written (`BT:396-439`) | — |

- **No service UUID is used anywhere upstream.** Characteristics are resolved by UUID across all
  services (`BT:719-721`, `BT:415-417`). The service hosting `0a0b…`–`0e0b…` is **UNVERIFIED (U1)**.
  Discovery therefore MUST call `discoverServices(nil)`, then `discoverCharacteristics` on every
  service, and match by characteristic UUID. The legacy service `d30a7847-e12b-09a8-b04b-8e0922a9abab`
  (`LEG:10`) MUST NOT be assumed.
- Characteristic property flags and encryption requirements are **UNVERIFIED (U1, U2)**. Upstream
  never inspects `properties` and always writes `response=True` (`BT:639`, `BT:699`).
- Upstream never writes without response. A write-without-response attempt in `07f6f13` was
  reverted the same day (`2c7250f`).
- MTU: upstream has no MTU logic. The system performs long writes and long reads (≤ 512 bytes)
  transparently. Notifications are **not** reassembled (§3.8). The negotiated MTU is diagnostic
  only: the adapter reports it through `attMTU()` (§6.2) and the raw tap (§6.10).

### 3.2 Discovery (`BT:522-537`)

- Scan with no service filter for `duration`, default **5 s** (bleak `discover(timeout=5.0)`,
  `BLEAK:237-268`).
- Keep a peripheral iff its name is non-nil, non-empty and **case-sensitively** starts with one of
  `("MICRA", "MINI", "LINEA", "GS3")` (`BT:46,534`). `"LINEAR_4"` matches (`TBC:1326-1342`).
- Name source: `CBPeripheral.name` (what bleak reports on macOS, `B-SC:162-168`). If that is nil,
  use the advertised `CBAdvertisementDataLocalNameKey`. The fallback is an addition (D3).
- Return every match, de-duplicated by identifier, **in first-seen order**. Upstream returns
  bleak's order (`TBC:1326-1342` asserts scan order).
- No name-to-model or name-to-serial mapping happens (`BT:534`). The real advertised name format is
  **UNVERIFIED (U3)**.

### 3.3 Token acquisition

| Source | Upstream | Angstrom |
|---|---|---|
| Cloud | `Thing.ble_auth_token`, JSON key `"bleAuthToken"`, `str \| None` (`GEN:128-130`). README method 1 reads it from `list_things()` (`README:78-98`). Often `null` in fixtures (`dashboard_micra.json:15`). Placeholder values are 64 × `"0"`. | `LaMarzoccoCloudClient.bluetoothAuthToken(serial:)` (§4.21): `GET /things`, find the element whose `serialNumber == serial`, read top-level `bleAuthToken`. A JSON string that is non-empty → token. `null`, absent or `""` → `nil`. No such serial → `.decoding("things: no thing with serial <serial>")`. |
| Machine in pairing mode | `read_token`: plain `BleakClient` (no retry, bleak default connect timeout 10 s), **no auth**, one `read_gatt_char(0c0b…)`, `token.decode()` (strict UTF-8, **no** NUL stripping), disconnect (`BT:539-547`) | `static readToken(transport:peripheral:)` (§4.14) |
| QR label in the chassis | `README:118-125`: "The scanned value is your Bluetooth token" | the consumer passes the string to `BluetoothAuthToken(_:)` |

Token format and length are **UNVERIFIED (U4)**. The library MUST treat the token as an opaque
string. The meaning of `bleAuthToken: null` is UNVERIFIED.

### 3.4 Authentication handshake (`BT:628-653`)

It runs once per link, immediately after connect + discovery, while the connection gate is held.

1. **Write** `UTF8(token)` (exact bytes, **no** NUL, no base64, no length prefix) to `0d0b…`,
   **with response** (`BT:636-640`; `TBC:448` asserts the first write is `(AUTH_CHAR, b"token")`).
2. **Read** `0d0b…` up to `AUTH_READ_ATTEMPTS = 10` times (`BT:50,642`). Before every read
   **except the first**, sleep `AUTH_READ_INTERVAL = 0.05` s (`BT:51,643-644`; sleep purpose
   `.authPoll`).
3. After **every** read, set `authenticationFailed = (bytes != [0x01])` (`BT:646`). If the bytes are
   exactly `[0x01]` (`AUTH_SUCCESS`, `BT:49`), auth has succeeded: stop reading. `[0x00]`,
   `[0x01,0x00]` and empty all count as "not confirmed".
4. If 10 reads complete without `[0x01]`, throw `.bluetoothAuthenticationFailed` (`BT:653`,
   message `"Bluetooth authentication failed"`).
5. A transport error during the write or any read (including a timeout) throws
   `.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: <description>")`
   (`BT:649-652`). An `.unavailable` transport error maps to `.bluetoothUnavailable` instead (D10).
6. `authenticationFailed` is **not** reset at the start of auth or on transport errors. Only a read
   of `[0x01]` resets it (`BT:646`; `TBC:1305-1323`).
7. If the auth characteristic is missing after discovery, throw
   `.bluetoothConnectionFailed("Could not find characteristic 0d0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")`
   (`BT:633,745-747`).

### 3.5 Request framing

**Outbound** (`BT:674-700`): `frame = UTF8(payload) + [0x00]` (exactly one trailing NUL,
`BT:689-690`), written **with response** to the target characteristic.

**Inbound** (`BT:659-671`): one GATT read. Keep the bytes **before the first `0x00`**
(`split(b"\x00", 1)[0]`, `BT:671`), then decode strictly as UTF-8. Invalid UTF-8 →
`.decoding("bluetooth <setting|command>: invalid UTF-8")`. Vector: `"BrewingMode"\0\0garbage` →
`"BrewingMode"` (`TBC:1223-1231`).

- No polling, no reassembly, no request IDs. Correlation relies only on request serialisation
  (`BT:126-128`).
- Whether the machine has always written its response by the time the write acknowledgement
  arrives is **UNVERIFIED (U6)**. Upstream assumes it, and so does Angstrom.

### 3.6 Read settings (`CONST:322-330`, `BT:555-594`)

Request bytes are `UTF8(rawValue) + [0x00]`, written to `0a0b…`, then `0a0b…` is read. Responses
are JSON (fragments allowed) after NUL truncation.

| `BluetoothReadSetting` | Raw value (verbatim) | Response top level | Decoding (§3.10 rules) | Vector |
|---|---|---|---|---|
| `.machineCapabilities` | `"machineCapabilities"` | array of objects. Use element `[0]`. Empty array → `.decoding` (`IndexError` parity) | `BluetoothMachineCapabilities` | `TBC:342,347` |
| `.machineMode` | `"machineMode"` | JSON string | `"BrewingMode"`/`"EcoMode"`/`"StandBy"` → `MachineMode`. Any other value → `.decoding` (`ValueError` parity, `BT:558`) | `TBC:424,429` |
| `.tankStatus` | `"tankStatus"` | bool or string | `parseBool` | `TBC:410,415` |
| `.boilers` | `"boilers"` | array of objects | `[BluetoothBoilerDetails]` in wire order. `[]` is valid. | `TBC:365,370`; `TBC:1274` |
| `.smartStandBy` | `"smartStandBy"` (capital **B**) | object (not an array, `853a4d1`) | `BluetoothSmartStandbyDetails` | `TBC:393,399` |
| `.isPlumbedIn` | `"isPlumbedIn"` | bool or string | `parseBool` | `TBC:1234-1250` |

The machine's reply to an unknown setting (older firmware, `isPlumbedIn`) is **UNVERIFIED (U9)**.
An empty or non-JSON reply surfaces as `.decoding`. This is the case the device layer tolerates for
plumb-in (§4.17).

### 3.7 Commands (`BT:596-626`, `BT:702-710`)

Frame: `UTF8(json) + [0x00]` written to `0b0b…`. Then **read `0b0b…`** for the status. The JSON is
`{"name":<name>,"parameter":{…}}` with **compact separators** (`separators=(",", ":")`,
`BT:707`), **keys in exactly the order below**, and `ensure_ascii` escaping (§3.9).

| Swift (client) | `name` | `parameter` keys **in this order** | Upstream |
|---|---|---|---|
| `setPower(on:)` | `MachineChangeMode` | `mode`: `"BrewingMode"` if on, else `"StandBy"` | `BT:596-600` |
| `setSteam(on:)` | `SettingBoilerEnable` | `identifier`: `"SteamBoiler"`; `state`: bool | `BT:602-608` |
| `setSmartStandby(enabled:mode:minutes:)` | `SettingSmartStandby` | `minutes`: int; `mode`: `"LastBrewing"`/`"PowerOn"`; `enabled`: bool | `BT:610-618` |
| `setTemperature(boiler:celsius:)` | `SettingBoilerTarget` | `identifier`: `"CoffeeBoiler1"`/`"SteamBoiler"`; `value`: number (§3.9) | `BT:620-626` |

Pinned bytes (each ends in a single `\x00`):

```
BT-REQ-001 setPower(on: true)
{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}\x00          (TBC:302-306)
BT-REQ-002 setPower(on: false)
{"name":"MachineChangeMode","parameter":{"mode":"StandBy"}}\x00              (derived, BT:596-600)
BT-REQ-003 setTemperature(boiler: .steam, celsius: 90)
{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":90}}\x00   (TBC:317-320)
BT-REQ-004 setSmartStandby(enabled: true, mode: .powerOn, minutes: 42)
{"name":"SettingSmartStandby","parameter":{"minutes":42,"mode":"PowerOn","enabled":true}}\x00 (TBC:331-334)
BT-REQ-005 setSteam(on: true)
{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":true}}\x00 (derived, BT:602-608)
BT-REQ-006 setTemperature(boiler: .coffee, celsius: 96.5)
{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":96.5}}\x00 (derived)
```

**Command status** (`MBT:59-65`): the response is a JSON object with three **required** keys `id`,
`message`, `status`, each coerced with the required-string rule (§3.10). A key that is present with
value `null` gives `"None"` (`str(None)`), so `{"id":"a","message":null,"status":"success"}` is a
success (BT-COERCE-001). A missing key or a non-object → `.decoding("bluetooth command: …")`. Example: `{"id":"test-id","message":"Success","status":"success"}`
(`TBC:47`). **Success** iff `status.lowercased() == "success"` (`MACH:1023`). The client does
**not** throw on a non-success status. It returns it. The set of failure strings is **UNVERIFIED
(U8)**. The only upstream example is `"error"` (`TBD:517-519`).

`CommandStatus(rawValue:)` (cloud) MUST NOT be reused to interpret BLE statuses. It is
case-sensitive and would map `"success"` to `.other("success")` (`Sources/Angstrom/Commands.swift:24-33`).

### 3.8 Shot-counter notifications (`BT:441-465`, `MBT:90-213`)

- The host subscribes to `0e0b…` and never writes to it. Notifications only flow on an
  authenticated link (subscribe happens after `ensureConnected`).
- **One notification is one complete JSON object.** There is no reassembly (`BT:452`). Strip `0x00`
  from **both ends only** (`bytes.strip(b"\x00")`). A NUL in the middle makes the payload unparseable.
- `receivedAt` is stamped when the notification enters the process: in the adapter's delegate
  callback, using the transport's injected `now` (`BT:445` takes it first, before the replay check).
- **Replay:** the first notification after every successful subscribe is discarded unconditionally,
  whatever its content. The flag is armed **before** subscribing, because the replay may arrive
  before the subscribe acknowledgement (`BT:428-434,446-449`; `TBC:814-845`). Whether the machine
  always replays is **UNVERIFIED (U15)**. Default: always drop (parity).
- **Parse:** JSON must be an object. Decode `BluetoothBrewingData` **and** `BluetoothMachineTelemetry`
  from the same object using the field rules below. **If either decode fails, drop the whole
  notification** (`BT:451-457`). Unknown keys are ignored.
- **Dispatch:** if the brewing part is non-empty, run it through the tracker (§4.11) and emit any
  update. **Then**, if the telemetry part is non-empty, emit it (brewing first, `BT:460-465`).
  Telemetry is emitted as **only the fields present in this notification** (not merged).

Brewing keys (`MBT:94-123`):

| JSON key (verbatim) | Field | Rule |
|---|---|---|
| `BrewingStartedGroup1DoseIndex` | `startedDoseIndex: String?` | string |
| `BrewingUpdateGroup1Ev` | `ev: Bool?` | notification bool |
| `BrewingUpdateGroup1Backflush` | `backflush: Bool?` | notification bool |
| `BrewingUpdateGroup1Time` | `brewingTime: Double?` | double |
| `FlushStoppedGroup1Time` | `flushStoppedTime: Double?` | double |
| `FlushStoppedGroup1DoseIndex` | `flushStoppedDoseIndex: String?` | string |
| `BrewingStoppedGroup1Time` | `brewingStoppedTime: Double?` | double |
| `BrewingStoppedGroup1DoseIndex` | `brewingStoppedDoseIndex: String?` | string |
| `BrewingStoppedGroup1StopType` | `brewingStoppedStopType: String?` | string |
| `BrewingStoppedGroup1StopReason` | `brewingStoppedStopReason: String?` | string |

Telemetry keys (`MBT:198-213`):

| JSON key (verbatim) | Field | Rule |
|---|---|---|
| `CoffeeBoiler1UpdateTemperature` | `coffeeBoilerTemperature: Double?` | double |
| `SteamBoilerUpdateTemperature` | `steamBoilerTemperature: Double?` | double |
| `MachineMode` | `machineMode: MachineMode?` | a string mapping to `.brewing`/`.eco`/`.standby`. Any other value (including a non-string) → `nil`, i.e. unset (`_known_machine_mode`, `MBT:68-70`) |
| `Sleep` | `sleep: String?` | string |
| `MachineStatistics` | `machineStatistics: BluetoothJSONValue?` | absent or JSON `null` → `nil` (unset; the rest of the notification is processed, because mashumaro never calls `deserialize` for `None`). A JSON **string** → parse its content as JSON (`.fragmentsAllowed`; `deserialize=json.loads`, `MBT:209-213`): a JSON `null` result → `nil` (unset); any other result → that `BluetoothJSONValue` (not type-checked). Any other value (number, bool, array, object), or a string that does not parse → **drop the whole notification**. Vectors BT-NTF-COERCE-002…005. |

Keys observed but ignored: `SteamBoilerHeatingCoeff`, `CoffeeBoiler1HeatingCoeff` (`REC:13,78`). An
unknown key on its own yields empty parts, so nothing is emitted (`TBC:863-867`).

Size: the largest recorded notification (`MachineStatistics`, `REC:23`) is **418 bytes**, which
needs an ATT MTU ≥ 421 to arrive whole on Apple. This is **UNVERIFIED (U14)**. Parse-or-drop parity
applies. The raw tap logs every notification so a hardware run can settle it.

### 3.9 JSON encoding rules for command frames (Python `json.dumps` parity)

Command bytes are built by an **ordered writer** (`BluetoothCodec`), never by `JSONEncoder`
(`JSONEncoder` has no key-order guarantee, and `.sortedKeys` would break BT-REQ-004).

- Separators: `,` between members, `:` between key and value, **no whitespace anywhere**.
- Object key order: exactly as listed in §3.7. Top level is `name`, then `parameter`.
- Strings (Python `ensure_ascii=True`): `"` → `\"`, `\` → `\\`, U+0008 → `\b`, U+000C → `\f`,
  U+000A → `\n`, U+000D → `\r`, U+0009 → `\t`. Every other code point < U+0020 or ≥ U+007F
  (**including U+007F**: Python's `ESCAPE_ASCII` is `[^\ -~]`) → `\uxxxx` (**lowercase hex**, 4
  digits; `json.dumps("\x7f")` = `"\u007f"`). Code points above U+FFFF are written as a UTF-16
  surrogate pair (`\udxxx\udxxx`). `/` is **not** escaped. All current payloads are pure ASCII.
- Booleans: `true` / `false`.
- Integers (`Int`): decimal, no fraction (`42`).
- Doubles: if finite and integral (`value == value.rounded(.towardZero)` and `abs(value) < 1e15`),
  write the integer form (`90`, `128`). Otherwise write Swift's shortest round-trip
  `String(describing: value)` (`96.5`). Non-finite values MUST be rejected before encoding: the
  client throws `.operationNotAvailable("temperature must be finite")` (D21).
  **Divergence D6:** Python sends `93.0` for a float `93.0`. Angstrom sends `93`. Every upstream
  test vector passes ints, so all pinned vectors are reproduced exactly. Firmware tolerance of
  `93` vs `93.0` is **UNVERIFIED (U7)**.
- **No rounding** on the BLE leg. `set_temp` sends the caller's value unchanged
  (`BT:620-626`, `MACH:807-815`). Only the cloud leg rounds (`Sources/Angstrom/Commands.swift:160`).

### 3.10 Value coercion rules for responses and notifications

Upstream decodes with mashumaro 3.17 (`uv.lock:455-456`), which coerces using Python constructors
(`bool()`, `int()`, `float()`, `str()`, `Enum()`). The upstream column below was **executed**
against `4c639ee` with mashumaro 3.17 (U10, settled; vectors BT-COERCE-* and BT-NTF-COERCE-*,
§9.3.2–§9.3.3). Angstrom reproduces those coercions **except** the cases listed in D5, each with its
behavioural effect. JSON is parsed with `JSONSerialization` (`.fragmentsAllowed`).

**Hazard (normative):** `JSONSerialization` returns JSON `true`/`false` as `NSNumber`, and
`as? Bool` also matches the numbers `0` and `1`. Implementations MUST classify a value as a JSON
boolean only when `CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()`. They MUST classify a
number as integer vs float with `CFNumberIsFloatType`.

| Rule | Input → result | Upstream |
|---|---|---|
| `parseBool` (tank, plumb-in) | JSON bool → itself. JSON string `s` → `s.lowercased() == "true"`. Anything else (number, null, array, object) → `false`. | `_parse_bool`: `str(v).lower() == "true"` (`BT:62-64`) |
| **wire bool** (`hasCupWarmer`, `isEnabled`, smart-standby `enabled`) | JSON bool → itself. JSON string → `parseBool`. JSON number → `!= 0`. JSON null → `false` (parity: `bool(None)`). Array/object → `!isEmpty` (parity: `bool([])` is `False`, `bool({"a":1})` is `True`). Absent key → `.decoding` (parity: `MissingField`). | upstream `bool(v)` makes `"false"` → `True`. **D5:** Angstrom makes `"false"` → `false`. |
| **notification bool** (`ev`, `backflush`) | JSON bool → itself. string → `parseBool`. number → `!= 0`. null/absent → `nil`. array/object → `!isEmpty` (so `{"BrewingUpdateGroup1Ev":[]}` is `ev == false`, parity). | `bool(v)`. D5 as above. |
| **double** | JSON number → `Double`. JSON bool → `1.0`/`0.0`. JSON string → `Double(s.trimmingCharacters(in: .whitespacesAndNewlines))`; **error** if that is nil **or not finite** (`"nan"`, `"inf"`, D5), **or if `s` contains `x` or `X`** (Swift's `Double(String)` accepts hex floats such as `"0x1p3"`; Python's `float()` raises on them: parity). null/absent → `nil` (optional) or `.decoding` (required). array/object → **error**. A JSON number literal is always finite: `JSONSerialization` rejects `NaN`, `Infinity` and out-of-range literals such as `1e400`, so the whole payload fails to parse (D5). | `float(v)` (`"abc"` raises; `TBC:773`) |
| **int** (`minutes`, `groupsNumber`, …) | JSON number `n` → if `!CFNumberIsFloatType(n)` and `Int(n.stringValue)` is non-nil → that value (exact for every integer literal in `Int` range, including `Int.max` and `Int.min`). Otherwise let `d = n.doubleValue`, `t = d.rounded(.towardZero)`: **error** unless `d.isFinite` and `-9223372036854775808.0 <= t && t < 9223372036854775808.0` (never call `Int(_:)` on a value outside that range: it traps); else `Int(t)`. JSON bool → 1/0. JSON string → `Int(s.trimmingCharacters(in: .whitespacesAndNewlines))` (optional sign and decimal digits only, else **error**). Array/object → **error**. null/absent on a required key → `.decoding`. | `int(v)`: `int(93.5) == 93`, `int("93.5")` raises. Python ints are unbounded (D5). |
| **string** | JSON string → itself. Integer number → decimal (an integer literal too large for `UInt64` arrives from `JSONSerialization` as a non-fractional `NSDecimalNumber`: emit its `stringValue` digits, never float text; parity with Python `str(int)`). Float number → `String(describing:)`. Bool → `"True"`/`"False"` (Python `str()`). **Optional** field: null/absent → `nil`. **Required** field: null → `"None"` (parity: `str(None)`), absent → `.decoding`. Array/object → its compact JSON text, `String(decoding: try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)` (D5: Python gives its `repr`, e.g. `"['a']"`; only the text differs). | `str(v)` |

"Error" inside a **notification** means drop the whole notification. Inside a **read response** it
means `.decoding("bluetooth <rawValue>: <detail>")`.

Per model (all keys are **required** unless marked optional; extra keys are ignored):

- `BluetoothMachineCapabilities` (`MBT:22-39`): `family` (string → `Model(bluetoothFamily:)`. An
  unknown family → `.decoding("bluetooth machineCapabilities: Invalid model name: <raw>")`, parity
  with `CONST:216-217`), `groupsNumber` int, `coffeeBoilersNumber` int, `hasCupWarmer` wire bool,
  `steamBoilersNumber` int, `teaDosesNumber` int, `machineModes` array of strings →
  `MachineMode(rawValue:)` keeping `.other` (tolerant, D5), `schedulingType` string.
- `BluetoothBoilerDetails` (`MBT:42-49`): `id` string → `BluetoothBoilerType(rawValue:)` (unknown →
  `.other(raw)`, tolerant, D5), `isEnabled` wire bool, `target` double, `current` double (D9: no int
  truncation).
- `BluetoothSmartStandbyDetails` (`MBT:51-57`): `mode` string → `SmartStandbyAfter(rawValue:)`
  (unknown → `.decoding`, parity), `minutes` int, `enabled` wire bool (`"true"` → true, `TBC:393`).
- `BluetoothCommandStatus` (`MBT:59-65`): `id`, `message`, `status`, string rule, all required.

---

## 4. Behavioural specification

### 4.1 Client state and invariants

`LaMarzoccoBluetoothClient` is a `public actor`. Its state is listed in §6.6 (frozen). Invariants:

- **I1.** `link` is non-nil from the moment its authentication succeeds until the actor detaches it
  or processes that link's `.disconnected` event. Link-up before auth is not observable (D11). The
  `.disconnected` event reaches the actor through the watcher task (§5.3), so for a short window
  after the peripheral drops, `link` is non-nil but dead. A request that starts in that window is
  not reconnected: it fails with `.bluetoothConnectionFailed` (D7e).
- **I2.** Every `.connected` connection event is preceded by a successful auth, and transitions are
  edge-triggered: no two consecutive identical events (`BT:208-214`).
- **I3.** At most one idle timer task exists. None exists while `shotCounterEnabled` is true
  (`BT:271-280`).
- **I4.** Requests are serialised end-to-end (connect, auth, write, read) by the **request gate**.
  Connect/auth/teardown/subscribe are serialised by the **connection gate**. The lock order is
  always request → connection (`BT:126-128,235`). Both gates are FIFO.
- **I5.** Link events are processed by the actor in the order the link emitted them (one watcher
  task per link, sequential `await`s). Events from a link that is not the current `link` are
  ignored (`BT:469-470`).
- **I6.** No CoreBluetooth object ever crosses into the actor. Only `Sendable` values do (§5.4).

### 4.2 Connect: `ensureConnected(refresh:)` (`BT:233-269`)

Runs under the connection gate.

1. If `link != nil`: `resetIdleTimer()` and return `link` (`BT:236-239`). This is a stored-state
   check, not a liveness probe. Upstream checks bleak's live `is_connected` (`BT:183-186`); the
   difference is D7e.
2. Set `shotCounterSubscribed = false` ("a new connection never has active notifications", `BT:242-243`).
3. **Availability.** First create `let updates = central.availabilityUpdates()`, **then** read
   `await central.availability()`, so a transition between the two calls is not lost:
   - `.poweredOn` → continue.
   - `.unknown`, `.resetting`, `.unauthorized(.notDetermined)` → wait for `.poweredOn` on `updates`,
     bounded by `sleeper.sleep(for: timing.poweredOnWait, purpose: .poweredOnWait)` (10 s). The two
     race in a `withThrowingTaskGroup`; the first child to finish decides, and the group cancels
     the other. `.poweredOn` → continue. A terminal state (`.poweredOff`, `.unsupported`,
     `.unauthorized(.denied/.restricted/.allowedAlways)`) or the sleep finishing first → throw
     `.bluetoothUnavailable(<last state seen>)`. Cancellation of the caller → `CancellationError`.
   - `.poweredOff`, `.unsupported`, `.unauthorized(.denied/.restricted/.allowedAlways)` → throw
     `.bluetoothUnavailable(state)` immediately. No connect attempt (upstream on macOS raises
     `BleakError` per attempt, `B-CM:93-100`. Failing fast is behaviour-equivalent: D10).
4. **Connect with retry** (`establish_connection(max_attempts=3)`, `BT:247-255`, `BRC:398-589`): up
   to `timing.connectAttempts` (3) calls to `central.connect(to: peripheral, timeout: timing.connectTimeout)`
   (20 s). Between failed attempts, sleep (purpose `.connectBackoff`)
   `timing.connectBackoffAfterTimeout` (0.25 s) after `.timedOut`, else `timing.connectBackoff`
   (0.1 s) (`BRC:51-60,324-350`). `.unknownPeripheral` is terminal: no further attempts. When the
   attempts are exhausted, throw `.bluetoothConnectionFailed("Failed to connect to <peripheral> after <n> attempts: <last error>")`.
   Emit raw event `[connecting]` before the first attempt and `[connected]` when a link is returned.
5. **Discover** `discover({read, write, auth, shotCounter}, refresh: refresh, timeout: timing.operationTimeout)`
   and store the result in `discovered`. A discovery error → `.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: <e>")`.
   If `auth ∉ discovered` → `.bluetoothConnectionFailed("Could not find characteristic 0d0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")`.
   Emit raw `[mtu <n>]` if `await newLink.attMTU()` is non-nil.
6. **Authenticate** (§3.4).
7. **On any error from step 4 onward, including `CancellationError`:** if a link was obtained,
   `await newLink.disconnect()` (best effort), then rethrow the mapped error. No connection event is
   emitted ("never keep an unauthenticated link", `BT:257-264`; `TBC:1197-1220`).
8. **Success:** `link = newLink`. Start the watcher task over `newLink.events` (§4.7). Clear
   `needsRediscovery`. `resetIdleTimer()`. `setConnected(true)`. Emit raw `[authenticated]`.
   Return the link.

`refresh: true` is passed only by the shot-counter rediscovery pass (§4.9). It is the analogue of
`use_services_cache=False` (`BT:406-407`).

### 4.3 Authentication

Exactly §3.4. Implemented by `authenticate(_ link:)` (frozen internal). It is called only from
`ensureConnected`. Raw tap: the auth write is emitted with `isSecret: true`. Auth reads are emitted
with `isSecret: false`.

### 4.4 Requests: the `disconnect_on_exception` wrapper (`BT:114-136`)

`request(_ characteristic:frame:)` (frozen internal) does the following:

1. Acquire the **request gate** (held until the end).
2. `let link = try await ensureConnected()`.
3. `try await resolve(characteristic, on: link)` (§4.5).
4. Write `frame` with response (`timing.operationTimeout`). Emit raw `.write`.
5. **Same-link check (D7):** if `self.link !== link`, throw
   `.bluetoothConnectionFailed("Client is not connected")`. Upstream would silently reconnect and
   read a stale value (`BT:663`). Otherwise `resetIdleTimer()` (parity with the second
   `_ensure_connected`, `BT:663,238`).
6. Read the same characteristic (`timing.operationTimeout`). Emit raw `.read`. Return the raw bytes.
7. **On error:** map it (§4.4.1). If the mapped error is a *drop-class* error **and**
   `!(shotCounterEnabled && link != nil)` ("a single failed command must not kill a running shot
   counter", `BT:130-134`; `TBC:1287-1302`), call `dropConnectionInBackground()` (fire-and-forget,
   tracked for tests, "outside the lock to avoid deadlock", `BT:132-133`). Rethrow.

Drop-class errors: `.bluetoothConnectionFailed`, `.bluetoothAuthenticationFailed`,
`.bluetoothUnavailable`, `.bluetoothTimedOut`, and `CancellationError` (D7: upstream does not catch
`CancelledError` here). **Not** drop-class: `.decoding` (`BT:129`; `TBC` G-CODEC-5). With a decode
error the link stays up and the idle timer keeps running.

Read-setting (`readSetting`): the frame is `BluetoothCodec.readRequestFrame(setting)` on `0a0b…`.
The response is `BluetoothCodec.responseText(_:)` (§3.5) and is decoded by `BluetoothResponseDecoder`.
Decoding happens **after** the gate is released, so it never triggers a drop.

Command (`sendCommand`): the frame is `BluetoothCodec.commandFrame(…)` on `0b0b…`. The status is
read from `0b0b…` and decoded with `BluetoothResponseDecoder.commandStatus`.

#### 4.4.1 Error mapping by phase (frozen: `mapTransportError(_:phase:)`)

| Seam error | `.connect` phase | `.authenticate` phase | `.request` phase |
|---|---|---|---|
| `.unavailable(a)` | `.bluetoothUnavailable(a)` | `.bluetoothUnavailable(a)` | `.bluetoothUnavailable(a)` |
| `.timedOut(d)` | retried, then `.bluetoothConnectionFailed` | `.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: timed out (<d>)")` | `.bluetoothTimedOut(d)` |
| `.notConnected`, `.disconnected`, `.gatt`, `.valueTooLong` | retried, then `.bluetoothConnectionFailed` | `.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: <e>")` | `.bluetoothConnectionFailed("<e>")` |
| `.unknownPeripheral(id)` | `.bluetoothConnectionFailed("Unknown peripheral <id>; scan again")` | n/a | n/a |
| `.characteristicNotFound(u)` | n/a | n/a | `.bluetoothConnectionFailed("Could not find characteristic <u> on machine.")` |
| `CancellationError` | rethrown unchanged | rethrown unchanged | rethrown unchanged |
| `LaMarzoccoError` | unchanged | unchanged | unchanged |

### 4.5 Characteristic resolution (`BT:712-747`, D7)

`resolve(_ uuid:on:)`:

1. If `needsRediscovery` (set by `.servicesInvalidated`), run `discover(all five, refresh: true)` on
   the live link first and update `discovered`.
2. If `uuid ∈ discovered` → return.
3. Otherwise run `discover(all five, refresh: true)` **once** on the live link. This is the working
   analogue of upstream's `clear_cache()` + retry, which is a no-op on macOS (`BRC:198-203`). If
   `uuid` is now present → return.
4. Otherwise call `dropConnectionInBackground()` **unconditionally, even while the shot counter
   runs** (parity: `BT:742-744`; `TBC` G-CONN-6), and throw
   `.bluetoothConnectionFailed("Could not find characteristic <uuid> on machine.")`.

### 4.6 Idle auto-disconnect (`BT:271-291`)

- `resetIdleTimer()`: cancel the existing idle task. If `!shotCounterEnabled`, start a new idle task
  that `try await sleeper.sleep(for: timing.idleTimeout, purpose: .idleDisconnect)` (30 s) and,
  unless cancelled, calls `dropConnection(fromIdleTimer: true)`.
- Reset points: `ensureConnected` on a live link (twice per request, §4.4 steps 2 and 5), after a
  successful connect, after `stopShotCounter`, after a failed `startShotCounter` while connected, and
  after the reconnect loop gives up while connected (`BT:238,268,361,370,520`).
- **The idle task never cancels itself** while it performs its own disconnect (`BT:296-300`, fix
  `83289c6`; `TBC:1373`). `disconnectInternal(fromIdleTimer: true)` does not cancel `idleTask`. It
  only clears the reference.
- A link loss reported by the link (`.disconnected`) **cancels** the idle task (D16. Upstream leaves
  it to fire harmlessly, `TBC` G-CONN-7).

### 4.7 Teardown paths and link events

| Path | Gate | Steps |
|---|---|---|
| `disconnectInternal(fromIdleTimer:)` | caller holds the connection gate | cancel the idle task (unless `fromIdleTimer`) and set it to nil. Detach: `let old = link; link = nil` (so its `.disconnected` is ignored, `BT:303-304`). Cancel the watcher. `await old?.disconnect()` (never throws). Emit raw `[disconnected]` if `old != nil`. `setConnected(false)`. |
| `dropConnection(fromIdleTimer:)` | acquires the connection gate | `disconnectInternal`, then release, then `handleConnectionLost()` (`BT:313-317`) |
| `disconnect()` (public) | acquires the connection gate (**not** the request gate, parity `BT:319-325`) | `let wasSubscribed = disableShotCounter()`. Under the gate: `stopNotifyInternal()`, `disconnectInternal()`. After the gate: if `wasSubscribed`, emit `ShotCounterEvent.unsubscribed`. Idempotent. Never reconnects (`TBC:1094-1105`). |
| link event `.disconnected(_)` from the **current** link | none | `link = nil`. Cancel the idle task (D16). Cancel the watcher reference. Emit raw `[disconnected]`. `setConnected(false)`. `handleConnectionLost()` (`BT:467-473`). |
| link event `.notification(uuid, n)` | none | if `uuid == shotCounter` → `handleShotCounterNotification(n)`. Ignore other UUIDs. |
| link event `.servicesInvalidated` | none | `needsRediscovery = true`. Emit raw `[services invalidated]` (D7). |

Requests in flight when the link drops fail with the adapter's `.disconnected` error →
`.bluetoothConnectionFailed`. They do **not** reconnect (D7a, D7e). Plain requests never auto-reconnect.
The next request reconnects lazily (`BT:663,680`; `TBC:1382-1402`).

### 4.8 Connection events (`BT:188-214`)

- `connectionEvents()` returns a new multiplexed `AsyncStream<ConnectionEvent>` (the house pattern,
  `Sources/Angstrom/LaMarzoccoCloudClient.swift:488-498`). Iteration ends when the consumer
  cancels.
- `setConnected(_:)` is edge-triggered on `reportedConnected`. `.connected` comes only after auth.
  `.disconnected` comes from `disconnectInternal` and from link loss (`BT:269,311,472`).
- No event fires for a link that fails auth (`TBC:1405-1421`).
- Vectors: two commands, then idle → `[.connected, .disconnected]` (`TBC:1361-1379`). Loss, then
  `disconnect()`, then reconnect, then `disconnect()` → `[.connected, .disconnected, .connected, .disconnected]`
  (`TBC:1382-1402`).

### 4.9 Shot counter: start, stop, subscribe

**`startShotCounter() async throws -> Bool`** (`BT:327-362`):

1. `shotCounterEnabled = true` (this also suppresses idle timers from here on).
2. `supported = try await subscribeShotCounter()`.
3. If `subscribeShotCounter` threw, or returned `false`: `_ = disableShotCounter()`. If
   `link != nil`, `resetIdleTimer()`. Then rethrow, or return `false`. A start failure **throws**.
   It is not converted to `false` (`TBC` G-RC-4).
4. Return `supported`.
5. **Second call while subscribed:** returns `true` without resubscribing and **without** emitting
   `.subscribed` again. The tracker and replay flag are not reset (`BT:413-414`; `TBC:1108-1122`).

**`subscribeShotCounter() -> Bool`** (`BT:403-439`). For `refresh` in `[false, true]`:

1. `_ = try await ensureConnected(refresh: refresh)` (auth happens here).
2. Under the connection gate:
   - `link == nil` → throw `.bluetoothConnectionFailed("Client is not connected")`.
   - `!shotCounterEnabled` → return `false` (stopped meanwhile).
   - `shotCounterSubscribed` → return `true`. No event.
   - `shotCounter ∉ discovered`:
     - if `refresh` → return `false` (genuinely unsupported).
     - else `await disconnectInternal()` (this emits `.disconnected`), then continue with
       `refresh = true` ("the cached service table may be stale", `BT:418-427`; `TBC:652-696`).
   - `tracker = BrewingTracker()`. `replayPending = true` (**before** subscribing). `try await link.subscribe(shotCounter, timeout: timing.operationTimeout)`
     (errors are mapped with the `.request` phase). `shotCounterSubscribed = true`. Emit raw `[subscribed]`.
3. After releasing the gate: emit `ShotCounterEvent.subscribed`. Return `true`.

Loop exhausted → `false`.

**`stopShotCounter() async`** (`BT:364-371`): `let wasSubscribed = disableShotCounter()`. Under the
connection gate: `await stopNotifyInternal()`. If `link != nil`, `resetIdleTimer()`. After the gate:
if `wasSubscribed`, emit `.unsubscribed`. The link stays up, and idle disconnect resumes.
`stopShotCounter()` with no counter running is a no-op apart from re-arming the idle timer
(`TBC` G-SC-1).

**`disableShotCounter() -> Bool`** (`BT:373-394`): if `!shotCounterEnabled` return `false`.
Otherwise capture `wasSubscribed = shotCounterSubscribed`, set `shotCounterEnabled = false`,
`tracker = BrewingTracker()`, cancel and nil `reconnectTask`, and return `wasSubscribed`. All state is
mutated **before** any event is emitted ("call it last", `BT:376-377`).

**`stopNotifyInternal()`** (`BT:396-401`): if `shotCounterSubscribed && link != nil`,
`await link.unsubscribe(shotCounter)` (best effort, non-throwing) and emit raw `[unsubscribed]`.
Always set `shotCounterSubscribed = false`.

**Event emission rule:** `.brewing` and `.telemetry` events are emitted only while
`shotCounterEnabled` is true. Late notifications after a stop are dropped silently (`TBC` G-SC-4).

### 4.10 Notification handling (`BT:441-465`)

`handleShotCounterNotification(_ n: GATTNotification)` is synchronous on the actor:

1. Emit raw `.notification` (verbatim, before the replay check).
2. If `replayPending`: `replayPending = false`, emit raw `[replay dropped]`, return.
3. `guard let decoded = ShotCounterNotificationDecoder.decode(n.value) else { return }` (§3.8).
4. If `!decoded.brewing.isEmpty`, `let u = tracker.process(decoded.brewing, receivedAt: n.receivedAt)`.
   If `u != nil` and `shotCounterEnabled`, emit `.brewing(u)`.
5. If `!decoded.telemetry.isEmpty` and `shotCounterEnabled`, emit `.telemetry(decoded.telemetry)`.

### 4.11 Brewing state machine (`MBT:125-163`, `BT:77-111`)

**`BluetoothBrewingData.merging(_ other)`** (`MBT:85-87`): returns a copy of `self` where every
field that is **non-nil in `other`** overwrites. `false`, `0` and `""` count as set. A merge never
clears a field.

**`isEmpty`**: every field is nil.

**`deriveState(receivedAt:)`** on the merged data `D`. The rules are tested in order and the first
match wins:

| # | Predicate on `D` | State |
|---|---|---|
| 1 | `brewingStoppedTime != nil` ∨ `brewingStoppedDoseIndex != nil` ∨ `brewingStoppedStopType != nil` ∨ `brewingStoppedStopReason != nil` ∨ `ev == false` | `.brewingStopped` |
| 2 | `flushStoppedTime != nil` ∨ `flushStoppedDoseIndex != nil` | `.flushed` |
| 3 | `backflush == true` | `.backflushing` |
| 4 | `startedDoseIndex != nil` ∨ (`ev == true` ∧ `brewingTime != nil`) | `.brewing` |
| 5 | otherwise | `nil` (no update) |

The update fields (`MBT:151-163,180-188`):

- `timerValue = state == .brewing ? (D.brewingTime ?? 0.0) : nil`
- `finalShotTime = D.brewingStoppedTime` (any state. A flush's `FlushStoppedGroup1Time` is **not**
  surfaced, only `raw.flushStoppedTime`)
- `startedDoseIndex = D.startedDoseIndex`
- `stopReason = D.brewingStoppedStopReason`
- `receivedAt = receivedAt`
- `raw = D`
- `brewingStartTime = state == .brewing ? receivedAt − timerValue : nil`

**`BrewingTracker.process(M, receivedAt t)`** (`BT:90-111`):

```
1. if M.startedDoseIndex != nil { reset() }            // "a new shot or flush started"
2. D = D.merging(M)
3. U = D.deriveState(receivedAt: t)
4. if U == nil { return nil }                         // D is KEPT: fragments accumulate
5. if U.state ∈ {.flushed, .brewingStopped} { reset() }   // U keeps its values
6. else if let e = U.brewingStartTime {               // .brewing only
       if S == nil || e < S! { S = e }
       U.brewingStartTime = S                         // "notifications can only be delayed, so the earliest start is the best"
   }
7. return U
reset(): D = BluetoothBrewingData(), S = nil
```

The tracker is replaced with a fresh one on every successful subscribe, on connection loss, in
`disableShotCounter`, and at init (`BT:179,390,428,479`).

**Transition table.** Message shapes: `START(i)` = `{"BrewingStartedGroup1DoseIndex":i}`.
`TICK(t)` = `{"BrewingUpdateGroup1Time":t,"BrewingUpdateGroup1Ev":true,"BrewingUpdateGroup1Backflush":false}`.
`TICK_BF(t)` = the same with backflush `true`. `EV_OFF` = `{"BrewingUpdateGroup1Ev":false}`.
`BSTOP` = any `BrewingStoppedGroup1*`. `FSTOP` = any `FlushStoppedGroup1*`. `FRAG` = a brewing-only
fragment matching no rule after the merge. `t_r` = receivedAt. Phases: IDLE (D empty), PENDING
(D non-empty, no state), BREWING, BACKFLUSH.

| From | Message | Emitted (state, timerValue, finalShotTime, brewingStartTime) | Next phase, `S` |
|---|---|---|---|
| any | `START(i)` | `.brewing`, `0.0`, nil, `t_r` | BREWING, `S = t_r` |
| IDLE/PENDING | `TICK(t)` | `.brewing`, `t`, nil, `t_r − t` | BREWING, `S = t_r − t` |
| BREWING | `TICK(t)` | `.brewing`, `t`, nil, `min(S, t_r − t)` | BREWING, `S = min(…)` |
| IDLE/PENDING/BREWING | `TICK_BF(t)` | `.backflushing`, nil, nil, nil | BACKFLUSH, `S` unchanged |
| BACKFLUSH | `TICK(t)` | `.brewing`, `t`, nil, `min(S, t_r − t)` (or `t_r − t` if `S` is nil) | BREWING |
| any | `EV_OFF` | `.brewingStopped`, nil, `D.brewingStoppedTime` (normally nil), nil | IDLE (reset) |
| any | `BSTOP(t,…)` | `.brewingStopped`, nil, `t`, nil. `stopReason` set; `startedDoseIndex` = the preceding START's index, if any | IDLE (reset) |
| any | `FSTOP(t,i)` | `.flushed`, nil, nil, nil (`raw.flushStoppedTime = t`) | IDLE (reset) |
| IDLE/PENDING | `FRAG` | none | PENDING (the fragment is kept) |
| any | unparseable or telemetry-only | none; tracker untouched | unchanged |

Consequences, all parity: two `.brewingStopped` updates per shot are possible (`EV_OFF` then
`BSTOP`). A flush looks like a shot until it stops (`README:255`). A late tick after a stop
re-enters `.brewing` (no guard; Q9). `.backflushing` never moves `S`.

### 4.12 Telemetry

- `BluetoothMachineTelemetry.merging(_:)` has the same semantics as the brewing merge.
- The client emits **partial** telemetry, i.e. only the fields in that notification (`BT:464-465`;
  `TBC:859-862`).
- A telemetry-only notification never touches the tracker (`BT:460`).
- Merged telemetry is kept by the device layer (§4.19), not by the client.

### 4.13 Reconnect loop (`BT:475-520`)

**`handleConnectionLost()`** (`BT:475-486`): `wasSubscribed = shotCounterSubscribed`.
`shotCounterSubscribed = false`. `tracker = BrewingTracker()` ("the running shot must be
forgotten"). If `!shotCounterEnabled` return. If `wasSubscribed`, emit `.unsubscribed`. If
`reconnectTask == nil`, start `reconnectTask = Task { await reconnectLoop() }`.

**`reconnectLoop()`** (`BT:488-520`):

```
delay = timing.reconnectInitialDelay          // 1 s
authFailures = 0
lastError: LaMarzoccoError? = nil
updates = central.availabilityUpdates()       // created ONCE, here, before the first sleep: a stream only
                                              // sees later changes, so creating it per sleep would race (D14)
while shotCounterEnabled:
    sleep(delay, purpose: .reconnectBackoff)  // BEFORE every attempt, including the first (G-SC-7)
        — ends early if central.availabilityUpdates() yields .poweredOn after a non-poweredOn
          value seen during this loop; then delay = reconnectInitialDelay   (D14)
        — CancellationError → return (stopped)
    do:
        supported = try await subscribeShotCounter()
    catch .bluetoothAuthenticationFailed:
        authFailures += 1                     // cumulative per loop run, NOT "in a row" (D15)
        lastError = .bluetoothAuthenticationFailed
        if authFailures >= timing.maxAuthFailures (3): break       // delay is NOT doubled
        continue
    catch CancellationError: return
    catch any other error e:                  // connection-class (upstream: BleakError/TimeoutError/BluetoothConnectionFailed)
        lastError = e as? LaMarzoccoError
        under connection gate: await disconnectInternal()
        delay = min(delay * 2, timing.reconnectMaxDelay)           // 1,2,4,8,16,32,60,60,…
        continue
    if supported: reconnectTask = nil; return  // .subscribed was already emitted
    lastError = .bluetoothConnectionFailed("Could not find characteristic 0e0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")
    break
// give up for good, without cancelling this task
reconnectTask = nil
let stillEnabled = shotCounterEnabled
_ = disableShotCounter()                      // no .unsubscribed here (already sent at loss time)
if link != nil { resetIdleTimer() }
if stillEnabled, let e = lastError { emit .gaveUp(e) }    // Angstrom-only terminal event (D15)
```

Vectors: retries through `[timedOut, connectionFailed]` → 4 connects in total, events
`[.subscribed, .unsubscribed, .subscribed]` (`TBC:1053-1069`). A token mismatch after loss → 4
connects, `authenticationFailed == true`, not active, not connected, no background tasks
(`TBC:1072-1091`). Upstream's handling of non-Bleak exceptions (the task dies, `TBC` §4.2) is
replaced by the connection-error branch (D15).

### 4.14 Discovery, token read, GATT table (static, no client instance)

These are `static` on `LaMarzoccoBluetoothClient` and touch no client instance state (parity
`BT:522-547`). They use default `BluetoothTiming()` values and the given transport's sleeper. They
emit nothing on any raw tap: there is no instance.

The availability rule is §4.2 step 3, including the `.poweredOnWait` sleep on the transport's
sleeper.

- **`scanAll(transport:duration:)`** (Angstrom-only, diagnostic): availability, then return
  `central.scan(for: duration)` unchanged (no name filter; nil and empty names kept; first-seen
  order). It exists so a public-API consumer (`angcli ble scan --all`, H10) can see peripherals
  whose names the prefix filter would hide (U3).
- **`discoverMachines(transport:duration:)`**: `scanAll(transport:duration:)` filtered per §3.2.
- **`readToken(transport:peripheral:)`** (`BT:539-547`): availability check. **One** connect
  attempt with `timing.tokenReadConnectTimeout` (10 s, bleak `BleakClient` default). No auth.
  `discover({token}, refresh: false)`; if missing, `.bluetoothConnectionFailed("Could not find characteristic 0c0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")`.
  `read(token)`, then decode **strictly as UTF-8 with no NUL stripping** (parity, `BT:547`).
  Invalid UTF-8 → `.decoding("bluetooth token: invalid UTF-8")`. A `.gatt` error with ATT code 2, 5,
  8 or 15 (`ReadNotPermitted`, `InsufficientAuthentication`, `InsufficientAuthorization`,
  `InsufficientEncryption`) → `.bluetoothConnectionFailed("Could not read the Bluetooth token (ATT error <code>). Is the machine in pairing mode?")`.
  Always `disconnect()`, on success and on failure. The result is `BluetoothAuthToken`. The
  behaviour outside pairing mode is **UNVERIFIED (U5)**.
- **`gattTable(transport:peripheral:)`** (diagnostic, Angstrom-only): one connect attempt
  (`timing.connectTimeout`), `link.gattTable(timeout:)`, disconnect. No auth. Exists to settle
  U1/U2 on hardware.

### 4.15 Device layer: construction and transports

- `LaMarzoccoMachine` takes **both** clients at construction (parity `THING:73-90`). There is no
  setter. Either may be nil. The existing `init(serialNumber:client:snapshot:)` keeps today's
  behaviour (cloud only).
- **Cloud-only operations** without a cloud client throw `.cloudOnlyFunctionality` (`THING:27-38`)
  and record `lastError`. That includes `start()`. `stop()` is a no-op without a cloud client.
- **BLE-only operations** (`refreshDashboardFromBluetooth`, `refreshModelFromBluetooth`) without a
  BLE client throw `.bluetoothConnectionFailed("Bluetooth client not initialized")` (`MACH:332,353`).
  `startShotCounter()` without a BLE client returns `false` (`MACH:183-184`).
- **Model gating** uses `model` as today (dashboard ?? settings ?? schedule). If the model is
  unknown, `requireModel` throws `.unsupportedModel`. There is no silent Linea Micra default (D17).
- If a BLE client is present, `init` starts observing `bluetooth.connectionEvents()` and sets
  `isBluetoothConnected` (`startObservingBluetoothConnection()`, frozen).

### 4.16 BLE-first commands with cloud fallback (`MACH:983-1049`)

`bluetoothFirst(bluetooth:cloud:)` (frozen internal) runs **inside** the method's existing
`capturing { … }`, after gating:

```
if let bt = bluetooth (the client):
    do:
        status = try await bluetoothOperation(bt)
        if status.isSuccess:                                    // status.lowercased() == "success"
            return CommandResponse(id: status.id, status: .success, errorCode: nil)
        // non-success: no error is thrown; fall through to the cloud (G-DEV-1)
        if cloudClient == nil: throw .commandFailed(status: status.status, errorCode: status.message)   (D18)
    catch let e as LaMarzoccoError where e.isBluetoothConnectionFailure:   // connectionFailed | authenticationFailed | unavailable
        if cloudClient == nil: throw e                          // upstream returns False (D18)
        log "Could not send command to bluetooth device, even though initalized. Falling back to cloud"
    // any other error (.bluetoothTimedOut, .decoding, CancellationError) PROPAGATES, no fallback (parity, MACH:1025)
guard let cloud = cloudClient else: throw .cloudOnlyFunctionality     // no BT and no cloud (upstream returns False)
return try await cloudOperation(cloud)                          // cloud errors propagate; two-tier semantics unchanged
```

The BLE attempt is made whenever a BLE client exists. It does **not** check `isBluetoothConnected`
(the lazy connect happens first, `MACH:1013`).

Per command (frozen mapping; the gates run **before** any transport):

| Method | Gate | BLE call | Cloud call | Optimistic update after success (either transport) |
|---|---|---|---|---|
| `setPower(on:)` | — | `bt.setPower(on:)` | `client.setPower(serial:on:)` | `settingMachineMode(on ? .brewing : .standby)` (both status widgets; `status` untouched, `SNAP:122-132`) |
| `setSteam(on:)` | — | `bt.setSteam(on:)` | `client.setSteam(serial:on:)` | `settingSteamEnabled(on)` (both steam widgets if present, G-DEV-11) |
| `setSteamTargetLevel(_ level)` | `Model.steamLevelModels` | `bt.setTemperature(boiler: .steam, celsius: Double(level.bluetoothTargetTemperature))` (126/128/131) | `client.setSteamTargetLevel(serial:_:)` | `settingSteamTargetLevel(level)` |
| `setCoffeeTargetTemperature(celsius:)` | — | `bt.setTemperature(boiler: .coffee, celsius: celsius)` (unrounded) | `client.setCoffeeTargetTemperature(serial:celsius:)` (rounds, as today) | `settingCoffeeTargetTemperature(celsius)` |
| `setSteamTargetTemperature(celsius:)` | `Model.steamTemperatureModels` | `bt.setTemperature(boiler: .steam, celsius: celsius)` | `client.setSteamTargetTemperature(serial:celsius:)` | `settingSteamTargetTemperature(celsius)` |
| `setSmartStandby(enabled:minutes:after:)` | grinder guard (as today) | if `schedule?.autoStandBySupported == true`: **no BLE**. `setAutoStandby(mode: "HH:MM"/"Off")` (cloud only; `.cloudOnlyFunctionality` without a cloud client, D22). Else `bt.setSmartStandby(enabled:, mode: after, minutes:)` | `client.setSmartStandby(serial:enabled:minutes:after:)` | none (`MACH:870-892`) |

Notes: the BLE argument order is `(enabled, mode, minutes)` (`BT:611-612`). The cloud `after`
corresponds to BLE `mode`. `"HH:MM"` is `String(format: "%02d:%02d", minutes / 60, minutes % 60)`,
as today (`MACH:877`).

### 4.17 Dashboard from Bluetooth (`MACH:350-485`)

`refreshDashboardFromBluetooth() async throws -> Dashboard`:

1. No BLE client → throw `.bluetoothConnectionFailed("Bluetooth client not initialized")`.
2. **Model resolution (D17):** if `model` is nil or `.unknown`, first run
   `refreshModelFromBluetooth()`. Upstream would silently use its Linea Micra default. With a known
   model, capabilities are **not** read (`TBD:139`).
3. Reads, **in this order**, all over the same client: `machineMode()`; `isPlumbedIn()`, where
   `LaMarzoccoError.decoding` → `false` ("older firmware might not know this setting", `MACH:357-362`)
   and other errors propagate; `tankStatus()`; `boilers()`.
4. Any error in step 3 propagates, with **no mutation** (`MACH:365-367`). No cloud fallback.
5. `state = BluetoothDashboardState(machineMode:, isPlumbedIn:, tankStatus:, boilers:)`.
6. `base = (baseDashboard ?? Dashboard(machine: Machine(serialNumber: serialNumber, model: resolvedModel), widgets: []))`.
   Then `setBaseDashboard(base.applyingBluetoothState(state, model: resolvedModel))`. This re-renders
   the overlay (`MACH:485`).
7. Does **not** stamp `lastUpdateAt` (cloud-only semantics, Q11). Does not touch `settings`,
   `schedule`, `connected`, `connectionDate` or `name` (`MACH` §3.5 of note 03). Returns the rendered
   `dashboard`.

**`Dashboard.applyingBluetoothState(_:model:)`** (pure, core; frozen). Let `waterOK = isPlumbedIn || tankStatus`.
`boilerStatus(enabled) = !waterOK ? .noWater : (!enabled ? .off : BoilerStatus(bluetoothMode: mode))`.
"Existing W" means the first widget whose `code` is W **and** whose `kind` is the matching typed
case (an `.unknown` widget counts as absent). Upsert semantics: replace in place, keeping `code`
and `index`. If absent, **append** with `index: 1` (every cloud fixture uses `index: 1` for these
codes).

| Step | Widget | Default if absent | Then overwrite |
|---|---|---|---|
| 1 | `CMMachineStatus` | `MachineStatus(status: .standby, availableModes: [.brewing, .standby], mode: mode, nextStatus: nil, brewingStartTime: nil)` | `mode = mode`; `status = MachineState(bluetoothMode: mode)`. Keep `availableModes`, `nextStatus`, `brewingStartTime`. **Not** `CMMachineGroupStatus`. (`MACH:378-393`) |
| 2 | for each boiler in wire order (a duplicate id: last wins; `.other` ids ignored) | | |
| 2a | `id == .coffee` → `CMCoffeeBoiler` | `CoffeeBoiler(status: .standby, enabled: b.isEnabled, enabledSupported: false, targetTemperature: b.target, targetTemperatureMin: 80, targetTemperatureMax: 110, targetTemperatureStep: 0.1, readyStartTime: nil)` | `status = boilerStatus(true)` (**the coffee boiler never shows `.off`**, `MACH:413`); `enabled = b.isEnabled`; `targetTemperature = b.target` (`MACH:396-416`) |
| 2b | `id == .steam` and `Model.steamLevelModels.contains(model)` → `CMSteamBoilerLevel` | `SteamBoilerLevel(status: .standby, enabled: b.isEnabled, enabledSupported: true, targetLevel: .level1, targetLevelSupported: true, readyStartTime: nil)` | `status = boilerStatus(b.isEnabled)`; `enabled`; `targetLevel = SteamLevel(bluetoothTargetTemperature: b.target)`. Then **remove every** `CMSteamBoilerTemperature` widget (`MACH:419-445`) |
| 2c | `id == .steam`, other models → `CMSteamBoilerTemperature`, with `isMini = (model == .lineaMini)` | `SteamBoilerTemperature(status: .standby, enabled: b.isEnabled, enabledSupported: false, targetTemperature: b.target, targetTemperatureMin: isMini ? 95 : 20, targetTemperatureMax: isMini ? 140 : 134, targetTemperatureStep: 0.1, targetTemperatureSupported: !isMini, readyStartTime: nil)` | `status = boilerStatus(b.isEnabled)`; `enabled`; `targetTemperature = b.target`. Then **remove every** `CMSteamBoilerLevel` widget (`MACH:446-472`) |
| 3 | `CMNoWater` (always written) | `NoWater(alarm: !waterOK)` | `alarm = !waterOK` (`MACH:474-483`) |

Append order for absent widgets: `CMMachineStatus`, `CMCoffeeBoiler`, steam widget, `CMNoWater`.
Upstream's defaults are kept even where they differ from cloud fixtures (coffee max 110 vs 100;
non-Mini steam 20/134, `enabledSupported: false`). This is parity (Q12). Removal is from the
`widgets` list, the observable equivalent of upstream's `config.pop` (D12).

Truth table (Micra; normative, `TBD:560-636`; input `(mode, plumbedIn, tankOK, steamEnabled)`, boilers coffee `(true, 93, 92)` / steam `(steamEnabled, 128, 120)`):

| ID | Input | Machine status | Coffee status | Steam-level status | `NoWater.alarm` |
|---|---|---|---|---|---|
| BT-DASH-STATUS-001 | `(.brewing, F, T, T)` | `.poweredOn` | `.ready` | `.ready` | false |
| 002 | `(.eco, F, T, T)` | `.eco` | `.eco` | `.eco` | false |
| 003 | `(.standby, F, T, F)` | `.standby` | `.standby` | `.off` | false |
| 004 | `(.brewing, F, F, T)` | `.poweredOn` | `.noWater` | `.noWater` | true |
| 005 | `(.brewing, T, F, T)` | `.poweredOn` | `.ready` | `.ready` | false |

### 4.18 Model from Bluetooth (`MACH:325-348`)

`refreshModelFromBluetooth() async throws -> BluetoothMachineCapabilities`: no BLE client →
`.bluetoothConnectionFailed("Bluetooth client not initialized")`. Read `machineCapabilities()`. All
errors propagate (an unknown family → `.decoding`, from the decoder). On success, set the base
dashboard's `machine.model = capabilities.family` (rebuild `Dashboard(machine:widgets:)`. If there is
no base, create `Dashboard(machine: Machine(serialNumber:, model:), widgets: [])`) through
`setBaseDashboard`. No other capability field is written (parity: they are discarded, `MACH:341-348`).
Returns the capabilities.

### 4.19 Shot-counter overlay, telemetry merge and expiry (`MACH:158-323`)

**Model (D12): base + overlay.** Upstream mutates the cloud `MachineStatus` widget in place and
remembers its cloud `(status, brewing_start_time)` keyed by Python object identity. Angstrom's
widgets are values, so the device layer keeps:

- `baseDashboard`: everything except the BLE brewing overlay. Every assignment site
  (snapshot seed, `refreshDashboard`, `refreshAll`, websocket push, reconnect re-fetch via
  `refreshDashboard`, BLE refresh, model refresh, telemetry mode, all ~28 optimistic updates) goes
  through `setBaseDashboard(_:)` / `updateBaseDashboard(_:)`. Each of those calls `renderDashboard()`.
- **Read rule (normative):** every value that feeds a base write MUST be read from `baseDashboard`,
  never from the rendered `dashboard`. A transform of the current dashboard is written as
  `updateBaseDashboard { $0.… }`, whose closure receives the base. Otherwise the overlay's
  `status = .brewing` and BLE `brewingStartTime` leak into the base, outlive the overlay's expiry
  and are persisted by `snapshot`.
- `dashboard` (public, rendered) = `baseDashboard?.overlayingBluetoothBrewing(bluetoothBrewingUpdate)`.

**`Dashboard.overlayingBluetoothBrewing(_ u)`** (pure, core; frozen), equivalent to `MACH:287-314`
combined with `MACH:316-323`:

| `u` | `CMMachineStatus` absent | `u.state == .brewing` | any other state (`.brewingStopped`, `.flushed`, **`.backflushing`**) |
|---|---|---|---|
| nil | unchanged | — | — |
| non-nil | unchanged (no-op, note 02 §7.4 #8) | `status = .brewing`; `brewingStartTime = u.brewingStartTime` | `status = base.status == .brewing ? .poweredOn : base.status`; `brewingStartTime = base.brewingStartTime` |

Only `CMMachineStatus` is overlaid. `CMMachineGroupStatus` and the boiler widgets never are
(`MACH:287-314`).

Why this equals upstream: upstream's saved "cloud values" are always the values of the current
widget as last written by a non-overlay source. A new widget object (REST, push with widgets, BLE
creating it) re-captures both values. An in-place BLE refresh or telemetry mode re-captures
`status` and keeps the start time (`MACH:316-323`). In Angstrom the base widget *is* that record: BLE
paths write only `mode`/`status` into the base and never `brewingStartTime`. Vectors D1–D14 (§9.3.8)
are the acceptance tests.

**Event handling** (`handleShotCounterEvent(_:)`, MainActor. State is mutated **first**, then
`bluetoothEvents()` listeners are notified, G-DEV-12):

| Client event | Device-layer effect | Emitted on `bluetoothEvents()` |
|---|---|---|
| `.brewing(u)` | `bluetoothBrewingUpdate = u`. If `u.finalShotTime != nil`, `lastShotTime = u.finalShotTime` (never reset by anything, `MACH:211-213`). `renderDashboard()`. **Re-arm** the expiry (cancel the previous one, start a new one) for **every** state, including stopped/flushed (`MACH:215-220`). | `.brewing(u)` |
| `.telemetry(t)` | `bluetoothTelemetry = bluetoothTelemetry.merging(t)`. If `t.machineMode = m`: `updateBaseDashboard { $0.settingMachineMode(m).settingMachineState(MachineState(bluetoothMode: m)) }` (`MACH:230-241`). Telemetry **never** re-arms the expiry. | `.telemetry(t)` (partial) |
| `.subscribed` | `isShotCounterActive = true` | — |
| `.unsubscribed` | `isShotCounterActive = false`. `bluetoothTelemetry = BluetoothMachineTelemetry()`. `clearBluetoothBrewingState(notify: true)` (`MACH:223-228`) | `.brewingCleared`, always (parity: `_drop_ble_brewing_state` always notifies `None`, `MACH:243-246`) |
| `.gaveUp(e)` | `isShotCounterActive = false`. `lastError = e`. Stop listening. | `.shotCounterStopped(e)` (D15) |

**Expiry** (`BLE_BREWING_STATE_TIMEOUT = 60`, `MACH:88`): a MainActor task that sleeps
`bluetoothBrewingStateTimeout` through the injectable `brewingExpirySleep`. Unless cancelled, it
calls `clearBluetoothBrewingState(notify: true)` and the overlay disappears (`TM:882-907`). The
shot counter keeps running, and the next brewing update re-applies it.

**`clearBluetoothBrewingState(notify:)`**: `bluetoothBrewingUpdate = nil`. Cancel and nil the expiry.
`renderDashboard()`. If `notify`, emit `.brewingCleared`.

**`startShotCounter() async throws -> Bool`** (`MACH:158-191`): no BLE client → `false`. If no
listener task is running, subscribe to `bluetooth.shotCounterEvents()` **before** starting, and
consume it in a MainActor task calling `handleShotCounterEvent`. Then
`let ok = try await bluetooth.startShotCounter()`. If it throws or returns `false`, cancel the
listener task and rethrow or return `false`. On `true`, set `isShotCounterActive = true`. Not gated
on `shotCounterSupported` or on the model (`TM:745-762`).

**`stopShotCounter() async`** (`MACH:193-207`): cancel the listener task **first**, so the client's
`.unsubscribed` for this stop is never handled (the Swift equivalent of `_stopping_shot_counter`).
Then `await bluetooth?.stopShotCounter()`. Then `bluetoothTelemetry = BluetoothMachineTelemetry()`,
`clearBluetoothBrewingState(notify: false)` (silent: "The update callbacks are not called, refresh
after awaiting this."), and `isShotCounterActive = false`. `lastShotTime` is kept. The BLE link stays
up, and its idle timer resumes.

**Interaction with cloud updates:**

- A websocket push is merged as `updateBaseDashboard { $0.applying(update) }`, which does nothing
  while `baseDashboard` is nil (today's "no dashboard yet" drop). A push with widgets replaces the
  base widget set wholesale (`Dashboard.applying`, unchanged). The render re-applies the overlay to
  the new `CMMachineStatus`. A late cloud `Brewing`
  after a BLE stop renders as `.poweredOn` for as long as the overlay is held (≤ 60 s after the last
  brewing update) (`TM:811-815`).
- A push with **no** widgets keeps the base widgets (existing behaviour) and re-renders, which is
  idempotent.
- The reconnect re-fetch (`refreshDashboard()` on every `.connected` after the first) and an explicit
  REST refresh: same as a push. The overlay is re-applied over the fresh widget (G-DEV-5).
- `snapshot` persists **`baseDashboard`**. It never persists a transient `Brewing` or a BLE-derived
  `brewingStartTime`.
- `lastUpdateAt` is stamped only by cloud changes (unchanged semantics).
- `powerState`, `isMachineConnected` and `machineLastConnectionDate` read the rendered `dashboard`.
  The overlay never changes `mode` or `connected`, so they are unaffected.

### 4.20 Optimistic updates

Unchanged in kind and position. The existing six methods already apply their transform after the
command returns, which matches upstream's `if result:` (`MACH:504-507` etc.). In Angstrom a failure
throws, so the update is skipped. **Every** optimistic write moves from
`dashboard = dashboard?.settingX(…)` to `updateBaseDashboard { $0.settingX(…) }`. `setSmartStandby`
has none (`MACH:870-892`).

### 4.21 Cloud token read

`LaMarzoccoCloudClient.bluetoothAuthToken(serial:) async throws -> BluetoothAuthToken?`:
authenticated `GET /things`. Parse with `JSONSerialization` (the house shape-check pattern,
`Sources/Angstrom/LaMarzoccoCloudClient.swift:178-195`): the body must be an array of objects. Find
the first object with `serialNumber == serial`. If its `bleAuthToken` is a non-empty JSON string,
return a token. If it is `null`, absent or `""`, return `nil`. If no object matches, throw
`.decoding("things: no thing with serial <serial>")`. If the shape is wrong, throw
`.decoding("things shape")`. Never log or print the value.

---

## 5. Architecture

### 5.1 Module and product layout (decision)

```
Angstrom            (existing product; CoreBluetooth-FREE)
 ├─ cloud client, models, widgets, …                     (unchanged)
 └─ Bluetooth/      seam protocols (package), BLE models/enums, codec, coercion,
                    BrewingTracker, LaMarzoccoBluetoothClient actor (ALL protocol logic),
                    Dashboard+Bluetooth transforms, RawBluetoothFrame, BluetoothOpTable
AngstromBluetooth   (NEW product + target, depends on Angstrom; the ONLY `import CoreBluetooth`)
 └─ CoreBluetoothCentral / CoreBluetoothLink adapter + public `BluetoothTransport.coreBluetooth()`
AngstromUI          (existing; depends on Angstrom ONLY, never on AngstromBluetooth)
 └─ LaMarzoccoMachine gains an optional LaMarzoccoBluetoothClient
AngstromTestSupport (NEW non-product target under Tests/; fakes for both test targets)
```

Justification:

1. **Cloud-only consumers never link CoreBluetooth.** A Swift object that references CB symbols
   autolinks `CoreBluetooth.framework` (verified in note 06's `layout/` probe: only the leaf
   object file carries the autolink). App Store processing has historically flagged binaries that
   reference Bluetooth APIs without `NSBluetoothAlwaysUsageDescription` (UNVERIFIED for today's
   pipeline, U19). With this layout, only apps that `import AngstromBluetooth` take on that
   requirement.
2. **All logic is testable in CI.** The client actor depends only on `package` protocols. Tests
   inject fakes (§5.3). CI never instantiates a `CBCentralManager` (§9.5).
3. **AngstromUI stays CoreBluetooth-free.** It holds `LaMarzoccoBluetoothClient?` (core type). The
   app builds the client with `BluetoothTransport.coreBluetooth()` from the leaf module.
4. **Zero runtime dependencies are kept.** There is no third-party BLE wrapper (note 06 §8). Parity
   needs control over owed-reply swallowing, notify-before-ack routing, ordering, timeouts and the
   error taxonomy, and the adapter is small.
5. **`package` access** (Swift 5.9+, tools 6.0) keeps the seam out of the public API (semver) while
   letting the leaf target and the test-support target implement it. This mirrors the internal
   `WebSocketChannel` seam (`Sources/Angstrom/WebSocket.swift:8-14`).

### 5.2 Layers

```
 AngstromUI.LaMarzoccoMachine  (@MainActor @Observable)   BLE-first commands, BLE dashboard, overlay, expiry
        │ async calls + AsyncStream<ShotCounterEvent>/<ConnectionEvent>
 Angstrom.LaMarzoccoBluetoothClient  (public actor)       gates, connect+retry, auth poll, framing, idle timer,
        │ package protocols                                 drop-on-error, shot counter, reconnect, raw tap
        ▼
 BluetoothCentral / BluetoothLink / BluetoothSleeper + now()     ← the seam (package)
        ▲                                   ▲
 AngstromBluetooth.CoreBluetooth*          AngstromTestSupport.Fake*   (tests)
        │ delegate callbacks on ONE private serial DispatchQueue
 CBCentralManager / CBPeripheral
```

### 5.3 The transport seam

Defined in §6.2 (frozen). Design rules:

- `BluetoothCentral.connect` performs **one** attempt. Retries, backoff and attempt counting are
  protocol logic above the seam, so tests can count them.
- Each connection returns a **new** `BluetoothLink` object. The client compares links by identity
  (`===`) to ignore stale events (`BT:469-470`) and to implement detach-before-disconnect
  (`BT:303-304`).
- Each link exposes **one ordered** `AsyncStream<LinkEvent>` (`.notification`,
  `.servicesInvalidated`, terminal `.disconnected`), buffered `.unbounded`. A disconnect can never
  overtake the notifications before it. The stream finishes after `.disconnected`.
- The client has exactly one consumer of `link.events`: a watcher `Task` per link that awaits
  `handleLinkEvent` sequentially.
- `BluetoothSleeper` sleeps are **tagged by purpose** (`.authPoll`, `.connectBackoff`,
  `.idleDisconnect`, `.reconnectBackoff`, `.poweredOnWait`), so tests can fire one timer by hand and
  count the rest. Every timeout the protocol logic waits on goes through the sleeper; none uses
  `Task.sleep` or a clock directly
  (upstream patches `IDLE_TIMEOUT`/`AUTH_READ_INTERVAL`/`RECONNECT_INITIAL_DELAY` and fakes the idle
  sleep, `TBC:108-154`).
- `now` is injected (upstream patches `_utcnow`, `TBC:86-105`). The adapter stamps
  `GATTNotification.receivedAt` with it inside the delegate callback.
- Seam methods throw only `BluetoothTransportError` or `CancellationError`.

### 5.4 The CoreBluetooth adapter (`AngstromBluetooth`)

Design (option A of note 06, verified to build warning-free in Swift 6 mode for macOS 14 and iOS
17. The sketch passed its fake-driven tests 9/9):

- **One private serial `DispatchQueue`** (`label: "angstrom.bluetooth"`) is the `CBCentralManager`
  delegate queue **and** the confinement domain for every CB object and all adapter state.
  `CoreBluetoothCentral` and `CoreBluetoothLink` are `final class …: NSObject, …Delegate, @unchecked Sendable`.
  The unsafety is justified by queue confinement, asserted with
  `dispatchPrecondition(condition: .onQueue(queue))`.
- **Rejected:** an actor with a `DispatchSerialQueue` custom executor. Delegate callbacks could only
  enter it via `assumeIsolated`, whose custom-executor check (`SerialExecutor.checkIsolated()`) is
  `@available(macOS 15.0, iOS 18.0, …)` (note 06 §3.3). That risks a trap on the macOS 14 / iOS 17
  runtime (UNVERIFIED, H11). Also rejected: isolated conformances (need Swift ≥ 6.2, while the
  package floor is 6.0) and a main-actor delegate.
- **Async bridge:** `withTaskCancellationHandler` + `withCheckedThrowingContinuation`. Every
  in-flight operation is registered in a queue-confined **`BluetoothOpTable`** (core, CB-free,
  unit-tested). Its single `finish(token:)` path removes the entry **before** resuming, so double
  resume is impossible across reply, timeout, cancellation and disconnect fan-out.
- **Owed replies:** an ATT op abandoned by timeout or cancellation still owes exactly one delegate
  callback. The table counts it (`orphans[key]`) and swallows it, so it can never resolve a newer op
  with the same key. `unsubscribe` records a debt for its unawaited acknowledgement.
- **Read vs notification routing:** `didUpdateValueFor` resolves a pending (or owed) read for that
  characteristic first. Otherwise, if the characteristic is subscribed and there is no error, it
  yields `.notification`. The client never reads a subscribed characteristic.
- **Notify before ack:** `subscribe` inserts the characteristic into the routing set **before**
  `setNotifyValue(true, …)`, so a replay arriving before `didUpdateNotificationStateFor` is
  delivered (and then dropped by the client's replay flag).
- **Lazy manager:** `CBCentralManager` is allocated on first use with
  `CBCentralManagerOptionShowPowerAlertKey: showPowerAlert` (default false), so a process that never
  uses Bluetooth never prompts.
- **Retention:** keep a queue-confined `[UUID: CBPeripheral]`. Empty it when the state drops to
  `.unknown`, `.resetting`, `.unsupported` or `.unauthorized` (`CBCentralManager.h:264-268,303-305`).
- **Peripheral resolution on connect:** `known[uuid] ?? retrievePeripherals(withIdentifiers: [uuid]).first`.
  If neither finds it, scan (no service filter) for up to 10 s for that identifier (bleak
  `find_device_by_address` analogue, `B-CL:101-110`). Otherwise throw `.unknownPeripheral`.
- **Connect timeout:** CoreBluetooth connects never time out (`CBCentralManager.h:201`). The
  adapter calls `cancelPeripheralConnection` when `timeout` fires. A late `didConnect` with nobody
  waiting is cancelled immediately.
- **State drops:** on any state other than `.poweredOn`, synthesise `.disconnected` for every live
  link (at most once per link), fail pending connects with `.unavailable(state)`, and multicast the
  new state on `availabilityUpdates()`.
- **`didModifyServices`:** drop the link's characteristic table and yield `.servicesInvalidated`.
- **Write guard:** `.withResponse` writes longer than `maximumWriteValueLength(for: .withResponse)`
  throw `.valueTooLong` (never truncate). Upstream's longest payload is about 90 bytes.
- **`disconnect()`:** `cancelPeripheralConnection`, waiting at most 5 s for `didDisconnect`
  (`DISCONNECT_TIMEOUT = 5`, `bleak_retry_connector/const.py:8`).
- **Do not use** `CBConnectPeripheralOptionEnableAutoReconnect`. A system reconnect would bring up
  an unauthenticated link outside the client's state machine.
- `#if canImport(CoreBluetooth)` wraps every adapter file.
- **Do not** add `@preconcurrency import CoreBluetooth`. It would downgrade the region-isolation
  diagnostics. Only a real `swift build` (not `-typecheck`) reports CB-object isolation leaks, so
  CI's `swift build` is the gate (note 06 §3.1).

The bullets above and the seam in §6.2 are the complete, authoritative requirements. The research
sketch (note 06 Appendix B, `CoreBluetoothAdapter.swift`) is not in the repository. An implementer
MAY start from it when `$RESEARCH` provides it, and must then add `availabilityUpdates()`,
`attMTU()`, `gattTable(timeout:)`, the scan-by-identifier fallback and first-seen scan order, and use
the core `BluetoothOpTable`. Nothing in this spec depends on the sketch being available.

### 5.5 Swift 6 concurrency model

| Component | Isolation | Notes |
|---|---|---|
| `LaMarzoccoBluetoothClient` | `public actor` | Upstream's two `asyncio.Lock`s become two FIFO continuation gates (actor reentrancy at `await` would otherwise break request atomicity, `TBC:1253-1284`). Background work (drops, reconnect, idle) runs in unstructured `Task`s that inherit the actor, tracked in `backgroundTasks` for tests. |
| Link watcher | `Task` per link | `linkWatcher = Task { [weak self] in for await e in link.events { await self?.handleLinkEvent(e, from: link) } }`. With `[weak self]` the closure is not actor-isolated, so the `await` is a real hop. A strong `self` would inherit the actor and make the `await` on the synchronous `handleLinkEvent` a warning (`#UnnecessaryEffectMarker`, gate G5). |
| Adapter | private serial `DispatchQueue` | §5.4 |
| `LaMarzoccoMachine` | `@MainActor @Observable` (unchanged) | consumes client streams in `Task`s with `[weak self]` |
| Value types (models, events, `BluetoothTransport`, IDs, token) | `Sendable` | |
| Locks | `OSAllocatedUnfairLock` (macOS 13+) or `NSLock` | `Mutex` is macOS 15+ and MUST NOT be used |

Rules: no CB object crosses an isolation boundary (only `Data`, `String`, UUIDs, enums). There is no
`Task {}` hop inside a delegate callback (ordering). There is no `Task.immediate` dependency: the
re-entrancy tests are restated (§9.4).

### 5.6 Injectable time

- Client: `BluetoothTransport.sleeper` (tagged) and `BluetoothTransport.now`. Durations live in
  `BluetoothTiming`, overridable via `setTimingForTesting(_:)` (package).
- Device layer: `bluetoothBrewingStateTimeout` + `brewingExpirySleep` via
  `setBluetoothBrewingExpiryForTesting(timeout:sleep:)` (internal). This is AngstromUI's first timing
  seam.

### 5.7 Diagnostics tap

`LaMarzoccoBluetoothClient.rawFrames() -> AsyncStream<RawBluetoothFrame>` is the analogue of
`LaMarzoccoCloudClient.rawFrames()` (`Sources/Angstrom/Diagnostics.swift`). It is multiplexed and
costs nothing without listeners (emission is guarded by `rawFrameListeners.isEmpty`). It taps
writes (outbound), reads and notifications (inbound, verbatim, notifications before the replay
check), and synthetic lifecycle markers. The library tap is **verbatim**, per the house rule
(redaction happens at the display boundary). Frames carrying the token (the auth write, the token
read) set `isSecret = true` so every consumer can redact without knowing UUIDs.
`rawRead(_ setting:)` returns the verbatim response bytes of one read request.

### 5.8 How AngstromUI gains Bluetooth

`LaMarzoccoMachine.init(serialNumber:client:bluetooth:snapshot:)` (§6.16). The machine owns no
transport. The app constructs and persists the identity:

```swift
import Angstrom
import AngstromBluetooth
import AngstromUI

let transport = BluetoothTransport.coreBluetooth()            // create once per process and share
let token = try await cloud.bluetoothAuthToken(serial: serial) // or a Keychain copy / QR label
let ble = LaMarzoccoBluetoothClient(transport: transport, peripheral: storedPeripheralID, token: token!)
let machine = LaMarzoccoMachine(serialNumber: serial, client: cloud, bluetooth: ble, snapshot: saved)
```

---

## 6. Public API contracts (frozen)

Declarations below are **exact**. Bodies are omitted (`{ … }`). Doc comments are one-liners and
implementers SHOULD expand them. "package" and "internal" members listed here are frozen
cross-file contracts. Everything else an implementer adds to `Sources/Angstrom`,
`Sources/AngstromBluetooth`, `Sources/AngstromUI` or `Tests/AngstromTestSupport` MUST be
`private`/`fileprivate`. In test files, `XCTestCase` subclasses and their `test…` methods are
internal (XCTest discovers only those) and helpers are private. In `cli/`, command types and their
`@Option`/`@Flag`/`@Argument` properties may be internal (tests call `parse`).

### 6.1 `Sources/Angstrom/Bluetooth/BluetoothConstants.swift`

```swift
import Foundation

/// La Marzocco BLE protocol constants, verbatim from pylamarzocco v2.5.6 (`_bluetooth.py:40-54`).
package enum BluetoothConstants {
    package static let readCharacteristic = GATTUUID("0a0b7847-e12b-09a8-b04b-8e0922a9abab")
    package static let writeCharacteristic = GATTUUID("0b0b7847-e12b-09a8-b04b-8e0922a9abab")
    package static let tokenCharacteristic = GATTUUID("0c0b7847-e12b-09a8-b04b-8e0922a9abab")
    package static let authCharacteristic = GATTUUID("0d0b7847-e12b-09a8-b04b-8e0922a9abab")
    package static let shotCounterCharacteristic = GATTUUID("0e0b7847-e12b-09a8-b04b-8e0922a9abab")
    /// The four characteristics discovered on every authenticated connection.
    package static let sessionCharacteristics: Set<GATTUUID> =
        [readCharacteristic, writeCharacteristic, authCharacteristic, shotCounterCharacteristic]
    /// `BT_MODEL_PREFIXES` — case-sensitive name prefixes kept by discovery.
    package static let machineNamePrefixes: [String] = ["MICRA", "MINI", "LINEA", "GS3"]
    /// `AUTH_SUCCESS = b"\x01"`.
    package static let authSuccess = Data([0x01])
}

/// Every timing constant of the BLE client. Defaults are upstream values or bleak defaults (§2.2).
package struct BluetoothTiming: Sendable, Equatable {
    package var idleTimeout: Duration = .seconds(30)
    package var authReadAttempts: Int = 10
    package var authReadInterval: Duration = .milliseconds(50)
    package var maxAuthFailures: Int = 3
    package var reconnectInitialDelay: Duration = .seconds(1)
    package var reconnectMaxDelay: Duration = .seconds(60)
    package var connectAttempts: Int = 3
    package var connectTimeout: Duration = .seconds(20)
    package var connectBackoffAfterTimeout: Duration = .milliseconds(250)
    package var connectBackoff: Duration = .milliseconds(100)
    package var operationTimeout: Duration = .seconds(20)
    package var poweredOnWait: Duration = .seconds(10)
    package var tokenReadConnectTimeout: Duration = .seconds(10)
    package var scanDuration: Duration = .seconds(5)
    package init() {}
}
```

### 6.2 `Sources/Angstrom/Bluetooth/BluetoothTransport.swift` (the seam)

```swift
import Foundation

/// Persistable identity of a peripheral: the CoreBluetooth `CBPeer.identifier` UUID string.
/// Per Apple device and app; NOT a MAC address; never sync it across devices.
public struct BluetoothPeripheralID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { … }
    public var description: String { rawValue }
}

/// Mirror of `CBManagerAuthorization`.
public enum BluetoothAuthorization: Sendable, Hashable {
    case notDetermined, restricted, denied, allowedAlways
}

/// Mirror of `CBManagerState`, carrying the authorization when unauthorized.
public enum BluetoothAvailability: Sendable, Hashable {
    case unknown, resetting, unsupported, unauthorized(BluetoothAuthorization), poweredOff, poweredOn
}

/// A peripheral seen during a scan.
public struct DiscoveredPeripheral: Sendable, Hashable {
    public let id: BluetoothPeripheralID
    /// `CBPeripheral.name`, else the advertised local name.
    public let name: String?
    /// RSSI in dBm, nil when unavailable.
    public let rssi: Int?
    /// Public so consumers outside the package (angcli, its tests) can build values.
    public init(id: BluetoothPeripheralID, name: String?, rssi: Int?) { … }
}

/// Diagnostic GATT table entry (from `LaMarzoccoBluetoothClient.gattTable`).
public struct BluetoothGATTService: Sendable, Hashable {
    public let uuid: String               // lowercase
    public let characteristics: [BluetoothGATTCharacteristic]
    public init(uuid: String, characteristics: [BluetoothGATTCharacteristic]) { … }
}
public struct BluetoothGATTCharacteristic: Sendable, Hashable {
    public let uuid: String               // lowercase
    /// Property names: "broadcast", "read", "writeWithoutResponse", "write", "notify", "indicate",
    /// "authenticatedSignedWrites", "extendedProperties", "notifyEncryptionRequired", "indicateEncryptionRequired".
    public let properties: [String]
    public init(uuid: String, properties: [String]) { … }
}

/// Opaque handle to a Bluetooth stack. Build with `BluetoothTransport.coreBluetooth()` (AngstromBluetooth).
public struct BluetoothTransport: Sendable {
    package let central: any BluetoothCentral
    package let sleeper: any BluetoothSleeper
    package let now: @Sendable () -> Date
    package init(central: any BluetoothCentral,
                 sleeper: any BluetoothSleeper = RealSleeper(),
                 now: @escaping @Sendable () -> Date = { Date() }) { … }
}

/// A 128-bit GATT UUID normalised to lowercase.
package struct GATTUUID: Hashable, Sendable, CustomStringConvertible {
    package let string: String
    package init(_ string: String) { … }      // stores string.lowercased()
    package var description: String { string }
}

/// A notification value stamped with the transport clock when it entered the process.
package struct GATTNotification: Sendable, Hashable {
    package let value: Data
    package let receivedAt: Date
    package init(value: Data, receivedAt: Date) { … }
}

package enum BluetoothTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(BluetoothAvailability)
    case unknownPeripheral(BluetoothPeripheralID)
    case timedOut(String)
    case notConnected
    case characteristicNotFound(GATTUUID)
    case valueTooLong(Int, max: Int)
    /// Link dropped; `code` is the `CBError` code when CoreBluetooth gave one.
    case disconnected(code: Int?)
    /// A `CBErrorDomain` / `CBATTErrorDomain` error from a delegate callback.
    case gatt(domain: String, code: Int)
    package var description: String { … }
}

/// Everything one link reports, in order. `.disconnected` is terminal.
package enum LinkEvent: Sendable, Equatable {
    case notification(GATTUUID, GATTNotification)
    case servicesInvalidated
    case disconnected(BluetoothTransportError?)
}

package protocol BluetoothCentral: Sendable {
    /// Current state (allocates the manager lazily on first call).
    func availability() async -> BluetoothAvailability
    /// Every state change after the call (multicast; finishes never).
    func availabilityUpdates() -> AsyncStream<BluetoothAvailability>
    /// Foreground scan, no service filter; de-duplicated, first-seen order.
    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral]
    /// ONE connection attempt with our own timeout. Returns a NEW link object per connection.
    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink
}

package protocol BluetoothLink: AnyObject, Sendable {
    var peripheralID: BluetoothPeripheralID { get }
    /// Single-consumer, ordered, `.unbounded`; finishes after `.disconnected`.
    var events: AsyncStream<LinkEvent> { get }
    /// Which of `wanted` exist. `refresh: true` re-runs service + characteristic discovery.
    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID>
    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data
    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws
    /// Enable notifications; route values to `events` BEFORE the CCCD write is acknowledged.
    func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws
    /// Best effort; never throws.
    func unsubscribe(_ characteristic: GATTUUID) async
    /// Bounded (5 s); never throws; idempotent.
    func disconnect() async
    /// `maximumWriteValueLength(.withoutResponse) + 3`, nil if unknown. Diagnostic only.
    func attMTU() async -> Int?
    /// Full discovery of every service/characteristic with properties. Diagnostic only.
    func gattTable(timeout: Duration) async throws -> [BluetoothGATTService]
}

package enum SleepPurpose: Sendable, Hashable { case authPoll, connectBackoff, idleDisconnect, reconnectBackoff, poweredOnWait }

package protocol BluetoothSleeper: Sendable {
    /// Throws `CancellationError` when the calling task is cancelled.
    func sleep(for duration: Duration, purpose: SleepPurpose) async throws
}

package struct RealSleeper: BluetoothSleeper {
    package init() {}
    package func sleep(for duration: Duration, purpose: SleepPurpose) async throws { … } // Task.sleep(for:)
}
```

### 6.3 `Sources/Angstrom/Bluetooth/BluetoothAuthToken.swift`

```swift
/// The machine's Bluetooth auth token. Opaque; prints and reflects as redacted; NOT Codable —
/// the library never persists it. Store `rawValue` in the Keychain yourself.
public struct BluetoothAuthToken: Sendable, Hashable, CustomStringConvertible,
                                  CustomDebugStringConvertible, CustomReflectable {
    public let rawValue: String
    public init(_ rawValue: String) { … }
    public var description: String { "**REDACTED**" }
    public var debugDescription: String { "BluetoothAuthToken(**REDACTED**)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
```

### 6.4 `Sources/Angstrom/Models.swift` — edits to `LaMarzoccoError` (frozen)

Add these cases **at the end** of the enum, and the matching `errorDescription` arms:

```swift
    /// A Bluetooth connection, discovery or GATT operation failed (upstream `BluetoothConnectionFailed`/`BleakError`).
    case bluetoothConnectionFailed(String)
    /// The machine rejected the Bluetooth token (upstream `BluetoothAuthenticationFailed`).
    case bluetoothAuthenticationFailed
    /// Bluetooth is off, unauthorized, unsupported or not ready.
    case bluetoothUnavailable(BluetoothAvailability)
    /// A request-phase Bluetooth read/write did not complete in time (upstream bare `TimeoutError`).
    case bluetoothTimedOut(String)
    /// The operation needs the cloud, but no cloud client was given (upstream `CloudOnlyFunctionality`).
    case cloudOnlyFunctionality
```

`errorDescription` text (verbatim):

| Case | Description |
|---|---|
| `.bluetoothConnectionFailed(m)` | `"Bluetooth connection failed: \(m)"` |
| `.bluetoothAuthenticationFailed` | `"Bluetooth authentication failed. The Bluetooth token is likely wrong."` |
| `.bluetoothUnavailable(.poweredOff)` | `"Bluetooth is turned off."` |
| `.bluetoothUnavailable(.unauthorized(_))` | `"Bluetooth access is not allowed. Check Privacy & Security settings."` |
| `.bluetoothUnavailable(.unsupported)` | `"Bluetooth Low Energy is not supported on this device."` |
| `.bluetoothUnavailable(_)` (other) | `"Bluetooth is not ready."` |
| `.bluetoothTimedOut(m)` | `"The machine did not answer over Bluetooth in time (\(m))."` |
| `.cloudOnlyFunctionality` | `"Functionality is cloud only, but cloud client not initialized."` (verbatim `EXC:34`) |

Add, in the same file:

```swift
extension LaMarzoccoError {
    /// Mirrors upstream's `except (BleakError, BluetoothConnectionFailed)` (MACH:1025):
    /// true for `.bluetoothConnectionFailed`, `.bluetoothAuthenticationFailed`, `.bluetoothUnavailable`.
    public var isBluetoothConnectionFailure: Bool { … }
}
```

`CancellationError` keeps propagating unchanged. This is the existing house exception to "all
thrown errors are `LaMarzoccoError`" (`Sources/Angstrom/LaMarzoccoCloudClient.swift:445,553`).

Also reword the `Machine` doc comments at `Models.swift:25-26` (`coffeeStation`) and `:29-31`
(`shotCounterSupported`) to drop "Bluetooth is out of scope". The `bleAuthToken` note becomes: "The
Bluetooth token is deliberately not a `Machine` field. Read it with
`LaMarzoccoCloudClient.bluetoothAuthToken(serial:)`." No `Machine` field or coding change.

### 6.5 `Sources/Angstrom/Bluetooth/BluetoothEnums.swift`

```swift
/// What a read-setting request asks for (`const.py:322-330`).
public enum BluetoothReadSetting: String, Sendable, Hashable, CaseIterable {
    case machineCapabilities = "machineCapabilities"
    case machineMode = "machineMode"
    case tankStatus = "tankStatus"
    case boilers = "boilers"
    case smartStandBy = "smartStandBy"
    case isPlumbedIn = "isPlumbedIn"
}

/// Brewing states derived from shot-counter notifications (`const.py:333-339`).
public enum BluetoothBrewingState: String, Sendable, Hashable, Codable {
    case brewing = "Brewing"
    case brewingStopped = "BrewingStopped"
    case flushed = "Flushed"
    case backflushing = "Backflushing"
}

/// A boiler identifier on the BLE wire (`const.py:307-311`), tolerant of unknown values.
public enum BluetoothBoilerType: Sendable, Hashable {
    case coffee          // "CoffeeBoiler1"
    case steam           // "SteamBoiler"
    case other(String)
    public init(rawValue: String) { … }
    public var rawValue: String { … }
}

extension Model {
    /// BLE `machineCapabilities.family` → model (`ModelName.from_string`, const.py:198-218):
    /// upper-case, strip ALL whitespace, then:
    /// "GS3"→.gs3AV, "GS3MP"→.gs3MP, "GS3AV"→.gs3AV, "LINEAMINI2023"→.lineaMiniR, "LINEAMICRA"→.lineaMicra,
    /// "LINEAMINI"→.lineaMini, "LINEA"→.lineaMini, "MICRA"→.lineaMicra, "STRADAX"→.stradaX,
    /// "PICOGRINDER"→.pico, "SWANGRINDER"→.swan; anything else → nil.
    public init?(bluetoothFamily: String) { … }
    /// Models whose steam boiler is set by level (`STEAM_LEVEL_MODELS`, const.py:182).
    public static let steamLevelModels: Set<Model> = [.lineaMicra, .lineaMiniR]
    /// Models whose steam boiler is set by temperature (`MACH:823`).
    public static let steamTemperatureModels: Set<Model> = [.gs3, .gs3AV, .gs3MP, .stradaX]
}

extension MachineState {
    /// `BLE_MACHINE_STATE` (MACH:65-69): .brewing→.poweredOn, .eco→.eco, .standby→.standby, .other(x)→.other(x).
    public init(bluetoothMode mode: MachineMode) { … }
}

extension BoilerStatus {
    /// `BLE_BOILER_STATUS` (MACH:71-75): .brewing→.ready, .eco→.eco, .standby→.standby, .other(x)→.other(x).
    public init(bluetoothMode mode: MachineMode) { … }
}

extension SteamLevel {
    /// `STEAM_LEVEL_MAPPING` (MACH:58-62): .level1→126, .level2→128, .level3→131 (°C).
    public var bluetoothTargetTemperature: Int { … }
    /// `_steam_level_from_temperature` (MACH:78-84): 0 < t < 128 → .level1; 128 ≤ t ≤ 130 → .level2;
    /// otherwise (including t ≤ 0) → .level3.
    public init(bluetoothTargetTemperature t: Double) { … }
}
```

### 6.6 `Sources/Angstrom/Bluetooth/BluetoothModels.swift`

```swift
/// `machineCapabilities` element [0] (MBT:22-39).
public struct BluetoothMachineCapabilities: Sendable, Hashable {
    public let family: Model
    /// The family string as sent (e.g. "MICRA").
    public let rawFamily: String
    public let groupsNumber: Int
    public let coffeeBoilersNumber: Int
    public let hasCupWarmer: Bool
    public let steamBoilersNumber: Int
    public let teaDosesNumber: Int
    public let machineModes: [MachineMode]
    public let schedulingType: String
    public init(family: Model, rawFamily: String, groupsNumber: Int, coffeeBoilersNumber: Int,
                hasCupWarmer: Bool, steamBoilersNumber: Int, teaDosesNumber: Int,
                machineModes: [MachineMode], schedulingType: String) { … }
}

/// One `boilers` element (MBT:42-49). Temperatures in °C.
public struct BluetoothBoilerDetails: Sendable, Hashable {
    public let id: BluetoothBoilerType
    public let isEnabled: Bool
    public let target: Double
    public let current: Double
    public init(id: BluetoothBoilerType, isEnabled: Bool, target: Double, current: Double) { … }
}

/// `smartStandBy` (MBT:51-57).
public struct BluetoothSmartStandbyDetails: Sendable, Hashable {
    public let mode: SmartStandbyAfter
    public let minutes: Int
    public let enabled: Bool
    public init(mode: SmartStandbyAfter, minutes: Int, enabled: Bool) { … }
}

/// A command's status reply read back from the command characteristic (MBT:59-65).
public struct BluetoothCommandStatus: Sendable, Hashable {
    public let id: String
    public let message: String
    public let status: String
    /// `status.lowercased() == "success"` (MACH:1023).
    public var isSuccess: Bool { … }
    public init(id: String, message: String, status: String) { … }
}

```

`Sources/Angstrom/Bluetooth/BluetoothResponseDecoder.swift` (owned by WP-B1):

```swift
/// Decoders for read/command responses (§3.6, §3.10). Input is the NUL-truncated UTF-8 text.
/// Every failure throws `LaMarzoccoError.decoding("bluetooth <setting|command>: <detail>")`.
package enum BluetoothResponseDecoder {
    package static func machineMode(_ text: String) throws -> MachineMode
    package static func capabilities(_ text: String) throws -> BluetoothMachineCapabilities
    package static func bool(_ text: String, setting: BluetoothReadSetting) throws -> Bool   // parseBool
    package static func boilers(_ text: String) throws -> [BluetoothBoilerDetails]
    package static func smartStandby(_ text: String) throws -> BluetoothSmartStandbyDetails
    package static func commandStatus(_ text: String) throws -> BluetoothCommandStatus
}
```

### 6.7 `Sources/Angstrom/Bluetooth/BluetoothWireCoercion.swift`

```swift
/// Python-constructor-compatible coercions (§3.10). Operates on `JSONSerialization` values.
package enum BluetoothWireCoercion {
    package struct Failure: Error, Sendable, Equatable { package let detail: String }
    /// `_parse_bool`: JSON true, or a string equal to "true" ignoring case.
    package static func parseBool(_ value: Any?) -> Bool
    /// True iff `value` is a JSON boolean (CFBoolean), not the numbers 0/1.
    package static func isJSONBoolean(_ value: Any) -> Bool
    /// Wire bool for required fields: bool → itself; string → parseBool; number → != 0; null → false;
    /// array/object → !isEmpty; absent → throws.
    package static func requiredBool(_ value: Any?, key: String) throws -> Bool
    /// Notification bool: nil for absent/null; array/object → !isEmpty; otherwise as requiredBool.
    package static func optionalBool(_ value: Any?) -> Bool?
    /// float(): number, bool (1/0), numeric string with a finite result; nil for absent/null;
    /// throws otherwise (incl. "nan"/"inf").
    package static func optionalDouble(_ value: Any?, key: String) throws -> Double?
    package static func requiredDouble(_ value: Any?, key: String) throws -> Double
    /// int(): finite number within Int range (truncated), bool (1/0), integer-literal string;
    /// throws otherwise or when absent. Never traps.
    package static func requiredInt(_ value: Any?, key: String) throws -> Int
    /// str(): string, integer/float numbers, bool → "True"/"False", array/object → compact JSON text;
    /// nil for absent/null.
    package static func optionalString(_ value: Any?) -> String?
    /// As optionalString, but null → "None" and absent → throws.
    package static func requiredString(_ value: Any?, key: String) throws -> String
}
```

### 6.8 `Sources/Angstrom/Bluetooth/BluetoothCodec.swift`

```swift
/// A JSON scalar for the ordered command writer (§3.9).
package enum BluetoothJSONScalar: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)     // integral → "90"; otherwise shortest round-trip; caller guarantees finite
}

package enum BluetoothCodec {
    /// `json.dumps({"name": name, "parameter": {…}}, separators=(",", ":"))` + NUL, keys in the given order.
    package static func commandFrame(name: String, parameter: [(String, BluetoothJSONScalar)]) -> Data
    /// `UTF8(setting.rawValue) + [0x00]`.
    package static func readRequestFrame(_ setting: BluetoothReadSetting) -> Data
    /// `UTF8(token.rawValue)` — no NUL.
    package static func authFrame(_ token: BluetoothAuthToken) -> Data
    /// Bytes before the first 0x00, strict UTF-8; throws `.decoding("bluetooth \(context): invalid UTF-8")`.
    package static func responseText(_ data: Data, context: String) throws -> String
    /// Python `json.dumps` string escaping with ensure_ascii (§3.9), including the quotes.
    package static func jsonString(_ s: String) -> String

    // Command frames (§3.7) — the only producers of command bytes.
    package static func machineChangeMode(on: Bool) -> Data
    package static func settingBoilerEnable(steamOn: Bool) -> Data
    package static func settingSmartStandby(minutes: Int, mode: SmartStandbyAfter, enabled: Bool) -> Data
    package static func settingBoilerTarget(boiler: BluetoothBoilerType, celsius: Double) -> Data
}
```

### 6.9 `Sources/Angstrom/Bluetooth/BluetoothShotCounterModels.swift` and `BrewingStateMachine.swift`

```swift
/// Arbitrary JSON (used for `MachineStatistics`, whose meaning upstream marks unverified).
public enum BluetoothJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BluetoothJSONValue])
    case object([String: BluetoothJSONValue])
    public subscript(key: String) -> BluetoothJSONValue? { get }   // object member, else nil
}

/// Brewing part of a notification; all fields optional (MBT:90-123).
public struct BluetoothBrewingData: Sendable, Hashable {
    public var startedDoseIndex: String?
    public var ev: Bool?
    public var backflush: Bool?
    public var brewingTime: Double?
    public var flushStoppedTime: Double?
    public var flushStoppedDoseIndex: String?
    public var brewingStoppedTime: Double?
    public var brewingStoppedDoseIndex: String?
    public var brewingStoppedStopType: String?
    public var brewingStoppedStopReason: String?
    public init(startedDoseIndex: String? = nil, ev: Bool? = nil, backflush: Bool? = nil,
                brewingTime: Double? = nil, flushStoppedTime: Double? = nil,
                flushStoppedDoseIndex: String? = nil, brewingStoppedTime: Double? = nil,
                brewingStoppedDoseIndex: String? = nil, brewingStoppedStopType: String? = nil,
                brewingStoppedStopReason: String? = nil) { … }
    public var isEmpty: Bool { get }
    /// Copy of self overridden by every non-nil field of `other` (MBT:85-87).
    public func merging(_ other: BluetoothBrewingData) -> BluetoothBrewingData
    // `deriveState(receivedAt:)` is declared in BrewingStateMachine.swift (below).
}

/// A brewing state update (MBT:166-188).
public struct BluetoothShotCounterUpdate: Sendable, Hashable {
    public let state: BluetoothBrewingState
    public let timerValue: Double?
    public let finalShotTime: Double?
    public let startedDoseIndex: String?
    public let stopReason: String?
    public let receivedAt: Date
    public let raw: BluetoothBrewingData
    /// Earliest estimate of the running shot's start; non-nil only for `.brewing`.
    public var brewingStartTime: Date?
    /// When `brewingStartTime` is nil, `state == .brewing` and `timerValue` is non-nil, it
    /// defaults to `receivedAt - timerValue`.
    public init(state: BluetoothBrewingState, timerValue: Double? = nil, finalShotTime: Double? = nil,
                startedDoseIndex: String? = nil, stopReason: String? = nil, receivedAt: Date,
                raw: BluetoothBrewingData, brewingStartTime: Date? = nil) { … }
}

/// Live machine values carried by shot-counter notifications (MBT:191-213).
public struct BluetoothMachineTelemetry: Sendable, Hashable {
    public var coffeeBoilerTemperature: Double?
    public var steamBoilerTemperature: Double?
    /// Never `.other`: unknown modes decode as nil.
    public var machineMode: MachineMode?
    public var sleep: String?
    public var machineStatistics: BluetoothJSONValue?
    public init(coffeeBoilerTemperature: Double? = nil, steamBoilerTemperature: Double? = nil,
                machineMode: MachineMode? = nil, sleep: String? = nil,
                machineStatistics: BluetoothJSONValue? = nil) { … }
    public var isEmpty: Bool { get }
    public func merging(_ other: BluetoothMachineTelemetry) -> BluetoothMachineTelemetry
}

/// What the client's shot-counter stream delivers.
public enum ShotCounterEvent: Sendable, Equatable {   // not Hashable: LaMarzoccoError is only Equatable
    /// Subscribed (upstream `connection_callback(True)`).
    case subscribed
    /// Subscription lost or stopped (upstream `connection_callback(False)`).
    case unsubscribed
    case brewing(BluetoothShotCounterUpdate)
    /// Only the values present in that notification.
    case telemetry(BluetoothMachineTelemetry)
    /// Angstrom-only: the reconnect loop gave up (3 auth failures, or the characteristic vanished).
    case gaveUp(LaMarzoccoError)
}

/// Parsed notification (§3.8).
package struct DecodedShotCounterNotification: Sendable, Hashable {
    package let brewing: BluetoothBrewingData
    package let telemetry: BluetoothMachineTelemetry
    package init(brewing: BluetoothBrewingData, telemetry: BluetoothMachineTelemetry) { … }
}
```

`Sources/Angstrom/Bluetooth/BrewingStateMachine.swift` (owned by WP-B2):

```swift
extension BluetoothBrewingData {
    /// MBT:125-163 (§4.11).
    public func deriveState(receivedAt: Date) -> BluetoothShotCounterUpdate?
}

/// `_BrewingTracker` (BT:77-111, §4.11).
package struct BrewingTracker: Sendable {
    package init()
    package mutating func process(_ message: BluetoothBrewingData, receivedAt: Date) -> BluetoothShotCounterUpdate?
}

/// §3.8 framing + field rules. nil = drop the notification.
package enum ShotCounterNotificationDecoder {
    package static func decode(_ data: Data) -> DecodedShotCounterNotification?
}
```

### 6.10 `Sources/Angstrom/Bluetooth/BluetoothDiagnostics.swift`

```swift
/// A raw BLE frame on the diagnostic tap (`LaMarzoccoBluetoothClient.rawFrames()`).
public struct RawBluetoothFrame: Sendable, Hashable {
    public enum Direction: Sendable, Hashable { case inbound, outbound }
    public enum Kind: Sendable, Hashable { case write, read, notification, event }
    public let timestamp: Date
    public let direction: Direction
    public let kind: Kind
    /// Lowercase characteristic UUID; nil for `.event`.
    public let characteristic: String?
    /// Verbatim bytes; for `.event`, the UTF-8 marker text.
    public let data: Data
    /// True for the auth write and the token read: display layers MUST redact `data`.
    public let isSecret: Bool
    public init(timestamp: Date, direction: Direction, kind: Kind, characteristic: String?,
                data: Data, isSecret: Bool) { … }

    // `.event` markers (exact text).
    public static let connectingMarker = "[connecting]"
    public static let connectedMarker = "[connected]"
    public static let authenticatedMarker = "[authenticated]"
    public static let disconnectedMarker = "[disconnected]"
    public static let subscribedMarker = "[subscribed]"
    public static let unsubscribedMarker = "[unsubscribed]"
    public static let replayDroppedMarker = "[replay dropped]"
    public static let servicesInvalidatedMarker = "[services invalidated]"
    /// "[mtu <n>]".
    public static func mtuMarker(_ mtu: Int) -> String
}
```

`Sources/Angstrom/Bluetooth/BluetoothOpTable.swift`: `package final class BluetoothOpTable<Key: Hashable & Sendable>`
(not thread-safe, adapter-queue-confined). Its API is `register(_:key:isGATTRequest:complete:)`,
`finish(_:_:abandoning:) -> Bool`, `finishOldest(_:_:) -> Bool`, `owe(_:)`, `isAwaiting(_:) -> Bool`,
and `failAll(where:_:)`, with the exactly-once semantics of §5.4 (finish removes the entry before
completing; an abandoned GATT request owes one reply, which `finishOldest` swallows; `failAll` drops
owed replies). The exact generic signature and per-method semantics are frozen in PLAN §3.1, because
only the adapter and its unit tests use it.

### 6.11 `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient*.swift`

Public surface (frozen):

```swift
/// BLE client for one La Marzocco machine (port of pylamarzocco's LaMarzoccoBluetoothClient).
public actor LaMarzoccoBluetoothClient {
    /// Name prefixes kept by discovery (`BT_MODEL_PREFIXES`).
    public static let machineNamePrefixes: [String]                       // = BluetoothConstants.machineNamePrefixes
    /// The peripheral this client talks to (upstream `address`; a CoreBluetooth UUID, not a MAC).
    public nonisolated let peripheral: BluetoothPeripheralID

    public init(transport: BluetoothTransport, peripheral: BluetoothPeripheralID,
                token: BluetoothAuthToken, logHandler: (@Sendable (String) -> Void)? = nil)

    /// An authenticated link is up.
    public var isConnected: Bool { get }
    /// The last auth read was not 0x01 — usually a wrong token.
    public internal(set) var authenticationFailed: Bool
    /// Shot counter enabled ∧ subscribed ∧ connected.
    public var shotCounterActive: Bool { get }
    /// Edge-triggered `.connected` (after auth) / `.disconnected` (any close, incl. idle).
    public func connectionEvents() -> AsyncStream<ConnectionEvent>
    /// Stop the shot counter (if any) and close the link. Never throws; idempotent.
    public func disconnect() async

    // Discovery & pairing (static; no instance state) — +Discovery.swift
    /// Every peripheral seen, unfiltered (diagnostic; §4.14). `discoverMachines` = this, filtered.
    public static func scanAll(transport: BluetoothTransport,
                               duration: Duration = .seconds(5)) async throws -> [DiscoveredPeripheral]
    public static func discoverMachines(transport: BluetoothTransport,
                                        duration: Duration = .seconds(5)) async throws -> [DiscoveredPeripheral]
    public static func readToken(transport: BluetoothTransport,
                                 peripheral: BluetoothPeripheralID) async throws -> BluetoothAuthToken
    public static func gattTable(transport: BluetoothTransport,
                                 peripheral: BluetoothPeripheralID) async throws -> [BluetoothGATTService]

    // Reads — +Requests.swift
    public func machineMode() async throws -> MachineMode
    public func machineCapabilities() async throws -> BluetoothMachineCapabilities
    public func tankStatus() async throws -> Bool
    public func isPlumbedIn() async throws -> Bool
    public func boilers() async throws -> [BluetoothBoilerDetails]
    public func smartStandby() async throws -> BluetoothSmartStandbyDetails

    // Commands — +Requests.swift. A non-success status is RETURNED, not thrown.
    @discardableResult public func setPower(on: Bool) async throws -> BluetoothCommandStatus
    @discardableResult public func setSteam(on: Bool) async throws -> BluetoothCommandStatus
    @discardableResult public func setSmartStandby(enabled: Bool, mode: SmartStandbyAfter,
                                                   minutes: Int) async throws -> BluetoothCommandStatus
    /// Throws `.operationNotAvailable("temperature must be finite")` for NaN/∞ (D21). No rounding.
    @discardableResult public func setTemperature(boiler: BluetoothBoilerType,
                                                  celsius: Double) async throws -> BluetoothCommandStatus

    // Shot counter — +ShotCounter.swift
    /// True when subscribed (also when already subscribed); false when unsupported. Throws connect/auth errors.
    public func startShotCounter() async throws -> Bool
    /// Unsubscribe and resume idle disconnects; the link stays up.
    public func stopShotCounter() async
    /// Multiplexed shot-counter events; register before `startShotCounter()`.
    public func shotCounterEvents() -> AsyncStream<ShotCounterEvent>

    // Diagnostics — +Requests.swift / main
    public func rawFrames() -> AsyncStream<RawBluetoothFrame>
    /// Verbatim response bytes (before NUL truncation) of one read-setting request.
    public func rawRead(_ setting: BluetoothReadSetting) async throws -> Data
}
```

Internal state (frozen; declared in the main file with **internal** access so sibling-file
extensions can use it):

```swift
    let central: any BluetoothCentral
    let sleeper: any BluetoothSleeper
    let now: @Sendable () -> Date
    let token: BluetoothAuthToken
    let log: (@Sendable (String) -> Void)?
    var timing: BluetoothTiming
    var link: (any BluetoothLink)?
    var linkWatcher: Task<Void, Never>?
    var discovered: Set<GATTUUID>
    var needsRediscovery: Bool
    var reportedConnected: Bool
    var idleTask: Task<Void, Never>?
    var gateBusy: Set<BluetoothGate>
    var gateWaiters: [BluetoothGate: [CheckedContinuation<Void, Never>]]
    var shotCounterEnabled: Bool
    var shotCounterSubscribed: Bool
    var replayPending: Bool
    var tracker: BrewingTracker
    var reconnectTask: Task<Void, Never>?
    var connectionListeners: [UUID: AsyncStream<ConnectionEvent>.Continuation]
    var shotCounterListeners: [UUID: AsyncStream<ShotCounterEvent>.Continuation]
    var rawFrameListeners: [UUID: AsyncStream<RawBluetoothFrame>.Continuation]
    var backgroundTasks: [UUID: Task<Void, Never>]
```

Internal helpers (frozen signatures; owner file in brackets):

```swift
    enum BluetoothGate: Hashable { case connection, request }                         // [main]
    enum BluetoothErrorPhase { case connect, authenticate, request }                  // [main]
    func acquire(_ gate: BluetoothGate) async                                          // [main] FIFO
    func release(_ gate: BluetoothGate)                                                // [main]
    func ensureConnected(refresh: Bool = false) async throws -> any BluetoothLink      // [main] §4.2
    func authenticate(_ link: any BluetoothLink) async throws                          // [main] §3.4
    func resetIdleTimer()                                                              // [main] §4.6
    func disconnectInternal(fromIdleTimer: Bool = false) async                         // [main] caller holds .connection
    func dropConnection(fromIdleTimer: Bool = false) async                             // [main]
    func dropConnectionInBackground()                                                  // [main] tracked Task
    func handleConnectionLost()                                                        // [main] §4.13
    func setConnected(_ connected: Bool)                                               // [main] edge-triggered
    func handleLinkEvent(_ event: LinkEvent, from source: any BluetoothLink)           // [main] §4.7
    func emitRaw(_ kind: RawBluetoothFrame.Kind, _ direction: RawBluetoothFrame.Direction,
                 characteristic: GATTUUID?, data: Data, isSecret: Bool)                // [main] no-op w/o listeners
    func emitRawEvent(_ marker: String)                                                // [main]
    func emitShotCounter(_ event: ShotCounterEvent)                                    // [main]
    nonisolated static func mapTransportError(_ error: any Error,
                                              phase: BluetoothErrorPhase) -> any Error // [main] §4.4.1
    func request(_ characteristic: GATTUUID, frame: Data) async throws -> Data         // [+Requests] §4.4
    func resolve(_ characteristic: GATTUUID, on link: any BluetoothLink) async throws  // [+Requests] §4.5
    func readSetting(_ setting: BluetoothReadSetting) async throws -> String           // [+Requests]
    func sendCommand(_ frame: Data) async throws -> BluetoothCommandStatus             // [+Requests]
    func subscribeShotCounter() async throws -> Bool                                   // [+ShotCounter] §4.9
    func disableShotCounter() -> Bool                                                  // [+ShotCounter]
    func stopNotifyInternal() async                                                    // [+ShotCounter]
    func handleShotCounterNotification(_ notification: GATTNotification)               // [+ShotCounter] §4.10
    func reconnectLoop() async                                                         // [+ShotCounter] §4.13

    // Test seams (package so AngstromTestSupport/UI tests can use them)
    package func setTimingForTesting(_ timing: BluetoothTiming)                        // [main]
    /// Awaits every tracked background task (drops, reconnect loop, idle task excluded).
    package func drainBackgroundWorkForTesting() async                                 // [main]
    package var hasBackgroundWorkForTesting: Bool { get }                               // [main] incl. idle & reconnect
```

### 6.12 `Sources/Angstrom/Bluetooth/Dashboard+Bluetooth.swift`

```swift
/// Inputs of `get_dashboard_from_bluetooth` (MACH:356-369).
public struct BluetoothDashboardState: Sendable, Hashable {
    public var machineMode: MachineMode
    public var isPlumbedIn: Bool
    /// `tankStatus`: true = water present.
    public var tankStatus: Bool
    public var boilers: [BluetoothBoilerDetails]
    public init(machineMode: MachineMode, isPlumbedIn: Bool, tankStatus: Bool,
                boilers: [BluetoothBoilerDetails]) { … }
}

extension Dashboard {
    /// Replace the first widget with `widget.code` (keeping its index), else append `widget`.
    public func upserting(_ widget: Widget) -> Dashboard
    /// Remove every widget with `code`.
    public func removingWidgets(code: String) -> Dashboard
    /// Set `CMMachineStatus.status` only (not the group status). No-op without that widget.
    public func settingMachineState(_ state: MachineState) -> Dashboard
    /// `get_dashboard_from_bluetooth`'s widget synthesis (§4.17).
    public func applyingBluetoothState(_ state: BluetoothDashboardState, model: Model) -> Dashboard
    /// The shot-counter overlay on `CMMachineStatus` (§4.19). nil → self.
    public func overlayingBluetoothBrewing(_ update: BluetoothShotCounterUpdate?) -> Dashboard
}
```

### 6.13 `Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift`

```swift
extension LaMarzoccoCloudClient {
    /// The machine's Bluetooth token from `GET /things` (`bleAuthToken`); nil when the cloud has none.
    public func bluetoothAuthToken(serial: String) async throws -> BluetoothAuthToken?
}
```

It uses the existing internal `authed(path:method:)`, which is visible within the target.

### 6.14 `Sources/AngstromBluetooth/BluetoothTransport+CoreBluetooth.swift` (+ adapter files)

```swift
import Angstrom

extension BluetoothTransport {
    /// A CoreBluetooth-backed transport. Allocates its CBCentralManager lazily on first use.
    /// Create once per process and share. `showPowerAlert` maps to CBCentralManagerOptionShowPowerAlertKey.
    public static func coreBluetooth(showPowerAlert: Bool = false) -> BluetoothTransport
}

extension BluetoothAuthorization {
    /// `CBManager.authorization` (class property; allocates no manager, so it never prompts).
    public static var current: BluetoothAuthorization { get }
}
```

Every other declaration in `AngstromBluetooth` is `internal` (`CoreBluetoothCentral`,
`CoreBluetoothLink`).

### 6.15 Additions to existing core types

- `Sources/Angstrom/Commands.swift`: add, inside `CommandResponse`:
  ```swift
  package init(id: String, status: CommandStatus, errorCode: String?)
  ```
  (same labels as the synthesized memberwise init, so existing internal call sites still compile).
- No changes to `Widgets.swift`: `Dashboard+Bluetooth.swift` is in the same target and uses the
  internal memberwise initialisers.
- No changes to `Enums.swift`, `Optimistic.swift` or `WebSocket.swift`. All additions go in new
  files. `ConnectionEvent` (`WebSocket.swift:72-75`) is reused unchanged.

### 6.16 AngstromUI `LaMarzoccoMachine` (frozen additions and changes)

```swift
@MainActor @Observable
public final class LaMarzoccoMachine {
    // CHANGED: was `private let client: LaMarzoccoCloudClient`
    let cloudClient: LaMarzoccoCloudClient?
    /// The Bluetooth client, if this machine was created with one.
    public let bluetooth: LaMarzoccoBluetoothClient?
    /// Cloud client or `.cloudOnlyFunctionality` (upstream `@cloud_only`).
    var client: LaMarzoccoCloudClient { get throws }

    // CHANGED access: `public private(set)` → `public internal(set)` for dashboard, settings, schedule,
    // statistics, isLive, isConnected, lastUpdateAt, lastError.
    /// Rendered dashboard: `baseDashboard` + the BLE brewing overlay.
    public internal(set) var dashboard: Dashboard?
    /// Everything except the overlay; what snapshots persist.
    var baseDashboard: Dashboard?

    // NEW observable state
    public internal(set) var isBluetoothConnected: Bool = false
    public internal(set) var isShotCounterActive: Bool = false
    public internal(set) var bluetoothBrewingUpdate: BluetoothShotCounterUpdate? = nil
    public internal(set) var bluetoothTelemetry: BluetoothMachineTelemetry = BluetoothMachineTelemetry()
    public internal(set) var lastShotTime: TimeInterval? = nil

    // NEW non-observable plumbing (@ObservationIgnored)
    @ObservationIgnored var shotCounterTask: Task<Void, Never>?
    @ObservationIgnored var bluetoothConnectionTask: Task<Void, Never>?
    @ObservationIgnored var brewingExpiryTask: Task<Void, Never>?
    @ObservationIgnored var bluetoothEventListeners: [UUID: AsyncStream<MachineBluetoothEvent>.Continuation] = [:]
    @ObservationIgnored var bluetoothBrewingStateTimeout: Duration = .seconds(60)
    @ObservationIgnored var brewingExpirySleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    // Initialisers
    /// Existing signature, unchanged behaviour (cloud only); delegates to the designated init.
    public convenience init(serialNumber: String, client: LaMarzoccoCloudClient, snapshot: MachineSnapshot? = nil)
    /// Designated. Either client may be nil (upstream `LaMarzoccoThing(serial, cloud_client, bluetooth_client)`).
    public init(serialNumber: String, client: LaMarzoccoCloudClient?, bluetooth: LaMarzoccoBluetoothClient?,
                snapshot: MachineSnapshot? = nil)

    public var hasCloudClient: Bool { get }
    public var hasBluetoothClient: Bool { get }

    // Base/overlay funnel [main file]
    func setBaseDashboard(_ dashboard: Dashboard?)
    func updateBaseDashboard(_ transform: (Dashboard) -> Dashboard)
    func renderDashboard()
    // CHANGED access private → internal
    func requireModel(_ supported: Set<Model>, _ what: String) throws
    func capturing<T>(_ body: () async throws -> T) async throws -> T

    // [+BluetoothCommands.swift]
    func bluetoothFirst(
        bluetooth bluetoothOperation: (LaMarzoccoBluetoothClient) async throws -> BluetoothCommandStatus,
        cloud cloudOperation: (LaMarzoccoCloudClient) async throws -> CommandResponse
    ) async throws -> CommandResponse

    // [+BluetoothDashboard.swift]
    @discardableResult public func refreshDashboardFromBluetooth() async throws -> Dashboard
    @discardableResult public func refreshModelFromBluetooth() async throws -> BluetoothMachineCapabilities

    // [+BluetoothConnection.swift]
    public func bluetoothConnectionEvents() async -> AsyncStream<ConnectionEvent>
    func startObservingBluetoothConnection()             // called from init when bluetooth != nil

    // [+ShotCounter.swift]
    @discardableResult public func startShotCounter() async throws -> Bool
    public func stopShotCounter() async
    public func bluetoothEvents() -> AsyncStream<MachineBluetoothEvent>
    func handleShotCounterEvent(_ event: ShotCounterEvent)
    func clearBluetoothBrewingState(notify: Bool)
    func armBluetoothBrewingExpiry()
    func setBluetoothBrewingExpiryForTesting(timeout: Duration,
                                             sleep: @escaping @Sendable (Duration) async throws -> Void)
}
```

Main-file behaviour changes (all in WP-U1):

- Every `dashboard = …` write becomes `setBaseDashboard(…)` or `updateBaseDashboard { … }`, under
  the §4.19 read rule (a value feeding a base write is read from `baseDashboard`, never from
  `dashboard`):
  - **wholesale** → `setBaseDashboard(value)`: the snapshot seed, `refreshDashboard`, `refreshAll`;
  - **merge** → the websocket push in `start()` (today `if let current = self.dashboard { self.dashboard = current.applying(update); self.lastUpdateAt = Date() }`)
    becomes `if self.baseDashboard != nil { self.updateBaseDashboard { $0.applying(update) }; self.lastUpdateAt = Date() }`.
    It is **not** wholesale: a widget-less push keeps the base widgets;
  - **optimistic** → `updateBaseDashboard { $0.settingX(…) }` at every optimistic site. Guard reads
    that only validate an argument (e.g. `dashboard?.groupDoses`) also read `baseDashboard`.
- `snapshot` uses `baseDashboard`.
- `Self.steamLevelModels` / `Self.steamTemperatureModels` are redefined as `Model.steamLevelModels` /
  `Model.steamTemperatureModels`. The other gating sets stay.
- The six BLE-first methods (§4.16) call `bluetoothFirst(bluetooth:cloud:)`. Their gating and
  optimistic updates stay where they are.
- `start()` resolves `let cloud = try client` first (so it throws `.cloudOnlyFunctionality` and
  records `lastError`). `stop()` uses `cloudClient?`.
- `var clientForTesting: LaMarzoccoCloudClient { cloudClient! }` (internal test seam kept).
- `init` calls `startObservingBluetoothConnection()` when `bluetooth != nil`.

`Sources/AngstromUI/MachineBluetoothEvent.swift`:

```swift
/// Bluetooth events of a `LaMarzoccoMachine` (upstream `update_callback`/`telemetry_callback`).
public enum MachineBluetoothEvent: Sendable, Equatable {
    /// A brewing update was applied to `dashboard` (upstream `update_callback(update)`).
    case brewing(BluetoothShotCounterUpdate)
    /// The BLE brewing state is no longer applied — link lost or 60 s without an update
    /// (upstream `update_callback(None)`). NOT sent on `stopShotCounter()`.
    case brewingCleared
    /// One notification's telemetry, after any machine mode was applied to `dashboard`.
    case telemetry(BluetoothMachineTelemetry)
    /// Angstrom-only: the shot counter stopped for good (reconnect gave up).
    case shotCounterStopped(LaMarzoccoError)
}
```

`MachineSnapshot` is **unchanged**. It persists the base dashboard, and no BLE state is
persisted.

### 6.17 `Tests/AngstromTestSupport` (frozen test-support API)

A non-product `.target` at `Tests/AngstromTestSupport`, depending on `Angstrom`, with
`resources: [.copy("Fixtures")]`. Both test targets depend on it. Everything is `package`.

```swift
package extension BluetoothPeripheralID {
    static let fake: BluetoothPeripheralID   // "00000000-0000-0000-0000-000000000001"
}

/// Every op a FakeBluetoothLink performed, in order — the assertion surface.
package enum FakeOp: Equatable, Sendable {
    case discover(refresh: Bool)
    case read(GATTUUID)
    case write(GATTUUID, Data)
    case subscribe(GATTUUID)
    case unsubscribe(GATTUUID)
    case disconnect
}

package final class FakeBluetoothCentral: BluetoothCentral, @unchecked Sendable {
    package init()
    /// Sets the state AND yields it on every `availabilityUpdates()` stream.
    package func setAvailability(_ availability: BluetoothAvailability)
    package func setScanResults(_ results: [DiscoveredPeripheral])
    /// Popped per `connect`; when empty, `makeLink()` is used.
    package func enqueueConnect(_ outcome: Result<FakeBluetoothLink, BluetoothTransportError>)
    package var makeLink: @Sendable () -> FakeBluetoothLink        // default: .laMarzocco(token: "token")
    /// Notification clock. `BluetoothTransport.fake(_:sleeper:clock:)` sets it to `clock.now`; `connect`
    /// copies it into every link it returns (queued or made) before returning it.
    package var now: @Sendable () -> Date                           // default: { Date(timeIntervalSince1970: 0) }
    package var connectCount: Int { get }
    package var connectTimeouts: [Duration] { get }
    /// The peripheral id passed to every `connect(to:timeout:)` attempt, in order (C51).
    package var connectPeripheralIDs: [BluetoothPeripheralID] { get }
    /// When non-nil, every connect attempt with nothing queued throws it instead of using `makeLink()`
    /// (the attempt is still counted and recorded). Default nil.
    package var connectFailure: BluetoothTransportError?
    /// Live `availabilityUpdates()` streams (created and not yet terminated). A stream only sees changes
    /// made after it was created, so a test waits for this to be non-zero before `setAvailability`.
    package var availabilitySubscriberCount: Int { get }
    package var links: [FakeBluetoothLink] { get }
}

package final class FakeBluetoothLink: BluetoothLink, @unchecked Sendable {
    package init(peripheralID: BluetoothPeripheralID = .fake)
    /// Characteristics `discover(_, refresh: false)` reports. Default: all five.
    package var present: Set<GATTUUID>
    /// If non-nil, what `discover(_, refresh: true)` reports (models a stale cache).
    package var presentAfterRefresh: Set<GATTUUID>?
    package var onRead: @Sendable (GATTUUID) throws -> Data
    package var onWrite: @Sendable (GATTUUID, Data) throws -> Void
    /// Awaited before every op is recorded — hold an op in flight (serialisation, cancellation tests).
    /// Every throwing op throws `CancellationError` if the calling task is cancelled when `beforeOp`
    /// returns, as the real seam does (§5.3) — unless the link is already down, in which case
    /// `.notConnected` wins (a dead link is reported as dead, cancelled or not).
    package var beforeOp: (@Sendable (FakeOp) async -> Void)?
    /// Delivered as notifications, stamped `now()`, BEFORE `subscribe` returns (the machine's replay).
    /// Default mirrors upstream's fake (`self.replay = _tick(3.34)`, TBC:176): most upstream shot-counter
    /// tests rely on it consuming the client's replay flag. Set `[]` for no replay (upstream `replay = None`).
    package var replayOnSubscribe: [Data] = [BluetoothTestVectors.tick("3.34")]
    /// Stamps replay notifications; set by the central on `connect`.
    package var now: @Sendable () -> Date                           // default: { Date(timeIntervalSince1970: 0) }
    package var mtu: Int?
    package var gatt: [BluetoothGATTService]
    package var recordedOps: [FakeOp] { get }
    /// The `timeout:` of every discover / read / write / subscribe / gattTable call, in call order (D19):
    /// recorded at call entry, before `beforeOp` is awaited and even if the op then throws, so a held op
    /// can sit earlier here than in `recordedOps`.
    package var requestedTimeouts: [Duration] { get }
    package func notify(_ characteristic: GATTUUID, _ value: Data, at receivedAt: Date)
    /// Yields `.disconnected(error)` once and finishes `events`. Later ops throw `.notConnected`.
    package func drop(_ error: BluetoothTransportError?)
    package func invalidateServices()
    /// A machine accepting `token`: auth reads return [0x01] from the `confirmOnRead`-th read after a
    /// matching auth write ([0x00] otherwise); reads of 0b0b… return `commandResponse`; reads of 0a0b…
    /// return `settingResponses[last setting written to 0a0b…] ?? Data("[]".utf8)`.
    package static func laMarzocco(token: String, confirmOnRead: Int = 1,
                                   commandResponse: Data = BluetoothTestVectors.commandSuccess,
                                   settingResponses: [BluetoothReadSetting: Data] = [:]) -> FakeBluetoothLink
}

/// Tagged sleeper. Purposes in `manual` suspend until `fire` or cancellation; others return immediately.
/// With the default `manual`, a `.poweredOnWait` sleep returns at once, so an availability wait times
/// out immediately; a test that flips availability during the wait passes `[.idleDisconnect, .poweredOnWait]`
/// and fires `.poweredOnWait` to time it out.
package final class ManualBluetoothSleeper: BluetoothSleeper, @unchecked Sendable {
    package init(manual: Set<SleepPurpose> = [.idleDisconnect])
    package func requested(_ purpose: SleepPurpose) -> [Duration]   // every requested duration, in order
    package func startedCount(_ purpose: SleepPurpose) -> Int
    package func pendingCount(_ purpose: SleepPurpose) -> Int       // cancelled sleeps are not pending
    package func fire(_ purpose: SleepPurpose)                      // resumes the oldest pending one
    package func waitForPending(_ purpose: SleepPurpose, count: Int) async
}

package final class BluetoothTestClock: @unchecked Sendable {
    package init(_ start: Date)
    package var now: @Sendable () -> Date { get }
    package func set(_ date: Date)
    package func advance(by seconds: TimeInterval)
}

package extension BluetoothTransport {
    static func fake(_ central: FakeBluetoothCentral, sleeper: ManualBluetoothSleeper = .init(),
                     clock: BluetoothTestClock = .init(Date(timeIntervalSince1970: 0))) -> BluetoothTransport
}

/// Verbatim upstream test constants (§9.3).
package enum BluetoothTestVectors {
    package static let commandSuccess: Data   // {"id":"test-id","message":"Success","status":"success"}  (TBC:47)
    package static let started: Data          // {"BrewingStartedGroup1DoseIndex":"DoseA"}               (TBC:48)
    /// `json.dumps` default separators (WITH spaces), as `_tick` (TBC:51-59).
    package static func tick(_ time: String, backflush: Bool = false) -> Data
}

/// REC, copied verbatim to Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt.
package enum ShotCounterRecording {
    package struct Line: Sendable { package let receivedAt: Date; package let payload: Data; package let isReplay: Bool }
    /// Ports `_load_sessions` (TBC:894-909): skip lines starting with `#` (file comments, REC:1-5); split
    /// each other line at the first space into `HH:MM:SS.fff` (UTC, 2026-10-05) and payload. A payload
    /// ending in `# replay` starts a new session; its first Line is that payload with the suffix removed
    /// and whitespace stripped (`isReplay == true`). Every other line appends to the current session.
    package static func sessions() throws -> [[Line]]
}
```

`tick(_:backflush:)` takes the time as a **string**, so `"3.34"` renders exactly as Python did. For
example `tick("3.34")` = `{"BrewingUpdateGroup1Time": 3.34, "BrewingUpdateGroup1Ev": true, "BrewingUpdateGroup1Backflush": false}`.

---

## 7. File map and work packages

### 7.1 New and changed files

| File | Status | Responsibility / contracts | WP |
|---|---|---|---|
| `Package.swift` | edit | add product `.library(name: "AngstromBluetooth", targets: ["AngstromBluetooth"])`. Add target `.target(name: "AngstromBluetooth", dependencies: ["Angstrom"])` and target `.target(name: "AngstromTestSupport", dependencies: ["Angstrom"], path: "Tests/AngstromTestSupport", resources: [.copy("Fixtures")])`. Add `"AngstromTestSupport"` to the dependencies of **both** test targets. No `unsafeFlags`, no new runtime dependency. | F0 |
| `Sources/Angstrom/Models.swift` | edit | §6.4: 5 error cases + descriptions + `isBluetoothConnectionFailure`. Reword the doc comments at `:25-26`, `:29-31`. | F0 |
| `Sources/Angstrom/Commands.swift` | edit | §6.15: `CommandResponse` `package init` | F0 |
| `Sources/Angstrom/Bluetooth/BluetoothConstants.swift` | new | §6.1 | F0 |
| `Sources/Angstrom/Bluetooth/BluetoothTransport.swift` | new | §6.2 seam + public identity/availability types | F0 |
| `Sources/Angstrom/Bluetooth/BluetoothAuthToken.swift` | new | §6.3 | F0 |
| `Sources/Angstrom/Bluetooth/BluetoothEnums.swift` | new | §6.5 | F0 |
| `Sources/Angstrom/Bluetooth/BluetoothWireCoercion.swift` | new | §6.7 (pure; full implementation in F0) | F0 |
| `Sources/Angstrom/Bluetooth/BluetoothModels.swift` | new | §6.6 types (no decoders) | F0 |
| `Sources/Angstrom/Bluetooth/BluetoothShotCounterModels.swift` | new | §6.9 types incl. `isEmpty`/`merging`, `ShotCounterEvent`, `BluetoothJSONValue` | F0 |
| `Sources/Angstrom/Bluetooth/BluetoothDiagnostics.swift` | new | §6.10 `RawBluetoothFrame` | F0 |
| ~~`Sources/AngstromBluetooth/Placeholder.swift`~~ | not created | **Superseded by PLAN §3.6 R1:** BT-W0-01 creates `BluetoothTransport+CoreBluetooth.swift` with the two §6.14 stubs instead, so the target builds without a placeholder. Its absence is not a finding. | — |
| `Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt` | new | verbatim copy of `REC` | F0 |
| `Tests/AngstromTestSupport/*.swift` | new | §6.17 | T0 |
| `Sources/Angstrom/Bluetooth/BluetoothCodec.swift` | new | §6.8 | B1 |
| `Sources/Angstrom/Bluetooth/BluetoothResponseDecoder.swift` | new | §6.6 decoder | B1 |
| `Sources/Angstrom/Bluetooth/BrewingStateMachine.swift` | new | §6.9 `deriveState`, `BrewingTracker`, `ShotCounterNotificationDecoder` | B2 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient.swift` | new | §6.11 public core + all stored state + `[main]` helpers | B3 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Requests.swift` | new | reads, commands, `rawRead`, `[+Requests]` helpers | B3 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+ShotCounter.swift` | new | shot counter + reconnect, `[+ShotCounter]` helpers | B3 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Discovery.swift` | new | `scanAll`, `discoverMachines`, `readToken`, `gattTable` | B6 |
| `Sources/Angstrom/Bluetooth/BluetoothOpTable.swift` | new | package op table (§5.4) | B7 |
| `Sources/AngstromBluetooth/CoreBluetoothCentral.swift` | new | adapter: central | B7 |
| `Sources/AngstromBluetooth/CoreBluetoothLink.swift` | new | adapter: link | B7 |
| `Sources/AngstromBluetooth/BluetoothTransport+CoreBluetooth.swift` | new | §6.14 | B7 |
| `Sources/AngstromBluetooth/Documentation.docc/AngstromBluetooth.md` | new | catalog landing: `coreBluetooth()`, platform requirements | B7 |
| `Sources/Angstrom/Bluetooth/Dashboard+Bluetooth.swift` | new | §6.12 | B8 |
| `Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift` | new | §6.13 | B9 |
| `Sources/AngstromUI/LaMarzoccoMachine.swift` | edit | §6.16 main-file changes | U1 |
| `Sources/AngstromUI/MachineBluetoothEvent.swift` | new | §6.16 | U1 |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothCommands.swift` | new | `bluetoothFirst` | U1 |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothDashboard.swift` | new | `refreshDashboardFromBluetooth`, `refreshModelFromBluetooth` | U1 |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothConnection.swift` | new | `startObservingBluetoothConnection`, `bluetoothConnectionEvents` | U1 |
| `Sources/AngstromUI/LaMarzoccoMachine+ShotCounter.swift` | new | overlay, expiry, start/stop, `bluetoothEvents` | U2 |
| `Tests/AngstromTests/Bluetooth/*.swift` | new | §9.4 (one owner per file) | B1, B2, B6, B7, B8, B9, T1–T4 |
| `Tests/AngstromUITests/Bluetooth/*.swift` | new | §9.4 | T5, T6 |
| `cli/…` | see §10.6 | | C0, C1 |
| `Sources/Angstrom/Documentation.docc/Angstrom.md`, new `Bluetooth.md` article, `GettingStarted.md`, `Sources/AngstromUI/Documentation.docc/AngstromUI.md`, `CLAUDE.md`, `README.md`, `UPSTREAM.md`, `.github/workflows/docs.yml`, `.github/workflows/upstream-drift.yml` | edit | §11 | D1 |

Files that MUST NOT change: `Widgets.swift`, `Enums.swift`, `Optimistic.swift`, `WebSocket.swift`,
`LaMarzoccoCloudClient.swift`, `Diagnostics.swift`, `MachineSnapshot.swift`, `Stomp.swift`,
`Proof.swift`, `InstallationKey.swift`, `Statistics.swift`, `Settings.swift`, every existing test
file, and `.github/workflows/ci.yml` (its `swift build`/`swift test` already cover new targets).

### 7.2 Work packages and ordering

| Phase | WP | Scope | Depends on |
|---|---|---|---|
| 1 | **F0** core foundation | Every `F0` row. All types compile, and `BluetoothWireCoercion` is fully implemented. Adds `BluetoothEnumsTests.swift` (O04–O07, `Model(bluetoothFamily:)`, maps, steam level) and `BluetoothWireCoercionTests.swift`. | — |
| 2 | **T0** test support | `Tests/AngstromTestSupport/*.swift` (§6.17) + a self-test file `Tests/AngstromTests/Bluetooth/FakeBluetoothTests.swift` | F0 |
| 2 | **B1** codec + decoders | `BluetoothCodec.swift`, `BluetoothResponseDecoder.swift`, `BluetoothCodecTests.swift`, `BluetoothResponseDecoderTests.swift` | F0 |
| 2 | **B2** state machine | `BrewingStateMachine.swift`, `BrewingStateMachineTests.swift` (inline vectors only. The `REC` replay belongs to T3.) | F0 |
| 2 | **B7** adapter | `BluetoothOpTable.swift`, `Sources/AngstromBluetooth/*`, `BluetoothOpTableTests.swift` | F0 |
| 2 | **B8** dashboard transforms | `Dashboard+Bluetooth.swift`, `DashboardBluetoothTests.swift` | F0 |
| 2 | **B9** cloud token | `LaMarzoccoCloudClient+BluetoothToken.swift`, `BluetoothTokenTests.swift` | F0 |
| 2 | **C0** CLI foundation | §10.6 C0 rows | F0 |
| 3 | **B3** client | the three client files + `BluetoothClientSmokeTests.swift` | F0, T0, B1, B2 |
| 4 | **B6** discovery/token/GATT | `+Discovery.swift`, `BluetoothDiscoveryTests.swift` | B3 |
| 4 | **T1–T4** client suites | §9.4 files | B3 |
| 4 | **U1** UI foundation + commands + dashboard + connection | U1 rows | B3, B8 |
| 5 | **U2** UI shot counter | `LaMarzoccoMachine+ShotCounter.swift` | U1 |
| 5 | **T5** UI suites (fallback, side effects, dashboard, device state) | §9.4 | U1 |
| 5 | **C1** CLI `ble` subcommands | §10 | B3, B6, C0 |
| 6 | **T6** UI overlay suite | `ShotCounterOverlayTests.swift` | U2 |
| 6 | **D1** docs and process | §11 | everything |

Each WP must leave `swift build` and `swift test` green at the root, and `swift build/test --package-path cli`
green for CLI WPs.

---

## 8. Platform requirements

### 8.1 Authorization and state → errors

| `CBManagerState` | `CBManager.authorization` | Library behaviour | Error | Cloud fallback (§4.16) |
|---|---|---|---|---|
| `.unknown`, `.resetting` | any | wait up to `poweredOnWait` (10 s) for `.poweredOn` | on timeout `.bluetoothUnavailable(.unknown/.resetting)` | yes |
| `.unauthorized` | `.notDetermined` | prompt pending: wait like `.unknown` | as above | yes |
| `.unauthorized` | `.denied`/`.restricted` | fail fast | `.bluetoothUnavailable(.unauthorized(.denied/.restricted))` | yes |
| `.poweredOff` | any | fail fast | `.bluetoothUnavailable(.poweredOff)` | yes |
| `.unsupported` | any | fail fast | `.bluetoothUnavailable(.unsupported)` | yes |
| `.poweredOn` | `.allowedAlways` | proceed | — | — |

Apps can gate UI on `BluetoothAuthorization.current` (from AngstromBluetooth), which never
allocates a manager and so never prompts. The manager, and therefore the TCC prompt, is created on
first BLE use. Whether `state` reads `.unknown` or `.unauthorized` while the first-run prompt is on
screen is **UNVERIFIED (H3)**.

### 8.2 Info.plist and entitlements (apps)

| Item | Who needs it |
|---|---|
| `NSBluetoothAlwaysUsageDescription` (Info.plist string) | every app or tool that uses `AngstromBluetooth`, on macOS and iOS. On iOS a missing key terminates the app at first CB use (Apple docs). The macOS behaviour without it is **UNVERIFIED (H5)**. |
| `com.apple.security.device.bluetooth` (entitlement) | **only** App-Sandboxed macOS apps |
| `UIBackgroundModes` → `bluetooth-central` | iOS apps that want BLE while backgrounded (the app's decision, §8.6) |

### 8.3 Pronto (signed, notarised macOS menu-bar app)

- Note 06 read `$PRONTO/make-app.sh` and found Pronto is **not sandboxed** (it
  signs with `--options runtime`, no `--entitlements`). It therefore needs only one Info.plist
  addition in that script's heredoc:
  `<key>NSBluetoothAlwaysUsageDescription</key><string>Pronto uses Bluetooth to talk to your espresso machine when it's nearby.</string>`.
  It needs no entitlement, and the hardened runtime has no Bluetooth entitlement (UNVERIFIED, H28:
  notarise a build that scans).
- Pronto adds `.product(name: "AngstromBluetooth", package: "Angstrom")` only if it adopts BLE.
- TCC grants are keyed on the code signature. Ad-hoc or self-signed dev builds may re-prompt
  (**UNVERIFIED, H6**).
- Product decisions for the owner (Q4): the machine likely accepts **one central at a time**
  (`README:231`), so a persistent shot-counter link from the Mac may lock out the phone app. App
  Nap and timer coalescing may delay the idle and reconnect timers in an `LSUIElement` app
  (UNVERIFIED, H19). The app may need `ProcessInfo.beginActivity` while the shot counter runs.

### 8.4 angcli (SwiftPM executable) and TCC

- Embed an Info.plist into the Mach-O. In `cli/Package.swift`, the `angcli` target gets
  `linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Support/Info.plist"])]`.
  The path is relative to the `cli/` package root. This was verified in note 06 (`spmplist/`) to
  build, be readable via `Bundle.main`, and be bound by the signature.
- `unsafeFlags` is allowed because `cli/` is always a root package and never a dependency. The root
  `Package.swift` MUST NOT carry it.
- `cli/Support/Info.plist` keys: `CFBundleIdentifier` = `angstrom.angcli` (owner may change),
  `CFBundleName` = `angcli`, and `NSBluetoothAlwaysUsageDescription` = `angcli talks to your La Marzocco machine over Bluetooth for debugging.`.
- TCC attribution from a terminal (Terminal, iTerm2, VS Code, ssh) is **UNVERIFIED (H7)**. The
  expected behaviour is that the grant goes to the terminal app, and that under ssh/launchd access
  is unauthorized. `angcli` maps `.bluetoothUnavailable` to a clean `CLIError` with guidance.

### 8.5 Tests and CI

- **No test constructs `CBCentralManager` or `CBPeripheral`.** CI (`macos-15`) has no Bluetooth
  permission and possibly no radio. Only `swift build` compiles `AngstromBluetooth`. There is no
  test target for it. `BluetoothOpTable` (core) is unit-tested.

### 8.6 iOS

- v1 is **foreground-only**. Background scanning needs a service UUID filter
  (`CBCentralManager.h:176-178`), and the service UUID is UNVERIFIED (U1).
- An app that declares `bluetooth-central` keeps receiving notifications while backgrounded. The
  library takes no lifecycle actions.
- State restoration (`CBCentralManagerOptionRestoreIdentifierKey`) is **deferred**. Adding a
  `restoreIdentifier:` parameter to `coreBluetooth(...)` later is additive (Q14).
- The adapter compiles for iOS 17 with no `#if os` in core paths. It MUST NOT use the
  macOS-unavailable connection-event APIs.

### 8.7 Identity: what consumers persist

- `BluetoothPeripheralID` is the `CBPeer.identifier` UUID. It is **per Apple device (and possibly
  per app)**. It is not a MAC, cannot be derived from cloud data, and MUST NOT be synced via iCloud
  or the La Marzocco cloud. Its scope across apps, reboots and Bluetooth resets is **UNVERIFIED
  (H9)**. Consumers persist it locally (it is `Codable`) and rescan if `connect` fails with
  "Unknown peripheral".
- Correlating a peripheral with a cloud serial: the advertised name format is **UNVERIFIED (U3,
  H10)**. Until it is settled, the app lets the user pick from `discoverMachines`. A Device
  Information `0x2A25` read is not implemented (U3).
- The **token** is a secret: persist `BluetoothAuthToken.rawValue` in the Keychain. The library
  never persists it, never logs it, and never prints it (`description` is redacted).

---

## 9. Testing strategy

### 9.1 Approach

- XCTest only, matching the repo. Test classes are `final class …Tests: XCTestCase`, `@MainActor`
  in AngstromUITests.
- All client and device-layer tests run on `AngstromTestSupport` fakes. Timing is deterministic
  through `ManualBluetoothSleeper` (tagged, manually fired) and `BluetoothTestClock`. Background
  drops are awaited with `drainBackgroundWorkForTesting()`, never with sleep-polling. Stream events
  are awaited by iterating the stream.
- The device-layer 60 s expiry is driven by `setBluetoothBrewingExpiryForTesting` with a
  gate-controlled sleep (the analogue of upstream's captured `call_later` timers, `TM:99-131`).
- Every upstream behaviour pinned by a test gets a Swift test whose doc comment cites the upstream
  test name and line. Angstrom-only tests (gaps G-* and divergences) say so in their name or comment.

### 9.2 Swift equivalents of upstream fakes

| Upstream | Swift |
|---|---|
| `FakeBleakClient` (`TBC:157-292`) | `FakeBluetoothCentral` + `FakeBluetoothLink` |
| `missing` / `uncached` characteristics | `present` / `presentAfterRefresh` |
| `connect_errors` queue | `enqueueConnect(.failure(…))` |
| `replay` delivered inside `start_notify`, default `_tick(3.34)` (`TBC:176,272-273`) | `replayOnSubscribe`, default `[tick("3.34")]`; `[]` = `replay = None` |
| `drop_connection()` | `drop(_:)` |
| user `disconnect()` also reported via the disconnected callback | `FakeBluetoothLink.disconnect()` yields `.disconnected` (the client has detached, so it is ignored) |
| `IdleTimer` with `IDLE_TIMEOUT` patched to `4321.0` | `ManualBluetoothSleeper(manual: [.idleDisconnect])` |
| `AUTH_READ_INTERVAL`/`RECONNECT_INITIAL_DELAY` patched to 0 | non-manual purposes return immediately, and `requested(_:)` records the durations (so backoff values **can** be asserted, closing gap G-RC-1) |
| `FakeClock` / `_utcnow` | `BluetoothTestClock` + `FakeBluetoothLink.notify(at:)` |
| `_wait_for` / `_no_background_tasks` | `drainBackgroundWorkForTesting()` / `hasBackgroundWorkForTesting` |
| `MagicMock(spec=LaMarzoccoBluetoothClient)` (device tests) | a **real** `LaMarzoccoBluetoothClient` over the fakes, with byte-level scripted responses |
| `expiry_timers` capturing `call_later` | `setBluetoothBrewingExpiryForTesting` |
| `eager_start` re-entrancy | not applicable (no callbacks). Restated in §9.4. |

### 9.3 Vectors (normative; ids are stable)

All bytes are verbatim from upstream unless marked DERIVED.

**9.3.1 Request frames**: BT-REQ-001…006 (§3.7). Auth: **BT-AUTH-001**, the first write is
`(0d0b…, "token")` with no NUL (`TBC:448`). Read requests: **BT-READ-REQ-001…006** =
`machineCapabilities\0` (`TBC:347`), `boilers\0` (`:370`), `smartStandBy\0` (`:399`), `tankStatus\0`
(`:415`), `machineMode\0` (`:429`), `isPlumbedIn\0` (`:1249`).

**9.3.2 Responses** (bytes read → decoded):

| ID | Bytes | Expected | Source |
|---|---|---|---|
| BT-RSP-CMD-001 | `{"id":"test-id","message":"Success","status":"success"}` | `id "test-id"`, `message "Success"`, `status "success"`, `isSuccess` | `TBC:47` |
| BT-RSP-CAP-001 | `[{"family":"MICRA","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":false,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":["BrewingMode","StandBy"],"schedulingType":"smartWakeUpSleep"}]` | `.lineaMicra`, `"MICRA"`, 1, 1, false, 1, 0, `[.brewing, .standby]`, `"smartWakeUpSleep"` | `TBC:342-357` |
| BT-RSP-BOIL-001 | `[{"id":"SteamBoiler","isEnabled":true,"target":131,"current":45},{"id":"CoffeeBoiler1","isEnabled":true,"target":94,"current":65}]` | `[(.steam, true, 131, 45), (.coffee, true, 94, 65)]` | `TBC:365-384` |
| BT-RSP-SSB-001 | `{"mode":"PowerOn","minutes":42,"enabled":"true"}` | `(.powerOn, 42, true)` | `TBC:392-402` |
| BT-RSP-TANK-001 | `"true"` | `true` | `TBC:410-416` |
| BT-RSP-MODE-001 | `"BrewingMode"` | `.brewing` | `TBC:424-430` |
| BT-RSP-MODE-002 | `"BrewingMode"\0\0garbage` | `.brewing` | `TBC:1227-1230` |
| BT-RSP-PLUMB-001…004 | `true` / `false` / `"true"` / `"false"` | `true` / `false` / `true` / `false` | `TBC:1236` |
| BT-RSP-EMPTY-001 | `[]` on `boilers` | `[]` | `TBC:1274` |
| BT-RSP-SSB-002 (D5) | `{"mode":"PowerOn","minutes":42,"enabled":"false"}` | `enabled == false` (upstream: `True`) | Angstrom-only |
| BT-RSP-CAP-002 | family `"LINEA"` / `"GS3"` / `"LINEAMINI2023"` / `"FOO"` | `.lineaMini` / `.gs3AV` / `.lineaMiniR` / `.decoding` | `TMO:407-418`, `CONST:217` |

Conftest statuses (**BT-CMDSTATUS-CONF**, `CONF:183-195`): `id "ble"`, `status "success"`, messages
`"power on"`, `"boiler enable success"`, `"Setting Temperature Success"`, `"Success"`. Failure:
`{"id":"ble","message":"Failed","status":"error"}` (`TBD:517-519`).

**BT-COERCE** (decoder level, §3.10). "Upstream" is the result of running the input through the
`4c639ee` model's `from_dict`/`from_json` with mashumaro 3.17 (reproduce with X3, PLAN §6.1). Unless a
D-id is given, Angstrom's result is the same.

| ID | Decoder ← input | Upstream (executed) | Angstrom |
|---|---|---|---|
| BT-COERCE-001 | `commandStatus` ← `{"id":"a","message":null,"status":"success"}` | `message='None'`, success | `message "None"`, `isSuccess` |
| BT-COERCE-002 | `commandStatus` ← `{"id":5,"message":true,"status":"success"}` / `{"id":"a","message":[1],"status":"success"}` | `id='5'`, `message='True'` / `message='[1]'` | same texts |
| BT-COERCE-003 | `commandStatus` ← `{"id":"a","status":"success"}` / `[1]` | `MissingField` / `ValueError` | `.decoding("bluetooth command: …")` |
| BT-COERCE-004 | `capabilities` ← BT-RSP-CAP-001 with `"schedulingType":null` / `5` | `'None'` / `'5'` | same |
| BT-COERCE-005 | `boilers` ← BT-RSP-BOIL-001 with steam `"isEnabled"` = `[]` / `{"a":1}` / `null` / `0` | `False` / `True` / `False` / `False` | same |
| BT-COERCE-006 | `boilers` ← steam `"isEnabled":"false"` | `True` | `false` (D5) |
| BT-COERCE-007 | `boilers` ← steam `"target"` = `127.5` / `"127.5"` / `null` | `127` / `InvalidFieldValue` / `InvalidFieldValue` | `127.5` / `127.5` (D9) / `.decoding` |
| BT-COERCE-008 | `boilers` ← `"id":"Foo"`; `capabilities` ← `"machineModes":["BrewingMode","Foo"]` | `InvalidFieldValue` (both) | `.other("Foo")`; `[.brewing, .other("Foo")]` (D5) |
| BT-COERCE-009 | `smartStandby` ← `"minutes"` = `42.7` / `"42"` / `null` | `42` / `42` / `InvalidFieldValue` | `42` / `42` / `.decoding` |
| BT-COERCE-010 | `smartStandby` ← `"minutes"` = `1e300` / `12345678901234567890` | accepted (unbounded `int`) | `.decoding` (D5; never traps) |
| BT-COERCE-011 | `capabilities` ← `"groupsNumber":"1.0"`; `"family":5`; `"family":"linea mini 2023"` | `InvalidFieldValue`; `InvalidFieldValue`; `Linea Mini R` | `.decoding`; `.decoding`; `.lineaMiniR` |

**9.3.3 Notifications.** `STARTED` = `{"BrewingStartedGroup1DoseIndex":"DoseA"}` (`TBC:48`).
`tick(t)` uses spaced separators (`TBC:51-59`).

- **BT-NTF-SEQ-001** (`TBC:749-768`), giving `(state, timerValue, finalShotTime)`:
  1 `STARTED` → (brewing, 0.0, nil). 2 `tick("0.1")` → (brewing, 0.1, nil). 3 `tick("1.17")` →
  (brewing, 1.17, nil). 4 `{"BrewingUpdateGroup1Ev":false}` → (brewingStopped, nil, nil). 5
  `{"BrewingStoppedGroup1Time":27.4,"BrewingStoppedGroup1DoseIndex":"DoseA","BrewingStoppedGroup1StopType":"X","BrewingStoppedGroup1StopReason":"Manual"}`
  → (brewingStopped, nil, 27.4). 6 `{"FlushStoppedGroup1Time":3.1}` → (flushed, nil, nil). 7
  `STARTED` → (brewing, 0.0, nil). 8 `tick("0.1", backflush: true)` → (backflushing, nil, nil).
  9 `{"BrewingUpdateGroup1Ev":false}` → (brewingStopped, nil, nil). 10 `tick("5.2")` →
  (brewing, 5.2, nil).
- **BT-NTF-SEQ-002** (`TBC:769-781`): `STARTED` → (brewing, 0.0, nil). Then **no brewing event**
  for each of: `not json`, `{"BrewingUpdateGroup1Time":"abc"}`, `[]`, bytes `FF FE`,
  `{"SteamBoilerUpdateTemperature":130}`. Then `{"SomethingNew":1,"BrewingUpdateGroup1Time":3.5}` →
  (brewing, 3.5, nil), and `tick("4.5") + [0x00]` → (brewing, 4.5, nil).
- **BT-NTF-REPLAY-001** (`TBC:811-845`): replay `{"MachineMode":"StandBy"}`, delivered either
  inside `subscribe` or right after it → no events. The next identical notification →
  `.telemetry(machineMode: .standby)` exactly once.
- **BT-NTF-TEL-001…005** (`TBC:848-884`): `{"CoffeeBoiler1UpdateTemperature":95}` → telemetry
  coffee 95. `{"SteamBoilerHeatingCoeff":"[{\"temperature\":18}]"}` → nothing.
  `{"MachineMode":"Unknown"}` → nothing. `{"MachineStatistics":"{\"tot_doses\":2123}"}` →
  `machineStatistics == .object(["tot_doses": .number(2123)])`.
  `{"BrewingStartedGroup1DoseIndex":"DoseA","SteamBoilerUpdateTemperature":127}` → `.brewing`
  (state brewing) **then** `.telemetry(steam 127)`.
- **BT-NTF-START-001** (`TBC:980-1006`): clock `2026-10-05T07:00:00Z` = t0. `STARTED` →
  `brewingStartTime == t0`. Advance 5.07 s, `tick("5")` → timer 5, bst `t0`,
  `startedDoseIndex "DoseA"`. Advance 1 s, `tick("6.1")` → bst `t0 − 0.03 s`.
- **BT-NTF-RESET-001** (`TBC:1033-1048`): `STARTED`, link drop, reconnect (the replay is dropped),
  then `{"BrewingUpdateGroup1Backflush":false}` → no brewing event.
- **BT-NTF-COERCE** (executed upstream like BT-COERCE; client level, each after `STARTED` where it
  says so):
  - 001 `{"BrewingUpdateGroup1Ev":"false","BrewingUpdateGroup1Time":1}` after a reset →
    `.brewingStopped` (D5; upstream `.brewing(1.0)`).
  - 002 `{"MachineStatistics":{"a":1}}` → dropped, and so is `{"MachineStatistics":true}` and
    `{"MachineStatistics":"{bad"}` (parity).
  - 003 `{"MachineStatistics":null,"CoffeeBoiler1UpdateTemperature":90}` → `.telemetry(coffee 90)`,
    `machineStatistics == nil` (parity: null is unset).
  - 004 `{"MachineStatistics":"null"}` → nothing emitted (parity: `is_empty`).
    `{"MachineStatistics":"null","CoffeeBoiler1UpdateTemperature":90}` → `.telemetry(coffee 90)` only.
  - 005 `{"MachineStatistics":"5"}` → `.telemetry(machineStatistics: .number(5))` (parity).
  - 006 `STARTED`, then `{"BrewingUpdateGroup1Ev":[]}` → `.brewingStopped` (parity: `bool([])`).
  - 007 `{"BrewingStartedGroup1DoseIndex":["a"]}` → `.brewing`, `startedDoseIndex` `["a"]` (D5:
    upstream `"['a']"`). `{"Sleep":{"a":1}}` → `sleep` `{"a":1}` (D5: upstream `"{'a': 1}"`);
    `{"Sleep":5}` → `"5"` (parity).
  - 008 `STARTED`, then `{"BrewingUpdateGroup1Time":"nan","BrewingUpdateGroup1Ev":true}` → dropped,
    tracker unchanged (D5: upstream merges `nan` into the tracker, then `derive_state` raises
    `ValueError` inside the notification callback, so nothing is emitted either).
  - 009 `{"CoffeeBoiler1UpdateTemperature":"inf"}`, the bare literal
    `{"CoffeeBoiler1UpdateTemperature":NaN}`, and `{"CoffeeBoiler1UpdateTemperature":1e400}` →
    dropped (D5: upstream emits telemetry `inf` / `nan` / `inf`).
  - 010 `{"BrewingUpdateGroup1Time":"1_0","BrewingUpdateGroup1Ev":true}` → dropped (D5: Python's
    `float("1_0")` is `10.0`).
- **Angstrom-only**: BT-NTF-LATE-001 `BSTOP(10.0)` then `tick("10.2")` →
  (brewingStopped…) then (brewing, 10.2) (parity, no guard). BT-NTF-FRAG-001
  `{"BrewingUpdateGroup1Ev":true}` → nothing, then `{"BrewingUpdateGroup1Time":2.0}` → (brewing, 2.0,
  bst = t_r − 2).

**9.3.4 BT-REC-001: recorded Linea Micra morning** (`REC`, `TBC:894-976`). Harness
(`ShotCounterRecording.sessions()`, §6.17): lines starting with `#` are file comments and are skipped.
Every other line is `HH:MM:SS.mmm <payload>`, a notification at `2026-10-05T…Z`. A data line whose
payload ends with `# replay` (a trailing comment, e.g. `REC:6`, `REC:73`) starts a new session; its
replay is that payload with the suffix removed and whitespace stripped (`TBC:904-906`). Per session:
`startShotCounter()` with the replay as `replayOnSubscribe`, then each line, then
`stopShotCounter()`. Upstream assertions (normative):

1. Grouped brewing states: `[(brewing,3),(flushed,1),(brewing,3),(flushed,1),(brewing,13),(brewingStopped,1),(brewing,10),(flushed,1)]` (33 updates).
2. `receivedAt` of updates with `timerValue == 0.0`: `07:50:02.612`, `07:50:09.360`, `07:57:49.729`, `07:59:22.007`.
3. For every `.brewing` update: `0 ≤ startEventReceivedAt − brewingStartTime < 0.05 s`.
4. The single stop: received `07:58:02.461`, `finalShotTime 12.727`, `stopReason "Manual"`, `startedDoseIndex "ContinuousDose"`.
5. Telemetry `machineMode`s, in order: `[.standby, .standby]`.
6. Merged telemetry: coffee `87`, steam `115`, sleep `"command"`, `machineStatistics["tot_doses"] == .number(2123)`.

Finer golden (DERIVED by hand trace in note 02 §7.1, and independently by a scratch
re-implementation in note 04 §3.6. Both agree, and both reproduce assertions 1–6). Compare
brewingStartTime with ≤ 1 ms tolerance:

| Lines (REC) | Expected brewingStartTime |
|---|---|
| 15 / 16 / 17 | 07:50:02.612 / 07:50:02.593 / 07:50:02.583, then line 18 FLUSHED |
| 19–21 | 07:50:09.360 (the late tick at line 21 does not move it), then line 22 FLUSHED |
| 38 / 39 / 40–43 / 44–50 | 07:57:49.729 / .723 / .716 / .713, then line 51 BREWING_STOPPED (final 12.727) |
| 59–63 / 64–68 | 07:59:22.007 / 07:59:22.005, then line 69 FLUSHED |

Counts: 43 telemetry events (31 steam, 7 coffee, 2 mode, 2 sleep, 1 statistics), 2 replays dropped,
2 heating-coefficient lines ignored. 33 + 43 + 2 + 2 = 80 data lines.

**9.3.5 Discovery** — BT-DISC-001 (`TBC:1326-1342`): names `MICRA_1, MINI_2, LINEA_3, LINEAR_4, GS3_5, OTHER`
→ `[MICRA_1, MINI_2, LINEA_3, LINEAR_4, GS3_5]` in order. A nil name is skipped.

**9.3.6 Dashboard from Bluetooth** — seed **BT-DASH-SEED-001** (`TBD:68-105`): `CMMachineStatus(standby, [brewing, standby], mode standby)`,
`CMCoffeeBoiler(standby, enabled, enabledSupported false, 93.0, 80…100 step 0.1)`,
`CMSteamBoilerLevel(standby, enabled, enabledSupported true, level1, supported true)`,
`CMSteamBoilerTemperature(standby, enabled, enabledSupported false, 126.0, 126…131 step 1.0, supported true)`.
Model Linea Micra.

- **BT-DASH-SNAP-001** (`SNAP:2-54`): mode brewing. Coffee `(true, 95, 94)`, steam `(false, 128, 50)`,
  tank true, plumbed false → MachineStatus `(poweredOn, [brewing, standby], brewing, nil, nil)`.
  Coffee `(ready, true, false, 95.0, 80, 100, 0.1)`. SteamLevel `(off, false, true, level2, true)`.
  NoWater `alarm false`. **No** `CMSteamBoilerTemperature`. The coffee max stays **100** (existing
  widget). `connected` false.
- **BT-DASH-SNAP-002** (`SNAP:56-108`): empty dashboard, model Linea Mini R. Coffee `(true, 92, 91)`,
  steam `(true, 130, 125)` → Coffee `(ready, true, false, 92.0, 80, **110**, 0.1)`. SteamLevel
  `(ready, true, true, level2, true)`. NoWater false. Machine status as SNAP-001. Appended indices are all 1.
- **BT-DASH-SNAP-003** (`SNAP:110-120`): `setCoffeeTargetTemperature(celsius: 96.5)` → Coffee
  `(standby, true, false, 96.5, 80, 100, 0.1)`.
- **BT-DASH-SNAP-004** (`SNAP:122-132`): `setPower(on: true)` → MachineStatus `mode brewing`,
  **status still standby**.
- **BT-DASH-SNAP-005** (`SNAP:134-145`): model GS3, `setSteamTargetTemperature(celsius: 122.5)` →
  SteamTemperature `(standby, true, false, 122.5, 126, 131, 1.0, supported true)`.
- **BT-DASH-STATUS-001…005**: §4.17 table.
- **BT-DASH-STEAMLVL-001…006** (`TBD:639-648`): target `0→level3`, `126→level1`, `127.9→level1`,
  `128→level2`, `130→level2`, `131→level3`. Plus Angstrom-only `130.5→level3`, `-1→level3`.
- **BT-DASH-GS3-001** (`TBD:269`): model GS3, steam `(true, 128, 120)` → SteamTemperature with
  `enabled true` and `targetTemperature 128.0`, no level widget. **BT-DASH-MINI-001** (`TBD:334`):
  model Linea Mini, steam `(true, 127, 115)` → target 127.0, and a created widget has min 95,
  max 140, `supported false`.
- **BT-DASH-PLUMB-001** (`TBD:674-689`): `isPlumbedIn` reply not JSON → treated as false; tank
  false, boilers `[]` → `NoWater.alarm == true`.

**9.3.7 Fallback** — BT-FALLBACK-001…006 (`TM:134-189`):

| ID | Machine call | BLE frame expected | Cloud call on BLE `.bluetoothConnectionFailed` |
|---|---|---|---|
| 001 | `setPower(on: true)` | BT-REQ-001 | `CoffeeMachineChangeMode` `{"mode":"BrewingMode"}` |
| 002 | `setSteam(on: false)` | `SettingBoilerEnable` `{"identifier":"SteamBoiler","state":false}` | `CoffeeMachineSettingSteamBoilerEnabled` |
| 003 | `setSteamTargetLevel(.level2)` (Micra) | `SettingBoilerTarget` `{"identifier":"SteamBoiler","value":128}` | `CoffeeMachineSettingSteamBoilerTargetLevel` |
| 004 | `setCoffeeTargetTemperature(celsius: 93)` | `{"identifier":"CoffeeBoiler1","value":93}` | `CoffeeMachineSettingCoffeeBoilerTargetTemperature` |
| 005 | `setSteamTargetTemperature(celsius: 124)` (GS3) | `{"identifier":"SteamBoiler","value":124}` | `CoffeeMachineSettingSteamBoilerTargetTemperature` |
| 006 | `setSmartStandby(enabled: true, minutes: 30, after: .powerOn)` | `{"minutes":30,"mode":"PowerOn","enabled":true}` | `CoffeeMachineSettingSmartStandBy` with `after: "PowerOn"` |

Plus: auto-standby (`TM:1133-1152`): `(true, 90)` → cloud `CoffeeMachineSettingAutoStandBy`
`{"mode":"01:30"}`, `(false, 90)` → `"Off"`, and BLE is never written.

**9.3.8 Overlay** — BT-OVL-001 (`TM:784-832`). `receivedAt = 2026-01-01T12:00:00Z`,
`cloudStart = 2026-01-01T11:00:00Z`:

| Step | Event | Expected rendered `CMMachineStatus` / state |
|---|---|---|
| 1 | base `poweredOn`, bst `cloudStart`; `.brewing(timer 12.5)` | `brewing`, bst `11:59:47.5Z`; event `.brewing` |
| 2 | `.brewingStopped(final 27.4)` | `poweredOn`, bst `cloudStart`; `lastShotTime 27.4` |
| 3 | push with widgets: status `brewing`, bst `cloudStart` | rendered `poweredOn` |
| 4 | push `standby` (bst nil), then `.flushed` | `standby`; `lastShotTime` still 27.4 |
| 5 | `.brewing(timer 1)` | `brewing` |
| 6 | link loss (`.unsubscribed`) | event `.brewingCleared`; `standby`, bst nil; `bluetoothBrewingUpdate == nil` |

D2–D14 of note 02 §7.3 (verbatim expectations): D7 stop → no event, `poweredOn`, update nil,
telemetry empty, expiry cancelled (`TM:853-879`). D8 two updates → the first expiry is cancelled.
Firing the second → `poweredOn`, update nil, `.brewingCleared` (`TM:882-907`). D9 `BREWING(3)`,
`STOPPED(27.4)`, BLE refresh with mode standby, fire the expiry → `standby` before and after
(`TM:917-937`). D10 base `poweredOn`/`cloudStart`, `BREWING(3)`, BLE refresh with mode brewing →
still `brewing`. After `STOPPED` → `poweredOn` with bst `cloudStart` (`TM:940-958`). D12 telemetry
`{steam 130}` → mode unchanged. Then `{mode standby, sleep "command"}` → `(mode, status) == (standby, standby)`,
merged `= {steam 130, mode standby, sleep "command"}`. Loss → empty (`TM:961-992`). D13
`BREWING(3)`, telemetry eco → `brewing`. After `FLUSHED` → `(eco, eco)` (`TM:995-1011`).

### 9.4 Parity test matrix

Files are under `Tests/AngstromTests/Bluetooth/` unless prefixed `UI:` (`Tests/AngstromUITests/Bluetooth/`).

| Upstream | Swift test | File (WP) |
|---|---|---|
| C01 `test_ble_set_power` (`TBC:295`) | `BluetoothRequestTests.testSetPowerOnWritesMachineChangeMode` | BluetoothRequestTests (T2) |
| C02 `test_ble_set_temperature` (`TBC:310`) | `…testSetTemperatureSteamWritesSettingBoilerTarget` | T2 |
| C03 `test_ble_set_smart_standby` (`TBC:324`) | `…testSetSmartStandbyWritesMinutesModeEnabled` | T2 |
| C04 `test_ble_get_machine_capability` (`TBC:338`) | `…testGetMachineCapabilitiesDecodesFirstElement` | T2 |
| C05 `test_ble_get_boiler_details` (`TBC:361`) | `…testGetBoilersDecodesList` | T2 |
| C06 `test_ble_get_smart_standby_details` (`TBC:388`) | `…testGetSmartStandbyAcceptsStringBool` | T2 |
| C07 `test_ble_get_tank_status` (`TBC:406`) | `…testGetTankStatusStringTrue` | T2 |
| C08 `test_get_machine_mode` (`TBC:420`) | `…testGetMachineModeBrewing` | T2 |
| C09 `test_persistent_connection_auto_connect` (`TBC:434`) | `BluetoothConnectionTests.testFirstCommandConnectsAndAuthenticates` | BluetoothConnectionTests (T1) |
| C10 `test_persistent_connection_reuse` (`TBC:454`) | `…testSequentialCommandsReuseConnection` | T1 |
| C11 `test_auto_disconnect_after_idle` (`TBC:475`) | `…testIdleTimeoutDisconnects` | T1 |
| C12 `test_timer_reset_on_new_command` (`TBC:493`) | `…testCommandRestartsIdleTimer`, restated: exactly one pending idle sleep after each command; firing it disconnects | T1 |
| C13 `test_concurrent_commands_thread_safe` (`TBC:516`) | `…testConcurrentCommandsConnectOnce` (writes `[auth, write, write, write]`) | T1 |
| C14 `test_exception_triggers_disconnect` (`TBC:544`) | `…testCommandErrorDropsIdleConnection` (throws `.bluetoothConnectionFailed`) | T1 |
| C15 `test_characteristic_resolution_failure_clears_cache` (`TBC:565`) | `…testMissingCharacteristicRediscoversThenDrops` (one `discover(refresh: true)`, then disconnect) | T1 |
| C16 `test_is_connected_property` (`TBC:584`) | `…testIsConnectedLifecycle` | T1 |
| C17 `test_reconnect_after_disconnect` (`TBC:600`) | `…testCommandAfterManualDisconnectReconnects` | T1 |
| C18 `test_auth_read_back_failure` (`TBC:617`) | `BluetoothAuthTests.testWrongTokenReadsTenTimesThenFails` (10 auth reads, 9 `.authPoll` sleeps of 50 ms, disconnect once) | BluetoothAuthTests (T1) |
| C19 `test_auth_read_back_retries_until_confirmed` (`TBC:636`) | `…testAuthRetriesUntilConfirmed` (3 auth reads + 1 status read) | T1 |
| C20 `test_start_shot_counter_characteristic_missing` (`TBC:652`) | `ShotCounterLifecycleTests.testMissingCharacteristicReturnsFalseAfterOneRediscovery` (connects with `refresh` `[false, true]`, one extra disconnect, stays connected, idle re-armed) | ShotCounterLifecycleTests (T3) |
| C21 `test_start_shot_counter_rediscovers_services` (`TBC:677`) | `…testStaleServiceCacheRediscoversCharacteristic` (`presentAfterRefresh`) | T3 |
| C22 `test_start_shot_counter` (`TBC:699`) | `…testStartSubscribesAndDisconnectUnsubscribes` | T3 |
| C23 `test_shot_counter_suppresses_auto_disconnect` (`TBC:719`) | `…testShotCounterSuppressesIdleDisconnect` | T3 |
| C24 `test_shot_counter_state_machine[sequence]` | `ShotCounterNotificationTests.testSequence` (BT-NTF-SEQ-001) + `BrewingStateMachineTests.testSequence` (B2) | T3, B2 |
| C25 `…[malformed]` | `…testMalformedPayloadsAreDropped` (SEQ-002) + B2 decoder test | T3, B2 |
| C26/C27 `test_shot_counter_discards_replay[during/after]` | `…testReplayDuringSubscribeIsDropped`, `…testReplayAfterSubscribeIsDropped` | T3 |
| C28 `test_shot_counter_telemetry` (`TBC:848`) | `…testTelemetryRoutingAndParsing` (TEL-001…005) | T3 |
| C29 `test_shot_counter_recorded_sessions` (`TBC:912`) | `ShotCounterRecordedSessionTests.testRecordedMorning20261005` (BT-REC-001 + golden) | T3 |
| C30 `test_shot_counter_brewing_start_time` (`TBC:980`) | `ShotCounterNotificationTests.testBrewingStartTimeIsEarliestEstimate` | T3 |
| C31 `test_shot_counter_callback_exception_is_caught` (`TBC:1009`) | restated: `…testCancelledConsumerDoesNotAffectClient` (a stream consumer that stops iterating does not stop delivery to other listeners or break the client) | T3 |
| C32 `test_shot_counter_reconnects_after_disconnect` (`TBC:1022`) | `ShotCounterReconnectTests.testReconnectsAndResetsTrackerAfterLinkLoss` | ShotCounterReconnectTests (T4) |
| C33 `…reconnect_retries_failed_connections` (`TBC:1053`) | `…testReconnectRetriesThroughConnectErrors`. Upstream mocks `establish_connection` (which retries internally) as one call. In Swift `central.connect` is one attempt, so to fail a whole reconnect attempt the test enqueues **3** failures (`.disconnected(code: 7)` ×3), then 3 × `.timedOut`, then success. Expect `connectCount == 1 + 3 + 3 + 1 = 8`, events `[.subscribed, .unsubscribed, .subscribed]`, `requested(.reconnectBackoff) == [1 s, 2 s, 4 s]`. | T4 |
| C34 `…gives_up_after_auth_failures` (`TBC:1072`) | `…testGivesUpAfterThreeAuthFailures`: `connectCount == 4` (initial + 3; auth failures are not retried inside a connect), `requested(.reconnectBackoff) == [1 s, 1 s, 1 s]`, `authenticationFailed`, not active, not connected, `hasBackgroundWorkForTesting == false`, plus `.gaveUp(.bluetoothAuthenticationFailed)` | T4 |
| C35 `…no_reconnect_after_disconnect` (`TBC:1094`) | `…testUserDisconnectDoesNotReconnect` | T4 |
| C36 `test_start_shot_counter_twice` (`TBC:1108`) | restated: `ShotCounterLifecycleTests.testStartTwiceSubscribesOnce` (one subscribe, no second `.subscribed`, returns true) | T3 |
| C37/C38 `test_stop_shot_counter_reentrant[…]` (`TBC:1125`) | restated: `…testStopFromEventConsumerIsNoOp` (a consumer calling `stopShotCounter()`/`disconnect()` on `.unsubscribed` → one unsubscribe, events `[.subscribed, .unsubscribed]`) | T3 |
| C39 `test_machine_stop_from_update_callback` (`TBC:1156`) | `UI: ShotCounterOverlayTests.testStopFromEventConsumerDoesNotRecurse` | T6 |
| C40 `…notifies_connection_callback` (`TBC:1183`) | `ShotCounterLifecycleTests.testDisconnectReportsUnsubscribed` | T3 |
| C41 `test_cancelled_connect_does_not_keep_unauthenticated_link` (`TBC:1197`) | `BluetoothAuthTests.testCancellationDuringAuthDropsLink` (`beforeOp` holds the auth read; cancel; 1 disconnect; no `.connected`) | T1 |
| C42 `test_read_response_is_nul_terminated` (`TBC:1223`) | `BluetoothRequestTests.testReadResponseCutAtFirstNul` | T2 |
| C43–46 `test_get_plumbed_in[…]` (`TBC:1234-1250`) | `…testGetPlumbedIn` (4 cases) | T2 |
| C47 `test_requests_are_atomic` (`TBC:1253`) | `BluetoothConnectionTests.testRequestWriteReadPairsAreAtomic` | T1 |
| C48 `test_command_error_keeps_shot_counter_connection` (`TBC:1287`) | `ShotCounterLifecycleTests.testCommandErrorKeepsShotCounterLink` | T3 |
| C49 `test_authentication_failed_flag` (`TBC:1305`) | `BluetoothAuthTests.testAuthenticationFailedFlagSetAndCleared` | T1 |
| C50 `test_discover_devices_prefixes` (`TBC:1326`) | `BluetoothDiscoveryTests.testNamePrefixFilter` | BluetoothDiscoveryTests (B6) |
| C51 `test_ble_device_callback` (`TBC:1345`) | restated: `…testConnectUsesStoredPeripheralID` (`connect(to: peripheral)` on every reconnect; assert `FakeBluetoothCentral.connectPeripheralIDs`) | B6 |
| C52 `test_connection_callback_connect_and_idle_disconnect` (`TBC:1361`) | `BluetoothConnectionTests.testConnectionEventsConnectAndIdle` | T1 |
| C53 `test_connection_callback_connection_lost` (`TBC:1382`) | `…testConnectionEventsDeduplicate` | T1 |
| C54 `…not_called_on_failed_authentication` (`TBC:1405`) | `BluetoothAuthTests.testUnauthenticatedLinkNeverReportedConnected` | T1 |
| C55 `test_connection_callback_unregister` (`TBC:1424`) | restated: `BluetoothConnectionTests.testCancelledEventStreamStopsDelivery` | T1 |
| D01 `test_get_dashboard_from_bluetooth` (`TBD:110`) | `UI: BluetoothDashboardRefreshTests.testRefreshMicraFromBluetooth` (SNAP-001; no capabilities read) | T5 |
| D02 `test_get_dashboard_no_bluetooth` (`TBD:183`) | `…testRefreshWithoutClientThrows` | T5 |
| D03 `test_get_model_info_from_bluetooth` (`TBD:189`) | `…testModelInfoFromCapabilities` (BLE family `"GS3"` → `.gs3AV`; upstream injects `ModelName.GS3` directly, see §9.3.2) | T5 |
| D04 `…initializes_missing_widgets` (`TBD:213`) | `…testRefreshCreatesMissingWidgetsMiniR` (SNAP-002) | T5 |
| D05 `…without_steam_level_support` (`TBD:269`) | `…testRefreshGS3UsesSteamTemperature` | T5 |
| D06 `…mini_original_temperature_only` (`TBD:334`) | `…testRefreshOriginalMiniUsesSteamTemperature` | T5 |
| D07/D08 `test_set_power[_off]_updates_dashboard` | `UI: BluetoothCommandSideEffectTests.testSetPowerUpdatesModeOnly` / `…OffUpdatesMode` | T5 |
| D09 `test_set_steam_updates_dashboard` | `…testSetSteamUpdatesEnabled` | T5 |
| D10 `test_set_coffee_temp_updates_dashboard` | `…testSetCoffeeTempUpdatesWidget` (SNAP-003) | T5 |
| D11 `test_set_steam_level_updates_dashboard` | `…testSetSteamLevelUpdatesWidget` | T5 |
| D12 `test_set_steam_temp_updates_dashboard` | `…testSetSteamTempUpdatesWidget` (SNAP-005) | T5 |
| D13 `test_failed_command_does_not_update_dashboard` (`TBD:506`) | restated (D18): `…testNonSuccessStatusWithoutCloudThrowsCommandFailed` (widget unchanged) | T5 |
| D14 `test_bluetooth_exception_does_not_update_dashboard` (`TBD:533`) | restated (D18): `…testBluetoothErrorWithoutCloudRethrows` (widget unchanged) | T5 |
| D15–19 `…_statuses[…]` | `UI: BluetoothDashboardRefreshTests.testStatusDerivation` (5) + `DashboardBluetoothTests` pure (B8) | T5, B8 |
| D20–25 `…_steam_level[…]` | `BluetoothEnumsTests.testSteamLevelFromTarget` (6+2) | F0 |
| D26 `…plumb_in_unsupported` (`TBD:674`) | `UI: BluetoothDashboardRefreshTests.testPlumbInUnsupportedFallsBackToTank` | T5 |
| M01–12 `test_bluetooth_command_with_cloud_fallback[…]` (`TM:192-237`) | `UI: BluetoothFallbackTests.testCommandUsesBluetoothThenCloud` (12: six commands × {BLE ok → no cloud call; BLE `.bluetoothConnectionFailed` → one cloud call}) | BluetoothFallbackTests (T5) |
| M13 `test_failing_command` (`TM:486`) | restated: `…testBothTransportsFailThrowsCloudError` | T5 |
| M14 `test_connect_bluetooth_shot_counter` (`TM:745`) | `UI: ShotCounterOverlayTests.testStartIgnoresCloudSupportFlag` (+ no client → false) | T6 |
| M15 `test_register_bluetooth_connection_callback` (`TM:765`) | `…testBluetoothConnectionEventsForwardOrFinish` | T6 |
| M16 `test_shot_counter_overrides_machine_status` (`TM:784`) | `…testOverrideLifecycle` (BT-OVL-001) | T6 |
| M17 `…falls_back_to_websocket_callback` (`TM:835`) | restated (D13): `…testBrewingUpdateRendersObservableDashboard` | T6 |
| M18 `test_disconnect_bluetooth_shot_counter` (`TM:853`) | `…testStopRestoresSilently` | T6 |
| M19 `test_shot_counter_state_expires` (`TM:882`) | `…testStaleStateExpiresAfter60s` | T6 |
| M20 `…refresh_after_shot_replaces_cloud_status` (`TM:917`) | `…testBluetoothRefreshBecomesBaseline` | T6 |
| M21 `…refresh_while_brewing_keeps_cloud_start_time` (`TM:940`) | `…testBluetoothRefreshKeepsCloudStartTime` | T6 |
| M22 `test_bluetooth_telemetry` (`TM:961`) | `…testTelemetryMergeAndModeApply` | T6 |
| M23 `test_bluetooth_machine_mode_during_shot` (`TM:995`) | `…testModeDuringShotAppliedAfterShot` | T6 |
| M24 `…machine_mode_falls_back_to_websocket_callback` (`TM:1014`) | restated (D13): `…testTemperatureTelemetryDoesNotChangeDashboard` | T6 |
| M25 `test_bluetooth_shot_counter_active` (`TM:1036`) | `…testShotCounterActiveMirrorsClient` | T6 |
| M26 `test_get_model_info_from_bluetooth_errors` (`TM:1049`) | `UI: BluetoothDashboardRefreshTests.testModelInfoErrors` | T5 |
| M27 `…unknown_model` (`TM:1063`) | restated: `…testUnknownFamilyThrowsAndKeepsModel` (`.decoding`; model unchanged) | T5 |
| M28 `test_get_dashboard_from_bluetooth_error` (`TM:1079`) | `…testRefreshErrorPropagatesWithoutMutation` | T5 |
| M29 `test_set_power_updates_group_status` (`TM:1089`) | `UI: BluetoothCommandSideEffectTests.testSetPowerUpdatesGroupStatus` | T5 |
| M30–31 `test_set_smart_standby_auto_standby[…]` | `UI: BluetoothFallbackTests.testSmartStandbyUsesCloudAutoStandbyWhenSupported` (2) | T5 |
| M32 `test_bluetooth_failure_without_cloud` (`TM:1155`) | restated (D18): `…testBluetoothFailureWithoutCloudRethrows` | T5 |
| T01/T02 `test_connection_properties_*` (`TT:36,48`) | `UI: BluetoothDeviceStateTests.testPropertiesWithoutClients` / `…WithClients` | T5 |
| O01–03 `test_shot_counter_supported[…]` (`TMO:391-404`) | existing coverage. Add `ModelsTests`-style `null` case in `BluetoothEnumsTests.testShotCounterSupportedNull` | F0 |
| O04–07 `test_model_name_from_bluetooth_family[…]` (`TMO:407-418`) | `BluetoothEnumsTests.testFamilyMapping` (4, + `"GS3MP"`, `"gs3 av"`, `"FOO"` → nil) | F0 |
| X01 `test_debug_log_masks_bluetooth_token` (`TCC:322`) | `BluetoothTokenTests.testTokenDescriptionIsRedacted` + `testBluetoothAuthTokenFromThings` (null → nil; `""` → nil; zero placeholder → token) | B9 |

Angstrom-only tests (gaps from note 04 §4 and the divergences), owned by the same files:
G-AUTH-1 (transport error during auth → `.bluetoothConnectionFailed`), G-CONN-5/6/7/8 (drop rules; a
missing characteristic drops even with the shot counter running; idle cancelled on loss; same-link
check), G-RC-1 (backoff `1,2,4,8,16,32,60,60` from `requested(.reconnectBackoff)`), G-RC-2 (auth,
connection error, auth, auth → gives up: cumulative), G-RC-3/4, G-SC-1/4/5/6/7, G-DEV-1 (non-success
→ cloud), G-DEV-2 (`.bluetoothTimedOut` and `.decoding` do not fall back), G-DEV-5/6/7/10/11/12,
D14 (poweredOn cuts the backoff short), D19 (op timeouts map per §4.4.1), the `.servicesInvalidated`
→ rediscovery path, `rawFrames()` (the auth write has `isSecret`, notifications are tapped before the
replay drop, zero cost without listeners), and `readToken` (no NUL strip, ATT error message, always
disconnects).

### 9.5 What CI can and cannot cover

- **Covered** (`swift test` on `macos-15`): codec, decoders, coercion, the state machine, the
  recorded session, the full client lifecycle over fakes, the op table, dashboard transforms, the
  device layer and the CLI formatting and redaction.
- **Compiled only:** `AngstromBluetooth` (`swift build`) and the `angcli ble` commands.
- **Not covered:** real CoreBluetooth behaviour, TCC, MTU, firmware responses. These go through the
  hardware checklist (§9.6), driven by `angcli ble`.

### 9.6 Hardware verification checklist (human)

Run on macOS 14 (the floor), macOS 15, the current macOS, and iOS 17+ where marked. Record raw
values (redacted) in a findings note. Each item lists the model(s) to test. **All**: Linea Micra,
Linea Mini, Linea Mini R, GS3 AV, GS3 MP, if available.

| ID | Check (via `angcli ble …`) | Models | Settles |
|---|---|---|---|
| H1 | `gatt`: services, characteristics, properties | all | U1 service UUID, U2 encryption flags, notify vs indicate on `0e0b` |
| H2 | MTU from `[mtu n]` on a Mac (`angcli`), and on an iPhone in an app that links `AngstromBluetooth` (see below) | all | U14, long-write need |
| H3 | first-run TCC: state and authorization while the prompt is up | — | `poweredOnWait`, §8.1 |
| H4 | deny, restrict, power off; is `didDisconnect` delivered on power-off? | — | §8.1 mapping |
| H5 | build without the usage string (Pronto, angcli) | — | crash vs silent deny |
| H6 | ad-hoc → self-signed → Developer ID rebuilds | — | TCC persistence |
| H7 | angcli from Terminal, iTerm2, ssh, and without the plist | — | TCC attribution |
| H8 | connect while the official app or phone is connected, and the reverse | one | single-central error signature, U12 |
| H9 | `peripheral.identifier` from Pronto vs angcli, across reboot, BT reset, "Forget" | one | identifier scope |
| H10 | `scan --all` (unfiltered, §4.14 `scanAll`): names vs serials | all | U3 (name format, MINI vs LINEA for Mini/Mini R) |
| H11 | (only if the custom-executor design is ever tried) the `assumeIsolated` probe on macOS 14 | — | R-4 |
| H12 | auth polls needed until `0x01` | all | whether 10 × 50 ms suffices |
| H13 | is the first notification after subscribe a replay, and does it precede the CCCD ack? | Micra + one | U15 |
| H14 | `listen` during a shot and at idle: notification lengths vs `REC:23` (418 B) | all with SC | U14 |
| H15 | if MTU < 93: the longest command (smart standby) succeeds | all | long-write support |
| H16 | OS pairing alert or bonded entry after first use | all | U2 |
| H17 | `token` in and out of pairing mode: ATT error code | all | U5, the error message |
| H18 | sleep/wake 5 min with the shot counter running; toggle Bluetooth | one | D14 |
| H19 | menu-bar app hidden 30 min: is the idle disconnect late? | — | App Nap |
| H20 | machine reboot or firmware update while connected → `[services invalidated]` | one | D7 path |
| H21 | iOS app (see below) in background, with and without `bluetooth-central` | one | §8.6 |
| H22 | `read capabilities` family string | **each** model | U13 (GS3 MP `"GS3"` vs `"GS3MP"`; Mini R `"LINEAMINI2023"`) |
| H23 | `cmd temp coffee 93` vs `93.5`; check the machine accepts integral and fractional values | one | U7 |
| H24 | rejected command (e.g. coffee 200 °C): status string and casing | one | U8 |
| H25 | `read isPlumbedIn` on old firmware | oldest available | U9 |
| H26 | `read smartStandBy` with standby disabled: `"enabled":"false"` vs `false` | one | D5 relevance |
| H27 | read latency: is the status always ready right after the write ack? | all | U6 |
| H28 | notarise a Pronto (or angcli) build that links `AngstromBluetooth` and scans; check that Gatekeeper accepts it and the TCC prompt appears with the hardened runtime and no entitlement | — (any Mac with Bluetooth) | §8.3 |

**iOS rows (H2 iPhone part, H21).** They need an iOS app that links `AngstromBluetooth`, declares
`NSBluetoothAlwaysUsageDescription` (and, for H21, `UIBackgroundModes` → `bluetooth-central`), and runs
the §5.8 recipe with a `rawFrames()` listener. No work package builds one: the maintainer supplies it
(for example a scratch app built from the DocC Bluetooth article). If none is available at release
time, these rows are recorded as **not run**, and U14-on-iOS and the §8.6 assumptions ship as
UNVERIFIED in the release notes (owner decision).

---

## 10. angcli additions

### 10.1 Command tree

`angcli ble <subcommand>`: a new `Ble` parent command registered in
`cli/Sources/angcli/AngCLI.swift` (`subcommands: [Listen.self, Dump.self, Machines.self, Ble.self]`).
Each subcommand lives in its own file under `cli/Sources/angcli/Ble/`.

| Subcommand | Needs cloud? | Needs token? | Library surface | Output (stdout, one JSON object per line) |
|---|---|---|---|---|
| `ble scan [--duration <s>=5] [--all]` | no | no | `discoverMachines`; with `--all`, `scanAll` (unfiltered, §4.14) and the count to stderr | `{"id","name","rssi"}` per peripheral (`name` may be null with `--all`) |
| `ble gatt --peripheral <uuid>` | no | no | `gattTable` | `{"service","characteristic","properties":[…]}` per characteristic. Settles H1. |
| `ble token --peripheral <uuid> [--show-secret]` | no | — (pairing mode) | `readToken` | `{"token":"**REDACTED**","length":n}`. The real value only with `--show-secret`. |
| `ble read <setting\|all> [selection]` | optional | yes | `rawRead` + typed read | per setting: `{"ts","setting","raw","decoded"}` (`raw` = UTF-8 text of the verbatim bytes, or hex if not UTF-8) |
| `ble cmd power <on\|off>` / `steam <on\|off>` / `temp <coffee\|steam> <celsius>` / `standby --enabled <bool> --minutes <n> --mode <LastBrewing\|PowerOn>` + `--confirm` | optional | yes | client commands | `{"ts","command","status":{id,message,status},"success":bool}` |
| `ble listen [selection] [--raw\|--decoded]` | optional | yes | `rawFrames`, `connectionEvents`, `shotCounterEvents`, `startShotCounter` | raw frame lines and decoded event lines until SIGINT |

`ble cmd` **actuates hardware**. It refuses to run without `--confirm`, as the design note
(`cli/SPEC.md`) requires for commands with side effects.

### 10.2 Selection: peripheral and token

- **Peripheral:** `--peripheral <uuid>`. Otherwise scan for 5 s and filter by prefix. Exactly one
  match → use it. Several → interactive pick on stderr. None → `CLIError("No La Marzocco machine found nearby")`.
- **Token precedence:** `--ble-token <t>` (discouraged: lands in shell history; the help text says
  so) → env `LAMARZOCCO_BLE_TOKEN` → cloud: `Bootstrap.connect()` + `MachineSelector` (`--serial`)
  + `bluetoothAuthToken(serial:)`. A nil cloud token → `CLIError("The cloud has no Bluetooth token for <serial>. Use 'angcli ble token' in pairing mode or the QR label.")`.
- The token and peripheral ID are **never persisted** by angcli. A
  `serial → peripheral` map in `installation.json` is deferred (Q16).

### 10.3 Output conventions

- Reuse `Stdout`/`Stderr` and the `{ts, dir, …}` line shape of `FramePrinter`
  (`cli/Sources/angcli/Output.swift:50-106`), with the `>>`/`<<` arrows in text mode. A raw BLE
  line is `{"ts","dir":">>"|"<<","kind":"write|read|notification|event","char":"0b0b…","hex":"…","text":"…"}`.
  `text` is present when the bytes are valid UTF-8. For `event`, `text` is the marker.
- A decoded line is `{"ts","event":"connected|disconnected|subscribed|unsubscribed|brewing|telemetry|gaveUp","value":{…}}`.
  `value` uses a CLI-local `Encodable` mirror of `BluetoothShotCounterUpdate` /
  `BluetoothMachineTelemetry`.
- `ble listen` installs `SignalHandler` (SIGINT) → `stopShotCounter()` + `disconnect()`, then exits
  0, mirroring `Listen.swift:34-38`.
- `.bluetoothUnavailable(.unauthorized(_))` → `CLIError("Bluetooth access denied. Grant it to your terminal app in System Settings › Privacy & Security › Bluetooth.")`.
  `.poweredOff` → `CLIError("Bluetooth is off.")`.

### 10.4 Redaction (normative)

- New `Redact.bluetoothFrame(_ frame: RawBluetoothFrame) -> (hex: String, text: String?)` in
  `Output.swift`. If `frame.isSecret`, **both** become `"**REDACTED**"` (`Redact.placeholder`).
  This covers the auth write and the token read.
- Defence in depth: also redact any write to `0d0b7847-e12b-09a8-b04b-8e0922a9abab` and any read of
  `0c0b7847-e12b-09a8-b04b-8e0922a9abab`, whatever `isSecret` says.
- `ble token` masks by default. `--show-secret` prints the raw token, to stdout only.
- No error message, log line or `logHandler` output may contain the token. `BluetoothAuthToken`'s
  `description` is already redacted. Interpolating the token is a review-blocking bug.
- `Redact.secrets(in:)` stays as is (`bleAuthToken` JSON key + STOMP bearer). Its existing tests
  must keep passing.

### 10.5 Platform

`cli/Package.swift`: add `.product(name: "AngstromBluetooth", package: "Angstrom")` to the `angcli`
target dependencies, and the `-sectcreate` linker flags from §8.4. Add `cli/Support/Info.plist`
(§8.4). macOS 14 only (unchanged).

### 10.6 CLI file ownership

| File | Change | WP |
|---|---|---|
| `cli/Package.swift` | add the dependency + `linkerSettings` | C0 |
| `cli/Support/Info.plist` | new | C0 |
| `cli/Sources/angcli/AngCLI.swift` | add `Ble.self` to `subcommands`; mention Bluetooth in `abstract`/`discussion`; `version: "2.0.0"` | C0 |
| `cli/Sources/angcli/Output.swift` | add `Redact.bluetoothFrame` + the UUID rule | C0 |
| `cli/Sources/angcli/Ble/Ble.swift` | new parent command; `subcommands: [BleScan.self, BleGatt.self, BleToken.self, BleRead.self, BleCmd.self, BleListen.self]` | C0 (declares all six; C1 fills them in) |
| `cli/Sources/angcli/Ble/BleSession.swift` | new: peripheral and token selection (§10.2), `BluetoothTransport.coreBluetooth()` | C0 |
| `cli/Sources/angcli/Ble/BleScan.swift`, `BleGatt.swift`, `BleToken.swift`, `BleRead.swift`, `BleCmd.swift`, `BleListen.swift`, `BleOutput.swift` | new. C0 creates stubs that throw `CLIError("not implemented")`, and C1 implements them. | C0 → C1 |
| `cli/Tests/angcliTests/BleTests.swift` | new: redaction, output encoding, token precedence (env/flag parsing only) | C1 |
| `cli/SPEC.md`, `cli/README.md` | a "ble" section, TCC notes, the redaction rules | D1 |

---

## 11. Docs and process changes (WP-D1)

| File | Change |
|---|---|
| `CLAUDE.md` | `:12`: replace "(Bluetooth is explicitly out of scope; cloud only.)" with "Bluetooth uses CoreBluetooth (`AngstromBluetooth`); the same reference-of-record rule applies to `clients/_bluetooth.py`, `models/_bluetooth.py` and the BT paths in `devices/`." Architecture (`:38-108`): add a `Sources/Angstrom/Bluetooth/` subsection, `Sources/AngstromBluetooth/`, `AngstromTestSupport`, the new AngstromUI files, and `angcli ble`. Conventions: "never construct `CBCentralManager` in tests", "BLE command bytes only via `BluetoothCodec`", "the BLE token never in logs or errors". Status: a v2.0.0 paragraph. Remove "Bluetooth remains out of scope". |
| `README.md` | `:5` and `:21-24`: cloud **and Bluetooth**. Add a Bluetooth section: products, pairing/token sources, the shot counter, app requirements (§8.2) and the single-central caveat. Install snippet `from: "2.0.0"`. |
| `UPSTREAM.md` | Scope row (`:24`) and `:26-31`: the watermark now means "cloud **and** Bluetooth parity at v2.5.6". **Do not change the markers at `:15-16`** (still `v2.5.6` / `4c639ee`). Add a "Bluetooth port (v2.0.0)" section listing every divergence D1–D22 with rationale and the UNVERIFIED items. Do not rewrite the historical "out of scope / no port" notes (`:119-163`); append a pointer saying they are superseded by the Bluetooth section. Keep the `e0f0249` note (`:94-100`) and add that the BLE aliases now live in `Model(bluetoothFamily:)`. Runbook triage (`:253-255`): `Bluetooth-only -> skip` becomes `bluetooth (clients/_bluetooth.py, models/_bluetooth.py, BT paths in devices/) -> port`, and the review-surface diff includes those files. |
| `.github/workflows/upstream-drift.yml` | `:97`: "port cloud-relevant changes (skip Bluetooth-only)" → "port cloud and Bluetooth changes". `:60`: fix the comment ("(cloud-relevant paths only)"); the compare is unfiltered. |
| `.github/workflows/docs.yml` | add `--target AngstromBluetooth` next to the existing `--target` flags (`:38-39`) |
| `.github/workflows/ci.yml` | no change (verify that the new targets build and test) |
| `Sources/Angstrom/Documentation.docc/Angstrom.md` | `:7-11` drop "Bluetooth is out of scope; this is a cloud-only client". Add a `### Bluetooth` topic group (`LaMarzoccoBluetoothClient`, `BluetoothTransport`, `BluetoothPeripheralID`, `BluetoothAuthToken`, the models, `ShotCounterEvent`, `RawBluetoothFrame`, `BluetoothDashboardState`). |
| `Sources/Angstrom/Documentation.docc/Bluetooth.md` | new article: tokens, discovery and identity, the lifecycle (lazy connect, 30 s idle, the shot counter), errors and fallback, platform requirements, and the Pronto recipe (§5.8) |
| `Sources/Angstrom/Documentation.docc/GettingStarted.md` | version `2.0.0`, plus a link to the Bluetooth article |
| `Sources/AngstromUI/Documentation.docc/AngstromUI.md` | BLE-first commands, `refreshDashboardFromBluetooth`, the shot counter, `bluetoothEvents()`, `isBluetoothConnected` |
| `Sources/AngstromBluetooth/Documentation.docc/AngstromBluetooth.md` | (WP-B7) `coreBluetooth(showPowerAlert:)`, `BluetoothAuthorization.current`, the Info.plist/entitlement table |

---

## 12. Intentional divergences from upstream

Each one MUST be recorded in `UPSTREAM.md` (§11).

| ID | Divergence | Rationale |
|---|---|---|
| D1 | The transport is CoreBluetooth instead of bleak + bleak-retry-connector. Connect retry approximates `establish_connection` (3 attempts, 20 s each, 0.25/0.1 s backoff) without its transient-error counter (`MAX_TRANSIENT_ERRORS = 9`) or its 4 s not-found backoff. | Platform. The visible semantics (3 attempts, a typed final error) are kept. |
| D2 | `bleAuthToken` is **not** a `Machine` field. It is read by `LaMarzoccoCloudClient.bluetoothAuthToken(serial:)` and wrapped in the opaque, redacting, non-`Codable` `BluetoothAuthToken`. | A field would land in every persisted `MachineSnapshot` and in CLI-encoded output, and would break `Machine` round-trip equality for fixtures carrying the placeholder. The house rule says tokens are never persisted or logged. |
| D3 | Peripheral identity is the `CBPeer.identifier` UUID (`BluetoothPeripheralID`), not a MAC. `ble_device_callback` is not ported; the adapter re-resolves by identifier on every connect. Discovery also accepts the advertised local name when `CBPeripheral.name` is nil, and returns first-seen order. | Apple exposes no MAC. bleak on macOS already reports the UUID as `address` (`B-SC:160`). |
| D4 | `AsyncStream`s instead of callbacks (`connectionEvents`, `shotCounterEvents`, `bluetoothEvents`). A second `startShotCounter` cannot "replace the callbacks". Re-entrant-stop recursion cannot happen. `_safe_call` is unnecessary. | House pattern (`dashboardUpdates()`/`connectionEvents()`). Swift concurrency. |
| D5 | Coercion differences from mashumaro 3.17 (§3.10; all executed, BT-COERCE/BT-NTF-COERCE): (a) string booleans use `_parse_bool` (`"false"` → false; upstream `bool("false")` is `True`), so `{"BrewingUpdateGroup1Ev":"false",…}` stops a shot instead of continuing it; (b) unknown boiler ids and `machineModes` entries become `.other` instead of failing the read; (c) an array/object in a string field becomes its compact JSON text instead of Python `repr` (`["a"]` vs `"['a']"`): only the text differs, because no logic compares these strings except `status` against `"success"`, which neither form can equal; (d) an int outside `Int` range, or from a non-finite value, is an error (`.decoding` in a read, drop in a notification) where Python's `int` is unbounded; (e) a non-finite double (string `"nan"`/`"inf"`; the bare literals `NaN`/`Infinity` and out-of-range literals such as `1e400`, which `JSONSerialization` rejects outright) drops the notification or fails the read, where upstream emits `nan`/`inf` telemetry, or for a brewing time raises `ValueError` from `derive_state` after merging `nan` into the tracker; (f) numeric strings with `_` digit separators (`"1_0"`) are an error, where Python's `float()`/`int()` accept them. | (a) latent upstream bug; (b) tolerant-parsing convention; (c)–(f) Swift has no unbounded int, no Python `repr`, and `JSONSerialization` has no NaN literals; failing a value is safer than trapping or emitting NaN. None of these inputs has been observed on the wire. |
| D6 | Integral temperatures are encoded without a fraction (`93`), where Python sends `93.0` for a float. | Swift has one numeric type here. Every upstream test vector passes ints, so all pinned bytes match. Firmware tolerance is UNVERIFIED (U7). |
| D7 | Request robustness: (a) a link drop between a request's write and read fails the request instead of silently reconnecting and reading a stale value. (b) A missing characteristic triggers one real rediscovery on the live link before dropping (upstream's `clear_cache` is a no-op on macOS). (c) `didModifyServices` forces rediscovery. (d) Cancellation inside a request is drop-class. (e) `ensureConnected` trusts the stored `link` (I1): a request that starts after the peripheral dropped but before the actor processed `.disconnected` fails with `.bluetoothConnectionFailed` (drop-class; the device layer falls back to the cloud) instead of reconnecting, which upstream does because it checks bleak's live `is_connected` (`BT:183-186,236`). The next request reconnects. | Correctness on Apple. Upstream's behaviour in (a)–(d) is either a no-op or a misread response. (e) keeps link state single-sourced in the actor; the window is one event hop and the outcome is a clean, retryable failure. |
| D8 | `Model(bluetoothFamily:)` implements the `e0f0249` aliases (`"GS3"` → GS3 AV, `"LINEA"` → Linea Mini). The cloud parser `Model.match` keeps `"GS3"` → `.gs3`. | Already-documented cloud divergence (`UPSTREAM.md:94-100`). BLE needs upstream's mapping. |
| D9 | `BluetoothBoilerDetails.target/current` are `Double` (upstream `int`, truncating). Identical for integral wire values. For others the derived steam level changes (`MACH:78-84,436-438`): `130.5` → upstream `int` 130 → `.level2`, Angstrom `.level3` (G-DEV-4, BT-DASH-STEAMLVL); `0.5` → upstream 0 → `.level3`, Angstrom `.level1`. A string target `"127.5"` fails the upstream read (`int("127.5")` raises, BT-COERCE-007); Angstrom accepts `127.5`. | Tolerant parsing, and no loss for fractional targets. |
| D10 | Error taxonomy: Swift enum cases (`.bluetoothConnectionFailed`, `.bluetoothAuthenticationFailed`, `.bluetoothUnavailable`, `.bluetoothTimedOut`, `.cloudOnlyFunctionality`) with `isBluetoothConnectionFailure` standing in for the subclass relation. Unavailable states fail fast instead of burning connect attempts. | No subclassing in Swift enums. The convention is that every error is a `LaMarzoccoError`. Fallback behaviour is unchanged (unavailable ⇒ fall back, like `BleakError`). |
| D11 | `isConnected` (client) and `isBluetoothConnected` (machine) mean an **authenticated** link. Upstream's `is_connected` is briefly true before auth. | Observable state should not report a link that can't serve requests. |
| D12 | The overlay is base + render on value types, replacing Python object identity (`is widget`). Removing the opposite steam widget removes it from the `widgets` list (upstream pops only `config`, leaving `widgets` stale). | Angstrom widgets are immutable values in a list. The vectors prove equivalence (§9.3.8). |
| D13 | No synthesized `ThingDashboardWebsocketConfig` is sent to the websocket update callback when there is no shot-counter or telemetry callback. Consumers observe `dashboard` (`@Observable`) or `bluetoothEvents()`. | AngstromUI has no update callback. Observation covers it. |
| D14 | The reconnect backoff ends early (and resets) when Bluetooth returns to `.poweredOn` (wake, toggle). | Otherwise the shot counter can stay dark for up to 60 s after a Mac wakes. |
| D15 | The reconnect loop emits a terminal `ShotCounterEvent.gaveUp(error)` (and `MachineBluetoothEvent.shotCounterStopped`). Errors other than auth failure and cancellation take the connection-error branch, where upstream lets non-Bleak exceptions kill the task. Auth failures are counted **cumulatively** per loop run, matching the code (`BT:491,497`), not the README's "in a row" (`README:269`). | Observable state must learn of the give-up. Robustness. The code is the reference of record. |
| D16 | A link loss cancels the idle timer task. | Upstream lets it fire against a dead link, which is harmless but noisy (G-CONN-7). |
| D17 | No silent Linea Micra default model. `refreshDashboardFromBluetooth()` reads capabilities first when the model is unknown. Model-gated commands throw `.unsupportedModel` until the model is known. | Sending Micra-specific commands (steam levels) to an unidentified machine is unsafe. |
| D18 | BLE-first commands return `CommandResponse`. A BLE success synthesizes `CommandResponse(id: status.id, status: .success, errorCode: nil)`. With no cloud client, a BLE connection failure **rethrows** and a non-success status throws `.commandFailed(status:errorCode: message)`, where upstream returns `False`. With neither client: `.cloudOnlyFunctionality`. | Angstrom commands signal failure by throwing (existing API). |
| D19 | Every GATT operation has a bounded timeout (20 s). Bluetooth waits up to 10 s for `.poweredOn`. Disconnect is bounded at 5 s. Request-phase timeouts are `.bluetoothTimedOut` (drop-class, **no** cloud fallback, parity with a bare `TimeoutError`). | bleak has no timeout on writes, notify or discovery. CoreBluetooth gives no guarantee that a lost reply ever errors. |
| D20 | `readToken` maps ATT permission errors to a "pairing mode?" message and always disconnects. Upstream surfaces the raw `BleakError`. | Diagnosability. The semantics are otherwise identical (one attempt, no auth, no NUL strip). |
| D21 | `setTemperature` rejects NaN/±∞ with `.operationNotAvailable("temperature must be finite")` before any I/O. Upstream `json.dumps` (default `allow_nan=True`, `BT:707`) writes `NaN`/`Infinity` to the machine. | Never send a value the firmware cannot parse. |
| D22 | `setSmartStandby` on an auto-standby machine (`schedule.autoStandBySupported == true`) without a cloud client throws `.cloudOnlyFunctionality`. Upstream fails `assert self._cloud_client` (`MACH:875`) with an `AssertionError` (or, under `python -O`, an `AttributeError`). | Every error is a `LaMarzoccoError`. Same outcome: the command is not sent. |

---

## 13. Versioning and compatibility

- Angstrom keeps its own semver. **Target: v2.0.0** — an owner decision: Bluetooth is a major
  update (a second transport, a new product, new `LaMarzoccoError` cases), so it ships as a
  **major** release rather than following the minor-bump precedent used for the source-breaking
  cloud parity ports (1.5.0/1.6.0/1.7.0). `UPSTREAM.md`'s watermark markers stay at
  `v2.5.6`/`4c639ee`, because the port is built against the same commit.
- **Additive:** the new product `AngstromBluetooth`; all `Bluetooth*` types;
  `LaMarzoccoBluetoothClient`; `LaMarzoccoCloudClient.bluetoothAuthToken(serial:)`; the
  `Dashboard` transforms; `Model(bluetoothFamily:)`, `Model.steamLevelModels`/`steamTemperatureModels`;
  `MachineState(bluetoothMode:)`, `BoilerStatus(bluetoothMode:)`, the `SteamLevel` BLE mappings;
  `LaMarzoccoMachine.init(serialNumber:client:bluetooth:snapshot:)` and its new observable
  properties and methods; `MachineBluetoothEvent`.
- **Source-breaking for consumers (including Pronto):**
  1. New `LaMarzoccoError` cases (`bluetoothConnectionFailed`, `bluetoothAuthenticationFailed`,
     `bluetoothUnavailable`, `bluetoothTimedOut`, `cloudOnlyFunctionality`) break exhaustive
     `switch`es. Pronto must add arms or a `default` if it switches exhaustively.
  2. Nothing else. `LaMarzoccoMachine.init(serialNumber:client:snapshot:)`, every existing method
     signature, `dashboard`'s public read-only shape, `MachineSnapshot` and `Machine` are unchanged.
- **Behavioural changes for cloud-only users:** none. Without a BLE client every path is the
  existing cloud path. `dashboard` equals `baseDashboard` when no overlay is held.
- `angcli` version `2.0.0`.

---

## 14. Open questions, owner decisions, UNVERIFIED items

Each item has a **default that the implementation uses now**. Changing a default later is a
follow-up, not a blocker.

### 14.1 Owner decisions

| ID | Question | Default (implemented) |
|---|---|---|
| Q1 | Module layout: logic in `Angstrom` + adapter in a new `AngstromBluetooth` product? | **Yes** (§5.1) |
| Q2 | Token: a `Machine` field or a dedicated read? | **Dedicated read** + opaque `BluetoothAuthToken` (D2) |
| Q3 | Should `LaMarzoccoMachine` support BLE-only use (no cloud client)? | **Yes**: the optional client + `.cloudOnlyFunctionality` (full parity). Pronto is unaffected. |
| Q4 | Should Pronto enable a persistent shot-counter link by default, given the single central? | **Not a library decision.** Recommend opt-in in Pronto with a "frees the machine for your phone when off" note. |
| Q5 | BLE-first command result type | `CommandResponse` synthesized on BLE success (D18). No transport tag is exposed. |
| Q6 | Fallback on BLE timeouts? | **No** (parity: `TimeoutError` is not caught, `MACH:1025`). `.bluetoothTimedOut` propagates. |
| Q7 | Error taxonomy: four BLE cases + cloud-only, or fold unavailable into connection-failed? | **Separate `.bluetoothUnavailable`** (D10); `isBluetoothConnectionFailure` includes it |
| Q8 | Bounded GATT timeouts (20 s) | **Yes** (D19) |
| Q9 | Late tick after a stop re-enters Brewing: keep or guard? | **Keep** (parity) |
| Q10 | Surface `.backflushing` separately in AngstromUI? | **No new state.** It is available via `bluetoothBrewingUpdate?.state` and `bluetoothEvents()`. The overlay shows the cloud status (parity). |
| Q11 | Should BLE refreshes stamp `lastUpdateAt`? | **No** (cloud-only semantics kept) |
| Q12 | Keep upstream's BLE widget defaults even where they differ from cloud values (coffee max 110, non-Mini steam 20/134)? | **Keep** (parity) |
| Q13 | Coercion parity vs strict | **D5** (fix `"false"`, tolerate unknown enum entries, fail instead of trapping or emitting NaN; otherwise match Python constructors, including `null` → `"None"` and container truthiness) |
| Q14 | iOS background/state restoration | **Deferred**: foreground-only v1 |
| Q15 | Reconnect immediately on `.poweredOn` | **Yes** (D14) |
| Q16 | angcli: persist `serial → peripheral` | **No** (rescan or `--peripheral`) |
| Q17 | Version number | **2.0.0** — decided by the owner (major release; Bluetooth is a major update) |
| Q18 | `MachineStatistics` typing | Untyped `BluetoothJSONValue` (upstream marks its meaning unverified) |
| Q19 | Expose `isBluetoothConnected` as link-level (upstream) or authenticated? | **Authenticated** (D11) |

### 14.2 UNVERIFIED (needs hardware or upstream input)

| ID | Item | Default until settled | Settle with |
|---|---|---|---|
| U1 | GATT service UUID hosting `0a0b…`–`0e0b…`; property flags | `discoverServices(nil)` and match by characteristic | H1 |
| U2 | Encryption or bonding requirements (OS pairing prompt) | none assumed | H1, H16 |
| U3 | Advertised name format; MINI vs LINEA prefix per model; whether `0x2A25` gives the serial | user picks from the scan | H10 |
| U4 | Token format, length, meaning of `null` | opaque string; null → nil | a real `/things` (length only) |
| U5 | `0c0b` behaviour outside pairing mode | ATT errors → "pairing mode?" message | H17 |
| U6 | Response ready immediately after the write ack; max response size | single read (parity) | H27 |
| U7 | Firmware accepts `93` vs `93.0` | integral → `93` (D6) | H23 |
| U8 | Failure status strings and casing | case-insensitive `"success"` | H24 |
| U9 | Reply to an unknown read setting | `.decoding`; plumb-in → false | H25 |
| U10 | mashumaro 3.17 coercion edge cases | **Settled** (executed against `4c639ee`): §3.10 and the BT-COERCE / BT-NTF-COERCE vectors record the results; D5 lists the differences | re-check with X3 (PLAN §6.1) if `uv.lock` moves past mashumaro 3.17 |
| U11 | Whether the `TBC`/`CONF` example payloads are real captures | treated as normative vectors | X6 (PLAN §6.1): ask the upstream author |
| U12 | Single central per machine | assumed true | H8 |
| U13 | `family` strings of the GS3 MP / Mini R / original GS3 | the full `from_string` table | H22 |
| U14 | Apple-negotiated MTU ≥ 421 for the 418-byte telemetry frame | parse-or-drop (parity) | H2, H14 (iOS: only if an iOS app is available, §9.6) |
| U15 | Replay always sent on subscribe | always drop the first (parity) | H13 |
| U16 | TCC attribution for angcli; grant persistence across rebuilds; missing-usage-string behaviour | plist embedded anyway | H5–H7 |
| U17 | Whether the 10 s `poweredOnWait` covers the first-run prompt | 10 s | H3 |
| U18 | `CBPeer.identifier` scope across apps and resets | rescan on unknown peripheral | H9 |
| U19 | App Store flagging of CB symbols without a usage string (justifies the leaf product) | leaf product | TestFlight upload |
| U20 | Build with the Swift **6.0** compiler (the tools floor); only 6.4.2 was available to research | use only 5.9/6.0-era features (`package`, `withTaskCancellationHandler`, `AsyncStream.makeStream`, `OSAllocatedUnfairLock`) | CI's selected Xcode |
| U21 | Upstream's 123 BLE test cases pass at `4c639ee` (not re-run in research) | assumed | `uv run --frozen --extra dev pytest tests/test_bluetooth_client.py tests/test_bluetooth_dashboard.py tests/test_machine.py` |
| U22 | Per-line `brewingStartTime` golden values (hand-traced and simulated, not run against upstream) | §9.3.4 golden with ≤ 1 ms tolerance; assertions 1–6 are authoritative | run upstream's recorded-session test with prints |

### 14.3 Disagreements between research notes, and how the source settled them

| Topic | Notes | Resolution |
|---|---|---|
| GATT op timeout | 01 suggests 5–10 s; 06 suggests 20 s | **20 s**: the only upstream-evidenced number is bleak's 20 s read timeout (`B-PD:170`) |
| `poweredOnWait` | 06 table says 10 s; 06 sketch uses 30 s | **10 s** (table); the sketch value was illustrative |
| BLE failure with no cloud client | 03: upstream returns `False`; 05: "rethrow is natural" | **Rethrow** (D18). Upstream confirmed at `MACH:1028-1034`. |
| Token placement | 05 offers Machine field vs read; 03 says "decode, keep out of snapshots" | **Dedicated read** (D2) |
| Auth-failure limit | README `:269` "in a row"; code `BT:491-506` cumulative | **Code** (cumulative), as notes 01, 02 and 04 recommend |
| Optimistic site count | 05 says about 28 | ~33 `dashboard =` assignments exist today (`grep`). The funnel rule covers all of them. |
| C12 idle-timer counts | 04 warns about a counting trap; 01 says "twice per request" | Restated to "exactly one pending idle sleep" (§9.4) |
| Per-line start times | 02 hand trace vs 04 simulation | They agree on every line checked (§9.3.4) |
| Device-layer fake | 04 suggests a spec'd mock of the whole client; 05/06 suggest fakes at the GATT seam | **A real client over GATT fakes**: fewer frozen contracts, byte-level fidelity (§9.2) |
| `Lenient`/internal-init widening | 05 suggests `package` widening of widget inits | **Not needed**: the BLE transforms live in the `Angstrom` target (§6.15) |

