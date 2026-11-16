# 03 — Upstream device layer: how `LaMarzoccoThing` / `LaMarzoccoMachine` / `LaMarzoccoGrinder` use Bluetooth

Scope: the **device layer** (`src/pylamarzocco/devices/`) of pylamarzocco at the porting
watermark **v2.5.6, commit `4c639ee`** ("Merge pull request #173 from zweckj/fix-linea-ble-family").
It covers how the device objects receive and use `LaMarzoccoBluetoothClient` for commands and reads,
the BT-first / cloud-fallback algorithm, the BT dashboard synthesis, model detection, smart standby, the
capability matrix, the token flow, and the public API.

**Out of scope here.** The shot-counter overlay (`connect_bluetooth_shot_counter`, telemetry, brewing-state
override, `_dashboard_config_updated` override, expiry timer) belongs to another note. Only its
boundary with this layer is recorded below (§9). The GATT/byte-level client (`clients/_bluetooth.py`)
also has its own note. Client facts appear here only where the device layer's behaviour depends on them.

Citation convention: every path is relative to the upstream clone root
`$UPSTREAM/`.
`path:N` is a line and `path:N-M` is a range. Values in backticks are copied verbatim from the source.
**UNVERIFIED** marks anything the source does not settle.

---

## 0. TL;DR for implementers

1. A device gets its BT client **only through the constructor** (`bluetooth_client=`). There is no setter
   and no lazy creation. The caller builds `LaMarzoccoBluetoothClient(ble_device, ble_token)` itself, usually
   with `Thing.ble_auth_token` from the cloud.
2. Exactly **six** machine commands route BT-first with a cloud fallback: `set_power`, `set_steam`,
   `set_steam_level`, `set_coffee_target_temperature`, `set_steam_target_temperature` and `set_smart_standby`.
   One exception: `set_smart_standby` goes cloud-only (`set_auto_standby`) when `schedule.auto_stand_by_supported`
   is true. **Every other command is `@cloud_only`.** No grinder command uses BT.
3. The fallback goes to the cloud when (a) the BT reply's `status.lower() != "success"` (silently) or (b) BT raises
   `BleakError`/`BluetoothConnectionFailed` (which includes `BluetoothAuthenticationFailed`). Any other exception
   (notably `TimeoutError` and `ValueError`) **propagates**. With no cloud client, a BT exception returns
   `False` (logged as an error) and a non-success BT reply also returns `False`.
4. Two BT reads exist at device level: `get_model_info_from_bluetooth()` (capabilities → `model_name` and
   `model_code`) and `get_dashboard_from_bluetooth()` (mode, plumb-in, tank, boilers → 4–5 widgets). The BT
   smart-standby read exists on the client but **the device layer never calls it**.
5. Optimistic local updates follow every successful BT-routed command (whichever transport succeeded),
   except `set_smart_standby`, which updates nothing locally.
6. `ModelName.from_string` gained the BT family aliases `"GS3"→"GS3 AV"` and `"LINEA"→"Linea Mini"` in v2.5.6
   (`e0f0249`). Before that, reading capabilities from those machines failed.

---

## 1. Construction and wiring

### 1.1 Constructors

`LaMarzoccoThing.__init__` (`src/pylamarzocco/devices/_thing.py:73-90`):

```python
def __init__(
    self,
    serial_number: str,
    cloud_client: LaMarzoccoCloudClient | None = None,
    bluetooth_client: LaMarzoccoBluetoothClient | None = None,
) -> None:
```

- It stores `self._cloud_client = cloud_client` and `self._bluetooth_client = bluetooth_client`
  (`_thing.py:82-83`). Both are private and set once. No method in `devices/` assigns them again.
  `grep` finds no other writer.
- It initialises `self.dashboard = ThingDashboardConfig(serial_number=serial_number)` (`_thing.py:87`), plus
  `settings`, `statistics` and `schedule` (`_thing.py:88-90`). The **default dashboard** inherits `Thing` defaults
  (`src/pylamarzocco/models/_general.py:90-136`). The defaults that matter for BT are:
  - `model_code: ModelCode = ... default=ModelCode.LINEA_MICRA` (`_general.py:98-100`)
  - `model_name: ModelName = ... default=ModelName.LINEA_MICRA` (`_general.py:101-106`)
  - `connected: bool = field(default=False)` (`_general.py:107`)
  - `widgets` is empty and `config` is `{}` (`src/pylamarzocco/models/_config.py:49-50`)
  - **Consequence:** in a BT-only setup, model gating (`@models_supported`) treats the machine as a
    **Linea Micra** until `get_model_info_from_bluetooth()` runs (see §4.4).
- `LaMarzoccoMachine.__init__` (`src/pylamarzocco/devices/_machine.py:108-130`) has the same three parameters
  and calls `super().__init__(serial_number, cloud_client, bluetooth_client)` (`_machine.py:115`). Everything
  else it initialises is shot-counter state (§9).
- `LaMarzoccoGrinder` (`src/pylamarzocco/devices/_grinder.py:29`) **defines no `__init__`**. It inherits
  `LaMarzoccoThing.__init__`, so it *accepts* a `bluetooth_client` and exposes the Thing-level BT properties
  (§1.2), but **none of its methods uses it**. All eleven grinder methods are `@cloud_only`
  (decorators at `_grinder.py:32, 45, 59, 73, 105, 119, 132, 145, 170, 195, 237`).
  The client's discovery prefixes `BT_MODEL_PREFIXES = ("MICRA", "MINI", "LINEA", "GS3")`
  (`src/pylamarzocco/clients/_bluetooth.py:46`) contain no grinder (and no Strada) prefix. **Grinders do not
  use Bluetooth upstream.**
- Exports: `devices/__init__.py:3-11` exports `LaMarzoccoGrinder`, `LaMarzoccoMachine` and `LaMarzoccoThing`.
  The package root re-exports `LaMarzoccoBluetoothClient`, `LaMarzoccoCloudClient`, `LaMarzoccoGrinder` and
  `LaMarzoccoMachine` (`src/pylamarzocco/__init__.py:3-15`).

Documented usage (`README.md:144-156`):

```python
machine = LaMarzoccoMachine(
    serial_number=serial_number,
    cloud_client=cloud_client,
    bluetooth_client=bluetooth_client,  # Optional
)
```

### 1.2 Thing-level BT properties and the connection callback

| Member | Source | Exact semantics |
|---|---|---|
| `bluetooth_client_available -> bool` (property) | `_thing.py:99-102` | `return self._bluetooth_client is not None`. Says whether a client exists, not whether it is connected. |
| `cloud_client_available -> bool` (property) | `_thing.py:104-107` | `return self._cloud_client is not None` |
| `bluetooth_connected -> bool` (property) | `_thing.py:109-114` | `self._bluetooth_client is not None and self._bluetooth_client.is_connected`. The client's `is_connected` is `self._client is not None and self._client.is_connected` (`clients/_bluetooth.py:183-186`). The client drops the link after `IDLE_TIMEOUT = 30  # seconds` of inactivity (`clients/_bluetooth.py:47`, `:282-291`) unless the shot counter is running (`:275-280`), so this is **usually `False` between commands**. |
| `register_bluetooth_connection_callback(callback: Callable[[bool], Any]) -> Callable[[], None]` | `_thing.py:116-126` | Without a BT client it returns `lambda: None` (a no-op unregister) (`_thing.py:124-125`). Otherwise it delegates to `self._bluetooth_client.register_connection_callback(callback)` and returns that unregister function unchanged (`_thing.py:126`; asserted identical at `tests/test_machine.py:776-777`). |

Client-side callback contract (needed to port the delegation faithfully), from
`clients/_bluetooth.py:188-214`:

- It appends to a list. The returned `unregister()` removes the callback if present (`:200-206`).
- The callback receives `True` "once a connection is established and authenticated" and `False` "when it is
  closed or lost, including idle disconnects" (docstring `:191-196`).
- It fires **only on change**: `if connected == self._reported_connected: return` (`:210-211`).
- Each callback runs through `_safe_call`, which logs and swallows exceptions (`:67-74`, `:213-214`).
- `True` is reported after `_authenticate()` succeeds in `_ensure_connected` (`:256`, `:269`). `False` is
  reported from `_disconnect_internal` (`:311`) and `_on_bleak_disconnected` (`:472`).

Tests: `tests/test_thing.py:36-63` (with no clients every property is `False` and `unregister()` returns `None`;
with clients, `bluetooth_connected` mirrors `is_connected = True`), and `tests/test_machine.py:765-781`.

### 1.3 Decorators that decide routing

- `cloud_only` (`_thing.py:27-38`): `if self._cloud_client is None: raise CloudOnlyFunctionality()`
  (`_thing.py:34-35`). The message is fixed:
  `"Functionality is cloud only, but cloud client not initialized."` (`src/pylamarzocco/exceptions.py:28-35`).
- `models_supported(supported_models)` (`_thing.py:41-67`): `if self.dashboard.model_code not in supported_models:`
  raises `UnsupportedModel(f"This functionality is only supported on: {supported_names}.")`, where
  `supported_names = ", ".join(model.name for model in supported_models)` (`_thing.py:58-62`). The check runs
  **before** any transport, BT included, and uses whatever `dashboard.model_code` currently holds (§1.1 default).
