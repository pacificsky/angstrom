# 02: Bluetooth shot counter and live telemetry, end to end

This research note is part of the Angstrom Bluetooth-parity plan. It specifies the
shot counter in upstream `pylamarzocco` **v2.5.6, commit `4c639ee`**. The shot counter
reports the brewing state in real time over Bluetooth. The same notification stream
also carries live machine telemetry. The note covers the whole path:

- the GATT notification bytes
- the parsed models
- the brewing state machine
- the client lifecycle of the persistent subscription
- the device-layer overlay on the cloud dashboard

The note does not implement anything. Downstream authors port from this note and the
source.

## Conventions

**Upstream root.** All upstream paths are relative to `U/` =
`$UPSTREAM/`.

**Source aliases.** The aliases below are used throughout. Every citation is `alias:line`
or `alias:start-end`.

| Alias | File |
|---|---|
| `C` | `src/pylamarzocco/clients/_bluetooth.py` |
| `M` | `src/pylamarzocco/models/_bluetooth.py` |
| `D` | `src/pylamarzocco/devices/_machine.py` |
| `T` | `src/pylamarzocco/devices/_thing.py` |
| `K` | `src/pylamarzocco/const.py` |
| `G` | `src/pylamarzocco/models/_general.py` |
| `CFG` | `src/pylamarzocco/models/_config.py` |
| `E` | `src/pylamarzocco/exceptions.py` |
| `TB` | `tests/test_bluetooth_client.py` |
| `TM` | `tests/test_machine.py` |
| `FX` | `tests/fixtures/machine/shot_counter_2026-10-05.txt` |
| `RM` | `README.md` |

**Status labels.**

- **VERIFIED**: copied verbatim from upstream source or tests.
- **DERIVED**: follows mechanically from upstream code plus its pinned dependency
  (mashumaro 3.17, `uv.lock:455-456`). Upstream has no direct test for it.
- **UNVERIFIED**: cannot be determined from the source. Each such item says what would
  resolve it.

**How the vectors were produced.** The test vectors in §7 were traced by hand through
the code. Running upstream code locally was not permitted in this session. The
aggregate assertions in upstream's own fixture test (`TB:931-976`) confirm the trace:
group counts, start times, the stop update, and the telemetry merge.

### History (where the rationale comes from)

Upstream history for this feature is short:

```
6754903 2026-10-03 Support Bluetooth shot timer            (pyproject version 2.5.0)
09bc1d4 2026-10-04 add bluetooth connection hook           (2.5.1)
83289c6 2026-10-05 add bluetooth telemetry, fixes          (2.5.2, adds FX)
0db3f08 2026-10-05 switch to src layout
ef0e947 2026-10-13 code cleanup                            (adds _widget helper)
06717ca 2026-10-30 Extend grinder functionality            (2.5.3, not shot counter)
```

Commit `83289c6` introduced most of the subtle behaviour. Its README diff gives the
rationale (current text: `RM:253-264`):

- the replay discard
- `_BrewingTracker` with the earliest-start estimate
- `BREWING` on the start event
- a separate telemetry model
- stale-service-cache rediscovery
- the reentrancy-safe stop
- the reconnect give-up that disables the counter

Before `83289c6`, all of the following were true:

- `brewing_start_time` was a computed property, `received_at - timer`, with no minimum.
- A parse failure merged an empty message.
- `BREWING` required `ev is True and brewing_time is not None`, so the start event alone
  produced nothing (see the `83289c6` diff of `M`).

The test comment "it recursed in 2.5.1" (`TB:1159`) refers to the old
`_disable_shot_counter`, which called the connection callback while state was still
half-cleared.

---

## 1. Notification wire format

### 1.1 Characteristic and subscription (VERIFIED)

The characteristic UUIDs, verbatim (`C:40-44`):

```python
READ_CHARACTERISTIC = "0a0b7847-e12b-09a8-b04b-8e0922a9abab"
WRITE_CHARACTERISTIC = "0b0b7847-e12b-09a8-b04b-8e0922a9abab"
GET_TOKEN_CHARACTERISTIC = "0c0b7847-e12b-09a8-b04b-8e0922a9abab"
AUTH_CHARACTERISTIC = "0d0b7847-e12b-09a8-b04b-8e0922a9abab"
SHOT_COUNTER_CHARACTERISTIC = "0e0b7847-e12b-09a8-b04b-8e0922a9abab"
```

The tests repeat these values on purpose "to pin the machine's protocol" (`TB:41-45`).

- **Lookup.** The shot counter characteristic is looked up by UUID only, with
  `self._client.services.get_characteristic(SHOT_COUNTER_CHARACTERISTIC)` (`C:415-417`).
