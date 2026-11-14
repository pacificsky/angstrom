# 01: Upstream Bluetooth client wire and protocol specification

Scope: the exact behaviour of `LaMarzoccoBluetoothClient` in pylamarzocco **v2.5.6 / commit
`4c639ee`** (the Angstrom porting watermark). It covers the GATT layout, discovery, token
acquisition, the auth handshake, framing, every read and command, the connection lifecycle,
the bleak/bleak-retry-connector behaviour a CoreBluetooth port has to reproduce or replace, and
the full public API.

**Out of scope:** the shot-counter/telemetry notification feature, which note 02 covers. This
note only marks where it hooks into the core lifecycle (tag **[SC-HOOK]**).

This is research only. Nothing in the Angstrom repo or the upstream clone was modified.

---

## 0. Conventions and sources

### 0.1 Path abbreviations

Upstream paths are relative to the clone root
`$UPSTREAM`.

| Abbrev | Path |
|---|---|
| `BT` | `src/pylamarzocco/clients/_bluetooth.py` (747 lines) |
| `CLI` | `src/pylamarzocco/clients/__init__.py` |
| `CONST` | `src/pylamarzocco/const.py` |
| `EXC` | `src/pylamarzocco/exceptions.py` |
| `MBT` | `src/pylamarzocco/models/_bluetooth.py` |
| `MGEN` | `src/pylamarzocco/models/_general.py` |
| `MCFG` | `src/pylamarzocco/models/_config.py` |
| `CLOUD` | `src/pylamarzocco/clients/_cloud.py` |
| `MACH` | `src/pylamarzocco/devices/_machine.py` |
| `THING` | `src/pylamarzocco/devices/_thing.py` |
| `TBT` | `tests/test_bluetooth_client.py` |
| `CONF` | `tests/conftest.py` |
| `LEG` | `docs/legacy/bluetooth_characteristics.md` |
| `README` | `README.md` |
| `PYPROJ` | `pyproject.toml` |
| `LOCK` | `uv.lock` |

Line references are `ABBREV:line` or `ABBREV:start-end`. Commit hashes refer to the upstream
clone (`git -C <clone> show <hash>`).

### 0.2 Third-party dependency sources

`PYPROJ:22` declares `"bleak >= 0.20.0"` and `"bleak-retry-connector >= 4.0.0"`. The lockfile
pins **bleak 1.1.1** (`LOCK:140-141`) and **bleak-retry-connector 4.4.4** (`LOCK:163-164`).
Those exact versions are installed (read-only) under
`$VENV/lib/python3.13/site-packages/`.
Abbreviations used below:

| Abbrev | Path under site-packages |
|---|---|
| `BRC` | `bleak_retry_connector/__init__.py` (4.4.4) |
| `BLEAK` | `bleak/__init__.py` (1.1.1) |
| `BCB` | `bleak/backends/corebluetooth/client.py` |
| `BCBS` | `bleak/backends/corebluetooth/scanner.py` |
| `BDEV` | `bleak/backends/device.py` |
| `BSCAN` | `bleak/backends/scanner.py` |

**Caveat:** Python could not be executed in this pass, because the sandbox refused it. Edge-case
decoding behaviour of mashumaro (the dataclass decoder upstream uses) is therefore marked
**UNVERIFIED** wherever the tests don't pin it. A previous run left a probe script at
`docs/bluetooth/research/probe/probe.py`.
Running it against the upstream `src/` with mashumaro 3.17 settles those items (§13).

---

## 1. Protocol at a glance

```
Discovery     : scan; keep peripherals whose name startswith "MICRA"|"MINI"|"LINEA"|"GS3"
Token         : cloud Thing.bleAuthToken  |  GATT read 0c0b… (machine in pairing mode)  |  QR label
Connect       : establish_connection(max_attempts=3), service discovery
Auth          : WRITE-WITH-RESPONSE 0d0b… <- utf8(token)              (no terminator)
                READ 0d0b… until == 0x01 (10 reads, 50 ms apart)
Read setting  : WRITE-WITH-RESPONSE 0a0b… <- utf8("<settingName>") + 0x00
                READ 0a0b… -> utf8 JSON, truncated at first 0x00
Command       : WRITE-WITH-RESPONSE 0b0b… <- utf8(compact JSON {"name":…,"parameter":{…}}) + 0x00
                READ 0b0b… -> utf8 JSON {"id","message","status"}, truncated at first 0x00
Idle          : disconnect 30 s after the last request (suppressed while the shot counter runs)
[SC-HOOK]     : NOTIFY 0e0b… (shot counter / telemetry, note 02)
```

A cold `set_power(True)` produces this exact sequence of GATT operations, pinned by `TBT:434-451`,
`TBT:636-649` and `TBT:295-307`:

1. `establish_connection(...)` (connect plus service discovery).
2. `write 0d0b7847-… = b"token"`, `response=True`.
3. `read 0d0b7847-…`. This is repeated until it returns `b"\x01"`, for at most 10 reads.
4. `write 0b0b7847-… = b'{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}\x00'`, `response=True`.
5. `read 0b0b7847-…` returns the command-status JSON.

---

## 2. GATT layout

### 2.1 Characteristics used by the current client

All five UUIDs share the suffix `-e12b-09a8-b04b-8e0922a9abab`. Only the first byte of the first
group differs.

| Constant (`BT` line) | UUID (verbatim) | Role | Ops performed by upstream |
|---|---|---|---|
| `READ_CHARACTERISTIC` (`BT:40`) | `0a0b7847-e12b-09a8-b04b-8e0922a9abab` | "read-setting" channel: request a value by name, then read it back | write with response (`BT:656` → `BT:696-700`), then read (`BT:657` → `BT:669`) |
| `WRITE_CHARACTERISTIC` (`BT:41`) | `0b0b7847-e12b-09a8-b04b-8e0922a9abab` | command channel: write a JSON command, read back the status | write with response (`BT:706-708` → `BT:696-700`), then read (`BT:709`) |
| `GET_TOKEN_CHARACTERISTIC` (`BT:42`) | `0c0b7847-e12b-09a8-b04b-8e0922a9abab` | exposes the BLE auth token while the machine is in pairing mode | read only (`BT:546`), only in the static `read_token` |
| `AUTH_CHARACTERISTIC` (`BT:43`) | `0d0b7847-e12b-09a8-b04b-8e0922a9abab` | auth: write the token, poll for `0x01` | write with response (`BT:636-640`), then read 1 to 10 times (`BT:645`) |
| `SHOT_COUNTER_CHARACTERISTIC` (`BT:44`) | `0e0b7847-e12b-09a8-b04b-8e0922a9abab` | **[SC-HOOK]** brewing and telemetry notifications | `start_notify` (`BT:432-434`), `stop_notify` (`BT:400`), presence check (`BT:415-417`) |

Notes:

- The upstream tests duplicate these UUIDs "on purpose, to pin the machine's protocol"
  (`TBT:41-45`). There `0b0b…` is named `SETTINGS_CHAR`.
- **The containing service UUID is never referenced** by the current code. Every lookup goes
  through `client.services.get_characteristic(<char uuid>)`, which searches all services
  (`BT:719-721`, `BT:415-417`). The service UUID that holds `0a0b`…`0e0b` is **UNVERIFIED**.
  An nRF Connect/LightBlue dump of a current machine would resolve it. A CoreBluetooth port can
  safely call `discoverServices(nil)` and then `discoverCharacteristics(nil, for:)` on every
  service, then match by characteristic UUID.
- Characteristic properties (read/write/notify flags) of `0a0b`…`0e0b` are **UNVERIFIED**:
  upstream never inspects `characteristic.properties`. It always passes `response=True`
  explicitly (§5.2), so it doesn't depend on the flags.
- Whether any of these characteristics needs link encryption or bonding is **UNVERIFIED**.
  Upstream never calls `pair()` (§8.4).

### 2.2 Legacy GATT table (historical, not used at v2.5.6)

`LEG:1-24` is a bleak service dump. It was added in commit `696c94b` (2023-05-10) and moved to
`docs/legacy` in `bbff74b` (2025-03-21). It shows service `d30a7847-e12b-09a8-b04b-8e0922a9abab`
with these characteristics:

```
030b7847-… ['read']           040b7847-… ['read']
090b7847-… ['read', 'write']  050b7847-… ['read', 'write']
060b7847-… ['write']          070b7847-… ['write']
```

…plus the standard GAP (`1800`), GATT (`1801`, with Service Changed `2a05` indicate) and Device
Information (`180a`: `2a29` manufacturer, `2a24` model number, `2a25` serial number, `2a26`
firmware, `2a28` software) services.

The legacy (gen-1, pre-2025) client used:

- `SETTINGS_CHARACTERISTIC = "050b7847-…"`
- `AUTH_CHARACTERISTIC = "090b7847-…"`

These constants come from `git show 5ddfdf8:pylamarzocco/legacy/const.py`, lines 108-110. That
client authenticated by writing
`base64(username + ":" + serial) + b"@" + base64(token)`, which commit `0ad74e2` shows being
removed. The v2 client (commit `0ad74e2`, 2025-03-28) replaced this with the `0a0b`…`0d0b`
characteristics and a raw-token auth.

The command JSON names (`MachineChangeMode`, `SettingBoilerEnable`, `SettingBoilerTarget`) and the
trailing `0x00` carried over unchanged from legacy to v2 (compare the 2024 test vectors in commit
`07f6f13`). **Do not implement the legacy layout.**

Whether current firmware still exposes the `180a` Device Information service is **UNVERIFIED**.
If it does, `2a25` Serial Number String could map a peripheral to a cloud serial. Upstream doesn't
use it (§3.3).

### 2.3 Characteristic resolution (`_resolve_characteristic`, `BT:712-747`)

Every GATT operation goes through this function except two: the `read_token` read, which uses a
UUID string directly (`BT:546`), and the shot-counter presence probe (`BT:415-417`).