- Decorator order on machine methods is `@cloud_only` outermost, then `@models_supported(...)`
  (e.g. `_machine.py:511-512`). So a cloud-only method without a cloud client raises `CloudOnlyFunctionality`
  before the model check. BT-routed methods carry no `@cloud_only`.

---

## 2. `__bluetooth_command_with_cloud_fallback`: the exact algorithm

Source: `src/pylamarzocco/devices/_machine.py:983-1049`. The name is private (double underscore, so Python
mangles it to `_LaMarzoccoMachine__bluetooth_command_with_cloud_fallback`). It is **not** public API.

### 2.1 Signature

```python
async def __bluetooth_command_with_cloud_fallback(
    self,
    command: str,
    cloud_command: str | None = None,
    bluetooth_kwargs: dict[str, Any] | None = None,
    cloud_kwargs: dict[str, Any] | None = None,
    **kwargs,
) -> bool:
```

(`_machine.py:983-990`). `command` is the **BT client method name**. `cloud_command` is the cloud client method
name and defaults to `command`. `**kwargs` are passed to both transports.

### 2.2 Step by step

1. `bluetooth_kwargs = bluetooth_kwargs or {}` and `cloud_kwargs = cloud_kwargs or {}` (`:1000-1001`).
2. `bt_kwargs = {**kwargs, **bluetooth_kwargs}` and `cl_kwargs = {**kwargs, **cloud_kwargs}` (`:1004-1005`).
   Specific kwargs win over common ones.
3. `cl_kwargs["serial_number"] = self.serial_number` (`:1008`). The cloud call is keyword-only and includes the serial.
4. `cloud_command = command if cloud_command is None else cloud_command` (`:1010`).
5. **BT attempt.** It runs only `if self._bluetooth_client is not None:` (`:1013`). **It does not check
   `bluetooth_connected`.** The client connects lazily: every request calls `_ensure_connected()`
   (`clients/_bluetooth.py:663`, `:680`), which runs `establish_connection(..., max_attempts=3, ...)` (`:247-255`)
   and then authenticates. When the machine is out of range, this connect attempt runs before any cloud fallback.
   - `func = getattr(self._bluetooth_client, command)` (`:1014`). This is dynamic dispatch by name.
   - Before the call, it logs at debug level: `"Sending command %s over bluetooth with params %s"` with `command, bt_kwargs` (`:1016-1020`).
   - `result = await func(**bt_kwargs)` (`:1021`). The result is a `BluetoothCommandStatus`.
   - **Success test:** `if result.status.lower() == "success": return True` (`:1023-1024`).
     - It compares case-insensitively against the literal `"success"`. `id` and `message` are ignored.
     - If the status is anything else (e.g. `"error"` in `tests/test_bluetooth_dashboard.py:518-520`), **nothing is
       logged and the code falls through to the cloud step**. With no cloud client, the method returns `False`
       (`tests/test_bluetooth_dashboard.py:506-530`).
   - `except (BleakError, BluetoothConnectionFailed) as exc:` (`:1025`). `BleakError` is imported from `bleak.exc`
     (`:11`). `BluetoothAuthenticationFailed` subclasses `BluetoothConnectionFailed` (`exceptions.py:46-47`),
     so a rejected token also triggers fallback.
     - `msg = "Could not send command to bluetooth device, even though initalized."` (`:1026`). The typo
       "initalized" is verbatim.
     - **No cloud client:** it logs at error level `"%s Cloud client not initialized, cannot fallback. Full error %s"` with
       `msg, exc` and **returns `False`** (`:1028-1034`). It does not raise. Tests: `tests/test_machine.py:1155-1162`,
       `tests/test_bluetooth_dashboard.py:533-557`.
     - **Cloud client present:** it logs at warning level `"%s Falling back to cloud"` with `msg`, then at debug level `"Full error: %s"`
       with `exc` (`:1036-1037`), and continues to the cloud step.
   - **Exceptions NOT caught, which propagate to the caller with no fallback:**
     - `TimeoutError`. The client's `disconnect_on_exception` catches `(BleakError, TimeoutError, BluetoothConnectionFailed)`,
       schedules a disconnect and **re-raises** (`clients/_bluetooth.py:129-134`). Only `BleakError` and
       `BluetoothConnectionFailed` match the device-layer `except`, so a `TimeoutError` raised by a GATT read or write
       inside `__write_bluetooth_message` or `_read_bluetooth_message` escapes. (`_authenticate` does wrap
       `TimeoutError` into `BluetoothConnectionFailed`, at `clients/_bluetooth.py:649-652`.) Whether bleak or
       bleak-retry-connector actually raise a bare `TimeoutError` on these paths is **UNVERIFIED**. A real BLE trace
       or the library sources would settle it.
     - `ValueError`/`json.JSONDecodeError` and mashumaro deserialisation errors from
       `BluetoothCommandStatus.from_json(result)` (`clients/_bluetooth.py:709-710`) when the reply is malformed.
     - `asyncio.CancelledError`.
6. **Cloud step.** It runs `if self._cloud_client is not None:` (`:1040`). It is reached when there is no BT client,
   when BT returned non-success, or when BT raised a caught exception and a cloud client exists.
   - It logs at debug level `"Sending command %s over cloud with params %s"` with **`command`** (the *BT* name, not
     `cloud_command`) and `cl_kwargs`, which includes the serial (`:1041-1045`).
   - `func = getattr(self._cloud_client, cloud_command)` (`:1046`).
   - `if await func(**cl_kwargs): return True` (`:1047-1048`). Cloud exceptions (`RequestNotSuccessful`, `AuthFail`,
     `PolicyAcceptanceRequired`, …) are **not caught** and propagate.
7. `return False` (`:1049`). This covers: the cloud returned falsy, or there was no cloud client and BT returned non-success.

**Return type:** a plain `bool`. The method does not report which transport succeeded. The cloud bool means "HTTP
command accepted, and websocket-confirmed `Success` if the websocket is connected". Otherwise the cloud returns
`True` right after the POST (`clients/_cloud.py:528-563`, specifically `:539-540`), waiting at most
`PENDING_COMMAND_TIMEOUT = 10` (`clients/_cloud.py:81`).

**Not done by the fallback:** it takes no lock across BT and cloud, does no retry, and makes no further BT attempt
after a cloud failure. It never touches `bluetooth_connected` and never notifies listeners.

### 2.3 Every call site (BT-first commands)

| Device method (`_machine.py`) | Gate | `command` (BT method) | BT kwargs as sent | `cloud_command` | Cloud kwargs as sent (plus `serial_number`) |
|---|---|---|---|---|---|
| `set_power(enabled: bool)` (`:494-509`) | none | `"set_power"` | common `enabled=enabled` (`:500-502`) | same: `"set_power"` | `enabled=enabled` |
| `set_steam(enabled: bool)` (`:764-782`) | none | `"set_steam"` | common `enabled=enabled` (`:770-773`) | same: `"set_steam"` | `enabled=enabled` |
| `set_steam_level(level: SteamTargetLevel)` (`:784-802`) | `@models_supported(STEAM_LEVEL_MODELS)` (`:784`) | `"set_temp"` | `{"boiler": BoilerType.STEAM, "temperature": STEAM_LEVEL_MAPPING[level]}` (`:790-793`) | `"set_steam_target_level"` (`:794`) | `{"target_level": level}` (`:795`) |
| `set_coffee_target_temperature(temperature: float)` (`:804-821`) | none | `"set_temp"` | `{"boiler": BoilerType.COFFEE, "temperature": temperature}` (`:809-812`) | `"set_coffee_target_temperature"` (`:813`) | `{"target_temperature": temperature}` (`:814`) |
| `set_steam_target_temperature(temperature: float)` (`:823-841`) | `@models_supported((ModelCode.GS3, ModelCode.GS3_AV, ModelCode.GS3_MP, ModelCode.STRADA_X))` (`:823`) | `"set_temp"` | `{"boiler": BoilerType.STEAM, "temperature": temperature}` (`:829-832`) | `"set_steam_target_temperature"` (`:833`) | `{"target_temperature": temperature}` (`:834`) |
| `set_smart_standby(enabled: bool, minutes: int, mode: SmartStandByType)` (`:870-892`) | none, but see the auto-standby branch (§5.2) | `"set_smart_standby"` | `{"enabled": enabled, "mode": mode, "minutes": minutes}` (`:882-886`) | same: `"set_smart_standby"` | `{"enabled": enabled, "minutes": minutes, "after": mode}` (`:887-891`) |

The test table `tests/test_machine.py:134-184` (`BLUETOOTH_COMMANDS`) pins these kwargs exactly. The test at
`tests/test_machine.py:192-235` runs each row twice: with BT success the cloud is not called, and with BT raising
`BluetoothConnectionFailed` the cloud is called once with `serial_number=serial, **cloud_kwargs`.

Constants used by the call sites:

- `STEAM_LEVEL_MAPPING = {SteamTargetLevel.LEVEL_1: 126, SteamTargetLevel.LEVEL_2: 128, SteamTargetLevel.LEVEL_3: 131}`
  (`_machine.py:59-63`). These are °C integers sent as the steam boiler target over BT.