- **No service UUID.** Upstream never names the GATT service that contains the
  characteristic. The legacy GATT dump at `docs/legacy/bluetooth_characteristics.md:10-16`
  shows service `d30a7847-e12b-09a8-b04b-8e0922a9abab` with `03..09 0b7847…`
  characteristics. That is older firmware: it does not list `0a..0e`. **UNVERIFIED**:
  which service holds `0e0b…`, and whether the characteristic uses notify or indicate
  (bleak's `start_notify` accepts both). A CoreBluetooth service discovery dump from a
  current-firmware machine would resolve this.
- **Subscribe.** The client subscribes with
  `await self._client.start_notify(characteristic, self._handle_shot_counter_notification)`
  (`C:432-434`).
- **Unsubscribe.** The client unsubscribes with
  `await self._client.stop_notify(SHOT_COUNTER_CHARACTERISTIC)`. The call is best-effort
  and wrapped in `suppress(Exception)` (`C:396-401`).
- **No request.** The host never writes anything to `0e0b…`. The stream is push-only.
- **Authentication first.** Authentication (§4.3) always happens inside
  `_ensure_connected` *before* the subscription. Notifications therefore only flow on an
  authenticated link.

### 1.2 Framing (VERIFIED)

The notification handler is `C:441-465`:

```python
received_at = _utcnow()                                   # C:445
if self._replay_pending: ... return                       # C:446-449 (see 1.3)
try:
    payload = json.loads(bytes(data).strip(b"\x00"))       # C:452
    brewing = BluetoothBrewingData.from_dict(payload)      # C:453
    telemetry = BluetoothMachineTelemetry.from_dict(payload)  # C:454
except Exception as e:                                     # C:455-457: debug log, drop
    return
if not brewing.is_empty:                                   # C:460-463
    update = self._brewing_tracker.process(brewing, received_at)
    if update is not None:
        _safe_call(self._shot_counter_callback, update)
if not telemetry.is_empty:                                 # C:464-465
    _safe_call(self._shot_counter_telemetry_callback, telemetry)
```

**One notification is one complete JSON object.** There is no reassembly, no chunk
buffer and no terminator scan. The handler only calls `.strip(b"\x00")`, which removes
NUL bytes at **both ends**. Contrast this with request/response reads: those are cut at
the *first* NUL with `bytes(result).split(b"\x00", 1)[0]` (`C:670-671`).

**The root must be a JSON object.** These inputs throw inside the `try` and are silently
dropped:

- `b"not json"`
- `b"[]"`, because `from_dict` on a list fails
- `b"\xff\xfe"`, which Python's `json.loads` sniffs as UTF-16 and decodes to empty

The same applies to any value that fails field coercion (§2.4). All of these are pinned
by the `malformed` vectors at `TB:769-781`.

**A parse failure drops the whole notification.** Both models are parsed inside one
`try`. If the telemetry half fails, the brewing half is lost too, and the reverse also
holds. An example is a `MachineStatistics` value that is not a JSON string. DERIVED from
`C:451-457`.

**Size.** The largest payload in the capture is the `MachineStatistics` notification:
418 bytes of JSON text (`FX:23`). It was delivered as one notification, so the capture
link had an ATT MTU of at least 421. **UNVERIFIED** for CoreBluetooth:

- the MTU macOS and iOS negotiate with this ESP32 gateway
- whether the firmware truncates or splits a notification when the MTU is smaller

A CoreBluetooth capture of a `MachineStatistics` notification would resolve both. If
splitting does occur, upstream itself would drop the value as unparsable.

**Timestamp.** `received_at` is taken at handler entry, before the replay check. It is
wall-clock UTC: `datetime.now(timezone.utc)` (`C:57-59`). Tests patch `_utcnow`
(`TB:100-105`).

### 1.3 Replay on subscribe (VERIFIED)

> "on subscribe, the machine first replays its last notification, which can be hours old" (`C:429-430`)

The flow is:

1. `_replay_pending = True` is set immediately **before** `start_notify` (`C:431`).
2. The next notification is discarded unconditionally, whatever its content (`C:446-449`).
3. The flag is cleared at that point.

A replay can arrive in two ways, both tested (`TB:814-845`):

- during `start_notify`, which is the fake's default (`TB:272-273`)
- after `start_notify` returns ("proxies may deliver it after subscribing", `TB:818-819`)

**Hazard.** If a machine ever subscribes *without* replaying, upstream drops the first
real notification. In the fixture, every session starts with a replay:

| Line | Replayed notification |
|---|---|
| `FX:6` | a 3.34 s tick from an earlier shot |
| `FX:73` | `{"Sleep":"command"}`, the same as the previous session's last line `FX:72` |

**UNVERIFIED**: whether the replay is guaranteed, for example after a power cycle with no
prior notification.

The tracker is also replaced with a fresh `_BrewingTracker()` on every successful
subscribe (`C:428`).

### 1.4 Every key: observed vs handled

Key counts were taken over the 80 data lines of `FX` (85 lines minus 5 comment lines);
the counts include the 2 replay lines.

| JSON key | Count in `FX` | Model field (alias at) | Kind | Example (`FX`) |
|---|---|---|---|---|
| `BrewingStartedGroup1DoseIndex` | 4 | `BluetoothBrewingData.started_dose_index: str\|None` (`M:94-96`) | brewing | `{"BrewingStartedGroup1DoseIndex":"ContinuousDose"}` (`FX:15`) |
| `BrewingUpdateGroup1Ev` | 26 | `.ev: bool\|None` (`M:97-99`) | brewing | `true` (`FX:16`) |
| `BrewingUpdateGroup1Backflush` | 26 | `.backflush: bool\|None` (`M:100-102`) | brewing | `false` (`FX:16`) |
| `BrewingUpdateGroup1Time` | 26 | `.brewing_time: float\|None` (`M:103-105`) | brewing | `0.089` (`FX:16`) |
| `FlushStoppedGroup1Time` | 3 | `.flush_stopped_time: float\|None` (`M:106-108`) | brewing | `1.891` (`FX:18`) |
| `FlushStoppedGroup1DoseIndex` | 3 | `.flush_stopped_dose_index: str\|None` (`M:109-111`) | brewing | `"ContinuousDose"` (`FX:18`) |
| `BrewingStoppedGroup1Time` | 1 | `.brewing_stopped_time: float\|None` (`M:112-114`) | brewing | `12.727` (`FX:51`) |
| `BrewingStoppedGroup1DoseIndex` | 1 | `.brewing_stopped_dose_index: str\|None` (`M:115-117`) | brewing | `"ContinuousDose"` (`FX:51`) |
| `BrewingStoppedGroup1StopType` | 1 | `.brewing_stopped_stop_type: str\|None` (`M:118-120`) | brewing | `"Continuous"` (`FX:51`) |
| `BrewingStoppedGroup1StopReason` | 1 | `.brewing_stopped_stop_reason: str\|None` (`M:121-123`) | brewing | `"Manual"` (`FX:51`) |
| `CoffeeBoiler1UpdateTemperature` | 7 | `BluetoothMachineTelemetry.coffee_boiler_temperature: float\|None` (`M:198-200`) | telemetry | `95` (`FX:26`) |
| `SteamBoilerUpdateTemperature` | 31 | `.steam_boiler_temperature: float\|None` (`M:201-203`) | telemetry | `112` (`FX:7`) |
| `MachineMode` | 2 | `.machine_mode: MachineMode\|None`, `deserialize=_known_machine_mode` (`M:204-207`) | telemetry | `"StandBy"` (`FX:71`) |
| `Sleep` | 3 | `.sleep: str\|None` (`M:208`) | telemetry | `"command"` (`FX:72`) |
| `MachineStatistics` | 1 | `.machine_statistics: dict[str, Any]\|None`, `deserialize=json.loads` (`M:209-213`) | telemetry | a JSON **string** containing an object (`FX:23`) |
| `SteamBoilerHeatingCoeff` | 1 | none | **ignored** | a JSON string of `[{"temperature":18,"coefficent":0.1957},…]` (`FX:13`; the coefficient values are "made up", `FX:4-5`) |
| `CoffeeBoiler1HeatingCoeff` | 1 | none | **ignored** | same shape (`FX:78`) |

The upstream tests pin how ignored and unknown keys behave:

- **Unknown keys are ignored.** An unknown key on its own yields empty models, so no
  callback fires: `{"SteamBoilerHeatingCoeff":…}` (`TB:863-867`).
- **Unknown keys do not block known ones.** `{"SomethingNew":1,"BrewingUpdateGroup1Time":3.5}`
  still parses its known key (`TB:777`).
- **An unknown machine mode is treated as absent.** `{"MachineMode":"Unknown"}`
  deserializes to `machine_mode=None`, so the telemetry is empty and no callback fires
  (`TB:866-867`).

**Mixed notifications.** One notification may carry both brewing and telemetry keys.
Each part is processed independently, brewing first: `{"BrewingStartedGroup1DoseIndex":"DoseA","SteamBoilerUpdateTemperature":127}`
fires the telemetry callback with only `steam_boiler_temperature=127` and the brewing
callback with `BREWING` (`TB:874-883`). In practice the machine sends single-purpose
notifications. A notification "usually carries only one" telemetry value (`M:195`).

**Contents of the `MachineStatistics` string.** The upstream model comment says "the
meaning of the counters is unverified" (`M:209`). The decoded object at `FX:23` has these
keys:

- `groups[].doses[]`: single-key objects `{"DoseA":2123}`, `{"DoseB":0}`, `{"DoseC":0}`,
  `{"DoseD":0}`, `{"ContinuousDose":0}`
- `groups[].clean`: `0`
- `groups[].ev_activations`: `3577`
- `groups[].ev_ontime`: `51431`
- `tot_doses`: `2123`
- `boilers`: `[{"rsteam_ontime":152},{"rcoffee_ontime":217}]`
- `tea`: `{"count":0,"ev_activation":0,"ev_ontime":0}`
- `pump_ontime`: `41289`
- `machine_ontime`: `25594`
- `refill_ontime`: `1432`
- `count_liter`: `0`

**Keys known only from the legacy local websocket.** They come from
`docs/legacy/websockets.md:29-90`. They use the same vocabulary but are **not handled**
by the BLE models, and their appearance over BLE is **UNVERIFIED**:

- `BrewingUpdateGroup1Volume`
- `FlushStoppedGroup1Volume`
- `BrewingStartedGroup1StopType`
- `BrewingStartedGroup1VolumeTarget`
- `BrewingSnapshotGroup1`
- `FlushSnapshotGroup1`
- `WakeUp` (for example `"manual"`)

The legacy doc shows each event split into one-key messages. That split explains why
upstream merges partial notifications (§2.1).

---

## 2. Models

### 2.1 `_PartialNotification` base (`M:73-87`, VERIFIED)

```python
@dataclass(kw_only=True)
class _PartialNotification(DataClassJSONMixin):
    def _set_fields(self) -> dict[str, Any]:
        return {f.name: v for f in fields(self) if (v := getattr(self, f.name)) is not None}
    @property
    def is_empty(self) -> bool:
        return not self._set_fields()
    def merge(self, other: Self) -> Self:
        return replace(self, **other._set_fields())
```

**Merge semantics.** `merge` returns a new copy of `self`. Every field that is non-`None`
in `other` overwrites the field in the copy.

- `False`, `0` and `""` all count as set: they are not `None`.
- A field can never be cleared back to `None` by a merge. Only a reset can do that
  (tracker `_reset`, §3.2).

**`is_empty`.** It is true when every field is `None`. It decides whether a part of a
notification is dispatched at all (`C:460`, `C:464`).

**Mutability.** Both subclasses are mutable dataclasses, but upstream only ever replaces
them through `merge`. This makes `update.raw` an effective snapshot.

### 2.2 `BluetoothBrewingData` (`M:90-163`)

There are ten optional fields, all defaulting to `None`; the aliases are in the §1.4
table. All of them are `Group1` only, and there is no multi-group support.
`derive_state` is specified in §3.1.

### 2.3 `BluetoothMachineTelemetry` (`M:191-213`)

There are five optional fields; the aliases are in the §1.4 table. The docstring reads
"Live machine values sent with the shot counter notifications. A notification usually
carries only one of them." (`M:193-196`).

### 2.4 Parsing quirks

These rules come from mashumaro 3.17 as pinned in upstream's `uv.lock:455-456`. They
were read from the mashumaro source in
`scratchpad/mvenv/.venv/lib/python3.12/site-packages/mashumaro/core/meta/types/unpack.py`.

**Key lookup is alias only.** Python field names such as `ev` are not accepted. The
default config has `allow_deserialization_not_by_alias` False (builder.py:1336-1363).
DERIVED.

**Key absent or `null` leaves the field `None`.** For an optional field with default
`None`, the unpacker only runs when the value is present and not `None`
(builder.py:1381-1390). DERIVED.

**Per-type coercion** (DERIVED):

- `float` fields use `float(value)` (`unpack.py:889-893`).
  - `112` becomes `112.0`.
  - The numeric string `"3.5"` becomes `3.5`. The JSON `true` becomes `1.0`.
  - `"abc"` raises, so the **whole notification is dropped**. This case is VERIFIED by
    `TB:773`: `{"BrewingUpdateGroup1Time":"abc"}` gives no callback.
- `bool` fields (`ev`, `backflush`) use `bool(value)` (`unpack.py:896-899`).
  - JSON `true` and `false` map exactly.
  - A **string** `"false"` gives `True`, because Python string truthiness applies.
  - `0` gives `False`, `1` gives `True`.
  - The module-level `_parse_bool` (`C:62-64`, `str(value).lower() == "true"`) is **not**
    used by these models. It applies only to the request/response reads `get_tank_status`
    and `get_plumbed_in` (`C:570-582`; tested at `TB:1234-1250`).
  - **UNVERIFIED** whether the firmware ever sends quoted booleans on the notify stream.
    The fixture only has JSON `true`/`false`.
- `str` fields (dose indices, stop type and reason, `sleep`) use `str(value)`
  (`unpack.py:1262-1263`). `1` becomes `"1"`, and `true` becomes `"True"`.

**`machine_mode`** uses `_known_machine_mode` (`M:68-70`):

```python
return MachineMode(value) if value in MachineMode else None
```

- A known raw value maps to its case. Known values come from `K:11-16`: `"BrewingMode"`,
  `"EcoMode"` and `"StandBy"`.
- Any other string becomes `None`. The field then counts as unset.
- A non-string is `None` on Python ≥ 3.12. Upstream requires 3.13 (`pyproject.toml`).

**`machine_statistics`** uses `json.loads(value)`.

- The value **must be a JSON string**. If the machine sent a raw object, `json.loads`
  raises `TypeError` and the whole notification is dropped. DERIVED.
- The decoded result is not type-checked, so it may be any JSON value.

**JSON numbers.** Python `json.loads` also accepts `NaN`/`Infinity`. Swift
`JSONSerialization` does not. This is irrelevant in practice.

The table below gives the Swift parity rules a port must decide on. Each row records
upstream behaviour, so diverging from it is an open decision (§9):

| Wire value | Field type | Upstream result |
|---|---|---|
| `true` / `false` | bool | `True` / `False` |
| `"true"` / `"false"` | bool | `True` / **`True`** |
| `1` / `0` | bool | `True` / `False` |
| `12` / `12.5` / `"12.5"` | float | `12.0` / `12.5` / `12.5` |
| `"abc"`, `[]`, `{}` | float | exception: notification dropped |
| `null` / absent | any | `None` (unset) |
| `"DoseA"` / `3` | str | `"DoseA"` / `"3"` |
| `"Unknown"` | MachineMode | `None` (unset) |

### 2.5 `BluetoothShotCounterUpdate` (`M:166-188`, VERIFIED)

```python
@dataclass(kw_only=True)
class BluetoothShotCounterUpdate:          # plain dataclass, NOT mashumaro (not serializable)
    state: BluetoothBrewingState
    timer_value: float | None = None
    final_shot_time: float | None = None
    started_dose_index: str | None = None
    stop_reason: str | None = None
    received_at: datetime
    raw: BluetoothBrewingData
    # when the current shot started, defaults to received_at - timer_value
    brewing_start_time: datetime | None = None

    def __post_init__(self) -> None:
        if (self.brewing_start_time is None
                and self.state is BluetoothBrewingState.BREWING
                and self.timer_value is not None):
            self.brewing_start_time = self.received_at - timedelta(seconds=self.timer_value)
```

`brewing_start_time` is mutable after construction: the tracker overwrites it at `C:110`.
The value is non-`None` **only** for `BREWING`.

`BluetoothBrewingState` (`K:333-339`):

```python
class BluetoothBrewingState(StrEnum):
    BREWING = "Brewing"
    BREWING_STOPPED = "BrewingStopped"
    FLUSHED = "Flushed"
    BACKFLUSHING = "Backflushing"
```

There is no `idle` state. "Nothing known" is expressed as `None`: the device layer's
`ble_brewing_update` is `None`, or the device callback receives `None`.

---

## 3. The brewing state machine

### 3.1 `derive_state(received_at)` over the merged data (`M:125-163`, VERIFIED)

`derive_state` works on the **accumulated** data `D`, not on the single message. The
rules are tested in priority order, and the first match wins:

| # | Predicate on `D` | State |
|---|---|---|
| 1 | `brewing_stopped_time` set **or** `brewing_stopped_dose_index` set **or** `brewing_stopped_stop_type` set **or** `brewing_stopped_stop_reason` set **or** `ev is False` | `BREWING_STOPPED` |
| 2 | `flush_stopped_time` set **or** `flush_stopped_dose_index` set | `FLUSHED` |
| 3 | `backflush is True` | `BACKFLUSHING` |
| 4 | `started_dose_index` set **or** (`ev is True` **and** `brewing_time` set) | `BREWING` |
| 5 | otherwise | return `None` (no update) |

`ev is False` and `ev is True` are identity checks. Because mashumaro produces real
`bool`s, this means exactly `false` or `true` after coercion.

The update is built as follows (`M:151-163`):

| Update field | Value |
|---|---|
| `timer_value` | `(D.brewing_time or 0.0)` if the state is `BREWING`, else `None`. A start event without a time gives `0.0`. |
| `final_shot_time` | `D.brewing_stopped_time`, for every state. In practice it is only non-`None` when the state is `BREWING_STOPPED`, because of rule 1. **A flush's `FlushStoppedGroup1Time` is never surfaced here.** It is only in `raw.flush_stopped_time`. |
| `started_dose_index` | `D.started_dose_index`, which can be a value carried over from the start event |
| `stop_reason` | `D.brewing_stopped_stop_reason` |
| `received_at` | `received_at or datetime.now(timezone.utc)` |
| `raw` | `D` itself, the merged snapshot |
| `brewing_start_time` | from `__post_init__`, so only for `BREWING`: `received_at - timer_value` |

The stop type (`brewing_stopped_stop_type`) and the flush dose index are **not** promoted
to update fields. Consumers read them from `raw`.

### 3.2 `_BrewingTracker.process(message, received_at)` (`C:77-111`, VERIFIED)

The tracker has two pieces of state:

- `_data: BluetoothBrewingData`, which is `D`
- `_start_time: datetime | None`, which is `S`

Both are reset by `_reset()` (`C:86-88`).

```
process(M, t):
  1. if M.started_dose_index is not None: _reset()            # "a new shot or flush started" (C:94-96)
  2. D := D.merge(M)                                          # C:97
  3. U := D.derive_state(t)                                   # C:98
  4. if U is None: return None                                # D is KEPT (fragments accumulate) (C:99-100)
  5. if U.state in {FLUSHED, BREWING_STOPPED}: _reset()        # C:101-105; U keeps its values
  6. elif U.brewing_start_time is not None:                   # i.e. U.state == BREWING
        if S is None or U.brewing_start_time < S: S := U.brewing_start_time
        U.brewing_start_time := S                             # C:106-110
        # "notifications can only be delayed, so the earliest start is the best"
  7. return U
```

Further rules:

- `process` is only called when the brewing part is non-empty (`C:460`). A
  telemetry-only notification **never** touches `D` or `S`.
- A `BACKFLUSHING` update has `brewing_start_time` `None`, so it never changes `S`.
- **The tracker is replaced wholesale with `_BrewingTracker()`** in four places:
  - on each successful subscribe (`C:428`)
  - on connection loss (`C:479`)
  - on `_disable_shot_counter` (`C:390`)
  - at construction (`C:179`)

### 3.3 Transition table

The table below can be re-implemented and unit-tested directly. "Phase" is a
non-normative name for the tracker's situation. Message kinds:

| Message kind | Shape |
|---|---|
| `START(i)` | `{"BrewingStartedGroup1DoseIndex": i}` |
| `TICK(t)` | `{"BrewingUpdateGroup1Time": t, "BrewingUpdateGroup1Ev": true, "BrewingUpdateGroup1Backflush": false}`, as in the fixture and `_tick` at `TB:51-59` |
| `TICK_BF(t)` | the same with `"BrewingUpdateGroup1Backflush": true` |
| `EV_OFF` | `{"BrewingUpdateGroup1Ev": false}` |
| `BSTOP(t, r, ty, i)` | `{"BrewingStoppedGroup1StopType": ty, "BrewingStoppedGroup1StopReason": r, "BrewingStoppedGroup1DoseIndex": i, "BrewingStoppedGroup1Time": t}` |
| `FSTOP(t, i)` | `{"FlushStoppedGroup1DoseIndex": i, "FlushStoppedGroup1Time": t}` |
| `FRAG` | any brewing-only fragment matching none of rules 1-4 after the merge, for example `{"BrewingUpdateGroup1Backflush": false}` or `{"BrewingUpdateGroup1Ev": true}` without a time |

Phases:

| Phase | Meaning |
|---|---|
| `IDLE` | `D` empty, `S` None |
| `PENDING` | `D` non-empty but no state derivable; only reachable via `FRAG` |
| `BREWING` | `D` matches rule 4 only |
| `BACKFLUSH` | `D` matches rule 3 |

`t_r` is `received_at` throughout.

| From | Message | Emitted update (state, `timer_value`, `final_shot_time`, `brewing_start_time`) | Next phase, `S` |
|---|---|---|---|
| any | `START(i)` | `BREWING`, `0.0`, `None`, `t_r` | `BREWING`, `S = t_r` |
| `IDLE` / `PENDING` | `TICK(t)` | `BREWING`, `t`, `None`, `t_r − t` ("joined mid-shot", `TB:764-765`) | `BREWING`, `S = t_r − t` |
| `BREWING` | `TICK(t)` | `BREWING`, `t`, `None`, `min(S, t_r − t)` | `BREWING`, `S = min(S, t_r − t)` |
| `IDLE` / `BREWING` / `PENDING` | `TICK_BF(t)` | `BACKFLUSHING`, `None`, `None`, `None` | `BACKFLUSH`, `S` unchanged |
| `BACKFLUSH` | `TICK_BF(t)` | `BACKFLUSHING`, `None`, `None`, `None` | `BACKFLUSH` |
| `BACKFLUSH` | `TICK(t)` (backflush back to false) | `BREWING`, `t`, `None`, `min(S, t_r − t)` or `t_r − t` if `S` is None | `BREWING` |
| any | `EV_OFF` | `BREWING_STOPPED`, `None`, `D.brewing_stopped_time` (normally `None`), `None` | `IDLE` (reset) |
| any | `BSTOP(t, …)` | `BREWING_STOPPED`, `None`, `t`, `None`; also `stop_reason = r`, and `started_dose_index` = the start's index if a `START` preceded it since the last reset | `IDLE` (reset) |
| any | `FSTOP(t, i)` | `FLUSHED`, `None`, `None`, `None` (`raw.flush_stopped_time = t`) | `IDLE` (reset) |
| `IDLE` / `PENDING` | `FRAG` | none (`C:99-100`) | `PENDING`, with the fragment kept in `D` |
| any | unparsable payload, or telemetry-only payload | none; the tracker is untouched | unchanged |

Consequences, all VERIFIED by `TB:746-767`:

- **Two `BREWING_STOPPED` updates per shot are possible.** An `EV_OFF` gives
  `(BREWING_STOPPED, None, None)`. A following `BSTOP` gives a second
  `(BREWING_STOPPED, None, 27.4)`, because after the reset `D` holds only the stop fields.
- **A flush looks like a shot until it stops.** A shot or flush is reported as `Brewing`
  right away, with a timer of 0 (`RM:255`). In the fixture, a 9.3 s pull ended with
  `FlushStopped…` (`FX:69`), so the classification is the machine's.
- **A late tick after a stop re-enters `BREWING`.** The stop reset `D`, and `TICK` alone
  satisfies rule 4. Upstream has no guard against this. The fixture has ticks 3 ms before
  a stop (`FX:21-22`), but never after one.
- **Fragments persist in `PENDING`.** Example: after a reset, `{"BrewingUpdateGroup1Backflush":false}`
  is kept. A later `{"BrewingUpdateGroup1Ev":true,"BrewingUpdateGroup1Time":2}` then
  derives `BREWING`. Upstream checks one variant: after a reconnect,
  `{"BrewingUpdateGroup1Backflush":false}` produces no callback (`TB:1046-1048`).

### 3.4 Timing semantics

- `timer_value` is the machine's own elapsed time for the running shot, in seconds, as a
  float. Fixture ticks arrive about every 1.07 s (`FX:39-50`).
- `brewing_start_time` is the earliest estimate seen so far:
  `min over the shot of (received_at − timer_value)`. The start event counts with timer 0.
  Late notifications therefore never move it later. Earlier ones move it earlier
  (`TB:980-1006`).
  - In the fixture the estimate moves at most 29 ms earlier than the start event's arrival.
  - Upstream asserts `0 ≤ start_event_received_at − brewing_start_time < 0.05 s` for every
    `BREWING` update (`TB:951-957`).
- `final_shot_time` is the machine-reported shot duration from `BrewingStoppedGroup1Time`,
  for example `12.727` (`FX:51`).
- `received_at` is wall-clock UTC. If the wall clock jumps, the start estimate is skewed;
  upstream has the same weakness.

---

## 4. Client lifecycle of the persistent subscription

### 4.1 Constants (`C:46-54`, VERIFIED)

```python
BT_MODEL_PREFIXES = ("MICRA", "MINI", "LINEA", "GS3")
IDLE_TIMEOUT = 30  # seconds
AUTH_SUCCESS = b"\x01"
AUTH_READ_ATTEMPTS = 10
AUTH_READ_INTERVAL = 0.05  # seconds
MAX_AUTH_FAILURES = 3
RECONNECT_INITIAL_DELAY = 1  # seconds
RECONNECT_MAX_DELAY = 60  # seconds
```

`establish_connection(..., max_attempts=3, ...)` is called at `C:247-255`. It is the
bleak-retry-connector's own internal retry count.

### 4.2 Client state (`C:157-181`)

| Field | Meaning |
|---|---|
| `_client` | the bleak client, or `None` |
| `_lock` | serializes connect, subscribe and disconnect |
| `_request_lock` | serializes write→read request pairs (`C:126-128`) |
| `_authentication_failed` | the `authentication_failed` property |
| `_disconnect_task` | the idle timer |
| `_connection_callbacks` | the list of general connection callbacks |
| `_reported_connected` | debounce for the general callbacks |
| `_shot_counter_enabled` | the user wants the counter running |
| `_shot_counter_subscribed` | notifications are active on the current link |
| `_shot_counter_callback` | user callback for brewing updates |
| `_shot_counter_connection_callback` | user callback for connection changes |
| `_shot_counter_telemetry_callback` | user callback for telemetry |
| `_brewing_tracker` | the §3.2 tracker |
| `_replay_pending` | the §1.3 replay flag |
| `_reconnect_task` | the running reconnect loop, if any |

`shot_counter_active` is defined as follows (`C:224-231`):

```python
return self._shot_counter_enabled and self._shot_counter_subscribed and self.is_connected
```

`is_connected` is `self._client is not None and self._client.is_connected` (`C:183-186`).

### 4.3 Connect and authenticate: `_ensure_connected(use_services_cache=True)` (`C:233-269`)

All of the following runs under `_lock`.

1. **Already connected.** If the link is up, `_reset_disconnect_timer()` and return
   (`C:236-239`).
2. **New link.** `_shot_counter_subscribed = False`, because "a new connection never has
   active notifications" (`C:242-243`).
3. **Device refresh.** If `ble_device_callback` is set, the device is refreshed from it
   (`C:245-246`).
4. **Connect.** `establish_connection(BleakClientWithServiceCache, device, name or "Unknown",
   disconnected_callback=self._on_bleak_disconnected, max_attempts=3,
   ble_device_callback=…, use_services_cache=…)` (`C:247-255`).
5. **Authenticate** with `_authenticate()` (`C:628-653`):
   1. Write the token, `bytes(self._ble_token, "utf-8")`, to `AUTH_CHARACTERISTIC` with
      `response=True`.
   2. Read the same characteristic up to `AUTH_READ_ATTEMPTS` (10) times. Sleep
      `AUTH_READ_INTERVAL` (0.05 s) before every attempt except the first.
   3. Success is `bytes(result) == b"\x01"`. `_authentication_failed` is updated on every
      read.
   4. A `BleakError` or `TimeoutError` raises `BluetoothConnectionFailed`.
   5. If all 10 reads fail, raise `BluetoothAuthenticationFailed("Bluetooth authentication failed")`.
      This is a subclass of `BluetoothConnectionFailed` (`E:46-47`).
6. **Any exception, including cancellation (`BaseException`).** Detach `_client`, then
   best-effort `disconnect()`, then re-raise: "never keep an unauthenticated link"
   (`C:257-264`). The general callbacks are **not** notified, because the link was never
   reported as connected (`TB:1405-1421`).
7. **Success.** `_reset_disconnect_timer()`, then `_set_connected(True)` (`C:265-269`).

So **authentication always precedes the subscribe**. The subscribe happens in
`_subscribe_shot_counter` after `_ensure_connected` returns (§4.5). The protocol details
of auth and requests are in note 01.

### 4.4 The idle auto-disconnect vs keeping the link alive

The idle timer is reset by `_reset_disconnect_timer` (`C:271-280`):

```python
if self._disconnect_task is not None:
    self._disconnect_task.cancel()
# Keep the connection open while the shot counter is running
self._disconnect_task = (None if self._shot_counter_enabled
                         else asyncio.create_task(self._auto_disconnect()))
```

- `_auto_disconnect` (`C:282-291`) sleeps for `IDLE_TIMEOUT`, which is 30 s, then calls
  `_drop_connection()`.
- Every `_ensure_connected` call on a live link resets the timer, including every request.
- **While `_shot_counter_enabled` is set, there is no idle timer.** `start_shot_counter`
  sets `_shot_counter_enabled = True` *before* subscribing (`C:353`). The `_ensure_connected`
  inside the subscribe then cancels any idle timer already running (`TB:719-730`).
- The idle timer resumes when either of these happens:
  - `stop_shot_counter` (`C:369-370`)
  - a failed start (`C:358-361`) or the reconnect loop giving up (`C:519-520`), each of
    which resets the timer while the link is connected
- `_disconnect_internal` (`C:293-311`) cancels the idle timer, unless it is the task
  doing the disconnect (`C:296-301`). It then detaches `_client` **before**
  `client.disconnect()`, "so bleak doesn't report this as a lost connection" (`C:303-304`).
  Finally it calls `_set_connected(False)`.

### 4.5 `start_shot_counter(callback, connection_callback=None, telemetry_callback=None) -> bool` (`C:327-362`)

```python
self._shot_counter_callback = callback
self._shot_counter_connection_callback = connection_callback
self._shot_counter_telemetry_callback = telemetry_callback
self._shot_counter_enabled = True
supported = False
try:
    supported = await self._subscribe_shot_counter()
finally:
    if not supported:
        self._disable_shot_counter()          # return value (callback) discarded
        if self.is_connected:
            self._reset_disconnect_timer()
return supported
```

`_subscribe_shot_counter` (`C:403-439`) runs this loop:

```
for use_services_cache in (True, False):              # C:406
    await self._ensure_connected(use_services_cache)  # auth happens here
    async with self._lock:
        if client is None or not connected: raise BluetoothConnectionFailed("Client is not connected")
        if not self._shot_counter_enabled: return False      # stopped meanwhile
        if self._shot_counter_subscribed: return True        # already subscribed: NO connection_callback(True)
        characteristic = services.get_characteristic(SHOT_COUNTER_CHARACTERISTIC)
        if characteristic is None:
            if not use_services_cache: return False          # genuinely unsupported
            await self._client.clear_cache()                 # "the cached service table may be stale or incomplete"
            await self._disconnect_internal()                # general callbacks: False
            continue                                         # reconnect WITHOUT the cache
        self._brewing_tracker = _BrewingTracker()
        self._replay_pending = True
        await self._client.start_notify(characteristic, self._handle_shot_counter_notification)
        self._shot_counter_subscribed = True
    _safe_call(self._shot_counter_connection_callback, True)  # outside the lock
    return True
return False
```

Contract of `start_shot_counter`:

- **Returns `True`** when subscribed, including when it was already subscribed.
- **Returns `False`** when the characteristic is missing even after one uncached
  rediscovery (`TB:652-674`).
  - The counter is then disabled.
  - The link stays connected on the uncached connection, and the idle timer resumes.
  - The cache is cleared exactly once, with exactly one extra disconnect. The connection
    sequence is `use_services_cache` `[True, False]` (`TB:665-668`).
- **Raises** connection or auth errors from `_ensure_connected` and `start_notify`:
  `BluetoothConnectionFailed`, `BluetoothAuthenticationFailed`, `BleakError` and
  `TimeoutError`. The `finally` disables the counter first. These errors are **not**
  converted to `False`, and the device layer does not catch them either (`D:187-191`).
- **Calling it again while subscribed** swaps the three callbacks and returns `True`
  without subscribing again and without `connection_callback(True)` (`TB:1108-1122`).
  Only the new brewing callback receives later updates.
- **Stale cache recovered** (`TB:677-696`): `connection_callback(True)` fires once.

### 4.6 Notifications, `stop_shot_counter`, `disconnect`

**`stop_shot_counter()`** (`C:364-371`) has the docstring "Unsubscribe from brewing
notifications and resume idle disconnects".

1. `cb = _disable_shot_counter()` (`C:373-394`). This step:
   - returns `None` immediately if the counter is not enabled
   - otherwise captures the connection callback **only if** `_shot_counter_subscribed`
   - sets `enabled = False`
   - clears all three callbacks
   - replaces the tracker
   - cancels and clears `_reconnect_task`
2. Under `_lock`, call `_stop_notify_internal()`. This is a best-effort
   `stop_notify(SHOT_COUNTER_CHARACTERISTIC)` and sets `subscribed = False`. Then, if
   connected, call `_reset_disconnect_timer()`.
3. Call `_safe_call(cb, False)` **last**, so "a callback stopping the shot counter again
   is a no-op" (`C:376-377`). Reentrancy is tested at `TB:1125-1153` and `TB:1156-1180`.

**`disconnect()`** (`C:319-325`) does the same as `stop_shot_counter`, except that it
also calls `_disconnect_internal()` under the lock. The general callbacks get `False`
first, then `cb(False)`. A user `disconnect()` never triggers a reconnect (`TB:1094-1105`):

- `_disable_shot_counter` has already cleared `enabled`.
- `_client` was detached, so bleak's disconnect callback is ignored (`C:469-470`).

**Late notifications.** Between `_disable_shot_counter` and `stop_notify`, a late
notification may still reach the handler. All callbacks are `None` by then, so
`_safe_call` ignores it (`C:69-70`), and only the fresh tracker is touched.

**Callback safety.** Every user callback invocation in the client goes through
`_safe_call` (`C:67-74`). Exceptions are logged with `_logger.exception("Error in
Bluetooth callback")` and swallowed (`TB:1009-1019`).

### 4.7 Connection loss and the reconnect loop

There are three entry points to connection loss:

- bleak reports a disconnect: `_on_bleak_disconnected` (`C:467-473`). It is ignored
  unless `client is self._client`, which filters out user disconnects. Otherwise it calls
  `_set_connected(False)`, then `_handle_connection_lost()`.
- `_drop_connection()` (`C:313-317`). It runs `_disconnect_internal()` under the lock,
  then `_handle_connection_lost()`. Three paths use it:
  - the idle timer
  - `disconnect_on_exception` when the counter is not running (`C:129-134`)
  - `_resolve_characteristic` failure (`C:743-744`). **This one is unconditional, even
    while the shot counter runs.** A request whose characteristic cannot be resolved
    drops the link, and the reconnect loop restores it.

`_handle_connection_lost` (`C:475-486`):

```python
was_subscribed = self._shot_counter_subscribed
self._shot_counter_subscribed = False
self._brewing_tracker = _BrewingTracker()        # "the running shot must be forgotten" (TB:1032)
if not self._shot_counter_enabled: return
if was_subscribed:
    _safe_call(self._shot_counter_connection_callback, False)
if self._reconnect_task is None or self._reconnect_task.done():
    self._reconnect_task = asyncio.create_task(self._reconnect_shot_counter())
```

`_reconnect_shot_counter` (`C:488-520`):

```python
delay: float = RECONNECT_INITIAL_DELAY        # 1
auth_failures = 0
while self._shot_counter_enabled:
    await asyncio.sleep(delay)                # sleeps BEFORE every attempt, including the first
    try:
        supported = await self._subscribe_shot_counter()
    except BluetoothAuthenticationFailed as e:            # caught first (it subclasses BluetoothConnectionFailed)
        auth_failures += 1
        if auth_failures >= MAX_AUTH_FAILURES:            # 3
            break                                         # delay NOT doubled; no explicit disconnect
    except (BleakError, TimeoutError, BluetoothConnectionFailed) as e:
        async with self._lock:
            await self._disconnect_internal()
        delay = min(delay * 2, RECONNECT_MAX_DELAY)       # 1 → 2 → 4 → 8 → 16 → 32 → 60 → 60 …
    else:
        if supported: return                              # success (connection_callback(True) fired inside)
        break                                              # characteristic gone, or stopped meanwhile
# give up for good, without cancelling this task
self._reconnect_task = None
self._disable_shot_counter()                               # its returned callback is DISCARDED: no False here
if self.is_connected:
    self._reset_disconnect_timer()
```

Precise semantics:

**Attempt timing.** The first attempt comes 1 s after the loss. Each attempt is a full
`_subscribe_shot_counter`: connect, authenticate, and the subscribe including the
stale-cache fallback.

**Backoff.** On a connection error the delays between attempts are 1, 2, 4, 8, 16, 32,
60, 60, … s. An auth failure leaves `delay` unchanged.

**`MAX_AUTH_FAILURES`.** The counter is **cumulative within one reconnect run**. It is
never reset by an intervening connection error. The README says "They stop after 3
failed logins in a row" (`RM:269`). The code counts 3 total since the loss.

- **The code is the reference of record.**
- `TB:1072-1091` expects `establish_connection` to be awaited exactly 4 times: the
  initial connect plus 3 failed reconnects.
- After giving up: `authentication_failed` is True, `shot_counter_active` is False and
  `is_connected` is False.

**Giving up is silent.** No callback fires at give-up time. The shot counter connection
callback already got `False` at loss time, if it was subscribed. After give-up,
`_shot_counter_enabled` is False, so `shot_counter_active` stays False until the caller
calls `start_shot_counter` again.

**Uncaught exceptions end the task.** An exception outside the three caught types kills
the task, for example a non-Bleak error from `start_notify`. The counter is then left
with `enabled = True` but no task, until the next loss creates a new one. This is
DERIVED, and an edge case upstream does not handle.

**Success.** `_subscribe_shot_counter` already called `connection_callback(True)`. A
retry sequence produces `connection_callback` calls `[True, False, True]`
(`TB:1053-1069`).

### 4.8 When the callbacks fire

**Shot counter `connection_callback(bool)`.** It is per subscription, set by
`start_shot_counter`.

| Event | Call |
|---|---|
| Successful (re)subscribe in `_subscribe_shot_counter` | `True` (`C:437`) |
| Start while already subscribed | nothing |
| Connection lost while subscribed (bleak, idle, error drop) | `False` (`C:482-484`) |
| Connection lost while not subscribed (for example during reconnect attempts) | nothing |
| `stop_shot_counter()` or `disconnect()` while subscribed | `False`, last (`C:325`, `C:371`) |
| Reconnect give-up, or a failed initial start | nothing |

**General `register_connection_callback(cb) -> unregister`** (`C:188-214`). It fires
`True` after an authenticated connect and `False` on any close or loss, including idle
disconnects. Calls are debounced by `_reported_connected`, so they only fire on change.
`unregister` is idempotent (`TB:1424-1435`). It is independent of the shot counter.

**Brewing `callback(update)`.** It fires once per notification that produces an update,
never with `None` at the client level. The `None` contract belongs to the device layer
(§5).

**`telemetry_callback(telemetry)`.** It fires once per notification with a non-empty
telemetry part. It receives **only the values present in that notification**, not a
merged state (`C:344-345`, `TB:859-862`).

### 4.9 Ordinary reads and commands on the same connection

**Shared link.** Requests share `_client`. They are serialized by `_request_lock` in
`disconnect_on_exception` (`C:114-136`), which keeps "write -> read pairs atomic so
responses can't interleave" (`TB:1253-1284`). Notifications are delivered independently:
the handler is synchronous and takes no lock.

**A failed request keeps the link.** A request that fails with `BleakError`,
`TimeoutError` or `BluetoothConnectionFailed` (which includes auth failure) normally
drops the link. That is skipped while `self._shot_counter_enabled and self.is_connected`:
"a single failed command must not kill a running shot counter" (`C:130-134`, `TB:1287-1302`).
The error is still re-raised.

**Requests while disconnected.** A request made during a reconnect gap calls
`_ensure_connected` and may establish the link itself, without subscribing. The reconnect
loop's next attempt then finds the link up and only subscribes. Because the counter is
enabled, the request's `_reset_disconnect_timer` creates no idle timer.

**`_resolve_characteristic`.** As noted in §4.7, a failure here drops the link even while
the counter runs (`C:737-747`).

**Single central.** The README says the machine "likely accepts only one central at a
time" (`RM:231`). A persistent shot counter link therefore blocks the official app and
other hosts. This is **UNVERIFIED**.

### 4.10 Client shot-counter lifecycle

```
            start_shot_counter()                 subscribe ok → conn_cb(True)
 DISABLED ───────────────────────► SUBSCRIBING ───────────────────────────────► ACTIVE
    ▲   ▲  raises / char missing        │                                          │
    │   └────────── (finally: disable) ─┘                                          │ link lost
    │                                                                              │ (bleak/idle/drop)
    │ stop/disconnect: conn_cb(False) if subscribed                                ▼
    ├───────────────────────────────────────────────────────────────────── LOST: conn_cb(False),
    │                                                                      tracker reset, spawn
    │   give up (3 auth failures, char gone): silent                        reconnect task
    └──────────────────────────────────────────────── RECONNECTING ◄───────────────┘
                                                        │  sleep(delay); subscribe
                                                        └─ ok → conn_cb(True) → ACTIVE
```

`shot_counter_active` is True only in `ACTIVE`.

---

## 5. Device-layer overlay (`D`, `LaMarzoccoMachine`)

### 5.1 Maps and constants (VERIFIED)

`BLE_MACHINE_STATE` (`D:65-69`):

```python
BLE_MACHINE_STATE = {
    MachineMode.BREWING_MODE: MachineState.POWERED_ON,
    MachineMode.ECO_MODE: MachineState.ECO_MODE,
    MachineMode.STANDBY: MachineState.STANDBY,
}
```

`BLE_BOILER_STATUS` (`D:71-75`):

```python
BLE_BOILER_STATUS = {
    MachineMode.BREWING_MODE: BoilerStatus.READY,
    MachineMode.ECO_MODE: BoilerStatus.ECO_MODE,
    MachineMode.STANDBY: BoilerStatus.STAND_BY,
}
```

The expiry timeout (`D:87-88`):

```python
# drop the Bluetooth brewing state if no notification arrived for this long
BLE_BREWING_STATE_TIMEOUT = 60  # seconds
```

The raw values of the enums involved:

| Enum | Location | Case = raw value |
|---|---|---|
| `MachineState` | `K:24-31` | `STANDBY="StandBy"`, `POWERED_ON="PoweredOn"`, `BREWING="Brewing"`, `ECO_MODE="EcoMode"`, `OFF="Off"` |
| `BoilerStatus` | `K:267-275` | `STAND_BY="StandBy"`, `HEATING="HeatingUp"`, `READY="Ready"`, `NO_WATER="NoWater"`, `ECO_MODE="EcoMode"`, `OFF="Off"` |

**Boiler widgets are never touched by the shot counter.** `BLE_BOILER_STATUS` is used
only by `get_dashboard_from_bluetooth`, inside `boiler_status()` (`D:371-376`): `NO_WATER`
if no water, `OFF` if disabled, otherwise `BLE_BOILER_STATUS[mode]`. Neither the
brewing updates nor the telemetry write any boiler widget. Telemetry boiler temperatures
are exposed **only** through `machine.bluetooth_telemetry`. The cloud boiler widgets have
no current-temperature field to write to.

**The only widget overlaid is `CMMachineStatus`** (`MachineStatus`, `CFG:116-119`). Its
fields (`CFG:96-113`) are:

- `status: MachineState`
- `available_modes`
- `mode: MachineMode`
- `next_status`
- `brewing_start_time: datetime | None`, alias `brewingStartTime`, epoch ms

Telemetry `machine_mode` also writes `mode` on `CMMachineGroupStatus` (`D:487-492`).
That widget's `status` is never overlaid.

### 5.2 Device state (`D:116-130`)

| Field | Meaning |
|---|---|
| `_ble_brewing_update: BluetoothShotCounterUpdate \| None` | the latest brewing update |
| `_last_shot_time: float \| None` | duration of the last shot |
| `_shot_counter_callback: Callable[[Update \| None], Any] \| None` | user brewing callback |
| `_telemetry_callback: Callable[[Telemetry], Any] \| None` | user telemetry callback |
| `_bluetooth_telemetry = BluetoothMachineTelemetry()` | the merged telemetry |
| `_stopping_shot_counter = False` | set while `disconnect_bluetooth_shot_counter` runs |
| `_cloud_machine_status: tuple[MachineStatus, MachineState, datetime \| None] \| None` | the saved cloud values ("cloud values of the machine status widget, before BLE overrides"): `(widget object, cloud status, cloud brewing_start_time)` |
| `_ble_brewing_expiry: asyncio.TimerHandle \| None` | the 60 s expiry timer |

### 5.3 Connecting: `connect_bluetooth_shot_counter(update_callback=None, telemetry_callback=None) -> bool` (`D:158-191`)

```python
if self._bluetooth_client is None:
    return False
self._shot_counter_callback = update_callback
self._telemetry_callback = telemetry_callback
return await self._bluetooth_client.start_shot_counter(
    self._on_shot_counter_update,
    connection_callback=self._on_shot_counter_connection,
    telemetry_callback=self._on_bluetooth_telemetry,
)
```

**No gating.** There is no check of `dashboard.shot_counter_supported`, of the model, or
of the cloud. `TM:745-762` asserts that the start works with `shot_counter_supported`
False.

- It returns `False` without a Bluetooth client, or when the client returns `False`.
- Exceptions propagate from the client (§4.5).

### 5.4 Brewing updates: `_on_shot_counter_update(update)` (`D:209-221`)

```python
self._ble_brewing_update = update
if update.final_shot_time is not None:
    self._last_shot_time = update.final_shot_time
self._apply_ble_brewing_state()
# never let a stale Bluetooth state mask the cloud on a long-running host
if self._ble_brewing_expiry is not None:
    self._ble_brewing_expiry.cancel()
self._ble_brewing_expiry = asyncio.get_running_loop().call_later(
    BLE_BREWING_STATE_TIMEOUT, self._drop_ble_brewing_state)
self._notify_shot_counter_listeners(update)
```

- **The expiry is re-armed for every update, of every state.** That includes
  `BREWING_STOPPED` and `FLUSHED`. The overlay therefore persists for 60 s after a shot
  ends. That window is what suppresses a late cloud `Brewing` push (§5.7).
- **Only brewing updates re-arm the expiry.** Telemetry does not (§5.6).
- **`last_shot_time`** (`D:145-148`) is only set from `final_shot_time`. Flushes never
  change it (`TM:820-822`). It is never reset: not by expiry, not by disconnect, not by
  stop.

### 5.5 `_apply_ble_brewing_state()` (`D:287-314`)

```python
update = self._ble_brewing_update
if update is None or (widget := self._widget(MachineStatus)) is None:
    return                                             # no widget → no-op, nothing saved
# remember the cloud values of a freshly loaded widget
if self._cloud_machine_status is None or self._cloud_machine_status[0] is not widget:
    self._cloud_machine_status = (widget, widget.status, widget.brewing_start_time)
_, cloud_status, cloud_brewing_start_time = self._cloud_machine_status
if update.state == BluetoothBrewingState.BREWING:
    widget.status = MachineState.BREWING
    widget.brewing_start_time = update.brewing_start_time
else:
    widget.status = (MachineState.POWERED_ON if cloud_status == MachineState.BREWING
                     else cloud_status)
    widget.brewing_start_time = cloud_brewing_start_time
```

`_widget(cls)` is `self.dashboard.config.get(cls.widget_type)` (`T:184-186`).

The overlay as a table:

| `update.state` | `widget.status` | `widget.brewing_start_time` |
|---|---|---|
| `BREWING` | `MachineState.BREWING` | `update.brewing_start_time` (tracker min-estimate) |
| `BREWING_STOPPED`, `FLUSHED`, **`BACKFLUSHING`** | saved cloud status, except that cloud `BREWING` is shown as `POWERED_ON` | the saved cloud `brewing_start_time` |

**`BACKFLUSHING` is not shown as brewing.** It falls into the else branch and shows the
cloud status mapped as above.

**"Freshly loaded" means a different object.** The widget object differs from the saved
one by **Python object identity**, `is not`. That happens when:

- the REST dashboard is reloaded
- a websocket push carries widgets
- `get_dashboard_from_bluetooth` *creates* a new widget

In each case the new widget's values become the saved cloud values *before* the overlay
is written.

### 5.6 Telemetry: `_on_bluetooth_telemetry(telemetry)` (`D:230-241`)

```python
self._bluetooth_telemetry = self._bluetooth_telemetry.merge(telemetry)
if (mode := telemetry.machine_mode) is not None:
    self._update_machine_mode_widgets(mode)          # MachineStatus.mode and MachineGroupStatus.mode
    if machine_status := self._widget(MachineStatus):
        machine_status.status = BLE_MACHINE_STATE[mode]
    self._dashboard_config_updated()                 # re-saves cloud status if same widget, then re-applies overlay
if self._telemetry_callback is not None:
    self._telemetry_callback(telemetry)              # the PARTIAL telemetry, not the merged one
elif mode is not None:
    self._notify_dashboard_listeners()
```

**Merged telemetry.** `bluetooth_telemetry` (`D:137-143`) holds the merge of all
telemetry since the start or the last connection loss. In the docstring's words, it is
"Reset when the shot counter stops or loses its connection." Merging the whole fixture
gives coffee `87`, steam `115`, sleep `"command"` and `machine_statistics["tot_doses"] == 2123`
(`TB:969-976`).

**A machine mode is applied right away.** For example, "standby half a second after
switching the machine off" (`RM:264`). The mapped status is written straight into the
current cloud widget. If an overlay is active, the hook (§5.7) then makes it the new
saved cloud status. If a shot is in progress, `BREWING` is re-applied on top.

- Test: an `ECO_MODE` received during a shot keeps `BREWING`. After `FLUSHED`, the widget
  shows `(ECO_MODE, ECO_MODE)` (`TM:995-1011`).
- Test: a `STANDBY` mode with no shot gives `(mode, status) == (STANDBY, STANDBY)`
  (`TM:961-988`).

**Only the machine mode reaches the dashboard.** Temperatures, sleep and statistics never
touch it. Without a telemetry callback, only machine-mode notifications reach the
dashboard callback (`TM:1014-1033`).

**Telemetry never re-arms the brewing expiry.**

### 5.7 The `_dashboard_config_updated` hook, and cloud updates during an overlay

The hook is a no-op in the base class (`T:181-182`) and is overridden at `D:316-323`:

```python
if self._cloud_machine_status is not None:
    widget, _, brewing_start_time = self._cloud_machine_status
    if self.dashboard.config.get(WidgetType.CM_MACHINE_STATUS) is widget:
        # refreshed in place by Bluetooth, which doesn't report the start time
        self._cloud_machine_status = (widget, widget.status, brewing_start_time)
self._apply_ble_brewing_state()
```

Callers of the hook:

| Caller | Location | Widget object |
|---|---|---|
| REST `get_dashboard()` | `T:134-141` | **new** objects |
| websocket push with non-empty `widgets` | `T:169-176` | **new** objects |
| `get_dashboard_from_bluetooth()` | `D:485` | same object, `status` freshly set at `D:392`; new only if the widget was absent |
| telemetry with a machine mode | `D:237` | same object, `status` freshly set at `D:236` |

**Invariant to preserve in a port.** The hook is only ever called *right after* the
widget's `status` was freshly written from a non-overlay source. For an in-place BLE
refresh it re-saves that status as the cloud baseline and keeps the saved cloud
`brewing_start_time`. For a new object, `_apply_ble_brewing_state` captures the new
values.

What happens when a cloud update arrives while an overlay is active:

**Websocket push with widgets** (`T:169-179`):

1. `dashboard.widgets` and `dashboard.config` are replaced by the push's.
2. The hook runs. Saved identity ≠ new widget, so the new cloud values are saved and the
   overlay is applied to the **new** widget.
3. **Then** `_update_callback(config)` is called. `config.config` is the same dict now in
   `dashboard.config`, so the consumer sees the overlaid status.

Example: a late cloud `Brewing` after the BLE stop is shown as `POWERED_ON`
(`TM:811-815`).

**Websocket push with no widgets.** The dashboard is untouched and the hook does not
run. `_update_callback(config)` is still called.

**REST refresh.** The overlay is re-applied over the fresh widget the same way.

**The old widget keeps the overlay values.** The previous widget object is no longer in
the dashboard. `_clear_ble_brewing_state` only restores if the saved widget is still
current (`D:283`).

**Writes that don't call the hook.** `set_power` and `set_mode` write only `mode` through
`_update_machine_mode_widgets` (`D:487-492`, `D:494-521`). They do not call the hook and
do not change `status`.

**Hook without an overlay.** When no brewing update has been received,
`_ble_brewing_update` is `None` and `_apply_ble_brewing_state` is a no-op. The
`_cloud_machine_status` may still be `None`.

### 5.8 Connection changes, expiry and stop

**`_on_shot_counter_connection(connected)`** (`D:223-228`):

```python
if connected or self._stopping_shot_counter:
    return
self._bluetooth_telemetry = BluetoothMachineTelemetry()
self._drop_ble_brewing_state()
```

- `True` does nothing.
- `False` resets the merged telemetry, restores the cloud values and notifies `None`.
  This does not happen during a device-initiated stop (`TM:824-832`, `TM:990-992`).

**`_drop_ble_brewing_state()`** (`D:243-246`) calls `_clear_ble_brewing_state()`, then
`_notify_shot_counter_listeners(None)`.

**`_clear_ble_brewing_state()`** (`D:273-285`):

```python
self._ble_brewing_update = None
if self._ble_brewing_expiry is not None:
    self._ble_brewing_expiry.cancel(); self._ble_brewing_expiry = None
if self._cloud_machine_status is None: return
widget, status, brewing_start_time = self._cloud_machine_status
self._cloud_machine_status = None
if self.dashboard.config.get(WidgetType.CM_MACHINE_STATUS) is widget:
    widget.status = status
    widget.brewing_start_time = brewing_start_time
```

**Expiry.** 60 s after the last brewing update, `_drop_ble_brewing_state` runs. It
restores the cloud values and notifies `None` (`TM:882-907`). The shot counter itself
keeps running; the next brewing update re-applies the overlay. If the widget was
refreshed in place by BLE meanwhile, the BLE-refreshed status survives the expiry
(`TM:917-937`).

The expiry callback runs from the event loop, outside the client's `_safe_call`. An
exception in the user callback therefore goes to the loop's exception handler.

**`disconnect_bluetooth_shot_counter()`** (`D:193-207`) has the docstring "The update
callbacks are not called, refresh after awaiting this."

```python
self._stopping_shot_counter = True
try:
    if self._bluetooth_client is not None:
        await self._bluetooth_client.stop_shot_counter()   # its connection_callback(False) is ignored via the flag
finally:
    self._stopping_shot_counter = False
self._shot_counter_callback = None
self._telemetry_callback = None
self._bluetooth_telemetry = BluetoothMachineTelemetry()
self._clear_ble_brewing_state()                             # silent restore; cancels the expiry
```

The Bluetooth link stays up, and its idle timer resumes. `last_shot_time` is kept. Tested
by `TM:853-879`: no callback, status restored, telemetry empty, the expiry timer
cancelled.

**Calling `client.disconnect()` or `client.stop_shot_counter()` directly** bypasses the
flag. The device layer then sees `False`: it resets the telemetry, drops the overlay and
notifies `None`.

**The reconnect give-up path is silent at the device layer too.** The `False` and `None`
already happened at loss time.

### 5.9 Listener routing

**`_notify_shot_counter_listeners(update_or_None)`** (`D:248-255`): call
`update_callback(update_or_None)` if one was given. Otherwise call
`_notify_dashboard_listeners()` (`TM:835-850`).

**`_notify_dashboard_listeners()`** (`D:257-271`): if `_update_callback` (the websocket
update callback from `connect_dashboard_websocket`, `T:188-210`) is set, call it with a
synthesized config:

```python
ThingDashboardWebsocketConfig(
    widgets=self.dashboard.widgets,
    config=self.dashboard.config,
    connected=self.dashboard.connected,
    connection_date=int(self.dashboard.connection_date.timestamp() * 1000),
    uuid="",
    commands=[],
)
```

Without a cloud client this callback can never be set, so there is no fallback
notification.

**Callback contract of `update_callback`.** It receives every brewing update. It receives
`None` when the Bluetooth state is no longer applied: on connection loss, or after 60 s
without an update (`D:170-173`). It does not receive `None` on a device-initiated stop.

**Callback contract of `telemetry_callback`.** It receives every telemetry notification,
after the machine mode has been applied (`D:174-178`).

### 5.10 Models and capabilities: `shot_counter_supported`

**The cloud flag.** It is defined at `G:131-136`:

```python
shot_counter_supported: bool = field(
    metadata=field_options(alias="shotCounterSupported", deserialize=lambda v: bool(v)),
    default=False,
)
```

It maps `null` and an absent key to `False` (`tests/test_models.py:391-403`). Only the
Strada X, Strada profile/settings/schedule and Swan fixtures carry the key, all `false`.
The Micra, Mini, Mini R and GS3 AV dashboard fixtures omit it, so no committed fixture
shows `true`. Angstrom already
ports it (`Machine.shotCounterSupported`, `Sources/Angstrom/Models.swift:32,96-97`).

**Upstream uses the flag only as information.** Nothing in the library gates on it.

**Supported machines.** The README says: "an ESP-gateway machine (Linea Micra, Linea
Mini, Linea Mini R, GS3 AV/MP) with shot counter firmware; `connect_bluetooth_shot_counter`
returns `False` otherwise" (`RM:229`).