```
1. if self._client is None -> raise BluetoothConnectionFailed("Client is not connected")   (BT:716-717)
2. c = self._client.services.get_characteristic(uuid); if c: return c                        (BT:719-723)
3. log debug "Characteristic %s not found in cache, clearing cache and retrying."            (BT:725-728)
   await self._client.clear_cache()                                                          (BT:729)
4. c = self._client.services.get_characteristic(uuid); if c: return c                        (BT:731-735)
5. log info "Could not find characteristic %s on machine. Clearing cache and disconnecting." (BT:738-741)
   await self._client.clear_cache()                                                          (BT:742)
   asyncio.create_task(self._drop_connection())   # "outside the lock to avoid deadlock"     (BT:743-744)
   raise BluetoothConnectionFailed(f"Could not find characteristic {characteristic} on machine.")  (BT:745-747)
```

Why it exists, from history:

- Up to commit `77e015f` ("clear char cache", 2025-11-15), each call site did its own
  `get_characteristic` and raised immediately. `77e015f` switched to
  `BleakClientWithServiceCache` and added the clear-cache retry. Commit `738fcfb` added the
  disconnect on a final miss. The rationale was that services are cached across connections, so
  a stale cached service table (for example after a firmware update adds a characteristic) must
  be invalidated so that the **next** connection re-discovers it.
- Characteristic objects are passed instead of UUID strings because of the December 2024 fixes
  in commits `2c7250f` ("switch to char handle"), `027024a` ("find chars") and `98f7921`.
  bleak's `write_gatt_char` docs say that "If a device has more than one characteristic with the
  same UUID, then attempting to use the UUID wil fail and a characteristic object must be used
  instead" (`BLEAK:673-740`). Resolving to an object avoids that ambiguity.

Behaviour a port must know:

- **Step 4 is effectively dead on a live link.** `clear_cache()` doesn't re-run service discovery
  on the current connection, so the second lookup searches the same collection. On pure bleak
  1.1.1, `BleakClient` has no `clear_cache` at all, so
  `BleakClientWithServiceCache.clear_cache()` just logs
  `"clear_cache not implemented in bleak version"` and returns `False` (`BRC:198-203`).
  `clear_cache` only does real work under Home Assistant's habluetooth wrapper or on BlueZ.
  Net effect of a miss: drop the link and fail. The **next** connection re-discovers.
- After a miss, `_drop_connection` is scheduled **unconditionally**, even while the shot
  counter runs. The decorator's "don't drop while the shot counter is active" guard (§7.4) does
  not cover this path.
- When the miss happens inside `_authenticate` (AUTH char missing), `_lock` is held by
  `_ensure_connected`. The scheduled `_drop_connection` waits for the lock, and
  `_ensure_connected`'s own error path has already disconnected (§7.2).
- **[SC-HOOK]** The shot counter has its own two-pass "cached, then uncached" rediscovery
  (`BT:403-439`): `use_services_cache=True` first, then `clear_cache()` + disconnect +
  reconnect with `use_services_cache=False`. Requests do **not** do this.

CoreBluetooth equivalent: CoreBluetooth has no client-controlled service cache. bleak's
CoreBluetooth backend re-discovers services on every connection, because `self.services = None`
in its disconnect callback (`BCB:118-121`). The OS keeps its own GATT cache and honours Service
Changed. A faithful port does a single lookup over freshly discovered characteristics. On a miss
it either re-runs `discoverServices` once on the live link (a sensible improvement) or
disconnects and throws, matching upstream.

---

## 3. Device discovery

### 3.1 `discover_devices` (`BT:522-537`)

```python
@staticmethod
async def discover_devices(scanner: BaseBleakScanner | BleakScanner | None = None) -> list[BLEDevice]:
    ble_devices = []
    if scanner is None:
        scanner = BleakScanner()
    assert hasattr(scanner, "discover")
    devices = await scanner.discover()
    for device in devices:
        if device.name and device.name.startswith(BT_MODEL_PREFIXES):
            ble_devices.append(device)
    return ble_devices
```

- **Filter:** only by advertised/OS device name. The name must be non-empty and must
  `startswith` one of `BT_MODEL_PREFIXES = ("MICRA", "MINI", "LINEA", "GS3")` (`BT:46`). The
  match is case-sensitive. There is no service-UUID filter, no manufacturer-data filter and no
  RSSI filter.
- The test pins the list: names `"MICRA_1"`, `"MINI_2"`, `"LINEA_3"`, `"LINEAR_4"` and
  `"GS3_5"` are kept, and `"OTHER"` is dropped (`TBT:1326-1342`). `"LINEAR_4"` shows that the
  `"LINEA"` prefix over-matches.
- Prefix history: `("MICRA", "MINI", "GS3")` from the legacy const until commit `6754903`
  (2026-10-03), which added `"LINEA"`.
- **Scan duration:** `BleakScanner.discover` is a classmethod with `timeout: float = 5.0`
  (`BLEAK:237-268`). It opens a fresh scanner, sleeps for `timeout`, and returns
  `discovered_devices`. **Subtlety:** for a real `BleakScanner` instance, `scanner.discover()`
  resolves to that classmethod, so it builds a *new* default scanner and ignores the instance's
  configuration. The `scanner` parameter only matters for objects with an instance-level
  `discover` (Home Assistant wrappers, test mocks such as `TBT:1328-1334`).
- Returns every match. There is no de-duplication beyond bleak's own, and no sort order.

### 3.2 What identifies a device

- A discovered device is a bleak `BLEDevice(address, name, details)` (`BDEV:13-27`). Upstream
  stores `ble_device.address` as the client's identity (`BT:158`) and returns it from the
  `address` property (`BT:549-553`, docstring "Return the BT MAC address of the machine.").
- **On macOS/iOS, `address` is not a MAC.** It's the per-host CoreBluetooth peripheral
  identifier UUID (`BDEV:21` "The Bluetooth address of the device on this machine (UUID on
  macOS)"; `BCBS:160` `address = p.identifier().UUIDString()`). It can't be derived from cloud
  data, isn't stable across hosts, and can't be shared between devices.
- On macOS, `BLEDevice.name` is `CBPeripheral.name` (`BCBS:162-168` passes `p.name()`), **not**
  the advertisement's `kCBAdvDataLocalName` (`BCBS:139`, which goes only into
  `AdvertisementData.local_name`). A port should match on either, preferring the advertised local
  name. `peripheral.name` can be nil or stale before a GAP name read.
- The `name` passed to `establish_connection` (`self._ble_device.name or "Unknown"`, `BT:250`)
  is used only for log messages.

### 3.3 Name → model / serial mapping

- **The client does no name → model or name → serial mapping.** The prefix only gates discovery.
- The full advertised name format is **UNVERIFIED**. The tests use the synthetic `"<PREFIX>_<n>"`.
  If real names are `"<PREFIX>_<serial>"`, a port could map a peripheral to a cloud machine by
  serial, but nothing upstream relies on that. Which model advertises which prefix (for example
  whether the Linea Mini R advertises `MINI…` or `LINEA…`) is also **UNVERIFIED**.
- The model is obtained **after connecting**, from the `machineCapabilities` read, field `family`
  (§6.2). It's decoded by `ModelName.from_string` (`CONST:198-218`), which upper-cases the input
  and removes all whitespace (`"".join(name.upper().split())`, `CONST:216`) before looking it up
  in:

  | input key | → `ModelName` value |
  |---|---|
  | `"GS3"` | `"GS3 AV"` (comment: "Bluetooth machineCapabilities family of the GS3 AV", `CONST:202-203`) |
  | `"GS3MP"` | `"GS3 MP"` |
  | `"GS3AV"` | `"GS3 AV"` |
  | `"LINEAMINI2023"` | `"Linea Mini R"` |
  | `"LINEAMICRA"` | `"Linea Micra"` |
  | `"LINEAMINI"` | `"Linea Mini"` |
  | `"LINEA"` | `"Linea Mini"` (comment: "Bluetooth machineCapabilities family of the original Linea Mini", `CONST:209-210`) |
  | `"MICRA"` | `"Linea Micra"` |
  | `"STRADAX"` | `"Strada X"` |
  | `"PICOGRINDER"` | `"Pico"` |
  | `"SWANGRINDER"` | `"Swan"` |

  Any other input raises `ValueError(f"Invalid model name: {name}")` (`CONST:217`).
- **The Linea BLE family fix.** Commit `e0f0249` ("Map LINEA and GS3 Bluetooth model families",
  merged as `4c639ee`, the watermark) added the `"GS3"` and `"LINEA"` rows. The commit message
  reads: "The machineCapabilities response over Bluetooth reports short family names. LINEA
  (original Linea Mini) and GS3 (GS3 AV) were not mapped, so reading the capabilities failed with
  'Invalid model name'." The new test `test_model_name_from_bluetooth_family` pins
  `LINEA→LINEA_MINI`, `LINEAMINI2023→LINEA_MINI_R`, `MICRA→LINEA_MICRA` and `GS3→GS3_AV`.
- The device layer then derives the cloud model code by enum *member name*:
  `self.dashboard.model_code = ModelCode[capabilities.family.name]` (`MACH:344`). For example
  BLE `"GS3"` → `ModelName.GS3_AV` → `ModelCode.GS3_AV` (`"GS3AV"`).
- **Angstrom seam:** Angstrom's `Model` parser maps `"GS3"` → `.gs3` and has no `"LINEA"` row
  (`Sources/Angstrom/Enums.swift:60-69`). The BLE `family` needs a
  **separate** mapper: `"GS3"` → `.gs3AV`, `"LINEA"` → `.lineaMini`, `"MICRA"` → `.lineaMicra`,
  `"LINEAMINI2023"` → `.lineaMiniR`, and so on. Reusing the cloud parser would mis-model a GS3 AV
  and fail on an original Linea Mini.

---

## 4. Token acquisition

Upstream's README lists three sources (`README:74-125`). The client only ever receives the
result as a `str` (`BT:145`, stored at `BT:157`).

### 4.1 From the cloud: `bleAuthToken`