- `STEAM_LEVEL_MODELS = (ModelCode.LINEA_MICRA, ModelCode.LINEA_MINI_R)` (`src/pylamarzocco/const.py:182`).
- `BoilerType.COFFEE = "CoffeeBoiler1"`, `BoilerType.STEAM = "SteamBoiler"` (`const.py:307-311`).
- `SmartStandByType.LAST_BREW = "LastBrewing"`, `SmartStandByType.POWER_ON = "PowerOn"` (`const.py:260-264`).
- `SteamTargetLevel` raw values: `"Level1"`, `"Level2"`, `"Level3"` (`const.py:141-146`).

### 2.4 What each BT method puts on the wire (pointer to the client note)

For cross-reference only. The client note owns the details. Each BT command is
`json.dumps({"name": name, "parameter": parameter}, separators=(",", ":"))`, with `b"\x00"` appended, written with response
to `WRITE_CHARACTERISTIC = "0b0b7847-e12b-09a8-b04b-8e0922a9abab"`. The reply is read back from the same
characteristic, cut at the first NUL and parsed as `BluetoothCommandStatus` (`clients/_bluetooth.py:41`, `:686-700`,
`:702-710`, `:671`).

| BT method | `name` | `parameter` (key order as in source) | Source |
|---|---|---|---|
| `set_power(enabled)` | `"MachineChangeMode"` | `{"mode": mode.value}` with `mode = MachineMode.BREWING_MODE if enabled else MachineMode.STANDBY` | `clients/_bluetooth.py:596-600` |
| `set_steam(enabled)` | `"SettingBoilerEnable"` | `{"identifier": BoilerType.STEAM.value, "state": enabled}` | `clients/_bluetooth.py:602-608` |
| `set_temp(boiler, temperature)` | `"SettingBoilerTarget"` | `{"identifier": boiler.value, "value": temperature}` | `clients/_bluetooth.py:620-626` |
| `set_smart_standby(enabled, mode, minutes)` | `"SettingSmartStandby"` | `{"minutes": minutes, "mode": mode.value, "enabled": enabled}` | `clients/_bluetooth.py:610-618` |

The example success reply is `b'{"id":"test-id","message":"Success","status":"success"}'` (`tests/test_bluetooth_client.py:47`).
`BluetoothCommandStatus` has three required `str` fields, `id`, `message` and `status`, with no aliases (`src/pylamarzocco/models/_bluetooth.py:59-65`).

**Temperature number formatting differs between transports.** The cloud rounds:
`"targetTemperature": round(target_temperature, 1)` (`clients/_cloud.py:645-648`). BT sends `temperature` exactly as
the caller passed it, with no rounding, and Python `json.dumps` prints `93` for an int and `93.0` for a float. Whether
the machine accepts non-integral or `x.0` values over BT is **UNVERIFIED**. The upstream tests only show
`93`, `96.5`, `122.5`, `124` and `128` passed through (`tests/test_machine.py:162-175`,
`tests/test_bluetooth_dashboard.py:452-503`). A BLE capture or a real-machine test would settle it.

### 2.5 Optimistic local updates after each BT-routed command

Every update below runs **only if the method's returned `result` is truthy**. It applies equally after BT
success and after cloud success. It mutates the cached widget objects in place through `self._widget(cls)`
(`_thing.py:184-186`, which reads `self.dashboard.config.get(cls.widget_type)`). It does **not** call
`_dashboard_config_updated()` and does **not** notify any callback.

| Method | Local mutation | Source |
|---|---|---|
| `set_power(enabled)` | `mode = MachineMode.BREWING_MODE if enabled else MachineMode.STANDBY`; `_update_machine_mode_widgets(mode)` sets `.mode` on the `MachineStatus` widget (`CMMachineStatus`) **and** on the `MachineGroupStatus` widget (`CMMachineGroupStatus`) if present. `.status` is **not** changed. | `_machine.py:504-507`, `:487-492`. The snapshot after `set_power(True)` still has `'status': 'StandBy'` with `'mode': 'BrewingMode'` (`tests/__snapshots__/test_bluetooth_dashboard.ambr`, `test_set_power_updates_dashboard`). The group status is covered by `tests/test_machine.py:1089-1099`. |
| `set_steam(enabled)` | `SteamBoilerLevel.enabled = enabled` if present; `SteamBoilerTemperature.enabled = enabled` if present (both may be updated) | `_machine.py:776-780` |
| `set_steam_level(level)` | `SteamBoilerLevel.target_level = level` | `_machine.py:798-800` |
| `set_coffee_target_temperature(t)` | `CoffeeBoiler.target_temperature = float(temperature)` (not rounded, unlike the cloud payload) | `_machine.py:817-819` |
| `set_steam_target_temperature(t)` | `SteamBoilerTemperature.target_temperature = temperature` (no `float()` cast here) | `_machine.py:837-839` |
| `set_smart_standby(...)` | **none**, on both the BT/cloud fallback path and the auto-standby path. `self.schedule` is not touched. | `_machine.py:870-892` |

Tests: `tests/test_bluetooth_dashboard.py:396-503` (each optimistic update) and `:506-557` (no update on a failed
reply or an exception).

---

## 3. `get_dashboard_from_bluetooth()`

Source: `src/pylamarzocco/devices/_machine.py:350-485`. Signature: `async def get_dashboard_from_bluetooth(self) -> None`.
Docstring: `"Fill the dashboard with data from Bluetooth (excluding standby settings)."` (`:351`). It is **not**
`@cloud_only` and has no model gate.

### 3.1 Preconditions and error handling

- With no BT client it raises `BluetoothConnectionFailed("Bluetooth client not initialized")` (`:352-353`). Test:
  `tests/test_bluetooth_dashboard.py:183-186`.
- All reads sit inside one `try` (`:355-364`) with `except (BleakError, BluetoothConnectionFailed) as exc:`. That
  handler logs at error level `"Failed to get dashboard from Bluetooth: %s"` and **re-raises** (`:365-367`). Test:
  `tests/test_machine.py:1079-1086` (`BleakError` propagates).
- **No partial mutation:** every dashboard write happens after all reads succeed. A failure in any read leaves
  `self.dashboard` unchanged.
- There is **no cloud fallback** for reads.
- A `ValueError` from `get_machine_mode()` (an unknown mode string makes `MachineMode(...)` raise,
  `clients/_bluetooth.py:555-560`) is outside the caught tuple and propagates.

### 3.2 Reads, in order (all unconditional)

| # | Call | Setting string written (`BluetoothReadSetting`, `const.py:322-330`) | Parsed as | Source |
|---|---|---|---|---|
| 1 | `machine_mode = await self._bluetooth_client.get_machine_mode()` | `"machineMode"` | `MachineMode(<json>)`; wire example `b'"BrewingMode"'` (`tests/test_bluetooth_client.py:424`) | `_machine.py:356`; `clients/_bluetooth.py:555-560` |
| 2 | `plumbed_in = await self._bluetooth_client.get_plumbed_in()`, inside a nested `try/except ValueError` | `"isPlumbedIn"` | `_parse_bool`: `str(value).lower() == "true"` (`clients/_bluetooth.py:62-64`); accepts `true`, `false`, `"true"` and `"false"` (`tests/test_bluetooth_client.py:1235-1250`) | `_machine.py:357-362`; `clients/_bluetooth.py:577-582` |
| 3 | `tank_status = await self._bluetooth_client.get_tank_status()` | `"tankStatus"` | `_parse_bool`; wire example `b'"true"'` | `_machine.py:363`; `clients/_bluetooth.py:570-575` |
| 4 | `boilers = await self._bluetooth_client.get_boilers()` | `"boilers"` | `list[BluetoothBoilerDetails]`; wire example `b'[{"id":"SteamBoiler","isEnabled":true,"target":131,"current":45},{"id":"CoffeeBoiler1","isEnabled":true,"target":94,"current":65}]'` (`tests/test_bluetooth_client.py:365`) | `_machine.py:364`; `clients/_bluetooth.py:584-588` |

Plumb-in tolerance (`_machine.py:357-362`, verbatim):

```python
try:
    plumbed_in = await self._bluetooth_client.get_plumbed_in()
except ValueError as exc:
    # older firmware might not know this setting
    _LOGGER.debug("Could not read plumb-in status: %s", exc)
    plumbed_in = False
```

`ValueError` covers `json.JSONDecodeError` from `json.loads` in `__read_value_from_machine` (`clients/_bluetooth.py:655-657`).
Test: `tests/test_bluetooth_dashboard.py:674-689`. Note that the client's `disconnect_on_exception` does *not* match `ValueError`,
so this failure does not drop the link.

**Not read** by this method: `machineCapabilities` (since `c790485`, v2.2.0, the caller must invoke
`get_model_info_from_bluetooth()` separately; `tests/test_bluetooth_dashboard.py:139` asserts
`get_machine_capabilities.assert_not_called()`), and `smartStandBy` ("excluding standby settings").

### 3.3 Derived values

- `water_ok = plumbed_in or tank_status` (`:369`). A plumbed-in machine reports an empty tank, and that is not an alarm
  (`tests/test_bluetooth_dashboard.py:595-602`).
- Nested helper (`:371-376`), verbatim:

```python
def boiler_status(enabled: bool = True) -> BoilerStatus:
    if not water_ok:
        return BoilerStatus.NO_WATER
    if not enabled:
        return BoilerStatus.OFF
    return BLE_BOILER_STATUS[machine_mode]
```