- **Firmware support** is detected at runtime by the presence of `0e0b…` (§4.5).
- **Discovery prefixes** are `("MICRA", "MINI", "LINEA", "GS3")` (`C:46`).
- **The capture** is from a Linea Micra (`FX:1`).
- **Strada X, the Pico and Swan grinders, and multi-group keys have no BLE path.**

**`get_model_info_from_bluetooth()`** (`D:325-348`):

- It raises `BluetoothConnectionFailed("Bluetooth client not initialized")` without a
  client.
- It calls `get_machine_capabilities()` and re-raises `BleakError` or
  `BluetoothConnectionFailed` after logging.
- It sets `dashboard.model_name = capabilities.family`, which is a `ModelName` parsed by
  `ModelName.from_string` (`K:198-218`). The BLE family strings `"GS3"` and `"LINEA"` map
  to `"GS3 AV"` and `"Linea Mini"`.
- It sets `dashboard.model_code = ModelCode[capabilities.family.name]`. The enum
  *member names* match between `ModelName` (`K:185-196`) and `ModelCode` (`K:167-178`).
  On `KeyError` it logs a warning and keeps the old code (`TM:1063-1076`).
- It does not interact with the shot counter.

---

## 6. Public API inventory

### 6.1 Client: `LaMarzoccoBluetoothClient` (`C`)