- `Thing.ble_auth_token: str | None`, JSON key `"bleAuthToken"`, default `None`
  (`MGEN:128-130`). `ThingDashboardConfig` (`MCFG:67`) and `ThingSettings` (`MCFG:342`) both
  inherit `Thing`, so the token arrives on `GET /things` (`CLOUD:284-288`), `GET
  /things/{serial}/dashboard` (`CLOUD:290-294`) and `GET /things/{serial}/settings`
  (`CLOUD:296-300`). It also appears nested under `coffeeStation.coffeeMachine`
  (fixture `tests/fixtures/machine/dashboard_strada_profile.json:33`).
- README usage: `ble_token = things[0].ble_auth_token` (`README:94-97`).
- It's **often `null`** in fixtures, including BLE-capable models
  (`dashboard_micra.json:15`, `dashboard_minir.json:15`, `dashboard_gs3av.json:15`,
  `settings_micra.json:15`). Where present it's a 64-character placeholder (`"000…0"`, 64 zeros)
  (`dashboard_stradax.json:17`, `schedule_micra_new.json:18`). Whether `null` means "not
  provisioned" or is a sanitising artefact, and the real token format and length, are
  **UNVERIFIED**.
- Upstream masks it in logs: `_mask_bluetooth_token` (`CLOUD:84-92`) replaces every non-empty
  `bleAuthToken` at any depth with `"**REDACTED**"`.
- **Angstrom seam:** `Machine` deliberately doesn't model `bleAuthToken`
  (`Sources/Angstrom/Models.swift:25-26`). `angcli` already masks it.
  Full parity needs it decoded (optional, tolerant of `null`) on `Machine` and/or
  `MachineSettings`, and never logged.

### 4.2 From the machine in pairing mode: `read_token` (`BT:539-547`)

```python
@staticmethod
async def read_token(address_or_ble_device: BLEDevice | str) -> str:
    """Read the token from the machine. Only possible when machine is in pairing mode."""
    async with BleakClient(address_or_ble_device) as client:
        token = await client.read_gatt_char(GET_TOKEN_CHARACTERISTIC)
        return token.decode()
```

Exact sequence:

1. Plain `BleakClient` connect via the context manager. This is **not**
   `BleakClientWithServiceCache` or `establish_connection`, so there are no retries. bleak's
   default connect timeout is 10 s (`BCB:57`, `BCB:95`, `BCB:100`). With a `str` address,
   CoreBluetooth first scans for it with `find_device_by_address` (`BCB:101-110`).
2. **No authentication write.**
3. One `read_gatt_char("0c0b7847-e12b-09a8-b04b-8e0922a9abab")`, by UUID string.
4. `bytes.decode()` = **UTF-8, strict, no NUL stripping.** This differs from request responses,
   which are cut at the first `0x00` (§5.3). Any trailing NUL would end up in the token.
5. Disconnect on context exit.

Other properties:

- It doesn't touch any client instance: no locks, no idle timer, no connection callbacks. If a
  `LaMarzoccoBluetoothClient` is connected to the same machine at the same time, the machine may
  refuse the second central (`README:231`: "the machine likely accepts only one central at a
  time").
- Errors propagate raw: `BleakError`, `BleakDeviceNotFoundError`, `TimeoutError`,
  `UnicodeDecodeError`. Nothing is wrapped in `BluetoothConnectionFailed`.
- History: introduced in `0ad74e2`, which returned raw bytes. `.decode()` was added later.
  Commit `0488f6b` widened the parameter from `address: str` to `BLEDevice | str`.
- What the machine returns **outside** pairing mode (an ATT error, empty bytes, or garbage) is
  **UNVERIFIED**. How to enter pairing mode is machine-specific (`README:116`).

### 4.3 From the QR code

`README:118-125`: the token is printed as a QR code on a label inside the chassis, and "The
scanned value is your Bluetooth token". The client consumes it as-is. Its format is
**UNVERIFIED**.

---

## 5. Authentication handshake and message framing

### 5.1 Authentication (`_authenticate`, `BT:628-653`)

It's called only from `_ensure_connected`, right after `establish_connection` returns, while
`_lock` is held (`BT:256`).

```python
if self._client is None: raise BluetoothConnectionFailed("Client is not connected")      # BT:630-631
auth_characteristic = await self._resolve_characteristic(AUTH_CHARACTERISTIC)             # BT:633
try:
    await self._client.write_gatt_char(char_specifier=auth_characteristic,
                                       data=bytes(self._ble_token, "utf-8"), response=True) # BT:636-640
    # the machine confirms a successful authentication with 0x01                            # BT:641
    for attempt in range(AUTH_READ_ATTEMPTS):                                               # BT:642
        if attempt:
            await asyncio.sleep(AUTH_READ_INTERVAL)                                         # BT:643-644
        result = await self._client.read_gatt_char(auth_characteristic)                     # BT:645
        self._authentication_failed = bytes(result) != AUTH_SUCCESS                         # BT:646
        if not self._authentication_failed:
            return                                                                          # BT:647-648
except (BleakError, TimeoutError) as e:
    raise BluetoothConnectionFailed(f"Failed to connect to machine with Bluetooth: {e}") from e  # BT:649-652
raise BluetoothAuthenticationFailed("Bluetooth authentication failed")                      # BT:653
```

| Item | Value | Source |
|---|---|---|
| Bytes written | `utf8(token)` exactly. No terminator, no base64, no length prefix | `BT:638`; `TBT:448` asserts the first write is `(AUTH_CHAR, b"token")` |
| Write type | with response (`response=True`) | `BT:639` |
| Success value | the read returns exactly `b"\x01"`, a single byte. Anything else (`b"\x00"`, `b"\x01\x00"`, empty) counts as "not yet / rejected" | `BT:49` `AUTH_SUCCESS = b"\x01"`, `BT:646` |
| Read attempts | `AUTH_READ_ATTEMPTS = 10` | `BT:50` |
| Interval | `AUTH_READ_INTERVAL = 0.05` s, **between** reads only (none before the first). Worst case: 10 reads + 9 × 50 ms = about 0.45 s of sleeping | `BT:51`, `BT:643-644` |
| Rejection | after 10 non-`0x01` reads → `BluetoothAuthenticationFailed("Bluetooth authentication failed")` | `BT:653`; `TBT:617-633` (exactly 10 reads, link dropped, `match="authentication failed"`) |
| Transport failure | a `BleakError` or `TimeoutError` during the write or any read → `BluetoothConnectionFailed("Failed to connect to machine with Bluetooth: <e>")`, chained | `BT:649-652` |
| AUTH char missing | `BluetoothConnectionFailed("Could not find characteristic 0d0b7847-e12b-09a8-b04b-8e0922a9abab on machine.")` from `_resolve_characteristic` | `BT:633`, `BT:745-747` |
| Retry until confirmed | succeeds as soon as a read returns `0x01`. The test confirms on the 3rd read: 3 auth reads + 1 status read = 4 reads total | `TBT:636-649` |

`BluetoothAuthenticationFailed` vs `BluetoothConnectionFailed`:

- `BluetoothAuthenticationFailed` is a **subclass** of `BluetoothConnectionFailed` (`EXC:46-47`).
  It's raised only when every read completed and none returned `0x01`, meaning the machine
  answered but rejected the token.
- Every transport-level failure (write or read error, timeout, missing characteristic) is a plain
  `BluetoothConnectionFailed`. Code that catches `BluetoothConnectionFailed` therefore catches
  both. This is how the device-layer fallback treats them (`MACH:1025`).

`authentication_failed` flag (`BT:164`, property `BT:216-222`, docstring "Return whether the last
connection attempt was rejected by the machine. Usually means the Bluetooth token is wrong."):

- It's set on **every** auth read: `True` if that read wasn't `0x01`, `False` on `0x01`
  (`BT:646`).
- It's **not** reset at the start of `_authenticate`, and not on transport errors. If the auth
  write throws before any read, the flag keeps its previous value.
- Only a successful `0x01` read resets it to `False`. `TBT:1305-1323` pins set-then-reset across
  two attempts.

Auth-failure counter (`MAX_AUTH_FAILURES = 3`, `BT:52`):

- It exists **only** inside the shot-counter reconnect loop **[SC-HOOK]** (`BT:488-520`), as a
  task-local `auth_failures = 0` (`BT:491`). Each `BluetoothAuthenticationFailed` adds 1
  (`BT:496-503`). At `>= 3` the loop gives up (`BT:504-506`), then disables the shot counter
  (`BT:516-520`).
- Connection errors in between do **not** reset it. It resets only when a new reconnect task is
  created. README describes this as "3 failed logins in a row" (`README:269`). Strictly it's
  "3 auth failures within one reconnect episode".
- Plain requests never count auth failures. Each request re-runs connect and auth, and each
  rejection raises.

Connection callbacks are not fired for a connection that fails auth. `_set_connected(True)` only
runs in the `else:` branch after `_authenticate` returns (`BT:265-269`). `TBT:1405-1421` pins this.

History:

- v2 auth (commit `0ad74e2`) was a write with no read-back.
- The read-back poll (`AUTH_SUCCESS`, 10 × 50 ms) and `BluetoothAuthenticationFailed` arrived in
  commit `6754903` ("Support Bluetooth shot timer", 2026-10-03). They were needed so the
  shot-counter reconnect loop could tell a wrong token apart from a radio failure and stop
  retrying.
- Legacy code slept 100 ms after auth (`await asyncio.sleep(0.1)`, commit `07f6f13`). v2 dropped
  that sleep.

### 5.2 Outbound framing (`__write_bluetooth_message`, `BT:674-700`)

```python
await self._ensure_connected()                                # BT:680 (lazy connect + timer reset)
if self._client is None: raise BluetoothConnectionFailed("Client is not connected")   # BT:682-683
if not isinstance(message, bytes): message = bytes(message, "utf-8")                 # BT:686-687
message += b"\x00"                                            # BT:689-690 "append trailing zeros"
settings_characteristic = await self._resolve_characteristic(characteristic)          # BT:694
await self._client.write_gatt_char(char_specifier=settings_characteristic, data=message, response=True)  # BT:696-700
```

- **Frame = UTF-8 payload + exactly one `0x00`.** No length prefix and no chunking by the app.
- **Always write-with-response** (`response=True`). History: write-without-response was briefly
  tried (commit `07f6f13`, 2024-12-30) and reverted the same day (`2c7250f`).
- Size limit: bleak documents write-with-response data as "limited to 512 bytes"
  (`BLEAK:673-740`). The largest upstream payload, `SettingSmartStandby`, is under 100 bytes.
  Payloads larger than (ATT MTU − 3) need a long write (Prepare/Execute Write). CoreBluetooth
  does that transparently for `.withResponse` writes up to 512 bytes. Upstream never reads or
  negotiates MTU (§8.3).
- The default characteristic is `WRITE_CHARACTERISTIC` (`BT:677`). Reads pass
  `READ_CHARACTERISTIC` (`BT:656`).
- There's no per-operation timeout. A write that never gets its ATT response blocks until bleak
  or the OS fails it (§8.2).

### 5.3 Inbound framing (`_read_bluetooth_message`, `BT:659-671`)

```python
await self._ensure_connected()                                # BT:663
if self._client is None: raise BluetoothConnectionFailed("Client is not connected")   # BT:665-666
read_characteristic = await self._resolve_characteristic(characteristic)              # BT:668
result = await self._client.read_gatt_char(read_characteristic)                       # BT:669
# responses are NUL-terminated, ignore anything after it                              # BT:670
return bytes(result).split(b"\x00", 1)[0].decode()                                    # BT:671
```

- A **single** GATT read. There's no polling, no "response ready" wait after the request write,
  and no reassembly across several reads. bleak/CoreBluetooth perform ATT long reads (Read Blob)
  transparently up to 512 bytes.
- Everything from the first `0x00` onwards is discarded. Then the bytes are decoded as strict
  UTF-8: invalid UTF-8 → `UnicodeDecodeError`, a `ValueError`. `TBT:1223-1231` pins
  `b'"BrewingMode"\x00\x00garbage'` → `MachineMode.BREWING_MODE`. The NUL truncation was added
  in commit `6754903`. Before it, `result.decode()` would have kept trailing NULs.
- Whether the machine has always written its response by the time the write-with-response
  completes is **UNVERIFIED**. Upstream assumes it, and the tests never model a delay.
- **Edge case:** `_ensure_connected` runs again before the read (`BT:663`). If the link dropped
  between write and read (an unexpected disconnect, or a concurrent public `disconnect()`, which
  doesn't take `_request_lock`), the read silently **reconnects, re-authenticates, and reads**
  the characteristic on a connection where the request was never written. A port should fail the
  request instead.

### 5.4 Read-setting request (`__read_value_from_machine`, `BT:655-657`)

```python
await self.__write_bluetooth_message(setting.value, READ_CHARACTERISTIC)   # write "<name>\0" to 0a0b
return json.loads(await self._read_bluetooth_message())                    # read 0a0b (default char)
```

On-wire request bytes are the ASCII setting name + `0x00`. Pinned examples:
`b"machineCapabilities\x00"` (`TBT:347`), `b"boilers\x00"` (`TBT:370`), `b"smartStandBy\x00"`
(`TBT:399`), `b"tankStatus\x00"` (`TBT:415`), `b"machineMode\x00"` (`TBT:429`) and
`b"isPlumbedIn\x00"` (`TBT:1249`). The response is parsed with `json.loads`; an empty string or
non-JSON raises `json.JSONDecodeError`, a `ValueError`.

### 5.5 Command request (`__send_command`, `BT:702-710`)

```python
await self.__write_bluetooth_message(
    json.dumps({"name": name, "parameter": parameter}, separators=(",", ":"))   # write to 0b0b
)
result = await self._read_bluetooth_message(WRITE_CHARACTERISTIC)               # read 0b0b
return BluetoothCommandStatus.from_json(result)
```

JSON encoding rules a port must reproduce byte-for-byte:

- **Compact separators:** `(",", ":")`, so there's no whitespace anywhere.
- **Key order is insertion order:** top level `name`, then `parameter`. Parameter order is
  per-command (§6.3) and is pinned by test vectors.
- `json.dumps` default `ensure_ascii=True`: non-ASCII would be `\uXXXX`-escaped. All current
  payloads are pure ASCII.
- **Numbers:** a Python `int` serialises without a decimal point (`90` → `90`, `TBT:319`). A
  Python `float` serialises with Python's shortest round-trip repr (`93.0` → `93.0`, `93.5` →
  `93.5`). The device layer passes the caller's value through, so both forms reach the machine:
  steam levels as ints `126`/`128`/`131` (`MACH:58-62`), and coffee temperature as whatever the
  caller passed. Whether firmware accepts both `93` and `93.0` is **UNVERIFIED**, though both
  have been sent historically. A Swift port must not rely on `JSONEncoder`, which emits `93.0`
  as `93`. Hand-build the bytes and pin them with golden tests.
- Booleans are `true`/`false`. Strings are JSON-quoted.
- The frame is the JSON bytes + `0x00` (§5.2).

The response is read from the **same** characteristic `0b0b…` and decoded by
`BluetoothCommandStatus.from_json` (§6.4). Commit history: status read-back introduced in
`57e6da1` ("Add bluetoothcommandstatus", 2025-11-16). Before that, commands returned `None`.

### 5.6 Atomicity of a request

The `disconnect_on_exception` decorator wraps every public read and command in
`async with self._request_lock` (`BT:126-128`), so a write and its read can't interleave with
another request's. `TBT:1253-1284` pins this: with `get_boilers` and `set_temp` gathered, every
request write is directly followed by its read.

---

## 6. Reads and commands: complete catalogue

### 6.1 `BluetoothReadSetting` (`CONST:322-330`)

| Member | Raw value (verbatim, written to `0a0b…`) |
|---|---|
| `MACHINE_CAPABILITIES` | `"machineCapabilities"` |
| `MACHINE_MODE` | `"machineMode"` |
| `TANK_STATUS` | `"tankStatus"` |
| `BOILERS` | `"boilers"` |
| `SMART_STAND_BY` | `"smartStandBy"` (capital `B`) |
| `IS_PLUMBED_IN` | `"isPlumbedIn"` |

### 6.2 Read methods and response shapes

All are `async`, wrapped by `@disconnect_on_exception`, and lazily connect.

| Method | Setting | Response JSON (top level) | Decoding | Pinned example |
|---|---|---|---|---|
| `get_machine_mode() -> MachineMode` (`BT:555-560`) | `machineMode` | JSON **string** | `MachineMode(value)`. Values: `"BrewingMode"`, `"EcoMode"`, `"StandBy"` (`CONST:11-16`). Anything else raises `ValueError` | `b'"BrewingMode"'` (`TBT:424`) |
| `get_machine_capabilities() -> BluetoothMachineCapabilities` (`BT:562-568`) | `machineCapabilities` | JSON **array** of objects. Only element `[0]` is used | `BluetoothMachineCapabilities.from_dict(capabilities[0])`. An empty array raises `IndexError` | `TBT:342` (below) |
| `get_tank_status() -> bool` (`BT:570-575`) | `tankStatus` | JSON bool **or** string | `_parse_bool` | `b'"true"'` → `True` (`TBT:410-416`) |
| `get_plumbed_in() -> bool` (`BT:577-582`) | `isPlumbedIn` | JSON bool **or** string | `_parse_bool` | `true`, `false`, `"true"`, `"false"` (`TBT:1234-1250`) |
| `get_boilers() -> list[BluetoothBoilerDetails]` (`BT:584-588`) | `boilers` | JSON **array** of objects | `[BluetoothBoilerDetails.from_dict(b) for b in boilers]` | `TBT:365` (below) |
| `get_smart_standby_settings() -> BluetoothSmartStandbyDetails` (`BT:590-594`) | `smartStandBy` | JSON **object** | `BluetoothSmartStandbyDetails.from_dict(data)` | `b'{"mode":"PowerOn","minutes":42,"enabled":"true"}'` (`TBT:392-402`) |

`_parse_bool` (`BT:62-64`): `str(value).lower() == "true"`, with the docstring "Parse a boolean
that the machine may send as JSON bool or string." So JSON `true` → `"True"` → `"true"` →
`True`, and `"TRUE"` → `True`. Everything else (`false`, `"false"`, `1`, `null`, `"yes"`) →
`False`. The device layer tolerates `ValueError` from `get_plumbed_in` as "older firmware might
not know this setting" and defaults to `False` (`MACH:357-361`). The machine's reply for an
unknown setting name is **UNVERIFIED**; an empty or non-JSON reply would surface as
`JSONDecodeError`.

Verbatim example responses from the tests:

```
machineCapabilities → [{"family":"MICRA","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":false,
                        "steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":["BrewingMode","StandBy"],
                        "schedulingType":"smartWakeUpSleep"}]                                  (TBT:342)
boilers             → [{"id":"SteamBoiler","isEnabled":true,"target":131,"current":45},
                       {"id":"CoffeeBoiler1","isEnabled":true,"target":94,"current":65}]       (TBT:365)
smartStandBy        → {"mode":"PowerOn","minutes":42,"enabled":"true"}                          (TBT:393)
tankStatus          → "true"                                                                    (TBT:410)
machineMode         → "BrewingMode"                                                             (TBT:424)
isPlumbedIn         → true | false | "true" | "false"                                           (TBT:1236)
```

These are test fixtures, first written in commit `528ff48` (2025-03-29, "bluetooth tests").
Whether they are verbatim device captures is **UNVERIFIED**, but they are the only shape evidence
upstream has.

#### Model field tables (`MBT`)

All models are mashumaro `DataClassJSONMixin` dataclasses, decoded by alias. Every field without
a default is **required**: a missing key fails the decode (mashumaro `MissingField`). Unknown
extra keys are ignored.

`BluetoothMachineCapabilities` (`MBT:22-39`):

| Python field | JSON key | Type / decode |
|---|---|---|
| `family` | `family` | `ModelName` via `ModelName.from_string` (§3.3); unknown → `ValueError` |
| `groups_number` | `groupsNumber` | `int` |
| `coffee_boilers_number` | `coffeeBoilersNumber` | `int` |
| `has_cup_warmer` | `hasCupWarmer` | `bool` |
| `steam_boilers_number` | `steamBoilersNumber` | `int` |
| `tea_doses_number` | `teaDosesNumber` | `int` |
| `machine_modes` | `machineModes` | `list[MachineMode]`; an unknown mode string fails the whole decode (UNVERIFIED error type) |
| `scheduling_type` | `schedulingType` | `str` (free-form; example `"smartWakeUpSleep"`) |

`BluetoothBoilerDetails` (`MBT:42-49`):

| Python field | JSON key | Type |
|---|---|---|
| `id` | `id` | `BoilerType`: `"CoffeeBoiler1"` or `"SteamBoiler"` (`CONST:307-311`); anything else fails the decode |
| `is_enabled` | `isEnabled` | `bool` |
| `target` | `target` | `int` |
| `current` | `current` | `int` |

`BluetoothSmartStandbyDetails` (`MBT:51-57`):

| Python field | JSON key | Type |
|---|---|---|
| `mode` | `mode` | `SmartStandByType`: `"LastBrewing"` or `"PowerOn"` (`CONST:260-264`) |
| `minutes` | `minutes` | `int` |
| `enabled` | `enabled` | `bool`; the machine may send the **string** `"true"` (`TBT:393`), which decodes to `True` |

**UNVERIFIED mashumaro coercions** (settle with the probe, §13):

- `int` fields given JSON floats (`93.5`): truncated or rejected?
- `bool` fields given the string `"false"`: by truthiness, `"false"` would become **`True`**, a
  latent upstream bug. Only `"true"` is tested.

A Swift port should decode `bool`-ish fields with `_parse_bool` semantics and number fields
tolerantly (Int or Double), following Angstrom's "tolerant parsing" convention.

### 6.3 Commands

All commands are `async`, wrapped by `@disconnect_on_exception`, lazily connect, write to `0b0b…`,
read the status back from `0b0b…`, and return `BluetoothCommandStatus`.

| Method (signature) | `name` | `parameter` (key order verbatim) | Exact on-wire bytes (test vector) |
|---|---|---|---|
| `set_power(enabled: bool)` (`BT:596-600`) | `"MachineChangeMode"` | `{"mode": "BrewingMode" if enabled else "StandBy"}` (`MachineMode.BREWING_MODE` / `.STANDBY` `.value`) | `b'{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}\x00'` (`TBT:302-306`) |
| `set_steam(enabled: bool)` (`BT:602-608`) | `"SettingBoilerEnable"` | `{"identifier": "SteamBoiler", "state": <bool>}` | legacy-era vector `b'{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":true}}\x00'` (commit `07f6f13`, same encoder path) |
| `set_smart_standby(enabled: bool, mode: SmartStandByType, minutes: int)` (`BT:610-618`) | `"SettingSmartStandby"` | `{"minutes": <int>, "mode": "<LastBrewing\|PowerOn>", "enabled": <bool>}` | `b'{"name":"SettingSmartStandby","parameter":{"minutes":42,"mode":"PowerOn","enabled":true}}\x00'` (`TBT:331-334`) |
| `set_temp(boiler: BoilerType, temperature: float)` (`BT:620-626`) | `"SettingBoilerTarget"` | `{"identifier": "<CoffeeBoiler1\|SteamBoiler>", "value": <number>}` | `b'{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":90}}\x00'` (`TBT:317-320`) |

Notes:

- The `set_power` docstring says "Power on the machine." but it handles both directions. It
  can't select `EcoMode`. `MachineMode.from_power` exists (`CONST:18-21`), but the client inlines
  the same ternary.
- `set_steam` always targets `SteamBoiler`. There's no command to enable or disable the coffee
  boiler.
- `set_temp` sends the temperature in °C, unvalidated. The device layer uses it for coffee
  temperature (`MACH:807-818` region), for steam temperature on GS3/GS3 AV/GS3 MP/Strada X
  (`MACH:827-838` region), and for **steam level** on Micra/Mini R by mapping
  `Level1/2/3 → 126/128/131` (`MACH:58-62`, `MACH:788-798`).
- Commands not available over BLE in upstream (the device layer marks them `@cloud_only`):
  backflush, pre-extraction, schedules, dosing, brew-by-weight, plumb-in toggle, eco/auto-on-off,
  Strada X mode, and all grinder commands.
- There are no machine-side request IDs. Correlation relies only on `_request_lock`
  serialisation.

### 6.4 Command status (`BluetoothCommandStatus`, `MBT:59-65`)

| Field | JSON key | Type |
|---|---|---|
| `id` | `id` | `str` |
| `message` | `message` | `str` |
| `status` | `status` | `str`, a **free string, not** the cloud `CommandStatus` enum |

- All three keys are required. A missing key or a non-JSON body raises out of `from_json`; these
  errors are **not** handled by the decorator, so the link stays up.
- Example status bodies:
  - `TBT:47`: `b'{"id":"test-id","message":"Success","status":"success"}'`.
  - `CONF:182-194` (mock): `status="success"` with messages `"power on"` (set_power),
    `"boiler enable success"` (set_steam), `"Setting Temperature Success"` (set_temp) and
    `"Success"` (set_smart_standby). Whether these strings are real captures is **UNVERIFIED**.
- **Success semantics live in the device layer:** `if result.status.lower() == "success": return
  True` (`MACH:1023`). A non-success status doesn't raise. The device layer then **falls through
  to the cloud** command if a cloud client exists (`MACH:1037-1047`). The set of failure `status`
  values the machine can send is **UNVERIFIED**.

---

## 7. Connection lifecycle

### 7.1 Per-client state (`__init__`, `BT:142-181`)

| Field | Initial | Purpose |
|---|---|---|
| `_ble_token` | arg | token (`BT:157`) |
| `_address` | `ble_device.address` | identity. **Never updated**, even when `ble_device_callback` returns a different device (`BT:158`) |
| `_ble_device` | arg | current device. Refreshed from the callback before each connect (`BT:159`, `BT:245-246`) |
| `_ble_device_callback` | arg or `None` | "returning the most recent BLEDevice (e.g. after switching adapters/proxies)" (`BT:152-155`, `BT:160`) |
| `_client` | `None` | the `BleakClientWithServiceCache` (`BT:161`) |
| `_lock` | `asyncio.Lock()` | connection-state lock (`BT:162`) |
| `_request_lock` | `asyncio.Lock()` | request serialisation (`BT:163`) |
| `_authentication_failed` | `False` | §5.1 (`BT:164`) |
| `_disconnect_task` | `None` | idle timer task (`BT:165`) |
| `_connection_callbacks` | `[]` | §7.7 (`BT:166`) |
| `_reported_connected` | `False` | edge detector for callbacks (`BT:167`) |
| shot-counter fields | various | **[SC-HOOK]** (`BT:169-181`) |

There's **no public `connect()`**. Connection is lazy, on the first request or on
`start_shot_counter`. The async context manager (`__aenter__`/`__aexit__`) was removed in commit
`3f5001a` (2025-11-15).

### 7.2 `_ensure_connected(use_services_cache=True)` (`BT:233-269`)

```
async with self._lock:
    if self.is_connected:
        self._reset_disconnect_timer(); return                         # BT:236-239  (every request op refreshes idle timer)
    log debug "Connecting to Bluetooth device %s"
    self._shot_counter_subscribed = False                              # BT:242-243  [SC-HOOK]
    try:
        if self._ble_device_callback is not None:
            self._ble_device = self._ble_device_callback()             # BT:245-246
        self._client = await establish_connection(
            BleakClientWithServiceCache, self._ble_device, self._ble_device.name or "Unknown",
            disconnected_callback=self._on_bleak_disconnected, max_attempts=3,
            ble_device_callback=self._ble_device_callback, use_services_cache=use_services_cache)  # BT:247-255
        await self._authenticate()                                     # BT:256
    except BaseException as e:                                         # BT:257  incl. CancelledError
        # also on cancellation: never keep an unauthenticated link
        log error "Failed to connect to Bluetooth device: %r"
        client, self._client = self._client, None                      # BT:260
        if client is not None and client.is_connected:
            with suppress(Exception): await client.disconnect()        # BT:261-263
        raise
    else:
        self._reset_disconnect_timer()                                 # BT:268
        self._set_connected(True)                                      # BT:269
```

- It's called **twice per request**, once before the write (`BT:680`) and once before the read
  (`BT:663`). Each call while connected resets the 30 s idle timer.
- Catching `BaseException` (commit `6754903`) means cancellation during connect or auth tears
  the link down and never leaves a half-open, unauthenticated connection. `TBT:1197-1220` pins
  this: the cancelled task leaves `is_connected` false, calls disconnect once, and fires no
  connection callback.
- Because `self._client` is detached *before* `client.disconnect()`, the bleak disconnect
  callback for that client is ignored (§7.6).
- `use_services_cache=False` is passed only by the shot-counter rediscovery pass **[SC-HOOK]**
  (`BT:406-407`). On macOS it makes no difference (§8.1).

### 7.3 `is_connected` semantics (`BT:183-186`)

`self._client is not None and self._client.is_connected`, meaning the **link** state.

- It becomes `True` as soon as `establish_connection` returns, so it is briefly true **before**
  authentication completes. It doesn't mean "authenticated". The authenticated signal is the
  connection callback (`_reported_connected`).
- After an unexpected disconnect, `_client` is **not** cleared by `_on_bleak_disconnected`, but
  bleak's `is_connected` turns `False`. On CoreBluetooth that means peripheral state is not
  `.connected` (`BCB:156-162`).
- The device layer exposes it as `bluetooth_connected` (`THING:109-114`).

### 7.4 `disconnect_on_exception` decorator (`BT:114-136`)

```python
try:
    # keep write -> read pairs atomic so responses can't interleave
    async with self._request_lock:
        return await func(self, *args, **kwargs)
except (BleakError, TimeoutError, BluetoothConnectionFailed):
    # a single failed command must not kill a running shot counter
    if not (self._shot_counter_enabled and self.is_connected):
        # Disconnect on error (outside the lock to avoid deadlock)
        asyncio.create_task(self._drop_connection())
    raise
```

- It applies to the 10 request methods: `get_machine_mode`, `get_machine_capabilities`,
  `get_tank_status`, `get_plumbed_in`, `get_boilers`, `get_smart_standby_settings`, `set_power`,
  `set_steam`, `set_smart_standby` and `set_temp`.
- It serialises whole requests: connect, auth, write and read all happen under `_request_lock`.
  Lock order is always `_request_lock` → `_lock`.
- **Errors that trigger a drop:** `BleakError` (and subclasses: retry-connector errors, GATT
  errors, CoreBluetooth `"disconnected"`), `TimeoutError`, and `BluetoothConnectionFailed`
  (which includes `BluetoothAuthenticationFailed`).
- **Errors that don't trigger a drop** (the link stays up and the idle timer keeps running):
  `json.JSONDecodeError`, `UnicodeDecodeError`, `ValueError` from enums or `ModelName`,
  `IndexError` (empty capabilities array), and mashumaro decode errors. All of them propagate raw.
- The error is always **re-raised unchanged**. Raw `BleakError` reaches callers; it isn't
  wrapped. `TBT:544-562` shows a write `BleakError` raising `BleakError` and the link getting
  dropped.
- **[SC-HOOK]** While the shot counter is enabled and the link is up, a failed request doesn't
  drop the link (`TBT:1287-1302`, `README:270`).
- History: per-method `try/except` blocks (`738fcfb`) became this decorator (`94de0db`). The
  request lock and the shot-counter guard came in `6754903`. Originally it scheduled
  `self.disconnect()`, which also stops the shot counter. Now it schedules `_drop_connection()`,
  which lets the shot counter reconnect.

### 7.5 Idle auto-disconnect (`BT:271-291`)

- `IDLE_TIMEOUT = 30  # seconds` (`BT:47`). It was configurable (`idle_timeout: float = 30.0`)
  in `738fcfb` and made a constant in `94de0db`.
- `_reset_disconnect_timer` (`BT:271-280`) cancels any existing timer task. It then starts a new
  `_auto_disconnect` task, **unless the shot counter is enabled**, in which case no timer runs
  ("Keep the connection open while the shot counter is running") **[SC-HOOK]**.
- `_auto_disconnect` (`BT:282-291`) does `await asyncio.sleep(30)`, swallows `CancelledError`
  (a reset is normal), and otherwise calls `await self._drop_connection()`.
- Reset points: every `_ensure_connected` on a live link, which is twice per request
  (`BT:238`); after a successful connect (`BT:268`); and after the shot counter stops or fails
  to start (`BT:361`, `BT:370`, `BT:520`). The effective idle window is 30 s after the **start of
  the last request's read**.
- `_disconnect_internal` doesn't cancel the timer task if that task is the one doing the
  disconnecting (`BT:296-300`). This was fixed in `83289c6`, where the timer had cancelled itself
  while awaiting `disconnect()`. `TBT:1373` has the comment "the fake disconnect yields, the
  idle timer must not cancel itself".
- Pinned by `TBT:475-491` (fire → disconnect once) and `TBT:493-513` (a second command restarts
  the timer).

### 7.6 Teardown paths

| Path | Lock | Steps |
|---|---|---|
| `_disconnect_internal()` (`BT:293-311`), caller holds `_lock` | n/a | cancel idle timer (unless self) → `_disconnect_task = None` → **detach** `client, self._client = self._client, None` ("so bleak doesn't report this as a lost connection") → if `client.is_connected`, `await client.disconnect()` (exceptions logged, not raised) → `_set_connected(False)` |
| `_drop_connection()` (`BT:313-317`) | takes `_lock` | `_disconnect_internal()`, then (outside the lock) `_handle_connection_lost()`, which resets shot-counter flags and schedules a reconnect if the shot counter is enabled **[SC-HOOK]** |
| `disconnect()`, public (`BT:319-325`) | takes `_lock` (not `_request_lock`) | `_disable_shot_counter()` (returns the SC connection callback to call) → under the lock, `_stop_notify_internal()` and `_disconnect_internal()` → `_safe_call(connection_callback, False)`. It's idempotent: a second call is a no-op apart from callbacks already being reported `False`. An "idempotent early return" was tried and reverted (`1fcf08f`/`99de588`) |
| `_on_bleak_disconnected(client)` (`BT:467-473`), bleak callback | none | `if client is not self._client: return` (stale or self-initiated) → `_set_connected(False)` → `_handle_connection_lost()`. **Doesn't** clear `self._client` or cancel the idle timer. A later timer fire runs `_drop_connection`, which is harmless |

- **Unexpected disconnect during a request:** bleak's CoreBluetooth backend fails all pending
  delegate futures with `BleakError("disconnected")` (`BCB:123-129`). The request raises
  `BleakError`, and the decorator schedules `_drop_connection`. `TBT:1382-1402` pins a link loss
  reported once (`[True, False]`) and a later request reconnecting (`[True, False, True,
  False]`).
- Plain requests have **no automatic reconnect**. The next request reconnects lazily. Background
  reconnect with backoff exists only for the shot counter (`RECONNECT_INITIAL_DELAY = 1`,
  `RECONNECT_MAX_DELAY = 60`, `BT:53-54`, loop `BT:488-520`). The delay sequence on repeated
  connection errors is 1, 2, 4, 8, 16, 32, 60, 60, … s. It sleeps before every attempt,
  including the first, and auth failures don't double the delay **[SC-HOOK]**.

### 7.7 Connection callbacks (`BT:188-214`)

- `register_connection_callback(callback: Callable[[bool], Any]) -> Callable[[], None]`
  (`BT:188-206`). The callback is appended to a list. The returned `unregister()` removes it if
  still present and is idempotent (`TBT:1424-1435` calls it twice).
- Docstring: "called with True once a connection is established and authenticated, and with
  False when it is closed or lost, including idle disconnects."
- `_set_connected(connected)` (`BT:208-214`) is **edge-triggered** on `_reported_connected`. It
  calls the callbacks synchronously, over a `tuple` snapshot (so unregistering inside a callback
  is safe), each wrapped by `_safe_call`. `_safe_call` (`BT:67-74`) swallows and logs any
  `Exception` with "Error in Bluetooth callback".
- `True` is emitted only after successful auth (`BT:269`). `False` is emitted from
  `_disconnect_internal` (`BT:311`) and `_on_bleak_disconnected` (`BT:472`).
- These are **separate** from the shot counter's own `connection_callback`
  (`start_shot_counter`), which reports *subscription* state **[SC-HOOK]**.
- Device-layer passthrough: `register_bluetooth_connection_callback` (`THING:116-126`). Without a
  BT client it returns a no-op unregister.
- Pinned by `TBT:1361-1435`.

### 7.8 Locking summary for a Swift port

- `_request_lock` serialises every public request end to end (connect, auth, write, read).
- `_lock` guards connect/auth, teardown, and the shot-counter subscribe/unsubscribe. It's held
  across the **whole** `establish_connection` + `_authenticate` (up to 3 connect attempts of
  20 s each with BRC backoffs, plus about 0.45 s of auth polling).
- Work that needs `_lock` from inside a `_lock`-held path is deferred with
  `asyncio.create_task(...)` ("outside the lock to avoid deadlock", `BT:132-133`, `BT:743-744`).
  A Swift `actor` gets this for free if the drop is enqueued as a separate task. Since
  `asyncio.Lock` isn't reentrant, actor reentrancy at `await` points must be handled explicitly,
  for example with an in-flight connect `Task` that others await (as Angstrom's `tokenTask`
  already does for cloud tokens).
- `TBT:516-541` pins that three concurrent commands share one `establish_connection` and produce
  writes in the order `[AUTH, SETTINGS, SETTINGS, SETTINGS]`.

---

## 8. Dependency behaviour a CoreBluetooth port must reproduce or consciously replace

### 8.1 `bleak_retry_connector.establish_connection` (4.4.4, `BRC:398-589`)

Upstream call: `establish_connection(BleakClientWithServiceCache, device, name,
disconnected_callback=..., max_attempts=3, ble_device_callback=..., use_services_cache=...)`
(`BT:247-255`). Behaviour at 4.4.4:

| Aspect | Value / behaviour | Source |
|---|---|---|
| Per-attempt connect timeout | `BLEAK_TIMEOUT = 20.0` s, passed as `client.connect(timeout=...)` | `BRC:102`, inside `BRC:398-589` |
| Safety timeout around each attempt | `BLEAK_SAFETY_TIMEOUT = 60.0` s (`asyncio_timeout`) | `BRC:113` |
| Give-up rule | raise when `timeouts + connect_errors >= max_attempts` (**3** here; library default `MAX_CONNECT_ATTEMPTS = 4`) **or** `transient_errors >= MAX_TRANSIENT_ERRORS = 9` | `BRC:94`, `BRC:101`, `_raise_if_needed` in `BRC:398-589` |
| Error classification | `asyncio.TimeoutError` → `timeouts`. `KeyError`/`BrokenPipeError`/`EOFError` → transient. `BleakError` or `AttributeError` matching `TRANSIENT_ERRORS`, or device-missing → transient. Other `BleakError`s → `connect_errors` | `BRC:84-90`, `BRC:139-145`, `BRC:398-589` |
| Backoff between attempts | `calculate_backoff_time`: 0.25 s for D-Bus/EOF/timeout/broken pipe, **4.0 s** for device-not-found/out-of-slots, 0.5 s / 1.0 s for ESP medium/long transient, 0.25 s for other transient, 0.0 s for `"Disconnected"`, default 0.1 s. On non-Linux, `wait_for_disconnect` simply sleeps for that time | `BRC:51-60`, `BRC:324-350` |
| Final exception types (all `BleakError` subclasses) | `BleakNotFoundError` (timeouts or device missing), `BleakOutOfConnectionSlotsError`, `BleakAbortedError`, `BleakConnectionError` | `BRC:171-184`, `_raise_if_needed` |
| `use_services_cache` | only affects `dangerous_use_bleak_cache` on BlueZ. `_has_valid_services_in_cache` returns `True` on non-Linux; the CoreBluetooth backend ignores the flag | `BRC:238-246`, `BRC:398-589` |
| `ble_device_callback` | **accepted but unused** at 4.4.4: it appears only in the signature (`BRC:405`). Upstream also calls it itself before connecting (`BT:245-246`) | grep of `BRC` |
| `BleakClientWithServiceCache.clear_cache()` | delegates to `super().clear_cache()` if present. bleak 1.1.1 has none, so it logs a warning and returns `False` | `BRC:187-203` |
| Disconnected callback | passed through to the bleak client constructor and invoked with the client on link loss | `BRC:398-589` |

Port decision: implement a small connect-with-retry inside the CoreBluetooth central. Reproduce
"up to 3 attempts, each with a timeout (20 s), a short backoff between attempts, and a typed final
error". A natural mapping is a single `connect(timeout:)` around
`CBCentralManager.connect(_:options:)` plus `cancelPeripheralConnection` on timeout. Then do
service and characteristic discovery, and treat discovery failure as a connect failure.

### 8.2 bleak specifics upstream relies on implicitly

- **Write type** is explicit `response=True`. CoreBluetooth: `.withResponse`, completing on
  `peripheral(_:didWriteValueFor:error:)` (`BCB:328-341`).
- **Read:** `read_gatt_char` issues a fresh device read (`use_cached=False`) and returns the
  full value (`BCB:280-297`). CoreBluetooth: `readValue(for:)`, completing on
  `didUpdateValueFor`. **Gotcha:** CoreBluetooth delivers both read results and notifications
  through `didUpdateValueFor`. `0a0b`/`0b0b`/`0d0b` are never notified by upstream, but the port
  must route by characteristic and by pending-read state.
- **No per-operation timeout:** neither upstream nor bleak's CoreBluetooth backend times out a
  read or write. They complete or fail with `BleakError("disconnected")` on link loss
  (`BCB:123-129`). A port should add a timeout (for example 5-10 s; the value is an owner
  decision) and map it to the same "drop the link" path as `TimeoutError` (`BT:129`).
- **Service discovery per connection:** bleak's CoreBluetooth backend discovers all services,
  characteristics and descriptors on every `connect` (`BCB:139`; discovery at `BCB:225-275`),
  and clears `services` on disconnect (`BCB:118-121`).
- **Disconnect callback:** bleak invokes `disconnected_callback(client)` after link loss. The
  CoreBluetooth equivalent is `centralManager(_:didDisconnectPeripheral:error:)`. Upstream's
  identity check `client is not self._client` (`BT:469`) maps to comparing a connection
  generation or token in the port.
- **Device handle refresh:** `ble_device_callback` exists for Home Assistant adapter or proxy
  switching. On Apple platforms, `CBCentralManager.retrievePeripherals(withIdentifiers:)` with the
  stored identifier UUID replaces it.

### 8.3 MTU

Upstream never reads or negotiates MTU. bleak exposes `mtu_size` (on CoreBluetooth:
`maximumWriteValueLength(for: .withoutResponse) + 3`, `BCB:174-188`), but `BT` never uses it.
All payloads are well under 512 bytes, and write-with-response and long reads are segmented by
the OS. No MTU handling is needed in the port.

### 8.4 Pairing and bonding

- Upstream never calls `BleakClient.pair()`. "Pairing mode" in `read_token` is a **machine-side
  mode** that exposes `0c0b…`; it isn't BLE bonding.
- On macOS, bleak notes that "the user will be prompted to pair the device the first time that a
  characteristic that requires authentication is read or written" (`BLEAK:588-600`;
  `BCB:97-98` logs "Explicit pairing is not available in CoreBluetooth"). Whether any La Marzocco
  characteristic triggers OS pairing is **UNVERIFIED**.

### 8.5 Platform and app requirements (port-only, no upstream counterpart)

- `NSBluetoothAlwaysUsageDescription` in Info.plist.
- macOS App Sandbox needs the `com.apple.security.device.bluetooth` entitlement.
- iOS background operation needs the `bluetooth-central` background mode.
- Pronto (signed, notarised macOS menu-bar app) needs the entitlement and usage string.
- `CBCentralManager` must be in `.poweredOn` before scanning or connecting. Upstream has no
  analogue, since bleak raises.

---

## 9. Public API inventory (`LaMarzoccoBluetoothClient`, v2.5.6)

Exported as `pylamarzocco.LaMarzoccoBluetoothClient` (`CLI:3`, `CLI:7-10`; package
`src/pylamarzocco/__init__.py:3-15`). Module constants live in the private `_bluetooth` module and
aren't exported.

"Wrapped" below means: serialised by `_request_lock`, lazily connects and authenticates, drops
the link on `BleakError`/`TimeoutError`/`BluetoothConnectionFailed` (unless the shot counter is
active), re-raises unchanged, and lets decoding errors propagate without dropping. Wrapped
methods can also raise any connect or auth error from §5.1 and §8.1.

| Member | Signature | Semantics | Errors |
|---|---|---|---|
| constructor | `__init__(self, ble_device: BLEDevice, ble_token: str, ble_device_callback: Callable[[], BLEDevice] \| None = None)` (`BT:142-181`) | stores state only; **no I/O** | none |
| `is_connected` | property `-> bool` (`BT:183-186`) | link up (may be true before auth completes, §7.3) | none |
| `register_connection_callback` | `(callback: Callable[[bool], Any]) -> Callable[[], None]` (`BT:188-206`) | edge-triggered auth/close notifications; returns an unregister function | none (callback exceptions swallowed) |
| `authentication_failed` | property `-> bool` (`BT:216-222`) | last auth read wasn't `0x01` (§5.1) | none |
| `shot_counter_active` | property `-> bool` (`BT:224-231`) | **[SC-HOOK]** enabled ∧ subscribed ∧ connected | none |
| `address` | property `-> str` (`BT:549-553`) | original `ble_device.address` (UUID on macOS) | none |
| `discover_devices` | `@staticmethod async (scanner: BaseBleakScanner \| BleakScanner \| None = None) -> list[BLEDevice]` (`BT:522-537`) | 5 s scan by default; filter `name.startswith(("MICRA","MINI","LINEA","GS3"))` | `AssertionError` if the scanner lacks `discover`; bleak scan errors raw |
| `read_token` | `@staticmethod async (address_or_ble_device: BLEDevice \| str) -> str` (`BT:539-547`) | standalone connect; reads `0c0b…`; UTF-8 decode (no NUL strip); disconnect; pairing mode only | bleak errors raw; `UnicodeDecodeError` |
| `disconnect` | `async () -> None` (`BT:319-325`) | stop the shot counter (callback → `False`), stop notify, close the link, fire `False` | none raised (disconnect errors logged) |
| `start_shot_counter` | `async (callback, connection_callback=None, telemetry_callback=None) -> bool` (`BT:327-362`) | **[SC-HOOK]** note 02 | connect/auth errors |
| `stop_shot_counter` | `async () -> None` (`BT:364-371`) | **[SC-HOOK]** note 02 | none |
| `get_machine_mode` | wrapped `async () -> MachineMode` (`BT:555-560`) | read `machineMode` | `ValueError` on an unknown mode; `JSONDecodeError`; `UnicodeDecodeError` |
| `get_machine_capabilities` | wrapped `async () -> BluetoothMachineCapabilities` (`BT:562-568`) | read `machineCapabilities`, element `[0]` | `IndexError`; `ValueError` (unknown `family`); mashumaro errors; JSON errors |
| `get_tank_status` | wrapped `async () -> bool` (`BT:570-575`) | read `tankStatus`, `_parse_bool` | JSON errors |
| `get_plumbed_in` | wrapped `async () -> bool` (`BT:577-582`) | read `isPlumbedIn`, `_parse_bool` | JSON errors (device layer tolerates `ValueError`) |
| `get_boilers` | wrapped `async () -> list[BluetoothBoilerDetails]` (`BT:584-588`) | read `boilers` | mashumaro errors; JSON errors |
| `get_smart_standby_settings` | wrapped `async () -> BluetoothSmartStandbyDetails` (`BT:590-594`) | read `smartStandBy` | mashumaro errors; JSON errors |
| `set_power` | wrapped `async (enabled: bool) -> BluetoothCommandStatus` (`BT:596-600`) | `MachineChangeMode` | status decode errors |
| `set_steam` | wrapped `async (enabled: bool) -> BluetoothCommandStatus` (`BT:602-608`) | `SettingBoilerEnable` on `SteamBoiler` | status decode errors |
| `set_smart_standby` | wrapped `async (enabled: bool, mode: SmartStandByType, minutes: int) -> BluetoothCommandStatus` (`BT:610-618`) | `SettingSmartStandby` | status decode errors |
| `set_temp` | wrapped `async (boiler: BoilerType, temperature: float) -> BluetoothCommandStatus` (`BT:620-626`) | `SettingBoilerTarget` | status decode errors |

Exception classes (`EXC`):

- `LaMarzoccoError(Exception)` (`EXC:4-5`)
- `BluetoothConnectionFailed(LaMarzoccoError)` (`EXC:20-21`): "we couldn't successfully connect
  through bluetooth".
- `BluetoothAuthenticationFailed(BluetoothConnectionFailed)` (`EXC:46-47`): "the machine rejected
  the Bluetooth auth token".

Exact messages raised by `BT`:

| Message | Source |
|---|---|
| `"Client is not connected"` | `BT:410`, `BT:631`, `BT:666`, `BT:683`, `BT:717` |
| `f"Failed to connect to machine with Bluetooth: {e}"` | `BT:650-651` |
| `"Bluetooth authentication failed"` | `BT:653` |
| `f"Could not find characteristic {characteristic} on machine."` | `BT:745-747` |

Device-layer callers also raise `BluetoothConnectionFailed("Bluetooth client not initialized")`
(`MACH:332`, `MACH:353`).

Models (exported from `pylamarzocco.models`, `src/pylamarzocco/models/__init__.py:85-109`):

- In scope here: `BluetoothMachineCapabilities`, `BluetoothBoilerDetails`,
  `BluetoothSmartStandbyDetails`, `BluetoothCommandStatus`.
- **[SC-HOOK]**: `BluetoothBrewingData`, `BluetoothShotCounterUpdate`, `BluetoothMachineTelemetry`.

Constants (`BT:40-54`, verbatim):

```
READ_CHARACTERISTIC        = "0a0b7847-e12b-09a8-b04b-8e0922a9abab"
WRITE_CHARACTERISTIC       = "0b0b7847-e12b-09a8-b04b-8e0922a9abab"
GET_TOKEN_CHARACTERISTIC   = "0c0b7847-e12b-09a8-b04b-8e0922a9abab"
AUTH_CHARACTERISTIC        = "0d0b7847-e12b-09a8-b04b-8e0922a9abab"
SHOT_COUNTER_CHARACTERISTIC= "0e0b7847-e12b-09a8-b04b-8e0922a9abab"
BT_MODEL_PREFIXES = ("MICRA", "MINI", "LINEA", "GS3")
IDLE_TIMEOUT = 30  # seconds
AUTH_SUCCESS = b"\x01"
AUTH_READ_ATTEMPTS = 10
AUTH_READ_INTERVAL = 0.05  # seconds
MAX_AUTH_FAILURES = 3
RECONNECT_INITIAL_DELAY = 1  # seconds
RECONNECT_MAX_DELAY = 60  # seconds
```

Related enums (`CONST`, raw values verbatim):

- `MachineMode`: `"BrewingMode"`, `"EcoMode"`, `"StandBy"` (`11-16`)
- `BoilerType`: `"CoffeeBoiler1"`, `"SteamBoiler"` (`307-311`)
- `SmartStandByType`: `"LastBrewing"`, `"PowerOn"` (`260-264`)
- `BluetoothReadSetting` (§6.1)
- `ModelName.from_string` (§3.3)

---

## 10. Device-layer consumers (orientation only; note 03 covers them)

- `__bluetooth_command_with_cloud_fallback` (`MACH:983-1047`): tries BT first. Success means
  `status.lower() == "success"` (`MACH:1023`). It catches only `(BleakError,
  BluetoothConnectionFailed)` (`MACH:1025`), so `TimeoutError`, `ValueError` and decode errors
  propagate. On exception without a cloud client it returns `False`. On exception or a non-success
  status with a cloud client, it falls back to the cloud command.
- BT-routed commands: `set_power` (`MACH:500`), `set_steam` (`MACH:770`), `set_steam_level`
  (`MACH:788`), `set_coffee_target_temperature` (`MACH:807`), `set_steam_target_temperature`
  (`MACH:827`), `set_smart_standby` (`MACH:880`, cloud-only when the schedule has
  `auto_stand_by_supported`).
- `get_model_info_from_bluetooth` (`MACH:325-348`): reads capabilities, sets `model_name` and
  `model_code`.
- `get_dashboard_from_bluetooth` (`MACH:350-...`): reads in the order `machineMode` →
  `isPlumbedIn` (a `ValueError` is tolerated) → `tankStatus` → `boilers`. It synthesises
  widgets using `BLE_MACHINE_STATE` and `BLE_BOILER_STATUS` (`MACH:65-75`).

---

## 11. Upstream test vectors to port verbatim (non-shot-counter)

| Vector | Source |
|---|---|
| First write on a cold connect is `(AUTH_CHAR, b"token")` | `TBT:448` |
| `set_power(True)` → `b'{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}\x00'`, `response=True` | `TBT:302-306` |
| `set_temp(STEAM, 90)` → `…"identifier":"SteamBoiler","value":90}}\x00` | `TBT:317-320` |
| `set_smart_standby(True, POWER_ON, 42)` → `…{"minutes":42,"mode":"PowerOn","enabled":true}}\x00` | `TBT:331-334` |
| Read requests: `b"machineCapabilities\x00"`, `b"boilers\x00"`, `b"smartStandBy\x00"`, `b"tankStatus\x00"`, `b"machineMode\x00"`, `b"isPlumbedIn\x00"` | `TBT:347,370,399,415,429,1249` |
| Capabilities decode (MICRA → Linea Micra, etc.) | `TBT:338-358` |
| Boilers decode | `TBT:361-385` |
| Smart standby with `"enabled":"true"` | `TBT:388-403` |
| `"true"` tank status | `TBT:406-417` |
| NUL truncation `b'"BrewingMode"\x00\x00garbage'` | `TBT:1223-1231` |
| `isPlumbedIn` bool/string matrix | `TBT:1234-1250` |
| Auth: 10 reads then `BluetoothAuthenticationFailed`, disconnect once | `TBT:617-633` |
| Auth: confirm on 3rd read → 4 reads total | `TBT:636-649` |
| `authentication_failed` set then reset | `TBT:1305-1323` |
| Lazy connect; one connect reused across commands; concurrent commands share one connect | `TBT:434-472`, `TBT:516-541` |
| Idle disconnect and timer reset | `TBT:475-513` |
| Write `BleakError` → raise and drop link | `TBT:544-562` |
| Missing characteristic → `BluetoothConnectionFailed`, `clear_cache` awaited, link dropped | `TBT:565-581` |
| Reconnect after manual disconnect | `TBT:600-614` |
| Cancellation during auth leaves no link and fires no callback | `TBT:1197-1220` |
| Request atomicity | `TBT:1253-1284` |
| Discovery prefixes | `TBT:1326-1342` |
| `ble_device_callback` used for the connect | `TBT:1345-1358` |
| Connection-callback semantics | `TBT:1361-1435` |
| BLE family mapping (`LINEA`, `LINEAMINI2023`, `MICRA`, `GS3`) | commit `e0f0249`, `tests/test_models.py` |

---

## 12. History digest (why things are the way they are)

| Commit | Date | Change and reason |
|---|---|---|
| `696c94b` / `bbff74b` | 2023-05 / 2025-03 | legacy GATT dump (`LEG`), moved to `docs/legacy` |
| `07f6f13` → `2c7250f` | 2024-12-30 | tried write-without-response, reverted to with-response the same day |
| `3a8a291`…`98f7921` | 2024-12-31 | service-dump debugging; switched to resolving characteristic **objects** |
| `0ad74e2` | 2025-03-28 | **v2 protocol**: new UUIDs `0a0b`…`0d0b`, raw-token auth, read-by-name, `read_token` |
| `95d7f88` | 2025-03-28 | resolve the read characteristic before reading |
| `552a7c5` / `853a4d1` | 2025-03-28 | `smartStandBy` read; it's an **object**, not `[0]` |
| `99019db` | 2025-03-29 | `BluetoothReadSetting` enum |
| `26768fd` | 2025-11-10 | `bleak-retry-connector` `establish_connection(max_attempts=3)`; constructor takes `BLEDevice` only |
| `77e015f` | 2025-11-15 | `_resolve_characteristic` with clear-cache retry |
| `738fcfb` / `3f5001a` / `94de0db` / `03f533f` | 2025-11-15/16 | persistent connection, 30 s idle disconnect, lazy connect in read/write, `disconnect_on_exception`, context manager removed |
| `57e6da1` | 2025-11-16 | commands return `BluetoothCommandStatus` read back from `0b0b` |
| `0488f6b` | 2025-11-17 | `read_token` accepts `BLEDevice \| str` |
| `1fcf08f` / `99de588` | 2025-11-17 | idempotent-disconnect early return tried and reverted |
| `6754903` | 2026-10-03 | shot counter: `_request_lock`, auth read-back poll and `BluetoothAuthenticationFailed`, `BaseException` teardown, `ble_device_callback`, `_drop_connection`, `"LINEA"` prefix, `isPlumbedIn`, `_parse_bool`, NUL-terminated responses |
| `09bc1d4` | 2026-10-04 | `register_connection_callback` / `_set_connected` |
| `83289c6` | 2026-10-05 | telemetry; detach-before-disconnect; the idle timer no longer cancels itself; cached/uncached rediscovery for the shot counter |
| `ef0e947` | 2026-10-13 | `__send_command` refactor (no wire change) |
| `e0f0249` (merged as `4c639ee`) | 2026-11-05 | map BLE families `"LINEA"` → Linea Mini and `"GS3"` → GS3 AV |

---

## 13. UNVERIFIED items (consolidated)

| # | Item | How to resolve |
|---|---|---|
| U1 | Service UUID containing `0a0b`…`0e0b`, and those characteristics' property flags | GATT dump of a current machine (nRF Connect / LightBlue), or `discoverServices(nil)` logging in a probe build |
| U2 | Whether any characteristic requires encryption or bonding (OS pairing prompt) | Connect from macOS with a probe build and watch for a pairing prompt or `insufficientAuthentication` errors |
| U3 | Real advertised name format, and which model uses which prefix | Scan log from real machines (Micra, Mini, Mini R, GS3) |
| U4 | Token format and length; meaning of `bleAuthToken: null` | A real `/things` response (redacted length only) |
| U5 | `0c0b` behaviour outside pairing mode | Probe read with the machine not in pairing mode |
| U6 | Whether responses are always ready immediately after write-with-response, and maximum response size (anything over 512 bytes?) | Device capture; `machineCapabilities` on multi-group or Strada machines |
| U7 | Firmware acceptance of `93` vs `93.0` in `SettingBoilerTarget.value` | Device test, or keep Python's exact formatting |
| U8 | Full set of `status` strings in command responses (failure values) and whether `"success"` is always lowercase | Device capture of a rejected command (for example an out-of-range temperature) |
| U9 | Machine reply to an unknown read-setting name (older firmware and `isPlumbedIn`) | Device capture on old firmware |
| U10 | mashumaro coercions: `"false"` for `bool` fields, floats for `int` fields, unknown `machineModes` values, numeric `id` in the command status, exact exception types | Run `docs/bluetooth/research/probe/probe.py` with mashumaro 3.17 (execution was blocked in this pass) |
| U11 | Whether the example JSON responses in `TBT` and the `CONF` messages are real captures | Ask upstream, or capture from a device |
| U12 | Whether the machine accepts more than one simultaneous central (`README:231` says "likely accepts only one") | Device test |