- `BLE_MACHINE_STATE` (`_machine.py:65-69`):
  `MachineMode.BREWING_MODE → MachineState.POWERED_ON`, `MachineMode.ECO_MODE → MachineState.ECO_MODE`,
  `MachineMode.STANDBY → MachineState.STANDBY`.
- `BLE_BOILER_STATUS` (`_machine.py:71-75`):
  `MachineMode.BREWING_MODE → BoilerStatus.READY`, `MachineMode.ECO_MODE → BoilerStatus.ECO_MODE`,
  `MachineMode.STANDBY → BoilerStatus.STAND_BY`.
- Raw values: `MachineMode` `"BrewingMode"`, `"EcoMode"`, `"StandBy"` (`const.py:11-16`). `MachineState` `"StandBy"`,
  `"PoweredOn"`, `"Brewing"`, `"EcoMode"`, `"Off"` (`const.py:24-31`). `BoilerStatus` `"StandBy"`, `"HeatingUp"`,
  `"Ready"`, `"NoWater"`, `"EcoMode"`, `"Off"` (`const.py:267-275`).
- BT **cannot** produce `MachineState.BREWING` (only the shot-counter overlay can, §9), `MachineState.OFF`,
  `BoilerStatus.HEATING` (BT reports `current` but upstream never compares it to `target`), `ready_start_time`,
  `next_status` or `brewing_start_time`.
- Both maps cover all three `MachineMode` cases, so a `KeyError` is impossible for a parsed mode.

Truth table, pinned by `tests/test_bluetooth_dashboard.py:560-636` (Micra dashboard, so the steam widget is the level widget):

| mode | plumbed_in | tank_ok | steam enabled | MachineStatus.status | CoffeeBoiler.status | SteamBoilerLevel.status | NoWater.allarm |
|---|---|---|---|---|---|---|---|
| BrewingMode | F | T | T | PoweredOn | Ready | Ready | False |
| EcoMode | F | T | T | EcoMode | EcoMode | EcoMode | False |
| StandBy | F | T | F | StandBy | StandBy | Off | False |
| BrewingMode | F | F | T | PoweredOn | NoWater | NoWater | True |
| BrewingMode | T | F | T | PoweredOn | Ready | Ready | False |

### 3.4 Widget synthesis ("get, else construct default; then overwrite")

All writes go to `self.dashboard.config[...]` (the `dict[WidgetType, BaseWidgetOutput]`). The pattern for each widget is
`existing = config.get(code, DEFAULT)`, then overwrite selected fields, then `config[code] = existing`.
**Existing objects are mutated in place.** Fields that BT does not supply keep their existing (cloud) values.

**(a) `CMMachineStatus`** (`MachineStatus`), `_machine.py:378-393`:

- Default when absent: `MachineStatus(status=MachineState.STANDBY, available_modes=[MachineMode.BREWING_MODE, MachineMode.STANDBY], mode=machine_mode, next_status=None)`. `brewing_start_time` takes its dataclass default `None` (`_config.py:106-112`).
- Then always: `machine_status.mode = machine_mode`; `machine_status.status = BLE_MACHINE_STATE[machine_mode]`.
- **Not** touched: `available_modes` (BT capabilities include `machineModes`, but upstream does not use them), `next_status`,
  `brewing_start_time`. **`CMMachineGroupStatus` is not touched either** (unlike `set_power`).
- This overwrites a cloud `Brewing` status with `PoweredOn`. The trailing `_dashboard_config_updated()` call then
  re-applies the shot-counter override, if one is active (§9).

**(b) For each `boiler in boilers`** (`:395-472`). Order follows the BT list. With duplicate ids, the last one wins.
Only `BoilerType.COFFEE` and `BoilerType.STEAM` are handled. Any other id would already have failed enum parsing in the client.

- `CMCoffeeBoiler` (`CoffeeBoiler`), `:396-416`:
  - Default: `CoffeeBoiler(status=BoilerStatus.STAND_BY, enabled=boiler.is_enabled, enabled_supported=False, target_temperature=float(boiler.target), target_temperature_min=80, target_temperature_max=110, target_temperature_step=0.1)`. `ready_start_time` defaults to `None`.
  - Then: `status = boiler_status()`, **called with no argument, so `enabled=True`**. The coffee boiler therefore never
    shows `Off` even when `is_enabled` is false. Then `enabled = boiler.is_enabled` and
    `target_temperature = float(boiler.target)`.
- Steam boiler, **branch on the current `self.dashboard.model_code`** (`:417-472`):
  - If `model_code in STEAM_LEVEL_MODELS` (Micra, Mini R), the code works with `CMSteamBoilerLevel` (`SteamBoilerLevel`), `:419-445`:
    - Default: `SteamBoilerLevel(status=BoilerStatus.STAND_BY, enabled=boiler.is_enabled, enabled_supported=True, target_level=SteamTargetLevel.LEVEL_1, target_level_supported=True)`.
    - Then: `status = boiler_status(boiler.is_enabled)`, `enabled = boiler.is_enabled`,
      `target_level = _steam_level_from_temperature(boiler.target)`.
    - Then **removes** `CMSteamBoilerTemperature` from `config` (`config.pop(..., None)`) (`:443-445`).
  - Else (GS3 family, original Mini, Strada X, and anything else), the code works with `CMSteamBoilerTemperature` (`SteamBoilerTemperature`), `:446-472`:
    - `is_mini = self.dashboard.model_code == ModelCode.LINEA_MINI` (`:448`).
    - Default: `SteamBoilerTemperature(status=BoilerStatus.STAND_BY, enabled=boiler.is_enabled, enabled_supported=False, target_temperature=float(boiler.target), target_temperature_min=95 if is_mini else 20, target_temperature_max=140 if is_mini else 134, target_temperature_step=0.1, target_temperature_supported=not is_mini)`.
    - Then: `status = boiler_status(boiler.is_enabled)`, `enabled = boiler.is_enabled`,
      `target_temperature = float(boiler.target)`.
    - Then **removes** `CMSteamBoilerLevel` (`:472`).

`_steam_level_from_temperature` (`_machine.py:78-84`), verbatim:

```python
def _steam_level_from_temperature(temperature: float) -> SteamTargetLevel:
    """Map the steam boiler target temperature to a steam level."""
    if 0 < temperature < 128:
        return SteamTargetLevel.LEVEL_1
    if 128 <= temperature <= 130:
        return SteamTargetLevel.LEVEL_2
    return SteamTargetLevel.LEVEL_3
```

Pinned by `tests/test_bluetooth_dashboard.py:639-671`: `0→Level3`, `126→Level1`, `127.9→Level1`, `128→Level2`,
`130→Level2`, `131→Level3`. A target of `0` or below maps to **Level3**, not Level1. That is an edge case to reproduce exactly.

**(c) `CMNoWater`** (`NoWater`, single field `allarm: bool` with the misspelling verbatim, `_config.py:559-564`), `_machine.py:474-483`:
- Default: `NoWater(allarm=not water_ok)`. Then `allarm = not water_ok`. **This widget is always written**, even
  though no cloud dashboard fixture for the BT-capable models contains `CMNoWater`. Checked: `tests/fixtures/machine/dashboard_{micra,mini,minir,gs3av}.json`
  contain only `CMMachineStatus`, `CMCoffeeBoiler` and one steam widget, all with `index: 1`.

**(d) Finally** `self._dashboard_config_updated()` (`:485`). This is a no-op in `LaMarzoccoThing` (`_thing.py:181-182`) and
is overridden in `LaMarzoccoMachine` for the shot-counter overlay (`_machine.py:316-323`, §9).

### 3.5 What `get_dashboard_from_bluetooth` does *not* do

- It does **not** touch `self.dashboard.widgets` (the `list[Widget]`). Only `config` is updated. For a BT-only machine the
  snapshot shows `'widgets': list([])` with a populated `config` (`tests/__snapshots__/test_bluetooth_dashboard.ambr`,
  both dashboard snapshots). For a cloud-loaded dashboard, `config[code]` *is* the same object as `widgets[i].output`
  (`_config.py:58-63` builds `config` from `widgets` by reference). In-place mutations therefore show up in both, but
  newly created widgets (for example `CMNoWater`) exist only in `config`, and popped widgets stay in `widgets`.
  **Angstrom has only a widget list** (see §10), so this must be resolved explicitly.
- It does not set `dashboard.connected`, which stays `False` for a BT-only dashboard (snapshot shows `'connected': False`),
  nor `connection_date`, `model_*`, `name`, etc.
- It does not invoke the websocket update callback or `_notify_dashboard_listeners`. The caller must re-read state.
- It does not use `boiler.current` (current temperature is read and **discarded**).
- It does not touch `settings` (for example, it does not write `settings.is_plumbed_in` even though plumb-in was just read) or `schedule`.
- It does not change other widgets (pre-extraction, backflush, doses, …). Those keep any cloud values.
- When a cloud dashboard already exists, a later cloud websocket push with widgets **replaces** `dashboard.widgets`
  and `dashboard.config` wholesale (`_thing.py:169-179`), which discards BT-only widgets such as `CMNoWater`.
  `get_dashboard()` (cloud) replaces the whole `dashboard` object (`_thing.py:134-141`). Upstream has no merge
  policy between BT and cloud: the last writer wins.