| Member | Signature / type | Contract |
|---|---|---|
| ctor | `(ble_device: BLEDevice, ble_token: str, ble_device_callback: Callable[[], BLEDevice] \| None = None)` (`C:142-147`) | The callback supplies the newest `BLEDevice` on every (re)connect. |
| `is_connected` | `bool` property (`C:183-186`) | |
| `authentication_failed` | `bool` property (`C:216-222`) | the last auth read result |
| `shot_counter_active` | `bool` property (`C:224-231`) | enabled ∧ subscribed ∧ connected |
| `register_connection_callback` | `(callback: Callable[[bool], Any]) -> Callable[[], None]` (`C:188-206`) | debounced `True`/`False`; returns `unregister` |
| `start_shot_counter` | `async (callback: Callable[[BluetoothShotCounterUpdate], Any], connection_callback: Callable[[bool], Any] \| None = None, telemetry_callback: Callable[[BluetoothMachineTelemetry], Any] \| None = None) -> bool` (`C:327-362`) | §4.5 |
| `stop_shot_counter` | `async () -> None` (`C:364-371`) | §4.6; keeps the link up |
| `disconnect` | `async () -> None` (`C:319-325`) | §4.6; stops the counter and closes the link |
| `address` | `str` property (`C:549-553`) | |
| `discover_devices`, `read_token`, `get_*`, `set_*` | | covered by note 01; they share the link (§4.9) |