### 3.6 Upstream BT defaults vs observed cloud values (informational)

These are upstream's literal defaults, used only when the widget is absent. They differ from the
cloud fixtures. Match upstream unless the owner decides otherwise (open question):

| Field | BT default (upstream) | Cloud fixture value |
|---|---|---|
| `CMCoffeeBoiler.targetTemperatureMax` | `110` | Micra/Mini/Mini R: `100`; GS3 AV: `110` |
| `CMSteamBoilerTemperature.enabledSupported` | `False` | Mini and GS3 AV: `true` |
| `CMSteamBoilerTemperature.targetTemperatureMin/Max` (non-Mini) | `20` / `134` | GS3 AV: `95` / `140` |
| `CMSteamBoilerTemperature` (Mini) | min `95`, max `140`, supported `False` | Mini: `95`, `140`, `false`, which matches |

(Fixture values are from `tests/fixtures/machine/dashboard_{mini,gs3av,micra,minir}.json` widget outputs.)

### 3.7 Temperature units and rounding

- `BluetoothBoilerDetails.target: int` and `current: int` (`models/_bluetooth.py:42-49`) are degrees Celsius, as the client
  docstring says: "Set boiler temperature (in Celsius)" (`clients/_bluetooth.py:622`). The dataclass does not enforce
  `int`; the tests pass `127.9`.
- The device layer applies `float(boiler.target)` with no rounding. Steam level mapping uses the raw value.
- Commands send the caller's value unrounded over BT. The cloud rounds to 1 decimal (§2.4).

---

## 4. `get_model_info_from_bluetooth()` and BT model families

### 4.1 Algorithm

Source: `_machine.py:325-348`. Signature: `async def get_model_info_from_bluetooth(self) -> None`.

1. With no BT client it raises `BluetoothConnectionFailed("Bluetooth client not initialized")` (`:331-332`). Test:
   `tests/test_machine.py:1049-1056`.
2. `capabilities = await self._bluetooth_client.get_machine_capabilities()`. On `(BleakError, BluetoothConnectionFailed)`
   it logs at error level `"Failed to get machine capabilities from Bluetooth: %s"` and **re-raises** (`:334-338`).
   Test: `tests/test_machine.py:1058-1060`.
3. `self.dashboard.model_name = capabilities.family` (`:341`).
4. `self.dashboard.model_code = ModelCode[capabilities.family.name]` (lookup **by enum member name**). On `KeyError`
   it logs at warning level `"Could not map model_name %s to model_code"` and **keeps the previous `model_code`** (`:343-348`).
   With real `ModelName` values a `KeyError` cannot happen, because every `ModelName` member name has a `ModelCode`
   twin: `LINEA_MINI, LINEA_MICRA, LINEA_MINI_R, GS3, GS3_MP, GS3_AV, STRADA_X, PICO_GRINDER, SWAN_GRINDER`
   (`const.py:167-178` vs `:185-196`). It is only exercised with a mock (`tests/test_machine.py:1063-1076`).
5. Nothing else is written. The other capability fields are **parsed and discarded**: `groups_number`,
   `coffee_boilers_number`, `has_cup_warmer`, `steam_boilers_number`, `tea_doses_number`, `machine_modes` and `scheduling_type`.
   No listener is notified and `_dashboard_config_updated()` is not called.

Recommended call order for a BT-only machine (implied by the tests, e.g. `tests/test_bluetooth_dashboard.py:244-248`):
`await machine.get_model_info_from_bluetooth()` and then `await machine.get_dashboard_from_bluetooth()`. Otherwise the steam
widget choice and `@models_supported` gating use the default `LINEA_MICRA` (§1.1).

### 4.2 The capabilities payload

`BluetoothMachineCapabilities` (`models/_bluetooth.py:22-39`):

| Python field | JSON key | Type |
|---|---|---|
| `family` | `family` | `ModelName`, deserialised with `ModelName.from_string` |
| `groups_number` | `groupsNumber` | int |
| `coffee_boilers_number` | `coffeeBoilersNumber` | int |
| `has_cup_warmer` | `hasCupWarmer` | bool |
| `steam_boilers_number` | `steamBoilersNumber` | int |
| `tea_doses_number` | `teaDosesNumber` | int |
| `machine_modes` | `machineModes` | `list[MachineMode]` |
| `scheduling_type` | `schedulingType` | str |

The wire reply is a **JSON array**, and the client takes element `[0]`
(`BluetoothMachineCapabilities.from_dict(capabilities[0])`, `clients/_bluetooth.py:562-568`). Example (Micra):
`b'[{"family":"MICRA","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":false,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":["BrewingMode","StandBy"],"schedulingType":"smartWakeUpSleep"}]'`
(`tests/test_bluetooth_client.py:342`). An unknown family string makes `from_string` raise `ValueError(f"Invalid model name: {name}")`
(`const.py:216-217`). mashumaro may wrap it (wrapper type **UNVERIFIED**). Either way it is **not** caught by the device
layer's `(BleakError, BluetoothConnectionFailed)` and propagates.

### 4.3 `ModelName.from_string` and the BT family aliases

`const.py:198-218`, verbatim:

```python
@classmethod
def from_string(cls, name: str) -> ModelName:
    """Convert a string to a ModelName enum."""
    mapping = {
        # Bluetooth machineCapabilities family of the GS3 AV
        "GS3": "GS3 AV",
        "GS3MP": "GS3 MP",
        "GS3AV": "GS3 AV",
        "LINEAMINI2023": "Linea Mini R",
        "LINEAMICRA": "Linea Micra",
        "LINEAMINI": "Linea Mini",
        # Bluetooth machineCapabilities family of the original Linea Mini
        "LINEA": "Linea Mini",
        "MICRA": "Linea Micra",
        "STRADAX": "Strada X",
        "PICOGRINDER": "Pico",
        "SWANGRINDER": "Swan",
    }
    if (key := "".join(name.upper().split())) not in mapping:
        raise ValueError(f"Invalid model name: {name}")
    return cls(mapping[key])
```

- Normalisation: upper-case, then remove **all whitespace** (`"".join(name.upper().split())`).
- `ModelName` raw values: `"Linea Mini"`, `"Linea Micra"`, `"Linea Mini R"`, `"GS3"`, `"GS3 MP"`, `"GS3 AV"`, `"Strada X"`,
  `"Pico"`, `"Swan"` (`const.py:188-196`).
- **BT family strings known upstream** (with source):
  - `"MICRA"` → Linea Micra (BT client test `tests/test_bluetooth_client.py:342`; `tests/test_models.py:412`)
  - `"LINEA"` → **Linea Mini (original)**, added in v2.5.6 (`tests/test_models.py:410`)
  - `"GS3"` → **GS3 AV**, added in v2.5.6 (`tests/test_models.py:413`)
  - `"LINEAMINI2023"` → Linea Mini R (`tests/test_models.py:411`). Cloud fixtures also use the model name `"LINEA MINI 2023"`.
  - `"MINI"` is a *BLE advertised-name prefix* (`BT_MODEL_PREFIXES`, `clients/_bluetooth.py:46`), **not** a mapped
    family. What `family` a Mini R or a GS3 MP reports over BT is **UNVERIFIED**, beyond the test above that assumes
    `LINEAMINI2023` for the Mini R. A capability capture from each model would settle it.
- **Consequence of `"GS3"→GS3 AV`:** `ModelName.GS3` (raw `"GS3"`) is **unreachable** through `from_string`. On the cloud
  path `Thing.model_name` also goes through `from_string` (`_general.py:101-106`), but `Thing.model_code` is the
  `ModelCode` enum parsed directly, so cloud `modelCode: "GS3"` still yields `ModelCode.GS3`. On the BT path a
  `"GS3"` family yields `model_code = ModelCode.GS3_AV`. (`tests/test_bluetooth_dashboard.py:189-210` builds the
  capabilities object directly with `ModelName.GS3`, so it bypasses `from_string` and expects `ModelCode.GS3`.)
- **History (read-only git):** commit `e0f0249` ("Map LINEA and GS3 Bluetooth model families", 2026-11-05, first tag
  `v2.5.6`) says: *"The machineCapabilities response over Bluetooth reports short family names. LINEA (original Linea
  Mini) and GS3 (GS3 AV) were not mapped, so reading the capabilities failed with "Invalid model name"."* The diff
  adds exactly the two commented entries above. `"MICRA"` was present earlier. `git log -S'"MICRA"'` points to `99019db`
  "default values, name as enum".

### 4.4 Model-dependent behaviour on the BT path (summary)

| Uses `dashboard.model_code` | Where |
|---|---|
| Which steam widget `get_dashboard_from_bluetooth` builds or keeps (level vs temperature) and which it pops | `_machine.py:419`, `:448` |
| Mini-specific steam-temperature defaults | `_machine.py:448-462` |
| `set_steam_level` gate (`STEAM_LEVEL_MODELS`) | `_machine.py:784` |
| `set_steam_target_temperature` gate (GS3, GS3_AV, GS3_MP, STRADA_X) | `_machine.py:823` |

---

## 5. Smart standby over Bluetooth

### 5.1 Read: client-only, never used by the device layer

- Client: `async def get_smart_standby_settings(self) -> BluetoothSmartStandbyDetails`, which writes setting
  `"smartStandBy"` (`clients/_bluetooth.py:590-594`; `BluetoothReadSetting.SMART_STAND_BY = "smartStandBy"`, `const.py:329`).
- Model `BluetoothSmartStandbyDetails` (`models/_bluetooth.py:51-56`): `mode: SmartStandByType`, `minutes: int`,
  `enabled: bool`. Keys are identical in JSON (no aliases).
- Wire example: `b'{"mode":"PowerOn","minutes":42,"enabled":"true"}'`, which parses to
  `BluetoothSmartStandbyDetails(mode=SmartStandByType.POWER_ON, minutes=42, enabled=True)` (`tests/test_bluetooth_client.py:388-403`).
  **`enabled` arrives as the string `"true"`.** How mashumaro 3.17 coerces a `str` into a `bool` field, and in particular
  whether `"false"` becomes `False`, is **UNVERIFIED**. If the coercion is `bool(value)`, `"false"` becomes `True`. A Swift
  port should use the `_parse_bool` rule (`str(value).lower() == "true"`, `clients/_bluetooth.py:62-64`), and the owner
  should confirm.
- `grep` over `src/` finds the device layer **never** calling `get_smart_standby_settings`. `get_dashboard_from_bluetooth`
  explicitly excludes standby (`_machine.py:351`). **Upstream has no mapping from the BT smart-standby read into
  `schedule`.** Any such mapping in Angstrom is an extension and must be labelled so.

### 5.2 Write: `set_smart_standby(enabled, minutes, mode)`

`_machine.py:870-892`:

1. **Auto-standby branch first.** If `getattr(self.schedule, "auto_stand_by_supported", False)`:
   - `assert self._cloud_client`. Without a cloud client this raises a bare **`AssertionError`**, not
     `CloudOnlyFunctionality`. That is reachable only if a caller sets `schedule` manually, because without a cloud
     client the schedule is never fetched and keeps its default `auto_stand_by_supported=False` (`models/_schedule.py:190-193`).
   - `auto_mode = f"{minutes // 60:02d}:{minutes % 60:02d}" if enabled else "Off"`, then
     `return await self._cloud_client.set_auto_standby(self.serial_number, auto_mode)`. This is **cloud only, no BT**.
     Tests: `tests/test_machine.py:1132-1152` (`(True, 90) → "01:30"`, `(False, 90) → "Off"`, BT `set_smart_standby` not called).
   - Cloud command: `"CoffeeMachineSettingAutoStandBy"` with `{"mode": mode}` (`clients/_cloud.py:843-851`).
   - Introduced by `4eda859` / `3a0e224` (v2.2.5): "unify standby commands and model top-level smartStandBy".
2. **Otherwise BT-first with cloud fallback** (table in §2.3):
   - BT `set_smart_standby(enabled=enabled, mode=mode, minutes=minutes)` sends `"SettingSmartStandby"` with
     `{"minutes": minutes, "mode": mode.value, "enabled": enabled}` (`clients/_bluetooth.py:610-618`).
   - Cloud `set_smart_standby(serial_number, enabled, minutes, after)` sends `"CoffeeMachineSettingSmartStandBy"` with
     `{"enabled": enabled, "minutes": minutes, "after": after.value}` (`clients/_cloud.py:833-841`).
   - **Field rename:** BT `mode` corresponds to cloud `after`. Both take `SmartStandByType` (`"LastBrewing"` / `"PowerOn"`).
3. No local `schedule` update on either path.

### 5.3 Mapping to the cloud schedule model (for reference; not done upstream)

The cloud carries smart standby in two places on `ThingSchedulingSettings` (`models/_schedule.py:162-209`):

- Top-level `smartStandBy` → `SmartStandBy(enabled: bool = False, minutes: int = 0, minutes_min "minutesMin", minutes_max "minutesMax", minutes_step "minutesStep", after: SmartStandByType = POWER_ON)` (`_schedule.py:86-95`), with
  `smartStandBySupported` (`_schedule.py:166-169`).
- Legacy `smartWakeUpSleep.smartStandBy{Enabled,Minutes,MinutesMin,MinutesMax,MinutesStep,After}` (`_schedule.py:42-75`).

A natural BT→schedule mapping would be `enabled↔enabled`, `minutes↔minutes`, `mode↔after`. BT supplies no
`minutesMin`/`minutesMax`/`minutesStep`. Upstream does **not** implement any mapping, so if Angstrom adds one it is a
labelled divergence (open question).

---

## 6. Capability matrix: operation × transport (upstream v2.5.6 device layer)

Legend: **BT→C** means BT first, then cloud fallback. **C** means `@cloud_only` (raises `CloudOnlyFunctionality` without a cloud
client). **BT** means BT only (raises `BluetoothConnectionFailed` without a BT client). "—" means not available on that transport at device level.

### 6.1 `LaMarzoccoThing` (machines and grinders)

| Operation | Transport | Source |
|---|---|---|
| `bluetooth_client_available`, `bluetooth_connected`, `register_bluetooth_connection_callback` | BT (local state) | `_thing.py:99-126` |
| `cloud_client_available`, `websocket` | cloud state | `_thing.py:92-107` |
| `ensure_token_valid` | C | `_thing.py:128-132` |
| `get_dashboard` | C | `_thing.py:134-141` |
| `get_settings` | C | `_thing.py:143-147` |
| `get_statistics` | C | `_thing.py:149-155` |
| `get_schedule` | C | `_thing.py:157-161` |
| `get_firmware` | C | `_thing.py:163-167` |
| `connect_dashboard_websocket` | C | `_thing.py:188-210` |
| `update_firmware` | C | `_thing.py:212-216` |
| `to_dict` | local | `_thing.py:218-226` |

### 6.2 `LaMarzoccoMachine`

| Operation | BT | Cloud | Routing | Gate | Source |
|---|---|---|---|---|---|
| `get_model_info_from_bluetooth` | yes (`machineCapabilities`) | — (cloud gives model via `get_dashboard`) | BT | — | `_machine.py:325-348` |
| `get_dashboard_from_bluetooth` | yes (mode, plumb-in, tank, boilers) | — (cloud `get_dashboard` is separate) | BT | — | `_machine.py:350-485` |
| `set_power` | `MachineChangeMode` (BrewingMode/StandBy only) | `CoffeeMachineChangeMode` | BT→C | — | `_machine.py:494-509` |
| `set_steam` | `SettingBoilerEnable` | `CoffeeMachineSettingSteamBoilerEnabled` | BT→C | — | `_machine.py:764-782` |
| `set_steam_level` | `SettingBoilerTarget` (126/128/131) | `CoffeeMachineSettingSteamBoilerTargetLevel` | BT→C | STEAM_LEVEL_MODELS | `_machine.py:784-802` |
| `set_coffee_target_temperature` | `SettingBoilerTarget` | `CoffeeMachineSettingCoffeeBoilerTargetTemperature` | BT→C | — | `_machine.py:804-821` |
| `set_steam_target_temperature` | `SettingBoilerTarget` | `CoffeeMachineSettingSteamBoilerTargetTemperature` | BT→C | GS3, GS3_AV, GS3_MP, STRADA_X | `_machine.py:823-841` |
| `set_smart_standby` (no auto-standby support) | `SettingSmartStandby` | `CoffeeMachineSettingSmartStandBy` | BT→C | — | `_machine.py:880-892` |
| `set_smart_standby` (when `schedule.auto_stand_by_supported`) | — | `CoffeeMachineSettingAutoStandBy` | C (via `assert`) | — | `_machine.py:874-878` |
| `set_mode` (incl. EcoMode) | — | yes | C | STRADA_X | `_machine.py:511-521` |
| `set_auto_flush` / `set_steam_flush` / `set_rinse_flush` / `set_rinse_flush_time` | — | yes | C | STRADA_X | `_machine.py:523-557`, `:607-619` |
| `set_hot_water_dose_enabled` | — | yes | C | STRADA_X | `_machine.py:559-571` |
| `set_cup_warmer` | — | yes | C | — | `_machine.py:573-577` |
| `set_group_mode`, `set_coffee_boiler`, `set_brewing_pressure`, `set_mirror_group1` | — | yes | C | STRADA_X | `_machine.py:579-605`, `:700-722`, `:746-756` |
| `set_hot_water_dose`, `set_group_dose_mode`, `set_group_dose`, `set_continuous_dose_enabled`, `set_continuous_dose` | — | yes | C | STRADA_X, GS3_AV | `_machine.py:621-698`, `:724-744` |
| `set_plumb_in` | — (BT can *read* `isPlumbedIn` but there is no BT write) | yes | C | — | `_machine.py:758-762` |
| `start_backflush` | — | yes | C | — | `_machine.py:843-847` |
| `set_pre_extraction_mode` / `set_pre_extraction_times` | — | yes | C | — | `_machine.py:849-868` |
| `set_auto_on_off`, `set_wakeup_schedule`, `delete_wakeup_schedule` | — | yes | C | — | `_machine.py:894-920` |
| `set_brew_by_weight_dose_mode`, `set_brew_by_weight_dose` | — | yes | C | LINEA_MINI, LINEA_MINI_R | `_machine.py:922-981` |
| `get_coffee_and_flush_trend`, `get_last_coffee`, `get_coffee_and_flush_counter` | — | yes | C | — | `_machine.py:1051-1092` |
| Shot counter: `connect_bluetooth_shot_counter`, `disconnect_bluetooth_shot_counter`, `ble_brewing_update`, `bluetooth_telemetry`, `last_shot_time`, `bluetooth_shot_counter_active` | yes | — | BT (other note) | — | `_machine.py:132-207` |