The client callbacks are invoked synchronously on the event loop, from bleak's
notification or disconnect callbacks, and are always wrapped by `_safe_call`.

### 6.2 Models (exported from `pylamarzocco.models`)

All are exported in `src/pylamarzocco/models/__init__.py:85-109`.

| Type | Kind | Public members |
|---|---|---|
| `BluetoothBrewingData` | mashumaro `DataClassJSONMixin` | 10 optional fields; `is_empty`; `merge(other)`; `derive_state(received_at=None) -> BluetoothShotCounterUpdate \| None` |
| `BluetoothShotCounterUpdate` | plain dataclass | `state`, `timer_value`, `final_shot_time`, `started_dose_index`, `stop_reason`, `received_at`, `raw`, `brewing_start_time` |
| `BluetoothMachineTelemetry` | mashumaro | 5 optional fields; `is_empty`; `merge` |
| `BluetoothBrewingState` | `StrEnum` (`K:333-339`) | |

The exceptions are `BluetoothConnectionFailed(LaMarzoccoError)` (`E:20`) and
`BluetoothAuthenticationFailed(BluetoothConnectionFailed)` (`E:46-47`).

### 6.3 Device layer: `LaMarzoccoMachine` (`D`), plus `LaMarzoccoThing` (`T`)

| Member | Signature / type | Contract |
|---|---|---|
| `ble_brewing_update` | `BluetoothShotCounterUpdate \| None` (`D:132-135`) | the latest update; `None` when not applied |
| `bluetooth_telemetry` | `BluetoothMachineTelemetry` (`D:137-143`) | merged values; reset on stop or loss |
| `last_shot_time` | `float \| None` (`D:145-148`) | the last `final_shot_time`; never reset |
| `bluetooth_shot_counter_active` | `bool` (`D:150-156`) | delegates to the client; `False` without one |
| `connect_bluetooth_shot_counter` | `async (update_callback: Callable[[BluetoothShotCounterUpdate \| None], Any] \| None = None, telemetry_callback: Callable[[BluetoothMachineTelemetry], Any] \| None = None) -> bool` (`D:158-191`) | §5.3; fallback to the websocket `update_callback` |
| `disconnect_bluetooth_shot_counter` | `async () -> None` (`D:193-207`) | silent restore (§5.8) |
| `get_model_info_from_bluetooth` | `async () -> None` (`D:325-348`) | §5.10 |
| `get_dashboard_from_bluetooth` | `async () -> None` (`D:350-485`) | calls the hook; covered by note 03 |
| `bluetooth_connected` | `bool` (`T:109-114`) | |
| `bluetooth_client_available` | `bool` (`T:99-102`) | |
| `register_bluetooth_connection_callback` | `(callback: Callable[[bool], Any]) -> Callable[[], None]` (`T:116-126`) | a no-op lambda without a client |
| `connect_dashboard_websocket` | `(update_callback=None, connect_callback=None, disconnect_callback=None, auto_reconnect=True)` (`T:188-210`) | sets `_update_callback`, the fallback listener |
| `dashboard.shot_counter_supported` | `bool` (`G:131-136`) | informational |
| module constants | `BLE_MACHINE_STATE`, `BLE_BOILER_STATUS`, `BLE_BREWING_STATE_TIMEOUT` | §5.1 |

---

## 7. Test vectors

### 7.1 Fixture replay at client level (from `FX`)

The harness follows `TB:894-929`. Each line `HH:MM:SS.mmm <json>` becomes a notification
received at `2026-10-05THH:MM:SS.mmmZ`. A line ending in `# replay` starts a new session:
`start_shot_counter` is called with that payload as the machine's replay. After each
session, `stop_shot_counter()` is called. The machine went to standby, and the test
comment says this "stops the shot counter" (`TB:928-929`). That was Home Assistant's
policy (`TB:1166`), not the library's.

Notation:

- `B(timer, bst)` is `BREWING` with `final=None`, `stop_reason=None` and
  `started_dose_index="ContinuousDose"`. `bst` is the `brewing_start_time` as
  `HH:MM:SS.mmm`.
- `T{field=value}` is a telemetry callback with exactly that one field set; floats are
  shown as given.
- "dropped" means no callback.

**Session 1 (replay at `FX:6`)**

| `FX` line | Received | Payload (abbrev.) | Expected |
|---|---|---|---|
| 6 | 07:47:38.548 | tick 3.34 (replay) | dropped (replay) |
| 7-12 | 07:47:47.412 … 07:49:03.904 | steam 112, 115, 118, 121, 124, 127 | `T{steam=112.0}` … `T{steam=127.0}`, one each |
| 13 | 07:49:22.144 | `SteamBoilerHeatingCoeff` | dropped (unknown key) |
| 14 | 07:49:22.179 | steam 130 | `T{steam=130.0}` |
| 15 | 07:50:02.612 | `START(ContinuousDose)` | `B(0.0, 07:50:02.612)` |
| 16 | 07:50:02.682 | `TICK(0.089)` | `B(0.089, 07:50:02.593)`: estimate 02.593 < S |
| 17 | 07:50:03.742 | `TICK(1.159)` | `B(1.159, 07:50:02.583)` |
| 18 | 07:50:04.525 | `FSTOP(1.891, ContinuousDose)` | `FLUSHED`, timer None, final None, bst None, `started_dose_index="ContinuousDose"`, `raw.flush_stopped_time=1.891`; tracker reset |
| 19 | 07:50:09.360 | `START` | `B(0.0, 07:50:09.360)` |
| 20 | 07:50:09.507 | `TICK(0.107)` | `B(0.107, 07:50:09.360)`: estimate 09.400 ignored |
| 21 | 07:50:11.215 | `TICK(1.177)` | `B(1.177, 07:50:09.360)`: estimate 10.038 ignored, "late tick" (`TB:951`) |
| 22 | 07:50:11.218 | `FSTOP(1.374)` | `FLUSHED`; reset |
| 23 | 07:50:17.940 | `MachineStatistics` | `T{machine_statistics={…,"tot_doses":2123,…}}`, a dict |
| 24-37 | 07:52:56.703 … 07:57:34.881 | steam 133, 130; **coffee 95** (`FX:26`); steam 133, 130, 133, 130, 133, 130, 133, 130, 133, 130, 133 | one `T{…}` each; line 26 is `T{coffee=95.0}` |
| 38 | 07:57:49.729 | `START` | `B(0.0, 07:57:49.729)` |
| 39 | 07:57:49.831 | `TICK(0.108)` | `B(0.108, 07:57:49.723)` |
| 40 | 07:57:50.894 | `TICK(1.178)` | `B(1.178, 07:57:49.716)` |
| 41 | 07:57:51.983 | `TICK(2.251)` | `B(2.251, 07:57:49.716)`: estimate .732 |
| 42 | 07:57:53.054 | `TICK(3.324)` | `B(3.324, 07:57:49.716)`: .730 |
| 43 | 07:57:54.132 | `TICK(4.394)` | `B(4.394, 07:57:49.716)`: .738 |
| 44 | 07:57:55.192 | `TICK(5.479)` | `B(5.479, 07:57:49.713)`: new minimum |
| 45 | 07:57:56.282 | `TICK(6.556)` | `B(6.556, 07:57:49.713)`: .726 |
| 46 | 07:57:57.352 | `TICK(7.631)` | `B(7.631, 07:57:49.713)`: .721 |
| 47 | 07:57:58.433 | `TICK(8.703)` | `B(8.703, 07:57:49.713)`: .730 |
| 48 | 07:57:59.493 | `TICK(9.773)` | `B(9.773, 07:57:49.713)`: .720 |
| 49 | 07:58:00.583 | `TICK(10.846)` | `B(10.846, 07:57:49.713)`: .737 |
| 50 | 07:58:01.659 | `TICK(11.897)` | `B(11.897, 07:57:49.713)`: .762 |
| 51 | 07:58:02.461 | `BSTOP(12.727, Manual, Continuous, ContinuousDose)` | `BREWING_STOPPED`, timer None, **final 12.727**, `stop_reason="Manual"`, `started_dose_index="ContinuousDose"`, bst None, `raw.brewing_stopped_stop_type="Continuous"`; reset (`TB:959-963`) |
| 52-58 | 07:58:08.805 … 07:59:14.925 | steam 130, 133, 130, 127, 124, 127, 130 | `T{steam=…}` each |
| 59 | 07:59:22.007 | `START` | `B(0.0, 07:59:22.007)` |
| 60 | 07:59:22.140 | `TICK(0.118)` | `B(0.118, 07:59:22.007)`: .022 |
| 61 | 07:59:23.219 | `TICK(1.189)` | `B(1.189, 07:59:22.007)`: .030 |
| 62 | 07:59:24.267 | `TICK(2.259)` | `B(2.259, 07:59:22.007)`: .008 |
| 63 | 07:59:25.392 | `TICK(3.343)` | `B(3.343, 07:59:22.007)`: .049 |
| 64 | 07:59:26.428 | `TICK(4.423)` | `B(4.423, 07:59:22.005)`: new minimum |
| 65 | 07:59:27.520 | `TICK(5.485)` | `B(5.485, 07:59:22.005)`: .035 |
| 66 | 07:59:28.592 | `TICK(6.557)` | `B(6.557, 07:59:22.005)`: .035 |
| 67 | 07:59:29.798 | `TICK(7.639)` | `B(7.639, 07:59:22.005)`: .159 |
| 68 | 07:59:30.726 | `TICK(8.716)` | `B(8.716, 07:59:22.005)`: .010 |
| 69 | 07:59:31.412 | `FSTOP(9.314)` | `FLUSHED`; reset. A 9.3 s pull classified as a flush by the machine. |
| 70 | 07:59:38.589 | coffee 92 | `T{coffee=92.0}` |
| 71 | 07:59:42.983 | `{"MachineMode":"StandBy"}` | `T{machine_mode=STANDBY}` |
| 72 | 07:59:42.983 | `{"Sleep":"command"}` | `T{sleep="command"}` |