### 6.3 `LaMarzoccoGrinder`

Every method is C, with no BT path: `set_power`, `set_barista_light`, `set_grind_with`†, `set_dose`, `set_more_dose`†,
`set_single_dose_mode`, `set_mirror_doses`, `set_speed`†, `set_auto_speed`†, `set_auto_speed_reference`†, `set_auto_standby`
(`_grinder.py:32-248`; † marks `@models_supported((ModelCode.SWAN_GRINDER,))`).

### 6.4 Reads: what BT can and cannot supply

| Data | BT | Cloud |
|---|---|---|
| Machine mode → `CMMachineStatus.mode/status` | yes (no Brewing, Off, nextStatus or brewingStartTime) | yes |
| Group status `CMMachineGroupStatus` | — | yes |
| Coffee boiler enabled/target, steam enabled/target or level | yes | yes |
| Boiler current temperature | read but **discarded** | — (not in the cloud widgets used upstream) |
| Boiler `HeatingUp` status, `readyStartTime` | — | yes |
| Water alarm (`CMNoWater`) | yes (tank OR plumbed-in) | (not in the fixtures above; **UNVERIFIED** whether the cloud ever sends it) |
| Plumb-in state | read only for the water alarm | yes (`settings.isPlumbedIn`) |
| Model family / capabilities | yes | yes (dashboard identity) |
| Smart standby | client read exists, unused by devices | yes (`schedule`) |
| Pre-extraction, backflush, doses, BBW, flushes, cup warmer, scale, statistics, firmware, wake-up schedules, auto on/off, eco mode | — | yes |
| Live temperatures and machine mode as notifications | shot-counter telemetry (other note) | websocket |

---

## 7. Bluetooth token flow and masking

### 7.1 Source of the token

- `Thing.ble_auth_token: str | None = field(metadata=field_options(alias="bleAuthToken"), default=None)` (`models/_general.py:128-130`).
  Because `ThingDashboardConfig`, `ThingSettings`, `ThingSchedulingSettings` and `ThingStatistics` all subclass `Thing`,
  the field is present on `list_things()` results (`clients/_cloud.py:284-288`) and on dashboard, settings, schedule
  and statistics reads. It also appears **nested** inside `coffeeStation.coffeeMachine` (e.g.
  `tests/fixtures/machine/dashboard_strada_profile.json:14-38`).
- The value can be `null`. The micra, mini, minir and gs3av dashboard fixtures have `"bleAuthToken": null`. The Strada and Swan
  fixtures carry a 64-hex-zero placeholder `"0000000000000000000000000000000000000000000000000000000000000000"`.
  Whether real tokens are always 64 hex characters is **UNVERIFIED**, because fixtures are anonymised.
- README method 1 (`README.md:78-98`): `things = await cloud_client.list_things()` then `ble_token = things[0].ble_auth_token`.
  The other methods are `LaMarzoccoBluetoothClient.read_token(...)` in pairing mode (`README.md:100-116`;
  `clients/_bluetooth.py:539-547`, reading `GET_TOKEN_CHARACTERISTIC = "0c0b7847-e12b-09a8-b04b-8e0922a9abab"`) and the
  QR label inside the chassis (`README.md:118-125`).

### 7.2 How it reaches the BT client

- **The device layer never reads `ble_auth_token`.** The caller constructs
  `LaMarzoccoBluetoothClient(ble_device: BLEDevice, ble_token: str, ble_device_callback: Callable[[], BLEDevice] | None = None)`
  (`clients/_bluetooth.py:142-156`), which stores `self._ble_token`. The caller then passes the client to the Machine constructor (§1.1).
  No API on the device rotates or replaces the token. If the token changes, the caller has to build a new client and a new Machine.
- The client writes the token UTF-8-encoded to `AUTH_CHARACTERISTIC = "0d0b7847-e12b-09a8-b04b-8e0922a9abab"` with response, then polls
  for `AUTH_SUCCESS = b"\x01"` up to `AUTH_READ_ATTEMPTS = 10` times at `AUTH_READ_INTERVAL = 0.05` s
  (`clients/_bluetooth.py:43`, `:49-51`, `:628-653`). The client note owns the details. For the device layer, what matters is that a
  rejected token raises `BluetoothAuthenticationFailed`, a subclass of `BluetoothConnectionFailed`, so commands fall back to the cloud
  (§2.2), and that `client.authentication_failed` is the observable flag (`clients/_bluetooth.py:216-222`). That flag is *not*
  surfaced on the Thing.
- The token-write path does not log the token. `_authenticate` calls `write_gatt_char` directly, while the debug log
  `"Sending bluetooth message: %s to %s"` exists only in `__write_bluetooth_message` (`clients/_bluetooth.py:692`), which the
  auth path does not use.

### 7.3 Masking

`clients/_cloud.py:84-92`, verbatim:

```python
def _mask_bluetooth_token(data: Any) -> Any:
    """Return a copy of a JSON response with the Bluetooth token masked."""
    # json.loads calls object_hook for every decoded object, nested ones included
    return json.loads(
        json.dumps(data),
        object_hook=lambda obj: (
            obj | {"bleAuthToken": "**REDACTED**"} if obj.get("bleAuthToken") else obj
        ),
    )
```

- It applies only to the debug log line `_LOGGER.debug("Response: %s", _mask_bluetooth_token(json_response))`
  (`clients/_cloud.py:211`). The returned/parsed data is **not** masked, so `ble_auth_token` keeps the real value
  (`tests/test_cloud_client.py:322-339`, which asserts `"secret-token" not in caplog.text` and that both parsed objects keep it).
- Only **truthy** values are replaced (`if obj.get("bleAuthToken")`). `null` and `""` are left as they are. The replacement string is
  `"**REDACTED**"`. Nested objects are masked too, because `object_hook` runs for every object.
- Angstrom today: `Machine` deliberately does not model `bleAuthToken` (`Sources/Angstrom/Models.swift:25-26`,
  comment "(`bleAuthToken` is intentionally not modeled — Bluetooth is out of scope.)"). `angcli` already redacts it in printed output
  (CLAUDE.md, v1.6.0 notes).

---

## 8. Public API inventory: BT-related device-layer members

"Public" means no leading underscore. Every signature is copied from source.

### 8.1 `LaMarzoccoThing` (`devices/_thing.py`)

| Member | Signature | Semantics |
|---|---|---|
| ctor | `__init__(self, serial_number: str, cloud_client: LaMarzoccoCloudClient \| None = None, bluetooth_client: LaMarzoccoBluetoothClient \| None = None) -> None` (`:73-78`) | Stores the clients once (§1.1) |
| property | `bluetooth_client_available -> bool` (`:99-102`) | client is not None |
| property | `cloud_client_available -> bool` (`:104-107`) | client is not None |
| property | `bluetooth_connected -> bool` (`:109-114`) | client exists and is connected now |
| method | `register_bluetooth_connection_callback(self, callback: Callable[[bool], Any]) -> Callable[[], None]` (`:116-126`) | Delegates; no-op unregister when there is no client |
| decorator (module) | `cloud_only` (`:27-38`), `models_supported(supported_models: tuple[ModelCode, ...])` (`:41-67`) | Routing and gating (§1.3) |

### 8.2 `LaMarzoccoMachine` (`devices/_machine.py`), excluding the shot counter

| Member | Signature | Semantics |
|---|---|---|
| method | `async get_model_info_from_bluetooth(self) -> None` (`:325`) | §4 |
| method | `async get_dashboard_from_bluetooth(self) -> None` (`:350`) | §3 |
| method | `async set_power(self, enabled: bool) -> bool` (`:494`) | BT→C; optimistic mode (§2.5) |
| method | `async set_steam(self, enabled: bool) -> bool` (`:764`) | BT→C |
| method | `async set_steam_level(self, level: SteamTargetLevel) -> bool` (`:785`) | BT→C, gated |
| method | `async set_coffee_target_temperature(self, temperature: float) -> bool` (`:804`) | BT→C |
| method | `async set_steam_target_temperature(self, temperature: float) -> bool` (`:824`) | BT→C, gated |
| method | `async set_smart_standby(self, enabled: bool, minutes: int, mode: SmartStandByType) -> bool` (`:870-872`) | auto-standby (C) or BT→C (§5.2) |
| module constants | `STEAM_LEVEL_MAPPING` (`:59-63`), `BLE_MACHINE_STATE` (`:65-69`), `BLE_BOILER_STATUS` (`:71-75`), `BLE_BREWING_STATE_TIMEOUT = 60  # seconds` (`:88`, shot counter) | |
| module function | `_steam_level_from_temperature(temperature: float) -> SteamTargetLevel` (`:78-84`) | private but behaviour-defining |
| private | `__bluetooth_command_with_cloud_fallback(...)` (`:983-1049`), `_update_machine_mode_widgets(mode)` (`:487-492`) | §2 |