**Session 2 (replay at `FX:73`)**

| `FX` line | Received | Payload | Expected |
|---|---|---|---|
| 73 | 08:36:59.441 | `{"Sleep":"command"}` (replay) | dropped |
| 74 | 08:37:20.950 | steam 106 | `T{steam=106.0}` |
| 75 | 08:37:25.509 | coffee 75 | `T{coffee=75.0}` |
| 76 | 08:37:32.318 | steam 109 | `T{steam=109.0}` |
| 77 | 08:37:33.088 | coffee 78 | `T{coffee=78.0}` |
| 78 | 08:37:40.800 | `CoffeeBoiler1HeatingCoeff` | dropped |
| 79 | 08:37:40.803 | coffee 81 | `T{coffee=81.0}` |
| 80 | 08:37:45.273 | steam 112 | `T{steam=112.0}` |
| 81 | 08:37:49.062 | coffee 84 | `T{coffee=84.0}` |
| 82 | 08:37:54.637 | `MachineMode` StandBy | `T{machine_mode=STANDBY}` |
| 83 | 08:37:54.638 | `Sleep` command | `T{sleep="command"}` |
| 84 | 08:37:55.104 | coffee 87 | `T{coffee=87.0}` |
| 85 | 08:37:57.458 | steam 115 | `T{steam=115.0}` |

**Aggregate assertions** (the first four are VERIFIED by `TB:931-976`):

- The brewing state run-lengths are `[(BREWING,3),(FLUSHED,1),(BREWING,3),(FLUSHED,1),(BREWING,13),(BREWING_STOPPED,1),(BREWING,10),(FLUSHED,1)]`.
  That is **33 brewing updates**.
- The updates with `timer_value == 0.0` were received at `07:50:02.612`, `07:50:09.360`,
  `07:57:49.729` and `07:59:22.007`.
- The telemetry `machine_mode`s that are not `None` are `[STANDBY, STANDBY]`.
- `reduce(merge, telemetry)` gives coffee `87`, steam `115`, sleep `"command"` and
  `tot_doses == 2123`.
- Counts, DERIVED: 43 telemetry callbacks (31 steam, 7 coffee, 2 mode, 2 sleep, 1
  statistics), 2 replays dropped, 2 heating-coefficient lines ignored. 33 + 43 + 2 + 2
  = 80 data lines.

### 7.2 Synthetic client vectors (VERIFIED from upstream tests)

**Shared setup.** `_tick(t, bf=False)` is defined at `TB:51-59`. `STARTED` is
`b'{"BrewingStartedGroup1DoseIndex":"DoseA"}'` (`TB:48`). Each expected tuple is
`(state, timer_value, final_shot_time)`.

**Sequence** (`TB:749-767`). One subscription, with the replay already dropped:

1. `STARTED` → `(BREWING, 0.0, None)`
2. `_tick(0.1)` → `(BREWING, 0.1, None)`
3. `_tick(1.17)` → `(BREWING, 1.17, None)`
4. `{"BrewingUpdateGroup1Ev":false}` → `(BREWING_STOPPED, None, None)`
5. `{"BrewingStoppedGroup1Time":27.4,"BrewingStoppedGroup1DoseIndex":"DoseA","BrewingStoppedGroup1StopType":"X","BrewingStoppedGroup1StopReason":"Manual"}`
   → `(BREWING_STOPPED, None, 27.4)`
6. `{"FlushStoppedGroup1Time":3.1}` → `(FLUSHED, None, None)`
7. `STARTED` → `(BREWING, 0.0, None)`
8. `_tick(0.1, backflush=True)` → `(BACKFLUSHING, None, None)`
9. `{"BrewingUpdateGroup1Ev":false}` → `(BREWING_STOPPED, None, None)`
10. `_tick(5.2)` → `(BREWING, 5.2, None)`, with no start event

**Malformed input** (`TB:769-781`). Start with `STARTED` → `(BREWING, 0.0, None)`. Each
of these then produces no brewing callback:

- `b"not json"`
- `b'{"BrewingUpdateGroup1Time":"abc"}'`
- `b"[]"`
- `b"\xff\xfe"`
- `b'{"SteamBoilerUpdateTemperature":130}'`, which is telemetry only

These still produce updates:

- `b'{"SomethingNew":1,"BrewingUpdateGroup1Time":3.5}'` → `(BREWING, 3.5, None)`
- `_tick(4.5) + b"\x00"` → `(BREWING, 4.5, None)`

**Replay.** With replay `{"MachineMode":"StandBy"}`, the first notification is dropped,
whether it arrives during or after subscribe. A second identical notification then gives
`telemetry_callback(BluetoothMachineTelemetry(machine_mode=STANDBY))` (`TB:811-845`).

**Telemetry** (`TB:848-884`):

- `{"CoffeeBoiler1UpdateTemperature":95}` → `T(coffee_boiler_temperature=95)`
- the heating coefficient, or `{"MachineMode":"Unknown"}` → nothing
- `{"MachineStatistics":"{\"tot_doses\":2123}"}` → `T(machine_statistics={"tot_doses": 2123})`
- `{"BrewingStartedGroup1DoseIndex":"DoseA","SteamBoilerUpdateTemperature":127}` →
  `T(steam=127)` plus a `BREWING` update

**Start time** (`TB:980-1006`):

1. `STARTED` at `t0` → `bst == t0`.
2. Clock +5.07 s, then `_tick(5)` → `timer=5`, `bst == t0`, and `started_dose_index == "DoseA"`.
3. Clock +1 s, then `_tick(6.1)` → `bst == now − 6.1 s`. This is earlier than `t0`.

**Reconnect** (`TB:1022-1050`):

- After `STARTED`, `drop_connection()` → `connection_callback(False)` and
  `shot_counter_active == False`.
- Reconnect happens with an initial delay patched to 0, ending in
  `connection_callback(True)`.
- `establish_connection` and `start_notify` are each awaited 2×.
- After reconnecting, `{"BrewingUpdateGroup1Backflush":false}` produces no callback. The
  shot was forgotten and the replay dropped again.

**Retries** (`TB:1053-1069`). Connect errors `[BleakError, TimeoutError]` give 4
`establish_connection` calls, and the connection callbacks are `[True, False, True]`.

**Auth give-up** (`TB:1072-1091`). With a token mismatch after the loss:

- 4 connects in total
- `authentication_failed` is True
- not active, not connected
- no background tasks remain

**Stop reentrancy** (`TB:1125-1153`). Calls are `[True, False]` and the stop runs once.
`stop_notify` is awaited once.

**Command error during the shot counter** (`TB:1287-1302`). The link is kept and the
counter stays active.

### 7.3 Device-layer overlay vectors (VERIFIED, `TM:709-1046`)

**Setup.** The widget starts as `machine_status(status, bst=None, mode=BREWING_MODE)`
(`tests/conftest.py:60-72`). Updates are built with
`_brewing_update(state, timer, final)` and `received_at = 2026-01-01T12:00:00Z`
(`TM:709-720`).

| # | Steps | Expected |
|---|---|---|
| D1 | cloud `POWERED_ON`, bst `11:00Z`; update `BREWING(12.5)` | `status=BREWING`, `bst=12:00:00Z−12.5s`; callback got the update |
| D2 | then `BREWING_STOPPED(final 27.4)` | `status=POWERED_ON`, `bst=11:00Z`, `last_shot_time=27.4` |
| D3 | then websocket push of a new widget `BREWING`, bst `11:00Z` | the new widget is in the dashboard; its status is shown as `POWERED_ON` |
| D4 | then push of a new widget `STANDBY`; update `FLUSHED` | `STANDBY`; `last_shot_time` still 27.4 |
| D5 | then `BREWING(1)`, then connection `False` | `BREWING`, then callback `None`, `STANDBY`, `bst None`, `ble_brewing_update None` |
| D6 | no update callback, websocket callback set; `BREWING(3)` | the dashboard callback gets a config with `CMMachineStatus.status == BREWING` (`TM:835-850`) |
| D7 | `BREWING(3)` + telemetry coffee 93; `disconnect_bluetooth_shot_counter()` | no callback; `POWERED_ON`; update None; telemetry empty; expiry cancelled (`TM:853-879`) |
| D8 | `BREWING(3)`, then `BREWING(4)`, then fire the expiry | 2 timers, the first cancelled; after the expiry `POWERED_ON`, update None, callback `None` (`TM:882-907`) |
| D9 | `BREWING(3)`, `STOPPED(27.4)`; BLE refresh with mode `STANDBY`; fire the expiry | `STANDBY` before and after the expiry (`TM:917-937`) |
| D10 | cloud `POWERED_ON` bst `11:00Z`; `BREWING(3)`; BLE refresh with mode `BREWING_MODE` | still `BREWING`; after `STOPPED`, `POWERED_ON` with bst `11:00Z` (`TM:940-958`) |
| D11 | telemetry steam 130 | telemetry callback gets exactly it; mode unchanged |
| D12 | then telemetry `{mode STANDBY, sleep "command"}` | `(STANDBY, STANDBY)`; no brewing callback; merged = `{steam 130, mode STANDBY, sleep "command"}`; connection `False` → empty (`TM:961-992`) |
| D13 | `BREWING(3)`; telemetry `ECO_MODE` | still `BREWING`; after `FLUSHED`, `(ECO_MODE, ECO_MODE)` (`TM:995-1011`) |
| D14 | no telemetry callback; coffee 93 | dashboard callback not called. Then mode `STANDBY` gives one call with `mode == STANDBY` (`TM:1014-1033`) |

### 7.4 Additional vectors derived from the spec (not tested upstream)

1. `FRAG` accumulation:
   1. `{"BrewingUpdateGroup1Ev":true}` → no update.
   2. Then `{"BrewingUpdateGroup1Time":2.0}` → `BREWING(2.0)`, `bst = t_r − 2`.
2. `FSTOP` without a start → `FLUSHED`, `started_dose_index None`.
3. A late tick after a stop:
   1. `BSTOP(10.0, …)` → `BREWING_STOPPED`.
   2. Then `TICK(10.2)` → `BREWING(10.2)`. This is upstream behaviour; a port should keep
      it for parity.
4. A backflush across ticks:
   1. `START`, `TICK_BF(1)`, `TICK_BF(2)` → `BREWING`, `BACKFLUSHING`, `BACKFLUSHING`.
   2. Then `EV_OFF` → `BREWING_STOPPED`.
   3. The device overlay shows the cloud status during `BACKFLUSHING`.
5. Coercion: `{"BrewingUpdateGroup1Ev":"false","BrewingUpdateGroup1Time":1}` after a
   reset → `BREWING(1.0)`, because `bool("false")` is True.
6. Coercion: `{"MachineStatistics":{"a":1}}` → the whole notification is dropped.
7. A START mid-shot resets: `START`, `TICK(3)`, `START` → the third update is
   `BREWING(0.0)` with `S = t_r` of the new start.
8. A device update with no `CMMachineStatus` widget: the state is stored and the
   callbacks fire, but nothing is saved or overlaid. A later dashboard load then applies
   the overlay.
9. Expiry is re-armed by `FLUSHED`: the overlay persists 60 s after a flush or stop, and
   `None` is emitted at +60 s.

---

## 8. Porting notes for Angstrom (non-normative)

**Layering.** The parsing, `derive_state` and `_BrewingTracker` are pure. They belong in
`Angstrom` as `Sendable` value types, testable without CoreBluetooth. Two places fit the
overlay:

- `AngstromUI.LaMarzoccoMachine`
- a pure `Dashboard` transform in the style of `Optimistic.swift`

**Identity versus value semantics.** Upstream relies on Python object identity (`is
widget`) to tell a cloud reload apart from a BLE in-place refresh (§5.5, §5.7).
Angstrom's `MachineStatus` is an immutable struct (`Sources/Angstrom/Widgets.swift:218-224`).
The suggested model is a *cloud baseline* `(status, brewingStartTime)`, which works as
follows:

- It is **replaced** when the REST dashboard loads, and on every websocket push that
  carries widgets.
- It has **only its `status` replaced** on a BLE-origin refresh: a telemetry mode, or
  `get_dashboard_from_bluetooth`.
- The displayed widget is `overlay(baseline, bleUpdate)`.

The vectors in §7.3 are the acceptance tests.

**Enums.** Angstrom's `MachineMode` and `MachineState` have `.other(String)` cases
(`Sources/Angstrom/Enums.swift:151-200`). `_known_machine_mode` must reject `.other`, so
that an unknown mode counts as unset.

**Timers.** Inject the clock and the timers. Upstream tests patch `_utcnow`,
`IDLE_TIMEOUT`, `RECONNECT_INITIAL_DELAY`, `AUTH_READ_INTERVAL` and `loop.call_later`
(`TB:100-154`, `TM:115-131`).

**Callbacks versus streams.** If the port uses `AsyncStream`s, the stream must keep these
distinctions:

- "overlay dropped" (`None`) versus "nothing yet"
- a silent device-initiated stop versus a loss
- the per-notification partial telemetry versus the merged telemetry

**CoreBluetooth mapping** (UNVERIFIED for this machine):

| bleak | CoreBluetooth |
|---|---|
| `start_notify` | `setNotifyValue(true, for:)`, then `peripheral(_:didUpdateValueFor:error:)` |
| `stop_notify` | `setNotifyValue(false, for:)` |
| `clear_cache` / `use_services_cache=False` | no public API; the nearest equivalents are a fresh `discoverServices` after reconnecting, or handling `peripheral(_:didModifyServices:)`. The legacy dump shows a Service Changed characteristic (`docs/legacy/bluetooth_characteristics.md:7`). |

Set the replay flag before calling `setNotifyValue`. The replay may arrive before or
after `didUpdateNotificationStateFor`.

---

## 9. UNVERIFIED items and open questions

1. **MTU and fragmentation on CoreBluetooth.** The 418-byte `MachineStatistics`
   notification (`FX:23`) must arrive whole. Does the firmware ever split or truncate it?
   *Resolve with* a CoreBluetooth capture, for example a BLE mode in `angcli`.
2. **The GATT service UUID** containing `0e0b…`, and its notify vs indicate property, are
   not in upstream. *Resolve with* a discovery dump.
3. **Is the replay guaranteed** on every subscribe? Upstream drops the first notification
   unconditionally.
4. **Coercion parity.** Python truthiness turns `"false"` into `True`. Numeric strings are
   accepted for floats, and numbers are stringified for `str` fields. Should Swift match
   this exactly or be strict? Nothing like this has been observed on the wire.
5. **`MAX_AUTH_FAILURES`.** The code counts cumulatively per reconnect run; the README
   says "in a row". Port the code's behaviour.
6. **Give-up is silent** at both layers. Should Angstrom add a terminal event? That would
   be an intentional divergence.
7. **`BACKFLUSHING`** is not reflected in the overlaid status. Should AngstromUI surface
   it separately?
8. **The late-tick-after-stop re-entry into `BREWING`** (§3.3): keep it for parity, or
   guard against it?
9. **`MachineStatistics` semantics** are "unverified" upstream. Keep the value as untyped
   JSON?
10. **`Sleep` values** other than `"command"`, and `WakeUp`, `…Volume` and the other
    legacy keys over BLE, are unobserved.
11. **The single-central limitation** (`RM:231`) has product impact on Pronto. A
    persistent link may block the official app.
12. **The UX of a 60 s overlay tail.** `None` arrives 60 s after every shot, and a late
    cloud `Brewing` is masked for up to 60 s. Confirm that Pronto wants upstream's
    semantics.
13. **Expiry callback errors.** Exceptions from the user callback on the expiry path
    escape `_safe_call` and go to the event loop. Swift has no direct equivalent, so the
    port must decide on error isolation.
14. **Not executed.** Running upstream Python was not permitted in this session. The
    vectors were traced by hand and cross-checked against the aggregate assertions in
    `TB:931-976`. A downstream implementer should confirm the per-line `bst` values by
    running upstream's `test_shot_counter_recorded_sessions` with extra prints, or by
    running a Swift port against §7.1.