Shot-counter public members (only listed, see the other note): `ble_brewing_update` (`:132-135`), `bluetooth_telemetry` (`:137-143`),
`last_shot_time` (`:145-148`), `bluetooth_shot_counter_active` (`:150-156`), `connect_bluetooth_shot_counter(...) -> bool` (`:158-191`),
`disconnect_bluetooth_shot_counter() -> None` (`:193-207`).

### 8.3 Models and constants consumed by the device layer

- `BluetoothMachineCapabilities`, `BluetoothBoilerDetails`, `BluetoothSmartStandbyDetails`, `BluetoothCommandStatus` (`models/_bluetooth.py:22-65`, §3, §4, §5).
- `BluetoothBoilerDetails` (`models/_bluetooth.py:42-49`): `id: BoilerType`, `is_enabled: bool` (alias `"isEnabled"`), `target: int`, `current: int`.
- `BluetoothReadSetting` (`const.py:322-330`): `MACHINE_CAPABILITIES = "machineCapabilities"`, `MACHINE_MODE = "machineMode"`,
  `TANK_STATUS = "tankStatus"`, `BOILERS = "boilers"`, `SMART_STAND_BY = "smartStandBy"`, `IS_PLUMBED_IN = "isPlumbedIn"`.
- `WidgetType` codes written by BT: `CM_MACHINE_STATUS = "CMMachineStatus"`, `CM_COFFEE_BOILER = "CMCoffeeBoiler"`,
  `CM_STEAM_BOILER_LEVEL = "CMSteamBoilerLevel"`, `CM_STEAM_BOILER_TEMPERATURE = "CMSteamBoilerTemperature"`, `CM_NO_WATER = "CMNoWater"`
  (`const.py:85-86`, `:93`, `:103`). `CM_MACHINE_GROUP_STATUS = "CMMachineGroupStatus"` (`:91`) is touched only by `set_power`'s optimistic update.
- `ModelName` (`const.py:185-218`), `ModelCode` (`const.py:167-178`), `STEAM_LEVEL_MODELS` (`const.py:182`).

### 8.4 Exceptions (`src/pylamarzocco/exceptions.py`)

| Exception | Base | Raised and seen in the BT device paths |
|---|---|---|
| `LaMarzoccoError` | `Exception` (`:4-5`) | base class |
| `BluetoothConnectionFailed` | `LaMarzoccoError` (`:20-21`) | Raised with `"Bluetooth client not initialized"` by both BT reads. Caught for command fallback. Re-raised by the reads. |
| `BluetoothAuthenticationFailed` | `BluetoothConnectionFailed` (`:46-47`) | Token rejected. Handled as `BluetoothConnectionFailed`. |
| `CloudOnlyFunctionality` | `LaMarzoccoError` (`:28-35`) | Every `@cloud_only` method when there is no cloud client |
| `UnsupportedModel` | `LaMarzoccoError` (`:38-39`) | `@models_supported` gate, checked before transport |
| `OperationNotAvailable` | `LaMarzoccoError` (`:42-43`) | Cloud-only dose commands; not BT |
| `bleak.exc.BleakError` | third party | Caught for command fallback; re-raised by the BT reads |

### 8.5 Device-layer log messages on BT paths (verbatim)

| Level | Format | Source |
|---|---|---|
| error | `"Failed to get machine capabilities from Bluetooth: %s"` | `_machine.py:337` |
| warning | `"Could not map model_name %s to model_code"` | `_machine.py:346-347` |
| debug | `"Could not read plumb-in status: %s"` | `_machine.py:361` |
| error | `"Failed to get dashboard from Bluetooth: %s"` | `_machine.py:366` |
| debug | `"Sending command %s over bluetooth with params %s"` | `_machine.py:1016-1020` |
| error | `"%s Cloud client not initialized, cannot fallback. Full error %s"` (with `msg = "Could not send command to bluetooth device, even though initalized."`) | `_machine.py:1026-1033` |
| warning | `"%s Falling back to cloud"` | `_machine.py:1036` |
| debug | `"Full error: %s"` | `_machine.py:1037` |
| debug | `"Sending command %s over cloud with params %s"` (logs the BT command name) | `_machine.py:1041-1045` |

---

## 9. Boundary with the shot-counter overlay (covered elsewhere)

The pieces of this layer that touch the shot counter:

- `LaMarzoccoMachine._dashboard_config_updated` (`_machine.py:316-323`) overrides the Thing hook. It runs at the end of
  `get_dashboard_from_bluetooth` (`:485`), after cloud `get_dashboard` (`_thing.py:141`), and after websocket pushes that carry widgets
  (`_thing.py:176`). It re-applies the BT brewing override to `CMMachineStatus` and, if the widget object is unchanged, refreshes
  the remembered "cloud" status from the in-place BT refresh. The comment reads "refreshed in place by Bluetooth, which doesn't report
  the start time" (`:321`). Tests that pin the interaction with `get_dashboard_from_bluetooth`: `tests/test_machine.py:917-958`.
- `_update_machine_mode_widgets` (`_machine.py:487-492`) is shared by `set_power` and the telemetry handler (`:234`).
  `BLE_MACHINE_STATE` is also reused by telemetry (`:236`).
- The BT client serialises requests with `_request_lock` (`clients/_bluetooth.py:126-128`). Commands and dashboard reads share the
  shot counter's connection, and a failed request does not drop the link while the shot counter is active (`:130-133`).
- The device-layer **commands and reads do not check or change** any shot-counter state.

---

## 10. Porting notes for Angstrom (analysis, not upstream fact)

These observations come from comparing upstream with the current Angstrom sources at
`$REPO` (v1.7.0). They are recommendations for the plan authors. Where a choice exists, it is
listed as an open question.

1. **Dashboard shape.** Angstrom's `Dashboard` is `{ machine: Machine, widgets: [Widget] }`, where each widget has `code`, `index` and `kind`
   (`Sources/Angstrom/Widgets.swift:12-40`, `:91-93`). There is no separate config dict. The BT fill therefore has to
   *upsert into the widget list*. Two questions follow: which `index` a synthesised widget gets (every cloud fixture uses `index: 1`
   for these codes, so `1` is the natural choice), and whether popping the opposite steam widget removes it from the list.
   Upstream only ever mutates `config`, which leaves `widgets` empty or stale (§3.5). A faithful *observable* port would keep
   `widgets` and the typed accessors consistent. Angstrom's existing `Dashboard.replacing(_:)` (`Sources/Angstrom/Optimistic.swift:18`)
   is the natural upsert primitive.
2. **Value types vs in-place mutation.** Upstream mutates shared widget objects. Angstrom's widgets are immutable value types rebuilt through
   `setting…` transforms (`Optimistic.swift`). The BT fill should be a pure
   `Dashboard.applyingBluetooth(mode:plumbedIn:tank:boilers:model:) -> Dashboard` transform. That makes it testable against every row of §3.3 and §3.4
   without hardware.
3. **Model parsing.** Angstrom's `Model.match` maps `"GS3"` to `.gs3` and has no `"LINEA"` alias (`Sources/Angstrom/Enums.swift:57-69`).
   Upstream BT families need `"GS3"` → **GS3 AV** and `"LINEA"` → **Linea Mini**, while cloud `modelCode: "GS3"` must stay `.gs3`. A separate
   `Model(bluetoothFamily:)` initialiser that mirrors `ModelName.from_string` (§4.3) avoids changing cloud behaviour.
4. **Gating.** `AngstromUI` already has `steamLevelModels = [.lineaMicra, .lineaMiniR]` and
   `steamTemperatureModels = [.gs3, .gs3AV, .gs3MP, .stradaX]` (`Sources/AngstromUI/LaMarzoccoMachine.swift:744-745`), which match
   upstream's gates. In BT-only mode the model comes from `get_model_info_from_bluetooth`. Upstream silently defaults to Micra, and
   Angstrom will need its own decision for a missing model.
5. **Return types.** Upstream BT-routed commands return `bool`. Angstrom's commands return `CommandResponse` (`Sources/Angstrom/Commands.swift:169-243`;
   `Sources/AngstromUI/LaMarzoccoMachine.swift:285-320`). The plan has to decide how a BT success is represented, for example a new transport-tagged
   result, or a synthesised `CommandResponse` with `status = .success`.
6. **Errors.** The upstream exceptions should map to `LaMarzoccoError` cases (CLAUDE.md convention), for example `bluetoothConnectionFailed`,
   `bluetoothAuthenticationFailed` and `cloudOnly`. Note that upstream returns `False` rather than throwing when BT fails and there is no cloud client.
7. **Existing smart-standby routing.** `AngstromUI.setSmartStandby` already applies upstream's auto-standby branch, using
   `schedule?.autoStandBySupported` and the HH:MM/Off format (`Sources/AngstromUI/LaMarzoccoMachine.swift:692-710`). The BT path slots into its
   `else` branch.
8. **Token.** Angstrom does not decode `bleAuthToken` today (`Models.swift:25-26`). Full parity needs it decoded, kept out of `Codable`
   snapshots and logs (never persisted in `MachineSnapshot`), and redacted like upstream (`"**REDACTED**"` for truthy values only) in any
   diagnostics surface.
9. **Timeout semantics.** Upstream does not fall back on `TimeoutError` (§2.2). A CoreBluetooth port has to choose whether a BLE timeout
   triggers fallback. Matching upstream strictly means propagating the error.
