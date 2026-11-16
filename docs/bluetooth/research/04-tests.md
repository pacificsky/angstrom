# 04 — Upstream Bluetooth test suite: parity matrix, mock seams, test vectors, gaps

Research note for the Angstrom Bluetooth (BLE) parity plan. It is the only test-side reference
downstream authors get besides the upstream source, so it lists every upstream BLE test case,
how upstream fakes the BLE stack, every reusable vector (copied verbatim), the behaviours that
have no upstream test, and the hardware hints in tests and fixtures.

- **Upstream of record:** `pylamarzocco` v2.5.6, commit `4c639ee` ("Merge pull request #173 from
  zweckj/fix-linea-ble-family"). The clone is at
  `$UPSTREAM`.
- **Test toolchain (upstream):** `pytest == 8.3.3`, `pytest-asyncio == 0.24.0` with
  `asyncio_mode = "auto"`, `syrupy == 4.7.2` (snapshots) (`pyproject.toml:34-46`). Locked runtime
  deps: `bleak` 1.1.1 (`uv.lock:140-141`), `bleak-retry-connector` 4.4.4 (`uv.lock:163-164`),
  `mashumaro` 3.17 (`uv.lock:455-456`).
- **Verification status of this note.** Every row, vector and line citation was re-checked
  line by line against the clone at `4c639ee`. Two things were **not** done:
  - **Upstream's suite was not re-run.** An attempt to execute it in an isolated scratch venv
    was denied by the session's permission system. The expected values are therefore those
    written in the test source, not observed outputs.
  - **mashumaro coercion was not executed.** Its behaviour was settled by reading the source of
    the locked `mashumaro` 3.17. The source was installed into a scratch venv (`probe04/venv313`)
    from upstream's `uv.lock` but never executed. The citations below use the form
    `mashumaro/core/meta/types/unpack.py:<line>`.
- **Path abbreviations used below.** All paths are relative to the clone root.

| Abbrev | Path |
|---|---|
| `TBC` | `tests/test_bluetooth_client.py` (1435 lines) |
| `TBD` | `tests/test_bluetooth_dashboard.py` (689 lines) |
| `SNAP` | `tests/__snapshots__/test_bluetooth_dashboard.ambr` (146 lines) |
| `CONF` | `tests/conftest.py` (202 lines) |
| `REC` | `tests/fixtures/machine/shot_counter_2026-10-05.txt` (85 lines) |
| `TM` | `tests/test_machine.py` (1195 lines) |
| `TT` | `tests/test_thing.py` |
| `TMO` | `tests/test_models.py` |
| `TCC` | `tests/test_cloud_client.py` |
| `SBT` | `src/pylamarzocco/clients/_bluetooth.py` (747 lines) |
| `MBT` | `src/pylamarzocco/models/_bluetooth.py` (213 lines) |
| `DM` | `src/pylamarzocco/devices/_machine.py` (1092 lines) |
| `DT` | `src/pylamarzocco/devices/_thing.py` |
| `CONST` | `src/pylamarzocco/const.py` |
| `EXC` | `src/pylamarzocco/exceptions.py` |

**How many tests:** 91 BLE-related test functions, expanding to 123 parametrized cases:

| File | Functions | Cases |
|---|---|---|
| `TBC` | 49 | 55 |
| `TBD` | 17 | 26 |
| `TM` | 20 | 32 |
| `TT` | 2 | 2 |
| `TMO` | 2 | 7 |
| `TCC` | 1 | 1 |
| `tests/test_grinder.py` | 0 | 0 (no grinder BLE exists; a grep of `src/pylamarzocco/devices/_grinder.py` finds no Bluetooth code) |

---

## 0. Constants the tests pin (quick reference, all verbatim)

| Name | Value | Source |
|---|---|---|
| `READ_CHARACTERISTIC` | `"0a0b7847-e12b-09a8-b04b-8e0922a9abab"` | `SBT:40` (tests duplicate it as `READ_CHAR`, `TBC:44`) |
| `WRITE_CHARACTERISTIC` | `"0b0b7847-e12b-09a8-b04b-8e0922a9abab"` | `SBT:41` (`SETTINGS_CHAR`, `TBC:42`) |
| `GET_TOKEN_CHARACTERISTIC` | `"0c0b7847-e12b-09a8-b04b-8e0922a9abab"` | `SBT:42` (not used by any test) |
| `AUTH_CHARACTERISTIC` | `"0d0b7847-e12b-09a8-b04b-8e0922a9abab"` | `SBT:43` (`AUTH_CHAR`, `TBC:43`) |
| `SHOT_COUNTER_CHARACTERISTIC` | `"0e0b7847-e12b-09a8-b04b-8e0922a9abab"` | `SBT:44` (`SHOT_COUNTER_CHAR`, `TBC:45`) |
| `BT_MODEL_PREFIXES` | `("MICRA", "MINI", "LINEA", "GS3")` | `SBT:46` |
| `IDLE_TIMEOUT` | `30  # seconds` | `SBT:47` (tests patch it to `4321.0`, `TBC:112,152`) |
| `AUTH_SUCCESS` | `b"\x01"` | `SBT:49` |
| `AUTH_READ_ATTEMPTS` | `10` | `SBT:50` |
| `AUTH_READ_INTERVAL` | `0.05  # seconds` | `SBT:51` (tests patch it to `0`) |
| `MAX_AUTH_FAILURES` | `3` | `SBT:52` |
| `RECONNECT_INITIAL_DELAY` | `1  # seconds` | `SBT:53` (tests patch it to `0`) |
| `RECONNECT_MAX_DELAY` | `60  # seconds` | `SBT:54` (no test) |
| `establish_connection(..., max_attempts=3, ...)` | `3` | `SBT:252` (no test asserts it) |
| `BLE_BREWING_STATE_TIMEOUT` | `60  # seconds` | `DM:88` (imported by `TM:28`) |
| `STEAM_LEVEL_MAPPING` | `LEVEL_1: 126`, `LEVEL_2: 128`, `LEVEL_3: 131` | `DM:59-63` |
| `STEAM_LEVEL_MODELS` | `(ModelCode.LINEA_MICRA, ModelCode.LINEA_MINI_R)` | `CONST:182` |
| `BluetoothReadSetting` | `machineCapabilities`, `machineMode`, `tankStatus`, `boilers`, `smartStandBy`, `isPlumbedIn` | `CONST:322-330` |
| `BluetoothBrewingState` | `"Brewing"`, `"BrewingStopped"`, `"Flushed"`, `"Backflushing"` | `CONST:333-339` |
| `BoilerType` | `COFFEE = "CoffeeBoiler1"`, `STEAM = "SteamBoiler"` | `CONST:307-311` |
| `SmartStandByType` | `LAST_BREW = "LastBrewing"`, `POWER_ON = "PowerOn"` | `CONST:260-264` |
| `MachineMode` | `"BrewingMode"`, `"EcoMode"`, `"StandBy"` | `CONST:11-16` |
| `BLE_MACHINE_STATE` | `BREWING_MODE: POWERED_ON`, `ECO_MODE: ECO_MODE`, `STANDBY: STANDBY` | `DM:65-69` |
| `BLE_BOILER_STATUS` | `BREWING_MODE: READY`, `ECO_MODE: ECO_MODE`, `STANDBY: STAND_BY` | `DM:71-75` |
| `_utcnow()` | `datetime.now(timezone.utc)`; it stamps `received_at` once per notification. Tests patch it. | `SBT:57-59`, used at `SBT:445` |
| `_parse_bool(value)` | `str(value).lower() == "true"`. Used **only** by `get_tank_status` and `get_plumbed_in`. | `SBT:62-64`, `SBT:573-582` |

Exception hierarchy: `BluetoothConnectionFailed(LaMarzoccoError)` is at `EXC:20`, and
`BluetoothAuthenticationFailed(BluetoothConnectionFailed)` is at `EXC:46`. The auth failure is a
**subclass** of the connection failure. The tests depend on this in two ways:
`pytest.raises(BluetoothConnectionFailed, match="authentication failed")` at `TBC:626`, and the
device-layer fallback, which catches `BluetoothConnectionFailed` at `DM:1025`.

---

## 1. Parity test matrix

Column notes:
- **Inputs → expected** names the vector IDs from §3 wherever a vector exists.
- **Swift test** is a suggested `XCTestCase` class plus method name.
- **Area** is one of: protocol codec / auth / connection lifecycle / commands / reads /
  shot-counter state machine / reconnect / device-layer fallback / dashboard-from-bluetooth /
  overlay / models.
- **Swift target.** Suggested placement: transport-level areas go in the core `Angstrom` target;
  fallback, dashboard-from-bluetooth and overlay go in `AngstromUI`. This is only a suggestion.
  The architecture notes decide where the device layer actually lives.

Unless a row says otherwise, every `TBC` test runs against `FakeBleakClient` (§2.1), with the
idle timer fixture installed via autouse.

### 1.1 `tests/test_bluetooth_client.py` — client, transport and shot counter

| # | Upstream test (line) | Behaviour asserted | Inputs → expected | Swift test | Area |
|---|---|---|---|---|---|
| C01 | `test_ble_set_power` (`TBC:295`) | `set_power(True)` writes the `MachineChangeMode` JSON plus a trailing NUL to the WRITE char, with `response=True`. | **BT-REQ-001**; asserts `write_gatt_char.assert_awaited_with(char_specifier=SETTINGS_CHAR, data=…, response=True)`. The reply is the default `COMMAND_SUCCESS` (**BT-RSP-CMD-001**). | `BluetoothCommandTests.testSetPowerOnWritesMachineChangeMode` | commands / protocol codec |
| C02 | `test_ble_set_temperature` (`TBC:310`) | `set_temp(STEAM, 90)` writes `SettingBoilerTarget` with `identifier` and `value` in that order. | **BT-REQ-003**: the last write equals `(SETTINGS_CHAR, bytes)`. | `BluetoothCommandTests.testSetTemperatureSteamWritesSettingBoilerTarget` | commands / protocol codec |
| C03 | `test_ble_set_smart_standby` (`TBC:324`) | `set_smart_standby(True, POWER_ON, 42)` writes `SettingSmartStandby` with keys in the order `minutes`, `mode`, `enabled`. | **BT-REQ-004** | `BluetoothCommandTests.testSetSmartStandbyWritesMinutesModeEnabled` | commands / protocol codec |
| C04 | `test_ble_get_machine_capability` (`TBC:338`) | A capabilities read writes `machineCapabilities\0` to the READ char, then decodes element `[0]` of the JSON array, mapping family `"MICRA"` to `ModelName.LINEA_MICRA`. | **BT-READ-REQ-001** → **BT-RSP-CAP-001** → **BT-DEC-CAP-001** | `BluetoothReadTests.testGetMachineCapabilitiesDecodesFirstElement` | reads / models |
| C05 | `test_ble_get_boiler_details` (`TBC:361`) | `boilers\0` → a list of `BluetoothBoilerDetails` in wire order (steam first here). | **BT-READ-REQ-002** → **BT-RSP-BOIL-001** → **BT-DEC-BOIL-001** | `BluetoothReadTests.testGetBoilersDecodesList` | reads |
| C06 | `test_ble_get_smart_standby_details` (`TBC:388`) | `smartStandBy\0` → `mode=POWER_ON, minutes=42, enabled=True`. The wire sends `enabled` as the **string** `"true"`. | **BT-READ-REQ-003** → **BT-RSP-SSB-001** | `BluetoothReadTests.testGetSmartStandbyAcceptsStringBool` | reads / models |
| C07 | `test_ble_get_tank_status` (`TBC:406`) | `tankStatus\0` → `True` for the JSON string `"true"`. | **BT-READ-REQ-004**, **BT-RSP-TANK-001** | `BluetoothReadTests.testGetTankStatusStringTrue` | reads |
| C08 | `test_get_machine_mode` (`TBC:420`) | `machineMode\0` → `MachineMode.BREWING_MODE` for `"BrewingMode"`. | **BT-READ-REQ-005**, **BT-RSP-MODE-001** | `BluetoothReadTests.testGetMachineModeBrewing` | reads |
| C09 | `test_persistent_connection_auto_connect` (`TBC:434`) | The client starts disconnected. The first command connects exactly once, and the first write ever is the raw token (no NUL) to the AUTH char. | `writes[0] == (AUTH_CHAR, b"token")` (**BT-AUTH-001**); `establish_connection.assert_awaited_once()` | `BluetoothConnectionTests.testFirstCommandConnectsAndAuthenticates` | connection lifecycle / auth |
| C10 | `test_persistent_connection_reuse` (`TBC:454`) | Three sequential commands reuse one connection, which is still connected afterwards. | `set_power(True)`, `set_power(False)`, `set_steam(True)` → one `establish_connection`; `is_connected` | `BluetoothConnectionTests.testSequentialCommandsReuseConnection` | connection lifecycle |
| C11 | `test_auto_disconnect_after_idle` (`TBC:475`) | When the idle timer expires, the client disconnects (`disconnect` awaited once) and `is_connected` becomes false. | Fire the idle timer (§2.2) | `BluetoothConnectionTests.testIdleTimeoutDisconnects` | connection lifecycle |
| C12 | `test_timer_reset_on_new_command` (`TBC:493`) | Each command restarts the idle timer, with only one timer pending at a time. After the timer fires, the client disconnects. | After 2 commands: `idle_timer.started == 2`, `pending == 1`. **Counting trap:** each request calls `_ensure_connected` twice, once for the write (`SBT:680`) and once for the read (`SBT:663`), so the timer is re-armed twice per command. `started` counts only timers whose coroutine actually reached `sleep`. The first arm is cancelled before it runs, because the fake's `AsyncMock` awaits never yield. A Swift port should assert "exactly one pending idle timer, re-armed per request", not raw arm counts. | `BluetoothConnectionTests.testCommandRestartsIdleTimer` | connection lifecycle |
| C13 | `test_concurrent_commands_thread_safe` (`TBC:516`) | Three concurrent commands share one connection, and all of them write. | `gather(set_power(True), set_steam(True), set_power(False))` → `[AUTH_CHAR, SETTINGS_CHAR, SETTINGS_CHAR, SETTINGS_CHAR]` | `BluetoothConnectionTests.testConcurrentCommandsConnectOnce` | connection lifecycle |
| C14 | `test_exception_triggers_disconnect` (`TBC:544`) | When a command write raises `BleakError` and no shot counter is running, the error propagates unchanged and the link is dropped in the background. | `write_gatt_char.side_effect = BleakError("Connection failed")` → raises `BleakError`; then `not is_connected` | `BluetoothConnectionTests.testCommandErrorDropsIdleConnection` | connection lifecycle |
| C15 | `test_characteristic_resolution_failure_clears_cache` (`TBC:565`) | If the WRITE char cannot be resolved, the client clears the cache, raises `BluetoothConnectionFailed`, and disconnects. | `missing={SETTINGS_CHAR}` → raises; `clear_cache.assert_awaited()`; `not is_connected` | `BluetoothConnectionTests.testMissingCharacteristicClearsCacheAndDisconnects` | connection lifecycle |
| C16 | `test_is_connected_property` (`TBC:584`) | `is_connected` is false initially, true after a command, and false after `disconnect()`. | — | `BluetoothConnectionTests.testIsConnectedLifecycle` | connection lifecycle |
| C17 | `test_reconnect_after_disconnect` (`TBC:600`) | After a manual `disconnect()`, the next command reconnects. | — | `BluetoothConnectionTests.testCommandAfterManualDisconnectReconnects` | connection lifecycle |
| C18 | `test_auth_read_back_failure` (`TBC:617`) | A wrong token means the auth char never reads `0x01`. The client reads it exactly 10 times, raises `BluetoothConnectionFailed` with a message matching `"authentication failed"`, disconnects once and ends disconnected. | `token="other"`; `AUTH_READ_INTERVAL=0` → `read_gatt_char.await_count == 10`; **BT-AUTH-002** | `BluetoothAuthTests.testWrongTokenReadsTenTimesThenFails` | auth |
| C19 | `test_auth_read_back_retries_until_confirmed` (`TBC:636`) | Auth succeeds on the 3rd read that returns `0x01`. Total reads = 3 for auth + 1 for the command status. | `auth_confirm_reads=3` → `read_gatt_char.await_count == 4` | `BluetoothAuthTests.testAuthRetriesUntilConfirmed` | auth |
| C20 | `test_start_shot_counter_characteristic_missing` (`TBC:652`) | The shot-counter char is missing even after rediscovery. The client clears the cache exactly once, disconnects once, reconnects with `use_services_cache=False`, returns `False`, never subscribes, stays connected, and re-arms the idle timer. | `missing={SHOT_COUNTER_CHAR}` → `[True, False]` for `use_services_cache` across connects; `clear_cache` once; `disconnect` once; `is_connected`; `not shot_counter_active`; firing the idle timer then disconnects | `ShotCounterLifecycleTests.testMissingCharacteristicReturnsFalseAfterOneRediscovery` | connection lifecycle |
| C21 | `test_start_shot_counter_rediscovers_services` (`TBC:677`) | The char is missing only from cached services. One rediscovery (cache cleared, reconnect with `use_services_cache=False`) finds it, then the client subscribes once, `shot_counter_active` is true, and `connection_callback(True)` fires once. | `uncached={SHOT_COUNTER_CHAR}` | `ShotCounterLifecycleTests.testStaleServiceCacheRediscoversCharacteristic` | connection lifecycle |
| C22 | `test_start_shot_counter` (`TBC:699`) | Start subscribes to `SHOT_COUNTER_CHAR` and fires `connection_callback(True)`. `disconnect()` calls `stop_notify(SHOT_COUNTER_CHAR)` once and clears the active flag. | returns `True`; `subscribed == SHOT_COUNTER_CHAR`; `stop_notify.assert_awaited_once_with(SHOT_COUNTER_CHAR)` | `ShotCounterLifecycleTests.testStartSubscribesAndDisconnectUnsubscribes` | connection lifecycle |
| C23 | `test_shot_counter_suppresses_auto_disconnect` (`TBC:719`) | While the shot counter runs, no idle timer is ever started, even after a command. `stop_shot_counter()` unsubscribes and resumes the idle disconnect. | `idle_timer.started == 0` after start + `set_power(True)`; after stop and fire: `disconnect` once | `ShotCounterLifecycleTests.testShotCounterSuppressesIdleDisconnect` | connection lifecycle |
| C24 | `test_shot_counter_state_machine[sequence]` (`TBC:749-768`, body `784`) | Each notification yields exactly one `(state, timer_value, final_shot_time)`. A notification with no brewing result calls nothing. | **BT-NTF-SEQ-001** | `ShotCounterStateMachineTests.testSequence` | shot-counter state machine |
| C25 | `test_shot_counter_state_machine[malformed]` (`TBC:769-781`) | Non-JSON, type-mismatched, non-object, undecodable and telemetry-only payloads produce no brewing callback. Unknown keys are ignored. A trailing NUL is stripped. | **BT-NTF-SEQ-002** | `ShotCounterStateMachineTests.testMalformedPayloadsAreDropped` | shot-counter state machine / protocol codec |
| C26 | `test_shot_counter_discards_replay[during_subscribe]` (`TBC:817`, body `822`) | The first notification after subscribing (here delivered synchronously inside `start_notify`) is dropped for both callbacks. The next identical one goes through to telemetry. | **BT-NTF-REPLAY-001**, replay inside `start_notify` | `ShotCounterStateMachineTests.testReplayDuringSubscribeIsDropped` | shot-counter state machine |
| C27 | `test_shot_counter_discards_replay[after_subscribe]` (`TBC:819`) | Same as C26, but the replay arrives after `start_notify` returns ("proxies may deliver it after subscribing", `TBC:818`). | **BT-NTF-REPLAY-001**, replay via `notify()` | `ShotCounterStateMachineTests.testReplayAfterSubscribeIsDropped` | shot-counter state machine |
| C28 | `test_shot_counter_telemetry` (`TBC:848`) | Telemetry reaches the telemetry callback with only the fields present. Unknown keys and an unknown `MachineMode` produce no call. `MachineStatistics` is JSON-in-a-string and gets parsed. A mixed payload fires both callbacks. | **BT-NTF-TEL-001…005** | `ShotCounterTelemetryTests.testTelemetryRoutingAndParsing` | shot-counter state machine / protocol codec |
| C29 | `test_shot_counter_recorded_sessions` (`TBC:912`) | Replaying a real Linea Micra morning (2 subscribe sessions) gives the exact grouped state sequence, the shot start times, start-time stability within 50 ms, the stop details, the telemetry modes, and the merged telemetry. | **BT-REC-001** (fixture + golden table §3.6) | `ShotCounterRecordedSessionTests.testRecordedMorning20261005` | shot-counter state machine |
| C30 | `test_shot_counter_brewing_start_time` (`TBC:980`) | `brewing_start_time` is the time `STARTED` was received. A late tick (estimate later than the current start) does not move it. An earlier estimate does. `started_dose_index` persists across ticks. | **BT-NTF-START-001** with the injected clock | `ShotCounterStateMachineTests.testBrewingStartTimeIsEarliestEstimate` | shot-counter state machine |
| C31 | `test_shot_counter_callback_exception_is_caught` (`TBC:1009`) | A user callback that throws is called once, and the exception does not escape into the BLE notification path. | `callback = MagicMock(side_effect=ValueError("boom"))`; `notify(STARTED)` | `ShotCounterStateMachineTests.testThrowingCallbackIsContained` | shot-counter state machine |
| C32 | `test_shot_counter_reconnects_after_disconnect` (`TBC:1022`) | A link loss reports `connection_callback(False)` and clears the active flag, then reconnects and resubscribes, reporting `True`. Brewing state from before the drop is forgotten, and the replay on resubscribe is dropped again. | `RECONNECT_INITIAL_DELAY=0`; `notify(STARTED)` → `drop_connection()` → `establish_connection.await_count == 2`, `start_notify.await_count == 2`; then `notify({"BrewingUpdateGroup1Backflush":false})` → no callback | `ShotCounterReconnectTests.testReconnectsAndResetsTrackerAfterLinkLoss` | reconnect |
| C33 | `test_shot_counter_reconnect_retries_failed_connections` (`TBC:1053`) | Reconnect keeps retrying through connect errors (`BleakError`, `TimeoutError`). The connection callbacks are exactly `[True, False, True]`, with no duplicate `False` per failed attempt. | `connect_errors=[BleakError("out of range"), TimeoutError()]` → `establish_connection.await_count == 4` | `ShotCounterReconnectTests.testReconnectRetriesThroughConnectErrors` | reconnect |
| C34 | `test_shot_counter_gives_up_after_auth_failures` (`TBC:1072`) | After 3 auth failures during reconnect, the client stops for good: `authentication_failed`, not active, not connected, and no background tasks left. | Token changed to `"other"` after start; `RECONNECT_INITIAL_DELAY=0`, `AUTH_READ_INTERVAL=0` → `establish_connection.await_count == 4` | `ShotCounterReconnectTests.testGivesUpAfterThreeAuthFailures` | reconnect / auth |
| C35 | `test_shot_counter_no_reconnect_after_disconnect` (`TBC:1094`) | A user `disconnect()` is also reported by bleak's disconnected callback, but must not trigger a reconnect. | `establish_connection.assert_awaited_once()`; no background tasks | `ShotCounterReconnectTests.testUserDisconnectDoesNotReconnect` | reconnect |
| C36 | `test_start_shot_counter_twice` (`TBC:1108`) | A second `start_shot_counter` returns `True` without resubscribing and **replaces** the callback: only the second callback fires. | `start_notify.assert_awaited_once()`; `notify(STARTED)` → `first` not called, `second` called once. Untested consequence (G-SC-5): the early `return True` at `SBT:413-414` skips `SBT:428-437`. So the second call's `connection_callback(True)` is **never** called, and the tracker and replay flag are not reset. | `ShotCounterLifecycleTests.testStartTwiceSubscribesOnceAndReplacesCallback` | connection lifecycle |
| C37 | `test_stop_shot_counter_reentrant[stop_shot_counter]` (`TBC:1125-1153`) | If `connection_callback(False)` re-enters `stop_shot_counter()` (eager task), there is no recursion: calls are `[True, False]`, exactly 1 re-entrant stop, and `stop_notify` once. | eager `asyncio.Task(..., eager_start=True)` inside the callback | `ShotCounterLifecycleTests.testStopReentrantFromConnectionCallback` | connection lifecycle |
| C38 | `test_stop_shot_counter_reentrant[disconnect]` (`TBC:1125`) | Same as C37, with `disconnect()` as both the outer and the re-entrant call. | — | `ShotCounterLifecycleTests.testDisconnectReentrantFromConnectionCallback` | connection lifecycle |
| C39 | `test_machine_stop_from_update_callback` (`TBC:1156`) | Device layer: an update callback that calls `machine.disconnect_bluetooth_shot_counter()` (eager) stops exactly once. This was a regression: it recursed in 2.5.1. | `LaMarzoccoMachine("MR012345", bluetooth_client=client)`; `update_callback(None)` → `len(stops) == 1`, `stop_notify` once | `ShotCounterOverlayTests.testStopFromUpdateCallbackDoesNotRecurse` | overlay / connection lifecycle |
| C40 | `test_stop_shot_counter_notifies_connection_callback` (`TBC:1183`) | `disconnect()` on a subscribed shot counter calls its connection callback once with `False`. | — | `ShotCounterLifecycleTests.testDisconnectReportsShotCounterDisconnected` | connection lifecycle |
| C41 | `test_cancelled_connect_does_not_keep_unauthenticated_link` (`TBC:1197`) | Cancelling the caller while the auth read is pending drops the half-open link (`disconnect` once). The client ends disconnected, and the registered connection callback is never called. | `read_gatt_char` never answers; `task.cancel()` → `CancelledError` | `BluetoothAuthTests.testCancellationDuringAuthDropsLink` | auth / connection lifecycle |
| C42 | `test_read_response_is_nul_terminated` (`TBC:1223`) | Read responses are cut at the first NUL. Bytes after it are ignored. | **BT-RSP-MODE-002** | `BluetoothCodecTests.testReadResponseCutAtFirstNul` | protocol codec |
| C43–46 | `test_get_plumbed_in[…]` x4 (`TBC:1234-1250`) | `isPlumbedIn\0` is accepted as a JSON bool or a JSON string. | **BT-RSP-PLUMB-001…004** | `BluetoothReadTests.testGetPlumbedIn` (4 cases) | reads |
| C47 | `test_requests_are_atomic` (`TBC:1253`) | A concurrent read request and command do not interleave. Every write is immediately followed by its read: 6 events, and positions 1, 3, 5 are reads (auth, boilers, set_temp). | `values[READ_CHAR]=b"[]"`; `gather(get_boilers(), set_temp(COFFEE, 93))` → `len(events)==6`, `events[1::2]==["r"]*3` | `BluetoothConnectionTests.testRequestWriteReadPairsAreAtomic` | connection lifecycle |
| C48 | `test_command_error_keeps_shot_counter_connection` (`TBC:1287`) | While the shot counter is active, a failed command re-raises but does **not** drop the link. | `write_gatt_char.side_effect = BleakError("write failed")` → raises; `is_connected`; `shot_counter_active`; `disconnect.assert_not_awaited()` | `ShotCounterLifecycleTests.testCommandErrorKeepsShotCounterLink` | connection lifecycle |
| C49 | `test_authentication_failed_flag` (`TBC:1305`) | A wrong token raises `BluetoothAuthenticationFailed` and sets `authentication_failed`. A later successful auth clears the flag. | token `"other"` then `"token"` | `BluetoothAuthTests.testAuthenticationFailedFlagSetAndCleared` | auth |
| C50 | `test_discover_devices_prefixes` (`TBC:1326`) | Discovery keeps devices whose name starts with a known prefix, in scan order. Note that `LINEAR_4` matches `LINEA`. | **BT-DISC-001** | `BluetoothDiscoveryTests.testNamePrefixFilter` | models / connection lifecycle |
| C51 | `test_ble_device_callback` (`TBC:1345`) | When connecting, the client resolves the device through `ble_device_callback` and passes both the new device (positional arg 1) and the callback to `establish_connection`. | `establish_connection.call_args.args[1] is new_device`; `kwargs["ble_device_callback"] is device_callback` | `BluetoothConnectionTests.testDeviceProviderUsedOnConnect` | connection lifecycle |
| C52 | `test_connection_callback_connect_and_idle_disconnect` (`TBC:1361`) | A registered connection callback sees `True` once for 2 commands, then `False` on idle disconnect. The idle task must not cancel itself while its own `disconnect()` yields. | → `[call(True), call(False)]` | `BluetoothConnectionTests.testConnectionCallbackConnectAndIdle` | connection lifecycle |
| C53 | `test_connection_callback_connection_lost` (`TBC:1382`) | A link loss reports `False` once; a following `disconnect()` adds no duplicate. Reconnect plus disconnect then report `True`, `False`. | → `[True, False, True, False]` | `BluetoothConnectionTests.testConnectionCallbackDeduplicates` | connection lifecycle |
| C54 | `test_connection_callback_not_called_on_failed_authentication` (`TBC:1405`) | A link that never authenticates is never reported as connected. | token `"other"` → `assert_not_called()` | `BluetoothAuthTests.testUnauthenticatedLinkNeverReportedConnected` | auth / connection lifecycle |
| C55 | `test_connection_callback_unregister` (`TBC:1424`) | The unregister closure is idempotent (called twice) and stops further calls. | — | `BluetoothConnectionTests.testUnregisterIsIdempotent` | connection lifecycle |

### 1.2 `tests/test_bluetooth_dashboard.py` — building the dashboard from BLE, and BLE command side effects

These tests use the `mock_bluetooth_client` from `CONF:179-196`. It is a
`MagicMock(spec=LaMarzoccoBluetoothClient)` with canned `BluetoothCommandStatus` values
(**BT-CMDSTATUS-CONF**) and `get_plumbed_in.return_value = False`. The fixture
`mock_machine_with_dashboard` (`TBD:53-107`) is a `LaMarzoccoMachine("MR123456",
bluetooth_client=…)` with no cloud client, `connection_date = 2024-01-01T12:00:00Z`, and four
pre-seeded widgets (**BT-DASH-SEED-001**). The default `model_code` is `LINEAMICRA` (from the
`Thing` defaults, `src/pylamarzocco/models/_general.py:98-106`).

| # | Upstream test (line) | Behaviour asserted | Inputs → expected | Swift test | Area |
|---|---|---|---|---|---|
| D01 | `test_get_dashboard_from_bluetooth` (`TBD:110`) | The BLE dashboard refresh calls mode, boilers and tank once each, and **not** capabilities. It updates the seeded widgets in place, keeps the Micra steam **level** widget, removes the steam **temperature** widget, and adds `CMNoWater`. The snapshot matches. | Mode `BREWING_MODE`; boilers coffee `(True,95,94)`, steam `(False,128,50)`; tank `True`; plumbed `False` (fixture) → **BT-DASH-SNAP-001** | `BluetoothDashboardTests.testRefreshMicraFromBluetooth` | dashboard-from-bluetooth |
| D02 | `test_get_dashboard_no_bluetooth` (`TBD:183`) | Without a BLE client, the refresh raises `BluetoothConnectionFailed`. | `LaMarzoccoMachine(serial)` | `BluetoothDashboardTests.testRefreshWithoutClientThrows` | dashboard-from-bluetooth |
| D03 | `test_get_model_info_from_bluetooth` (`TBD:189`) | Capabilities set `dashboard.model_name` and derive `model_code = ModelCode[family.name]`. | family `ModelName.GS3` (already decoded) → `model_name == GS3`, `model_code == GS3` | `BluetoothDashboardTests.testModelInfoFromCapabilities` | dashboard-from-bluetooth / models |
| D04 | `test_get_dashboard_initializes_missing_widgets` (`TBD:213`) | With an empty config and a Mini R, the refresh creates `MachineStatus`, `CoffeeBoiler` (default max **110**), `SteamBoilerLevel` and `NoWater`, but no steam temperature widget. | Family `LINEA_MINI_R`; coffee `(True,92,91)`, steam `(True,130,125)` → **BT-DASH-SNAP-002** | `BluetoothDashboardTests.testRefreshCreatesMissingWidgetsMiniR` | dashboard-from-bluetooth |
| D05 | `test_get_dashboard_without_steam_level_support` (`TBD:269`) | GS3 (not in `STEAM_LEVEL_MODELS`) gets a steam **temperature** widget and no level widget. | Family `GS3`; steam `(True,128,120)` → `enabled True`, `target_temperature == 128.0` | `BluetoothDashboardTests.testRefreshGS3UsesSteamTemperature` | dashboard-from-bluetooth |
| D06 | `test_get_dashboard_mini_original_temperature_only` (`TBD:334`) | The original Linea Mini also gets the steam temperature widget only. | Family `LINEA_MINI`; steam `(True,127,115)` → `target_temperature == 127.0` | `BluetoothDashboardTests.testRefreshOriginalMiniUsesSteamTemperature` | dashboard-from-bluetooth |
| D07 | `test_set_power_updates_dashboard` (`TBD:396`) | A successful BLE `set_power(True)` returns `True` and sets `mode = BrewingMode`, but **leaves `status` untouched** (`"StandBy"`). | **BT-DASH-SNAP-004** | `BluetoothCommandSideEffectTests.testSetPowerUpdatesModeOnly` | device-layer fallback |
| D08 | `test_set_power_off_updates_dashboard` (`TBD:414`) | `set_power(False)` returns `True` and sets `mode = StandBy`. | Pre-set `mode = BREWING_MODE` | `BluetoothCommandSideEffectTests.testSetPowerOffUpdatesMode` | device-layer fallback |
| D09 | `test_set_steam_updates_dashboard` (`TBD:436`) | `set_steam(False)` returns `True` and sets `SteamBoilerLevel.enabled = False`. | — | `BluetoothCommandSideEffectTests.testSetSteamUpdatesEnabled` | device-layer fallback |
| D10 | `test_set_coffee_temp_updates_dashboard` (`TBD:452`) | `set_coffee_target_temperature(96.5)` sets `target_temperature = 96.5`. The snapshot matches. | **BT-DASH-SNAP-003** | `BluetoothCommandSideEffectTests.testSetCoffeeTempUpdatesWidget` | device-layer fallback |
| D11 | `test_set_steam_level_updates_dashboard` (`TBD:470`) | `set_steam_level(LEVEL_3)` sets `target_level = Level3` (via BLE `set_temp`). | — | `BluetoothCommandSideEffectTests.testSetSteamLevelUpdatesWidget` | device-layer fallback |
| D12 | `test_set_steam_temp_updates_dashboard` (`TBD:488`) | With `model_code=GS3`, `set_steam_target_temperature(122.5)` sets the target. The snapshot matches. | **BT-DASH-SNAP-005** | `BluetoothCommandSideEffectTests.testSetSteamTempUpdatesWidget` | device-layer fallback |
| D13 | `test_failed_command_does_not_update_dashboard` (`TBD:506`) | A BLE status other than `"success"` with no cloud client returns `False` without raising, and the widget is unchanged. | `set_power.return_value = BluetoothCommandStatus(id="ble", message="Failed", status="error")` | `BluetoothCommandSideEffectTests.testNonSuccessStatusLeavesWidget` | device-layer fallback |
| D14 | `test_bluetooth_exception_does_not_update_dashboard` (`TBD:533`) | A BLE `BluetoothConnectionFailed` with no cloud client returns `False`, and the widget is unchanged. | `set_temp.side_effect = BluetoothConnectionFailed("Connection lost")` | `BluetoothCommandSideEffectTests.testBluetoothErrorLeavesWidget` | device-layer fallback |
| D15–19 | `test_get_dashboard_from_bluetooth_statuses[…]` x5 (`TBD:560-636`) | Machine status, coffee status, steam status and the `NoWater` alarm are derived from mode, plumb-in, tank and steam enabled. | **BT-DASH-STATUS-001…005** | `BluetoothDashboardTests.testStatusDerivation` (5) | dashboard-from-bluetooth |
| D20–25 | `test_get_dashboard_from_bluetooth_steam_level[…]` x6 (`TBD:639-671`) | The steam target temperature maps to a level. | **BT-DASH-STEAMLVL-001…006** | `BluetoothDashboardTests.testSteamLevelFromTarget` (6) | dashboard-from-bluetooth |
| D26 | `test_get_dashboard_from_bluetooth_plumb_in_unsupported` (`TBD:674`) | If `get_plumbed_in` raises `ValueError`, the refresh treats the machine as not plumbed in and falls back to the tank: an empty tank sets the alarm. | `get_plumbed_in.side_effect = ValueError("bad")`; tank `False`; boilers `[]` → `allarm is True` | `BluetoothDashboardTests.testPlumbInUnsupportedFallsBackToTank` | dashboard-from-bluetooth |

### 1.3 `tests/test_machine.py` — device layer: fallback, shot-counter overlay, telemetry

The fixtures used here:
- `mock_machine` (`TM:70-81`) has **both** the BLE mock and a `MagicMock(spec=LaMarzoccoCloudClient)`.
- `dashboard_callback` (`TM:84-89`) connects the cloud websocket with an update callback.
- `expiry_timers` (`TM:115-131`) captures `loop.call_later` calls whose delay equals `BLE_BREWING_STATE_TIMEOUT`.
- `_brewing_update` (`TM:709-720`) builds updates with `received_at = 2026-01-01T12:00:00Z`.
- `_connect_shot_counter` (`TM:723-742`) returns the three callbacks the machine passed to `client.start_shot_counter`.
- `machine_status()` (`CONF:60-72`) and `websocket_config()` (`CONF:75-89`) come from conftest.

| # | Upstream test (line) | Behaviour asserted | Inputs → expected | Swift test | Area |
|---|---|---|---|---|---|
| M01–12 | `test_bluetooth_command_with_cloud_fallback[<cmd>-bluetooth / -cloud]` (`TM:192-237`, table `TM:134-189`) | Each of the six commands calls the mapped BLE method once with the mapped kwargs. When BLE succeeds, the cloud is never called. When BLE raises `BluetoothConnectionFailed`, the cloud method is called once with `serial_number=` plus the mapped cloud kwargs, and the result is `True`. | **BT-FALLBACK-001…006** | `BluetoothFallbackTests.testCommandUsesBluetoothThenCloud` (12) | device-layer fallback |
| M13 | `test_failing_command` (`TM:486`) | If BLE raises and the cloud returns `False`, the result is `False`. | `set_power.side_effect = BluetoothConnectionFailed("Bluetooth error")`, `cloud.set_power.return_value = False` | `BluetoothFallbackTests.testBothTransportsFailReturnsFalse` | device-layer fallback |
| M14 | `test_connect_bluetooth_shot_counter` (`TM:745`) | Starting does **not** depend on the cloud `shot_counter_supported` flag (false here). The method returns the client result (`True`, then `False`). Without a BLE client it returns `False`. | — | `ShotCounterOverlayTests.testConnectIgnoresCloudSupportFlag` | overlay |
| M15 | `test_register_bluetooth_connection_callback` (`TM:765`) | The machine forwards the callback to the client and returns the client's unregister. Without a client it is a no-op returning a callable. | — | `ShotCounterOverlayTests.testRegisterConnectionCallbackForwards` | overlay |
| M16 | `test_shot_counter_overrides_machine_status` (`TM:784`) | Full overlay contract, see §3.8 **BT-OVL-001**:<br>• BREWING sets `status=Brewing` and `brewing_start_time = received_at − timer`.<br>• STOPPED restores the cloud status (Brewing → PoweredOn) and the cloud start time, and sets `last_shot_time`.<br>• A late cloud push of "Brewing" is overridden to PoweredOn.<br>• FLUSHED keeps a non-brewing cloud state.<br>• Connection loss calls the callback with `None` and restores the cloud values. | **BT-OVL-001** | `ShotCounterOverlayTests.testOverrideLifecycle` | overlay |
| M17 | `test_shot_counter_falls_back_to_websocket_callback` (`TM:835`) | With no shot-counter callback, a brewing update is delivered to the dashboard websocket update callback as a synthesized `ThingDashboardWebsocketConfig` whose machine status is `Brewing`. | — | `ShotCounterOverlayTests.testUpdateFallsBackToDashboardCallback` | overlay |
| M18 | `test_disconnect_bluetooth_shot_counter` (`TM:853`) | `disconnect_bluetooth_shot_counter()` calls `client.stop_shot_counter` once, does **not** call the update callback (even though stop triggers `connection(False)`), restores the cloud status, clears the update and telemetry, and cancels the expiry timer. | `stop_shot_counter.side_effect = lambda: on_connection(False)` → `expiry_timers` cancelled `[True]` | `ShotCounterOverlayTests.testDisconnectRestoresSilently` | overlay |
| M19 | `test_shot_counter_state_expires` (`TM:882`) | Each update re-arms a 60 s expiry, cancelling the previous one. When it fires, the cloud status is restored and the callback gets `None`. | Timer list after 1 update `[False]`, after 2 `[True, False]`; fire the last | `ShotCounterOverlayTests.testStaleStateExpiresAfter60s` | overlay |
| M20 | `test_bluetooth_refresh_after_shot_replaces_cloud_status` (`TM:917`) | A BLE dashboard refresh during the override (after STOPPED) becomes the new "cloud" baseline: `StandBy` survives expiry. | **BT-DASH-MOCK-001** with mode `STANDBY` | `ShotCounterOverlayTests.testBluetoothRefreshBecomesBaseline` | overlay / dashboard-from-bluetooth |
| M21 | `test_bluetooth_refresh_while_brewing_keeps_cloud_start_time` (`TM:940`) | A BLE refresh mid-shot keeps `status=Brewing`. After STOPPED, the original cloud `brewing_start_time` is restored, not the `None` from BLE. | **BT-DASH-MOCK-001** with mode `BREWING_MODE`; `cloud_start = 2026-01-01T11:00:00Z` | `ShotCounterOverlayTests.testBluetoothRefreshKeepsCloudStartTime` | overlay |
| M22 | `test_bluetooth_telemetry` (`TM:961`) | Telemetry is forwarded and merged into `bluetooth_telemetry`. Temperature-only telemetry does not touch the mode. A `MachineMode` applies `mode` and `status` immediately (StandBy → StandBy) and does not call the brewing callback. Connection loss resets telemetry. | **BT-TEL-MERGE-001** | `ShotCounterOverlayTests.testTelemetryMergeAndModeApply` | overlay |
| M23 | `test_bluetooth_machine_mode_during_shot` (`TM:995`) | `EcoMode` telemetry mid-shot keeps `status=Brewing`. After FLUSHED, `(mode, status) == (EcoMode, EcoMode)`. | — | `ShotCounterOverlayTests.testModeDuringShotAppliedAfterShot` | overlay |
| M24 | `test_bluetooth_machine_mode_falls_back_to_websocket_callback` (`TM:1014`) | Without a telemetry callback: temperature-only telemetry does not call the dashboard callback, and a mode change calls it once with `mode=StandBy`. | — | `ShotCounterOverlayTests.testModeChangeFallsBackToDashboardCallback` | overlay |
| M25 | `test_bluetooth_shot_counter_active` (`TM:1036`) | `machine.bluetooth_shot_counter_active` mirrors `client.shot_counter_active`, and is `False` without a client. | — | `ShotCounterOverlayTests.testShotCounterActiveMirrorsClient` | overlay |
| M26 | `test_get_model_info_from_bluetooth_errors` (`TM:1049`) | Without a client: `BluetoothConnectionFailed`. With a client that raises `BleakError("boom")`: rethrown unchanged. | — | `BluetoothDashboardTests.testModelInfoErrors` | dashboard-from-bluetooth |
| M27 | `test_get_model_info_from_bluetooth_unknown_model` (`TM:1063`) | A family whose `.name` has no `ModelCode` member still sets `model_name`, and keeps the previous `model_code` (logs a warning). | `family.name = "UNKNOWN"` | `BluetoothDashboardTests.testModelInfoUnknownFamilyKeepsModelCode` | dashboard-from-bluetooth / models |
| M28 | `test_get_dashboard_from_bluetooth_error` (`TM:1079`) | A `BleakError` from `get_machine_mode` propagates out of the refresh. | — | `BluetoothDashboardTests.testRefreshErrorPropagates` | dashboard-from-bluetooth |
| M29 | `test_set_power_updates_group_status` (`TM:1089`) | A successful (BLE) `set_power(True)` also sets `MachineGroupStatus.mode = BrewingMode`. The widget comes from the Strada X fixture. | `dashboard_stradax.json` widget, initial mode `StandBy` | `BluetoothCommandSideEffectTests.testSetPowerUpdatesGroupStatus` | device-layer fallback |
| M30–31 | `test_set_smart_standby_auto_standby[…]` x2 (`TM:1133-1152`) | If `schedule.auto_stand_by_supported` is set, smart standby goes to the cloud `set_auto_standby` as `"HH:MM"` or `"Off"` and **never** to BLE. | `(True,90)→"01:30"`, `(False,90)→"Off"` | `BluetoothFallbackTests.testSmartStandbyUsesCloudAutoStandbyWhenSupported` (2) | device-layer fallback |
| M32 | `test_bluetooth_failure_without_cloud` (`TM:1155`) | If BLE raises and there is no cloud client, the result is `False` and nothing is thrown. | — | `BluetoothFallbackTests.testBluetoothFailureWithoutCloudReturnsFalse` | device-layer fallback |

Implicit coverage (not a BLE test, but relevant): every `test_cloud_command` case (`TM:385-433`)
runs with a BLE client attached (`mock_machine`) and asserts only the cloud call. So cloud-only
commands never route through BLE.

### 1.4 `tests/test_thing.py`, `tests/test_models.py`, `tests/test_cloud_client.py`

| # | Upstream test (line) | Behaviour asserted | Inputs → expected | Swift test | Area |
|---|---|---|---|---|---|
| T01 | `test_connection_properties_without_clients` (`TT:36`) | With no clients, `bluetooth_client_available` and `bluetooth_connected` are false, and `register_bluetooth_connection_callback` returns an unregister closure that returns `None`. | — | `BluetoothDeviceStateTests.testPropertiesWithoutClients` | overlay |
| T02 | `test_connection_properties_with_clients` (`TT:48`) | With a BLE client whose `is_connected = True`, both `bluetooth_client_available` and `bluetooth_connected` are true. | — | `BluetoothDeviceStateTests.testPropertiesWithClients` | overlay |
| O01–03 | `test_shot_counter_supported[…]` x3 (`TMO:391-404`) | The cloud `shotCounterSupported` decodes `true→true`, `false→false`, `null→false`, and missing→false. | `{"serialNumber":"MR123456","shotCounterSupported": <v>}` | `BluetoothModelsTests.testShotCounterSupportedDecoding` (Angstrom already decodes `Machine.shotCounterSupported` per v1.6.0; re-verify the `null` case) | models |
| O04–07 | `test_model_name_from_bluetooth_family[…]` x4 (`TMO:407-418`) | BLE capability family strings map to model names. | **BT-FAMILY-001…004** | `BluetoothModelsTests.testFamilyMapping` (4) | models |
| X01 | `test_debug_log_masks_bluetooth_token` (`TCC:322`) | The cloud `bleAuthToken` is decoded on settings and `/things`, but never appears in debug logs. The masking replaces it with `"**REDACTED**"` (`src/pylamarzocco/clients/_cloud.py:90`). | `settings_micra.json` with `"bleAuthToken": "secret-token"` → `settings.ble_auth_token == things[0].ble_auth_token == "secret-token"`; `caplog.text.count("Response:") == 2`; `"secret-token" not in caplog.text` (`TCC:339-341`) | Already ported for `angcli` (v1.6.0). Add `BluetoothTokenTests.testTokenNeverLogged` if a BLE debug surface (e.g. raw-frame tap) is added. | models |

---

## 2. How upstream fakes the BLE stack, and what the Swift seam needs

### 2.1 `FakeBleakClient` (`TBC:157-292`) — a stateful machine behind autospec'd methods

**How the fake is built.** Each bleak method is a `create_autospec(BleakClientWithServiceCache,
instance=True)` attribute whose `side_effect` acts on explicit fake state (`TBC:188-204`). That
gives two things: the tests can assert calls (`assert_awaited_with`, `await_count`), and the
calls are checked against the real signatures. The fake is patched in at
`pylamarzocco.clients._bluetooth.establish_connection` (`TBC:284-292`, autouse).

**Fake state (`TBC:165-186`):**

| Field | Default | Meaning |
|---|---|---|
| `is_connected` | `False` | The link state. |
| `token` | `"token"` | The token the machine accepts. |
| `auth_confirm_reads` | `1` | Reads of the AUTH char needed before it returns `0x01`. |
| `values` | `{SETTINGS_CHAR: COMMAND_SUCCESS}` | Value read from each char. The command status is read from the **WRITE** char. |
| `missing` | `set()` | Chars that never resolve. |
| `uncached` | `set()` | Chars that do not resolve while `use_services_cache=True` (models a stale OS/BlueZ cache). |
| `replay` | `_tick(3.34)` | Bytes delivered **synchronously inside `start_notify`** (models the machine replaying its last notification). |
| `connect_errors` | `[]` | A queue of exceptions raised by successive `establish_connection` calls. |
| `writes` | — | Log of `(char, bytes)`. |
| `subscribed` | — | The char currently subscribed. |

**Behaviour:**
- **`_establish_connection`** (`TBC:218-233`):
  - asserts `client_class is BleakClientWithServiceCache`;
  - pops the next `connect_errors` entry and raises it, if there is one;
  - otherwise sets connected, records `use_services_cache`, resets auth, and stores `disconnected_callback`.
  - Positional args seen by C51: `args[1]` is the `BLEDevice`; `kwargs["ble_device_callback"]`.
- **`_get_characteristic`** (`TBC:239-244`): returns `None` if the char is in `missing`, or if it is in `uncached` while `_from_cache`. Otherwise it returns the UUID string itself as the "characteristic".
- **`clear_cache`**: a plain autospec, **no state change**. The cache is only "cleared" by the next connect with `use_services_cache=False`. Consequence: in `SBT:719-735` the second `get_characteristic` after `clear_cache()` can never succeed in tests.
- **`_write_gatt_char`** (`TBC:246-251`): raises `BleakError("Not connected")` when disconnected. A write to `AUTH_CHAR` sets `authenticated = (data == token.encode())` and resets the auth read counter.
- **`_read_gatt_char`** (`TBC:253-261`): returns `values[char]`. For `AUTH_CHAR` it returns `b"\x01"` only once `authenticated and reads >= auth_confirm_reads`, and `b"\x00"` otherwise.
- **`_start_notify`** (`TBC:263-273`): stores the handler and immediately invokes it with `replay`, if set.
- **`_stop_notify`**: clears the subscription.
- **`notify(payload)`** (`TBC:206-209`): calls the handler synchronously with `bytearray(payload)`.
- **`drop_connection()`** (`TBC:211-216`): sets disconnected, clears the subscription, and calls `disconnected_callback(self)` synchronously. It models an out-of-range link loss.
- **`_disconnect`** (`TBC:278-281`): `await asyncio.sleep(0)` and then `drop_connection()`. It mirrors bleak, which yields and then **also reports a user-initiated disconnect to the disconnected callback**. Upstream copes by detaching `self._client` before disconnecting (`SBT:303-304`) and ignoring callbacks from stale clients (`SBT:469-470`).

**Higher-level fakes:**
- **`mock_bluetooth_client`** (`CONF:179-196`): `MagicMock(spec=LaMarzoccoBluetoothClient)` with canned statuses. It is used by every device-layer test. Its async methods return the `return_value` because `MagicMock(spec=…)` produces `AsyncMock` children for coroutine functions.
- **`mock_cloud_client`** (`CONF:173-176`): `MagicMock(spec=LaMarzoccoCloudClient)`. The websocket push is simulated by calling the captured `notification_callback` (`TM:92-96`).
- **`ble_device`** (`TBC:76-83`): `BLEDevice(address="test-address", name="Test Device", details=None)`.

**Swift seam needed (derived from the above).** The protocol or actor boundary should let a
test-only `FakePeripheralLink` reproduce **every** knob in the state table above. Concretely:

1. **Connector:**
   `connect(device, useServiceCache: Bool, onDisconnect: @Sendable (LinkID) -> Void) async throws -> Link`.
   Tests must be able to count calls, inspect `useServiceCache`, inspect the device passed, and
   queue errors.
2. **Link:**
   - `isConnected`
   - `resolveCharacteristic(uuid) -> Handle?`
   - `clearCache() async`
   - `write(handle, Data, withResponse: Bool) async throws`
   - `read(handle) async throws -> Data`
   - `startNotify(handle, handler) async throws`
   - `stopNotify(handle) async`
   - `disconnect() async`
3. **Synchronous delivery inside `startNotify`** must be possible: C26 needs the replay delivered
   before `startNotify` returns. On CoreBluetooth the delegate fires
   `didUpdateValueFor` on its queue after `setNotifyValue`. The Swift client therefore must not
   assume ordering between "subscribed" and "first value". The replay-drop flag must be armed
   **before** enabling notifications (upstream arms it at `SBT:431` before `start_notify` at
   `SBT:432`).
4. **The disconnect callback also fires for user-initiated disconnects**, after a yield. The
   fake must reproduce this so C35 and C53 are meaningful. CoreBluetooth behaves the same way:
   `didDisconnectPeripheral` fires after `cancelPeripheralConnection`.
5. **Identity check on disconnect callbacks.** The callback carries the link identity, so the
   client can ignore stale links (`SBT:469`).
6. **The write log must record the exact bytes** (C01–C03 and C47 compare byte strings).
7. **Hooks to make the read/write async and observable** (C47 wraps both with `sleep(0)` and an
   event log), and **a never-answering read** (C41).
8. **Device-layer seam (the Swift counterpart of `MagicMock(spec=LaMarzoccoBluetoothClient)`).**
   Every `TBD`/`TM`/`TT` test drives the device layer against a spec'd mock of the *whole* BLE
   client, never against a fake link. The device layer therefore needs a protocol for the BLE
   client, and a stub implementing it must support:
   - per-method canned return values (`BluetoothCommandStatus`, models);
   - per-method thrown errors (`BluetoothConnectionFailed`, `BleakError` equivalent, and `ValueError` for `get_plumbed_in`);
   - call recording with arguments, so tests can assert the mapped kwargs (M01–M12);
   - capture of the three callbacks passed to `start_shot_counter`, so tests can invoke them directly (`_connect_shot_counter`, `TM:723-742`);
   - an `isConnected` / `shotCounterActive` value the test can set (T02, M25);
   - a `stop_shot_counter` side-effect hook. M18 makes the stub call the captured `on_connection(False)` synchronously from inside `stop_shot_counter`.
9. **Existing Angstrom seams to reuse.** For the cloud side of the fallback and overlay tests, use:
   - `setClockForTesting(_:)` (`Sources/Angstrom/LaMarzoccoCloudClient.swift:298`);
   - `setWebSocketTimingForTesting(...)` (`:459`);
   - `setWebSocketFactoryForTesting(_:)` (`:542`);
   - the AngstromUI mocks `Tests/AngstromUITests/MockTransport.swift` and `Tests/AngstromUITests/MockWebSocket.swift`.

   Upstream simulates the cloud websocket push by calling the captured `notification_callback`
   (`TM:92-96`). The Swift equivalent is a `DashboardUpdate` pushed through `MockWebSocket`.

### 2.2 Timing: every place the tests control time, and the Swift equivalent

| Upstream mechanism | Where | What it controls | Swift equivalent needed |
|---|---|---|---|
| `IdleTimer` (`TBC:108-138`) | autouse fixture `TBC:141-154`, which replaces the **client module's** `asyncio` with a clone whose `sleep` is wrapped, and patches `IDLE_TIMEOUT` to `4321.0` | Idle disconnect (`SBT:282-291`, `asyncio.sleep(IDLE_TIMEOUT)`). Each sleep of exactly 4321.0 s becomes a future that only `fire()` resolves. `started` counts timers created and `pending` counts unfinished ones. Every other sleep is real. | An injectable `Sleeper` / `Clock` that tests can drive per **purpose** (idle, auth-read interval, reconnect backoff), not per delay value. Needs: number of idle timers started, number pending, a manual "fire". Cancelling a pending idle sleep must count it as done (C12 asserts `pending == 1` after a restart). |
| `patch(..."AUTH_READ_INTERVAL", 0)` | C18, C19, C34, C49, C54 | The 0.05 s gap between auth reads (`SBT:643-644`) | Inject the interval, or use an immediate clock. |
| `patch(..."RECONNECT_INITIAL_DELAY", 0)` | C32, C33, C34, C35 | Backoff start (`SBT:490`). Note that `0 * 2 = 0`, so the doubling and the cap are never exercised. | Injectable delay plus a clock that records requested delays, so backoff `1, 2, 4, …, 60` can be asserted (gap G-RC-1). |
| `FakeClock` patching `_utcnow` (`TBC:86-105`) | C29, C30 | `received_at` stamped per notification (`SBT:445`). Starts at `datetime(2026, 10, 5, 7, 0, tzinfo=timezone.utc)` and advances with `tick(seconds)`. | An injectable `now: @Sendable () -> Date` (Angstrom already has `setClockForTesting(_:)` on the cloud client, `Sources/Angstrom/LaMarzoccoCloudClient.swift:298`). |
| `expiry_timers` capturing `loop.call_later(60, …)` (`TM:99-131`) | M18, M19, M20 | `BLE_BREWING_STATE_TIMEOUT` expiry in the device layer (`DM:216-220`). `FakeTimer.cancelled` and `.fire()`. | Device-layer timer injection: a factory returning a cancellable handle, so tests can assert "previous cancelled, new armed" and fire manually. |
| `_wait_for(cond)`: up to 100 × `asyncio.sleep(0)` (`TBC:62-68`) | throughout | Lets fire-and-forget tasks (`asyncio.create_task(self._drop_connection())`, `SBT:133,744`; reconnect task `SBT:486`) run. | Swift: `await Task.yield()` loops are fragile across executors. Prefer deterministic hooks: an `AsyncStream` of internal events, or `XCTestExpectation`s fulfilled by the fake link (e.g. `onDisconnect`). |
| `_no_background_tasks()` = `asyncio.all_tasks() == {current_task()}` (`TBC:71-73`) | C23, C34, C35, C48, C49, C54 | Asserts nothing is still scheduled (no idle timer, no reconnect loop). | A test-only introspection, e.g. `pendingBackgroundWork` (idle task, reconnect task, drop task) that tests can await to drain, or assert is empty. |
| `asyncio.Task(..., eager_start=True)` (`TBC:1139-1143, 1167-1171`) | C37, C38, C39 | Re-entrancy: the callback starts `stop`/`disconnect` running **synchronously** up to its first await, inside the caller's callback. | The Swift equivalent of eager start is `Task.immediate` (SE-0472, Swift 6.2). Its OS availability for macOS 14 / iOS 17 is **UNVERIFIED**; check the SDK's `@available` before relying on it. Without it, `Task {}` from inside the callback reproduces the "stop requested during stop" race but not synchronous entry. Either way, the client must follow upstream's "mutate state first, call the callback last" rule (`SBT:373-394`, docstring at `SBT:376-377`). |
| The fake `_disconnect` yields via `asyncio.sleep(0)` (`TBC:280`) | C52 | Exposes the idle task cancelling itself mid-disconnect. Upstream guards with `self._disconnect_task is not asyncio.current_task()` (`SBT:296-300`). | Swift: the idle `Task` must not `cancel()` itself from inside its own disconnect path. Compare task identity, or clear the stored handle before awaiting the disconnect. |

There is no `freezer`/`freezegun` use anywhere in the BLE tests. A grep for `freezer|freeze_time` in `tests/` returns nothing.

---

## 3. Verbatim test vectors

Every byte string below is copied exactly from upstream. `\x00` means a single NUL byte. Each
`DERIVED` vector is computed from source with no upstream test pinning its bytes, and says so.

### 3.1 UUIDs, auth, discovery

- **BT-UUID-001…005:** see §0. The test file comments that it duplicates these "on purpose, to
  pin the machine's protocol" (`TBC:41`).
- **BT-AUTH-001** (`TBC:448`): the auth write is the raw UTF-8 token, **no NUL terminator**, to
  `AUTH_CHAR`: `(AUTH_CHAR, b"token")`. Source: `SBT:636-640`, which writes
  `bytes(self._ble_token, "utf-8")` with `response=True`.
- **BT-AUTH-002** (`TBC:253-261`, `SBT:642-653`): auth confirmation. The client reads `AUTH_CHAR`.
  Success is exactly `b"\x01"`. Anything else (the fake returns `b"\x00"`) means retry. There are
  10 reads in total, with a 0.05 s sleep before every read except the first. After 10 failures it
  raises `BluetoothAuthenticationFailed("Bluetooth authentication failed")`. A
  `BleakError`/`TimeoutError` during auth is wrapped as
  `BluetoothConnectionFailed(f"Failed to connect to machine with Bluetooth: {e}")`
  (`SBT:649-652`).
- **BT-DISC-001** (`TBC:1326-1342`): scanned names
  `("MICRA_1", "MINI_2", "LINEA_3", "LINEAR_4", "GS3_5", "OTHER")` are filtered to
  `["MICRA_1", "MINI_2", "LINEA_3", "LINEAR_4", "GS3_5"]`. These names are synthetic; the real
  advertised-name format is UNVERIFIED (§5).

### 3.2 Requests written to the machine

Framing: request = UTF-8 payload + `b"\x00"`, sent with `response=True` (`SBT:686-700`). Command
JSON uses `json.dumps({"name": name, "parameter": parameter}, separators=(",", ":"))`
(`SBT:706-708`). Keys keep **Python dict insertion order**, which is the order written in the
source. The Swift encoder must reproduce that order and the compact separators byte-for-byte:
`JSONEncoder` does not guarantee key order, and `.sortedKeys` would give the wrong order for
BT-REQ-004.

| ID | Call | Char | Exact bytes | Pinned by |
|---|---|---|---|---|
| BT-REQ-001 | `set_power(True)` | WRITE `0b0b…` | `b'{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}\x00'` | `TBC:302-306` (also asserts `response=True`) |
| BT-REQ-002 | `set_power(False)` | WRITE | `b'{"name":"MachineChangeMode","parameter":{"mode":"StandBy"}}\x00'` | DERIVED from `SBT:596-600` |
| BT-REQ-003 | `set_temp(BoilerType.STEAM, 90)` | WRITE | `b'{"name":"SettingBoilerTarget","parameter":{"identifier":"SteamBoiler","value":90}}\x00'` | `TBC:317-320` |
| BT-REQ-004 | `set_smart_standby(True, SmartStandByType.POWER_ON, 42)` | WRITE | `b'{"name":"SettingSmartStandby","parameter":{"minutes":42,"mode":"PowerOn","enabled":true}}\x00'` | `TBC:331-334` |
| BT-REQ-005 | `set_steam(True)` | WRITE | `b'{"name":"SettingBoilerEnable","parameter":{"identifier":"SteamBoiler","state":true}}\x00'` | DERIVED from `SBT:602-608` |
| BT-REQ-006 | `set_temp(BoilerType.COFFEE, 96.5)` | WRITE | `b'{"name":"SettingBoilerTarget","parameter":{"identifier":"CoffeeBoiler1","value":96.5}}\x00'` | DERIVED. Python `json.dumps(93.0)` emits `93.0` but `json.dumps(93)` emits `93`. Which form the machine requires is **UNVERIFIED**; see open questions. |
| BT-READ-REQ-001 | `get_machine_capabilities()` | READ `0a0b…` | `b"machineCapabilities\x00"` | `TBC:347` |
| BT-READ-REQ-002 | `get_boilers()` | READ | `b"boilers\x00"` | `TBC:370` |
| BT-READ-REQ-003 | `get_smart_standby_settings()` | READ | `b"smartStandBy\x00"` | `TBC:399` |
| BT-READ-REQ-004 | `get_tank_status()` | READ | `b"tankStatus\x00"` | `TBC:415` |
| BT-READ-REQ-005 | `get_machine_mode()` | READ | `b"machineMode\x00"` | `TBC:429` |
| BT-READ-REQ-006 | `get_plumbed_in()` | READ | `b"isPlumbedIn\x00"` | `TBC:1249` |

**Request/response pairing.** A read request writes the setting name to the READ char and then
reads the READ char (`SBT:655-657`). A command writes to the WRITE char and then reads the
**WRITE** char for the status (`SBT:706-710`). The read response is cut at the first NUL and
UTF-8 decoded (`SBT:669-671`).

### 3.3 Responses read from the machine, and the decoded expectations

| ID | Char | Exact bytes | Decoded expectation | Pinned by |
|---|---|---|---|---|
| BT-RSP-CMD-001 | WRITE | `b'{"id":"test-id","message":"Success","status":"success"}'` | `BluetoothCommandStatus(id="test-id", message="Success", status="success")` (device layer: success iff `status.lower() == "success"`, `DM:1023`) | `TBC:47,171` |
| BT-RSP-CAP-001 | READ | `b'[{"family":"MICRA","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":false,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":["BrewingMode","StandBy"],"schedulingType":"smartWakeUpSleep"}]'` | **BT-DEC-CAP-001**: `family=ModelName.LINEA_MICRA, groups_number=1, coffee_boilers_number=1, has_cup_warmer=False, steam_boilers_number=1, tea_doses_number=0, machine_modes=[BREWING_MODE, STANDBY], scheduling_type="smartWakeUpSleep"` | `TBC:342-357` |
| BT-RSP-BOIL-001 | READ | `b'[{"id":"SteamBoiler","isEnabled":true,"target":131,"current":45},{"id":"CoffeeBoiler1","isEnabled":true,"target":94,"current":65}]'` | **BT-DEC-BOIL-001**: `[(STEAM, True, 131, 45), (COFFEE, True, 94, 65)]` as `(id, is_enabled, target, current)` | `TBC:365-384` |
| BT-RSP-SSB-001 | READ | `b'{"mode":"PowerOn","minutes":42,"enabled":"true"}'` | `mode=POWER_ON, minutes=42, enabled=True` (note the string `"true"`) | `TBC:392-402` |
| BT-RSP-TANK-001 | READ | `b'"true"'` | `True` (via `_parse_bool`, `SBT:62-64`: `str(value).lower() == "true"`) | `TBC:410-416` |
| BT-RSP-MODE-001 | READ | `b'"BrewingMode"'` | `MachineMode.BREWING_MODE` | `TBC:424-430` |
| BT-RSP-MODE-002 | READ | `b'"BrewingMode"\x00\x00garbage'` | `MachineMode.BREWING_MODE` (cut at the first NUL) | `TBC:1227-1230` |
| BT-RSP-PLUMB-001 | READ | `b"true"` | `True` | `TBC:1236` |
| BT-RSP-PLUMB-002 | READ | `b"false"` | `False` | `TBC:1236` |
| BT-RSP-PLUMB-003 | READ | `b'"true"'` | `True` | `TBC:1236` |
| BT-RSP-PLUMB-004 | READ | `b'"false"'` | `False` | `TBC:1236` |
| BT-RSP-EMPTY-001 | READ | `b"[]"` | `get_boilers()` → `[]` | `TBC:1274` |

**Field aliases** (`MBT:22-65`):
- `BluetoothMachineCapabilities`: `family` (deserialized via `ModelName.from_string`),
  `groupsNumber`, `coffeeBoilersNumber`, `hasCupWarmer`, `steamBoilersNumber`, `teaDosesNumber`,
  `machineModes`, `schedulingType`.
- `BluetoothBoilerDetails`: `id`, `isEnabled`, `target: int`, `current: int`.
- `BluetoothSmartStandbyDetails`: `mode`, `minutes: int`, `enabled: bool`.
- `BluetoothCommandStatus`: `id`, `message`, `status`, all `str`.

**Conftest command statuses** (**BT-CMDSTATUS-CONF**, `CONF:183-195`). Each has `id="ble"` and
`status="success"`:

| Command | `message` |
|---|---|
| `set_power` | `"power on"` |
| `set_steam` | `"boiler enable success"` |
| `set_temp` | `"Setting Temperature Success"` |
| `set_smart_standby` | `"Success"` |

The failure example is `BluetoothCommandStatus(id="ble", message="Failed", status="error")`
(`TBD:517-519`). Whether these messages are real machine strings is UNVERIFIED.

### 3.4 Shot-counter notification payloads

**Shared literals:**
- `STARTED = b'{"BrewingStartedGroup1DoseIndex":"DoseA"}'` (`TBC:48`).
- `_tick(t, backflush=False)` (`TBC:51-59`) is built with `json.dumps` and **default separators,
  which include spaces**. For example, `_tick(3.34)` is exactly
  `b'{"BrewingUpdateGroup1Time": 3.34, "BrewingUpdateGroup1Ev": true, "BrewingUpdateGroup1Backflush": false}'`.
  Other ticks swap the number (`0.1`, `1.17`, `5.2`, `4.5`, `5`, `6.1`). `_tick(0.1, backflush=True)`
  ends in `"BrewingUpdateGroup1Backflush": true}`.
- Swift fixtures should keep these spaced forms, so the decoder is tested against both compact
  (recorded) and spaced JSON.

**Notification decode pipeline** (`SBT:441-465`):
1. Drop the first notification after each subscribe (replay).
2. `json.loads(bytes(data).strip(b"\x00"))`. This strips leading and trailing NULs only.
3. Decode the brewing part and the telemetry part. If either decode raises, drop the whole
   notification.
4. If the brewing part is non-empty, run the tracker and call the shot callback with the
   result, if any.
5. If the telemetry part is non-empty, call the telemetry callback.

**Brewing keys** (`MBT:90-123`):

| JSON key | Field |
|---|---|
| `BrewingStartedGroup1DoseIndex` | `started_dose_index: str` |
| `BrewingUpdateGroup1Ev` | `ev: bool` |
| `BrewingUpdateGroup1Backflush` | `backflush: bool` |
| `BrewingUpdateGroup1Time` | `brewing_time: float` |
| `FlushStoppedGroup1Time` | `flush_stopped_time: float` |
| `FlushStoppedGroup1DoseIndex` | `flush_stopped_dose_index: str` |
| `BrewingStoppedGroup1Time` | `brewing_stopped_time: float` |
| `BrewingStoppedGroup1DoseIndex` | `brewing_stopped_dose_index: str` |
| `BrewingStoppedGroup1StopType` | `brewing_stopped_stop_type: str` |
| `BrewingStoppedGroup1StopReason` | `brewing_stopped_stop_reason: str` |

**Telemetry keys** (`MBT:191-213`):

| JSON key | Field |
|---|---|
| `CoffeeBoiler1UpdateTemperature` | `coffee_boiler_temperature: float` |
| `SteamBoilerUpdateTemperature` | `steam_boiler_temperature: float` |
| `MachineMode` | `machine_mode` (unknown value → `None`, `MBT:68-70`) |
| `Sleep` | `sleep: str` |
| `MachineStatistics` | `machine_statistics: dict` (`json.loads` of a **string** value) |

**Derivation precedence** (`MBT:125-163`), applied to the **merged** data:
1. Any `brewing_stopped_*` set, or `ev is False` → `BrewingStopped`.
2. Else any `flush_stopped_*` set → `Flushed`.
3. Else `backflush is True` → `Backflushing`.
4. Else `started_dose_index` set, or (`ev is True` and `brewing_time` set) → `Brewing`.
5. Else no update.

**Update fields:**
- `timer_value = brewing_time or 0.0` only for `Brewing`, else `None`.
- `final_shot_time = brewing_stopped_time`.
- `brewing_start_time = received_at − timer_value` for `Brewing` (`MBT:180-188`).

**Tracker rules** (`SBT:77-111`):
- `started_dose_index` present → reset, then merge.
- After deriving `Flushed` or `BrewingStopped` → reset.
- Otherwise `brewing_start_time` becomes the min of the previous start and this estimate.

#### BT-NTF-SEQ-001 (`TBC:749-768`): one tuple per step, `(state, timer_value, final_shot_time)`

| Step | Payload (exact) | Expected |
|---|---|---|
| 1 | `b'{"BrewingStartedGroup1DoseIndex":"DoseA"}'` | `(Brewing, 0.0, None)` |
| 2 | `_tick(0.1)` | `(Brewing, 0.1, None)` |
| 3 | `_tick(1.17)` | `(Brewing, 1.17, None)` |
| 4 | `b'{"BrewingUpdateGroup1Ev":false}'` | `(BrewingStopped, None, None)` |
| 5 | `b'{"BrewingStoppedGroup1Time":27.4,"BrewingStoppedGroup1DoseIndex":"DoseA","BrewingStoppedGroup1StopType":"X","BrewingStoppedGroup1StopReason":"Manual"}'` | `(BrewingStopped, None, 27.4)` |
| 6 | `b'{"FlushStoppedGroup1Time":3.1}'` | `(Flushed, None, None)` |
| 7 | `STARTED` | `(Brewing, 0.0, None)` |
| 8 | `_tick(0.1, backflush=True)` | `(Backflushing, None, None)` |
| 9 | `b'{"BrewingUpdateGroup1Ev":false}'` | `(BrewingStopped, None, None)` |
| 10 | `_tick(5.2)` ("without a start event, e.g. when subscribing during a shot") | `(Brewing, 5.2, None)` |

#### BT-NTF-SEQ-002 (`TBC:769-781`): `None` means the shot callback is not called

| Step | Payload (exact) | Expected |
|---|---|---|
| 1 | `STARTED` | `(Brewing, 0.0, None)` |
| 2 | `b"not json"` | `None` |
| 3 | `b'{"BrewingUpdateGroup1Time":"abc"}'` | `None`. mashumaro 3.17 decodes a `float \| None` field as `None if v is None else float(v)` (`mashumaro/core/meta/types/unpack.py:773-784` for the Optional path, `:889-893` for numbers). `float("abc")` raises `ValueError` inside the `try` at `SBT:451-457`, so the whole notification is dropped. (Verified by reading the source, not by running it; see G-CODEC-3.) |
| 4 | `b"[]"` | `None`. `from_dict` on a non-dict fails `d.get` and re-raises `ValueError('Argument for … should be a dict instance')` (`mashumaro/core/meta/code/builder.py:507-512`), so the notification is dropped. |
| 5 | `b"\xff\xfe"` | `None` (not valid UTF-8 JSON; Python decodes it as a UTF-16 BOM to `""` and then fails) |
| 6 | `b'{"SteamBoilerUpdateTemperature":130}'` | `None` (telemetry only) |
| 7 | `b'{"SomethingNew":1,"BrewingUpdateGroup1Time":3.5}'` | `(Brewing, 3.5, None)`. Unknown key ignored; `Brewing` because `started_dose_index` from step 1 is still merged. |
| 8 | `_tick(4.5) + b"\x00"` | `(Brewing, 4.5, None)` (trailing NUL stripped) |

#### BT-NTF-REPLAY-001 (`TBC:811-845`)

- `REPLAY = b'{"MachineMode":"StandBy"}'`.
- First delivery after subscribe → no shot callback and no telemetry callback.
- Second delivery → `telemetry_callback(BluetoothMachineTelemetry(machine_mode=MachineMode.STANDBY))` exactly once.
- The default fake replay for all other tests is `_tick(3.34)` (`TBC:176`).

#### BT-NTF-TEL-001…005 (`TBC:848-884`)

| ID | Payload (exact) | Expected telemetry callback |
|---|---|---|
| 001 | `b'{"CoffeeBoiler1UpdateTemperature":95}'` | `BluetoothMachineTelemetry(coffee_boiler_temperature=95)` |
| 002 | `b'{"SteamBoilerHeatingCoeff":"[{\\"temperature\\":18}]"}'` (Python literal; the bytes on the wire are `{"SteamBoilerHeatingCoeff":"[{\"temperature\":18}]"}`) | not called |
| 003 | `b'{"MachineMode":"Unknown"}'` | not called |
| 004 | `b'{"MachineStatistics":"{\\"tot_doses\\":2123}"}'` (wire: `{"MachineStatistics":"{\"tot_doses\":2123}"}`) | `BluetoothMachineTelemetry(machine_statistics={"tot_doses": 2123})` |
| 005 | `b'{"BrewingStartedGroup1DoseIndex":"DoseA","SteamBoilerUpdateTemperature":127}'` | `BluetoothMachineTelemetry(steam_boiler_temperature=127)` **and** the shot callback once with `state == Brewing` |

#### BT-NTF-START-001 (`TBC:980-1006`)

The clock starts at `2026-10-05T07:00:00Z`.

| Step | Action | Expected |
|---|---|---|
| 1 | `notify(STARTED)` at t0 | `brewing_start_time == t0` |
| 2 | `clock.tick(5.07)`, then `notify(_tick(5))` | `timer_value == 5`; `brewing_start_time == t0` (the estimate t0+0.07 is later, so it is ignored); `started_dose_index == "DoseA"` |
| 3 | `clock.tick(1)`, then `notify(_tick(6.1))` | `brewing_start_time == now − 6.1 s` = t0 + 6.07 − 6.1 = **t0 − 0.03 s** |

#### BT-NTF-RESET-001 (`TBC:1033-1048`)

`STARTED`, then link loss, reconnect and (dropped) replay, then
`b'{"BrewingUpdateGroup1Backflush":false}'`. Expected: no shot callback, because the tracker was
reset. Without the reset, the merged `started_dose_index` would yield `Brewing`.

### 3.5 Model-family and discovery vectors

**BT-FAMILY-001…004** (`TMO:407-418`): `ModelName.from_string(family)`.
`from_string` uppercases and removes whitespace before the lookup (`CONST:216`), and raises
`ValueError(f"Invalid model name: {name}")` for unknown keys (`CONST:217`).

| ID | Family | Model name |
|---|---|---|
| 001 | `"LINEA"` | `ModelName.LINEA_MINI` |
| 002 | `"LINEAMINI2023"` | `ModelName.LINEA_MINI_R` |
| 003 | `"MICRA"` | `ModelName.LINEA_MICRA` |
| 004 | `"GS3"` | `ModelName.GS3_AV` |

Full mapping table: `CONST:201-215`.

Caveat for D03 and D05: those tests inject an already-decoded `ModelName.GS3` and expect
`model_code == ModelCode.GS3`. A real BLE `"GS3"` family decodes to `GS3_AV`, giving
`model_code == GS3AV`. Both are outside `STEAM_LEVEL_MODELS`, so the widget choice is the same.

### 3.6 BT-REC-001 — recorded Linea Micra morning (`REC`, 85 lines)

**Fixture format and loader:**
- Header (`REC:1-5`): `# Shot counter notifications of a Linea Micra, recorded on 2026-10-05 (local time).`
- Line format is `<HH:MM:SS.fff> <payload>`. A `# replay` suffix marks the dropped replay that
  opens a new subscribe session (`REC:2-3`).
- The `HeatingCoeff` and `MachineStatistics` payloads keep the recorded structure, but "the
  coefficient values are made up" (`REC:4-5`).
- The loader (`TBC:894-909`) treats the times as UTC on `date(2026, 10, 5)`.
- For each session, the test sets the clock and fake replay to the replay line, calls
  `start_shot_counter(updates.append, telemetry_callback=telemetry.append)`, notifies each line
  with the clock set to its timestamp, and then calls `stop_shot_counter()` (`TBC:920-929`).
- **Swift:** copy `REC` verbatim into `Tests/.../Fixtures/` and port the loader.

**Upstream assertions (`TBC:931-976`), verbatim expectations:**

1. Grouped states:
   `[(BREWING, 3), (FLUSHED, 1), (BREWING, 3), (FLUSHED, 1), (BREWING, 13), (BREWING_STOPPED, 1), (BREWING, 10), (FLUSHED, 1)]`.
2. `received_at` of the updates with `timer_value == 0.0`:
   `["07:50:02.612", "07:50:09.360", "07:57:49.729", "07:59:22.007"]`.
3. For every update with a start time: `0 <= started_at − brewing_start_time < 0.05 s`.
   Comment: "late ticks, like 0.64 s at 07:50:11.215, don't move the start time".
4. The single stop: received at `07:58:02`, `final_shot_time == 12.727`,
   `stop_reason == "Manual"`, `started_dose_index == "ContinuousDose"`.
5. Telemetry modes in order: `[STANDBY, STANDBY]`.
6. `reduce(BluetoothMachineTelemetry.merge, telemetry)`: `coffee_boiler_temperature == 87`,
   `steam_boiler_temperature == 115`, `sleep == "command"`, and
   `machine_statistics["tot_doses"] == 2123`.

**Golden per-notification table (DERIVED).** Produced by a standalone re-implementation of
`SBT:77-111,441-465` and `MBT:73-213` (scratch script
`docs/bluetooth/research/sim04/sim.py`).
It reproduces all six upstream assertions above exactly, so it is safe as a finer-grained Swift
golden. Start times are printed at µs precision from Python `timedelta` arithmetic. In Swift
(`Date` = `Double` seconds), compare with a ≤ 1 ms tolerance.

Session 1 (replay dropped at 07:47:38.548: `{"BrewingUpdateGroup1Time":3.34,"BrewingUpdateGroup1Ev":true,"BrewingUpdateGroup1Backflush":false}`):

| Time | Shot callback (`state, timer, final, started_dose_index, stop_reason, brewing_start_time`) | Telemetry callback |
|---|---|---|
| 07:47:47.412 – 07:49:03.904 (6 lines) | — | steam 112, 115, 118, 121, 124, 127 |
| 07:49:22.144 | — | — (`SteamBoilerHeatingCoeff` unknown → nothing) |
| 07:49:22.179 | — | steam 130 |
| 07:50:02.612 | Brewing, 0.0, –, ContinuousDose, –, 07:50:02.612000 | — |
| 07:50:02.682 | Brewing, 0.089, …, 07:50:02.593000 | — |
| 07:50:03.742 | Brewing, 1.159, …, 07:50:02.583000 | — |
| 07:50:04.525 | Flushed, None, None, ContinuousDose, – , None | — |
| 07:50:09.360 | Brewing, 0.0, …, 07:50:09.360000 | — |
| 07:50:09.507 | Brewing, 0.107, …, 07:50:09.360000 | — |
| 07:50:11.215 | Brewing, 1.177, …, 07:50:09.360000 (estimate 07:50:10.038 is later → ignored) | — |
| 07:50:11.218 | Flushed, ContinuousDose | — |
| 07:50:17.940 | — | machine_statistics (tot_doses 2123, full object in REC:23) |
| 07:52:56.703 – 07:57:34.881 (15 lines) | — | steam 133/130 alternating, plus coffee 95 at 07:53:27.093 |
| 07:57:49.729 | Brewing, 0.0, …, 07:57:49.729000 | — |
| 07:57:49.831 | Brewing, 0.108, …, 07:57:49.723000 | — |
| 07:57:50.894 | Brewing, 1.178, …, 07:57:49.716000 | — |
| 07:57:51.983 – 07:57:54.132 | Brewing, 2.251 / 3.324 / 4.394, start 07:57:49.716000 | — |
| 07:57:55.192 – 07:58:01.659 | Brewing, 5.479 / 6.556 / 7.631 / 8.703 / 9.773 / 10.846 / 11.897, start 07:57:49.713000 | — |
| 07:58:02.461 | BrewingStopped, None, 12.727, ContinuousDose, Manual, None | — |
| 07:58:08.805 – 07:59:14.925 (7 lines) | — | steam 130, 133, 130, 127, 124, 127, 130 |
| 07:59:22.007 | Brewing, 0.0, …, 07:59:22.007000 | — |
| 07:59:22.140 – 07:59:25.392 | Brewing, 0.118 / 1.189 / 2.259 / 3.343, start 07:59:22.007000 | — |
| 07:59:26.428 – 07:59:30.726 | Brewing, 4.423 / 5.485 / 6.557 / 7.639 / 8.716, start 07:59:22.005000 | — |
| 07:59:31.412 | Flushed, ContinuousDose | — |
| 07:59:38.589 | — | coffee 92 |
| 07:59:42.983 | — | machine_mode StandBy |
| 07:59:42.983 | — | sleep "command" |

Session 2 (replay dropped at 08:36:59.441: `{"Sleep":"command"}`):

| Time | Shot callback | Telemetry |
|---|---|---|
| 08:37:20.950 – 08:37:33.088 | — | steam 106, coffee 75, steam 109, coffee 78 |
| 08:37:40.800 | — | — (`CoffeeBoiler1HeatingCoeff` unknown) |
| 08:37:40.803 – 08:37:49.062 | — | coffee 81, steam 112, coffee 84 |
| 08:37:54.637 | — | machine_mode StandBy |
| 08:37:54.638 | — | sleep "command" |
| 08:37:55.104, 08:37:57.458 | — | coffee 87, steam 115 |

### 3.7 Dashboard-from-Bluetooth vectors

**BT-DASH-SEED-001** (`TBD:68-105`): the pre-seeded widgets.

| Widget | Fields |
|---|---|
| `CMMachineStatus` | `status=StandBy, available_modes=[BrewingMode, StandBy], mode=StandBy, next_status=None, brewing_start_time=None` |
| `CMCoffeeBoiler` | `status=StandBy, enabled=True, enabled_supported=False, target_temperature=93.0, min 80, max 100, step 0.1, ready_start_time=None` |
| `CMSteamBoilerLevel` | `status=StandBy, enabled=True, enabled_supported=True, target_level=Level1, target_level_supported=True, ready_start_time=None` |
| `CMSteamBoilerTemperature` | `status=StandBy, enabled=True, enabled_supported=False, target_temperature=126.0, min 126, max 131, step 1.0, target_temperature_supported=True, ready_start_time=None` |

**Default widgets created when missing** (`DM:378-483`):

| Widget | Default fields |
|---|---|
| `MachineStatus` | `status=StandBy, available_modes=[BrewingMode, StandBy], mode=<read>, next_status=None` |
| `CoffeeBoiler` | `enabled_supported=False, min 80, max 110, step 0.1` |
| `SteamBoilerLevel` | `enabled_supported=True, target_level=Level1, target_level_supported=True` |
| `SteamBoilerTemperature` (original Mini, `is_mini`) | `min 95, max 140, step 0.1, target_temperature_supported=False` |
| `SteamBoilerTemperature` (other models) | `min 20, max 134, step 0.1, target_temperature_supported=True` |
| `NoWater` | `allarm = not water_ok` |

**Status derivation:**
- `water_ok = plumbed_in or tank_status`.
- Boiler status: if not `water_ok` → `NoWater`; else if not enabled → `Off`; else by mode:
  `BrewingMode→Ready`, `EcoMode→EcoMode`, `StandBy→StandBy` (`DM:71-75,369-376`).
- Machine status by mode: `BrewingMode→PoweredOn`, `EcoMode→EcoMode`, `StandBy→StandBy`
  (`DM:65-69`).
- The coffee boiler status always uses `boiler_status()` with `enabled` defaulting to `True`, so
  a disabled coffee boiler never reads `Off` (`DM:413`).

**BT-DASH-STATUS-001…005** (`TBD:560-605`). Input `(mode, plumbed_in, tank_ok, steam_enabled)`,
expected `(machine status, coffee status, steam level status, NoWater.allarm)`. Boilers are coffee
`(True, 93, 92)` and steam `(steam_enabled, 128, 120)`.

| ID | Input | Expected |
|---|---|---|
| 001 | `(BrewingMode, False, True, True)` | `(PoweredOn, Ready, Ready, False)` |
| 002 | `(EcoMode, False, True, True)` | `(EcoMode, EcoMode, EcoMode, False)` |
| 003 | `(StandBy, False, True, False)` | `(StandBy, StandBy, Off, False)` |
| 004 | `(BrewingMode, False, False, True)` | `(PoweredOn, NoWater, NoWater, True)` |
| 005 | `(BrewingMode, True, False, True)` ("plumbed-in machines report an empty tank, that's not a water alarm") | `(PoweredOn, Ready, Ready, False)` |

**BT-DASH-STEAMLVL-001…006** (`TBD:639-648`, rule at `DM:78-84`): steam target → level.

| ID | Target | Level |
|---|---|---|
| 001 | `0` | `Level3` (0 is not `> 0`, so it falls through) |
| 002 | `126` | `Level1` |
| 003 | `127.9` | `Level1` |
| 004 | `128` | `Level2` |
| 005 | `130` | `Level2` |
| 006 | `131` | `Level3` |

**BT-DASH-MOCK-001** (`TM:910-914`): `get_machine_mode → <mode>`, `get_plumbed_in → False`,
`get_tank_status → True`, `get_boilers → []`.

**BT-DASH-SNAP-001…005: verbatim syrupy snapshots (`SNAP`).** Python `to_dict()` shapes; port
them semantically to Angstrom's `Dashboard`/`Widget` model.

BT-DASH-SNAP-001 = `test_get_dashboard_from_bluetooth` (`SNAP:2-54`):
```
  dict({
    'available_firmware_update': False,
    'ble_auth_token': None,
    'coffee_station': None,
    'config': dict({
      'CMCoffeeBoiler': dict({
        'enabled': True,
        'enabled_supported': False,
        'ready_start_time': None,
        'status': 'Ready',
        'target_temperature': 95.0,
        'target_temperature_max': 100,
        'target_temperature_min': 80,
        'target_temperature_step': 0.1,
      }),
      'CMMachineStatus': dict({
        'available_modes': list([
          'BrewingMode',
          'StandBy',
        ]),
        'brewing_start_time': None,
        'mode': 'BrewingMode',
        'next_status': None,
        'status': 'PoweredOn',
      }),
      'CMNoWater': dict({
        'allarm': False,
      }),
      'CMSteamBoilerLevel': dict({
        'enabled': False,
        'enabled_supported': True,
        'ready_start_time': None,
        'status': 'Off',
        'target_level': 'Level2',
        'target_level_supported': True,
      }),
    }),
    'connected': False,
    'connection_date': '2024-01-01T12:00:00+00:00',
    'image_url': '',
    'location': None,
    'model_code': 'LINEAMICRA',
    'model_name': 'Linea Micra',
    'name': '',
    'offline_mode': False,
    'require_firmware_update': False,
    'serial_number': 'MR123456',
    'shot_counter_supported': False,
    'type': 'CoffeeMachine',
    'widgets': list([
    ]),
  })
```
Note: `CMSteamBoilerTemperature` was **removed** (it was in the seed). `CoffeeBoiler` keeps the
seed's max of **100**: existing widgets are updated in place, so the default 110 does not apply.

BT-DASH-SNAP-002 = `test_get_dashboard_initializes_missing_widgets` (`SNAP:56-108`). It is
identical in structure to SNAP-001 except for these fields:
- `CMCoffeeBoiler`: `'status': 'Ready'`, `'target_temperature': 92.0`, `'target_temperature_max': 110`, `'target_temperature_min': 80`, `'target_temperature_step': 0.1`, `'enabled': True`, `'enabled_supported': False`.
- `CMMachineStatus`: same as SNAP-001.
- `CMNoWater`: `'allarm': False`.
- `CMSteamBoilerLevel`: `'enabled': True`, `'enabled_supported': True`, `'status': 'Ready'`, `'target_level': 'Level2'`, `'target_level_supported': True`.
- Top level: `'model_code': 'LINEAMINIR'`, `'model_name': 'Linea Mini R'`. Every other top-level key is identical to SNAP-001.

BT-DASH-SNAP-003 = `test_set_coffee_temp_updates_dashboard` (`SNAP:110-120`):
```
  dict({
    'enabled': True,
    'enabled_supported': False,
    'ready_start_time': None,
    'status': 'StandBy',
    'target_temperature': 96.5,
    'target_temperature_max': 100,
    'target_temperature_min': 80,
    'target_temperature_step': 0.1,
  })
```

BT-DASH-SNAP-004 = `test_set_power_updates_dashboard` (`SNAP:122-132`):
```
  dict({
    'available_modes': list([
      'BrewingMode',
      'StandBy',
    ]),
    'brewing_start_time': None,
    'mode': 'BrewingMode',
    'next_status': None,
    'status': 'StandBy',
  })
```
(`set_power` changes `mode` only. `status` stays `StandBy`: `DM:487-509`.)

BT-DASH-SNAP-005 = `test_set_steam_temp_updates_dashboard` (`SNAP:134-145`):
```
  dict({
    'enabled': True,
    'enabled_supported': False,
    'ready_start_time': None,
    'status': 'StandBy',
    'target_temperature': 122.5,
    'target_temperature_max': 131,
    'target_temperature_min': 126,
    'target_temperature_step': 1.0,
    'target_temperature_supported': True,
  })
```

### 3.8 Device-layer vectors

**BT-FALLBACK-001…006** (`TM:134-189`): machine call → BLE call → cloud call.

| ID | Machine call | `model_code` set | BLE method and kwargs | Cloud method and kwargs (plus `serial_number=`) |
|---|---|---|---|---|
| 001 | `set_power(True)` | — | `set_power(enabled=True)` | `set_power(enabled=True)` |
| 002 | `set_steam(False)` | — | `set_steam(enabled=False)` | `set_steam(enabled=False)` |
| 003 | `set_steam_level(SteamTargetLevel.LEVEL_2)` | — (default LINEAMICRA) | `set_temp(boiler=BoilerType.STEAM, temperature=128)` | `set_steam_target_level(target_level=SteamTargetLevel.LEVEL_2)` |
| 004 | `set_coffee_target_temperature(93)` | — | `set_temp(boiler=BoilerType.COFFEE, temperature=93)` | `set_coffee_target_temperature(target_temperature=93)` |
| 005 | `set_steam_target_temperature(124)` | `ModelCode.GS3` | `set_temp(boiler=BoilerType.STEAM, temperature=124)` | `set_steam_target_temperature(target_temperature=124)` |
| 006 | `set_smart_standby(True, 30, SmartStandByType.POWER_ON)` | — | `set_smart_standby(enabled=True, minutes=30, mode=SmartStandByType.POWER_ON)` | `set_smart_standby(enabled=True, minutes=30, after=SmartStandByType.POWER_ON)` |

Note the argument-order trap: the machine-level signature is `(enabled, minutes, mode)`
(`DM:870-871`), but the BLE client's is `(enabled, mode, minutes)` (`SBT:611-612`).

**Model gating** (`DM:784, 823`):
- `set_steam_level` is gated to `STEAM_LEVEL_MODELS`.
- `set_steam_target_temperature` is gated to `(GS3, GS3_AV, GS3_MP, STRADA_X)`. That excludes the
  original `LINEA_MINI`, even though BLE builds a steam temperature widget for it with
  `target_temperature_supported=False`.

**BT-OVL-001** (`TM:784-832`). `received_at = 2026-01-01T12:00:00Z`; `cloud_start = 2026-01-01T11:00:00Z`.

| Step | Event | Expected |
|---|---|---|
| 1 | Cloud widget `PoweredOn` (start `cloud_start`); `Brewing` update with timer 12.5 | Callback gets the update object; `status == Brewing`; `brewing_start_time == 11:59:47.5Z` |
| 2 | `BrewingStopped`, final 27.4 | `status == PoweredOn`; `brewing_start_time == cloud_start`; `last_shot_time == 27.4` |
| 3 | Cloud push of a **new** widget object with status `Brewing` | The dashboard holds the new object, and its status is rewritten to `PoweredOn` |
| 4 | Cloud push `StandBy` (start `None`), then `Flushed` | `status == StandBy`; `last_shot_time` still 27.4 |
| 5 | `Brewing` timer 1 | `status == Brewing` |
| 6 | `connection(False)` | Callback gets `None`; `status == StandBy`; `brewing_start_time is None`; `ble_brewing_update is None` |

**Override rule** (`DM:287-314`):
- `Brewing` → `status = Brewing`, `brewing_start_time = update.brewing_start_time`.
- Any other state → `status = PoweredOn` if the cloud status was `Brewing`, else the cloud
  status; and `brewing_start_time = cloud value`.
- The cloud values are remembered per widget **object identity** (`DM:294-302`). A BLE refresh
  that mutates the same object in place rebases the remembered status but keeps the remembered
  start time (`DM:316-323`).

**BT-TEL-MERGE-001** (`TM:974-992`):
- `steam_boiler_temperature=130` → forwarded; `mode` unchanged (`BrewingMode`).
- Then `machine_mode=StandBy, sleep="command"` → `(mode, status) == (StandBy, StandBy)`.
- The merged state is then `BluetoothMachineTelemetry(steam_boiler_temperature=130, machine_mode=MachineMode.STANDBY, sleep="command")`.
- `connection(False)` resets it to `BluetoothMachineTelemetry()`.

**Synthesized dashboard-callback payload** (`DM:257-271`), used by M17 and M24:
`ThingDashboardWebsocketConfig(widgets=self.dashboard.widgets, config=self.dashboard.config, connected=self.dashboard.connected, connection_date=int(self.dashboard.connection_date.timestamp() * 1000), uuid="", commands=[])`.

---

## 4. Behaviours implemented in source with no upstream test (gaps to cover in Swift)

The Swift suite should pin each of these with its own test, labelled "Angstrom-only".

### 4.1 Client: protocol and codec (`SBT`, `MBT`)

- **G-CODEC-1. `read_token`** (`SBT:539-547`) is untested. It opens a plain `BleakClient` (not
  `establish_connection`, no auth, no idle timer), reads `GET_TOKEN_CHARACTERISTIC`
  (`0c0b…`), and returns `token.decode()` with **no** NUL stripping. The docstring says it is
  "Only possible when machine is in pairing mode." (`SBT:543`). Response bytes and token format
  are UNVERIFIED.
- **G-CODEC-2. Command bytes for `set_steam` and `set_power(False)`** are never asserted
  (BT-REQ-002 and BT-REQ-005 are derived). The same goes for a float `set_temp`: whether
  `96.5`/`93.0` encodings are accepted by the machine is UNVERIFIED.
- **G-CODEC-3. Type coercion in mashumaro decodes.**
  - **What mashumaro 3.17 does** (verified by reading the source of the locked version, not by
    running it). Its generated `from_dict` coerces primitives with constructors:
    - `bool(v)` (`mashumaro/core/meta/types/unpack.py:897-899`);
    - `int(v)` / `float(v)` (`:889-893`);
    - `str(v)` (`:1263-1264`);
    - `Enum(v)` (`:1337-1340`);
    - an `Optional[X]` is `None` if the value is `None`, otherwise X's coercion (`:773-784`).
  - **Upstream behaviours that follow, none of them tested:**
    - `{"enabled":"false"}` in `smartStandBy` decodes to **`True`**, because `bool("false")` is
      true. The same happens to `"isEnabled":"false"` in `boilers`, to `"hasCupWarmer":"false"`,
      and to `"BrewingUpdateGroup1Ev":"false"` in notifications. This is a **latent upstream
      bug**: only `get_tank_status` and `get_plumbed_in` use the string-aware `_parse_bool`. C06
      passes only because it uses `"true"`.
    - `BluetoothBoilerDetails.target: int` / `current: int` (`MBT:48-49`) truncate `93.5` to `93`.
    - Numeric strings are accepted: `"BrewingUpdateGroup1Time":"3.5"` → `3.5`.
    - A non-string dose index such as `1` becomes `"1"`.
    - `{"isEnabled": null}` on a non-Optional `bool` gives `bool(None)` = `False`.
    - An unknown `id` or `mode` raises `ValueError` from `BoilerType(v)` / `SmartStandByType(v)`,
      and so does an unknown entry in `machineModes`.
    - A missing required key raises mashumaro's `MissingField`.
  - **Swift decision needed (flag as a deliberate divergence or as parity):**
    - Recommended: decode every wire bool as JSON bool **or** string, with `_parse_bool`
      semantics (`"false"` → `false`). This diverges from upstream only on inputs that upstream
      mis-decodes.
    - Decode boiler `target`/`current` as `Double`.
    - Accept numeric strings for times only if parity is wanted.
  - **Still UNVERIFIED:** whether the machine ever sends string booleans other than the observed
    `"true"`. Resolve with a capture of `smartStandBy` while disabled.
- **G-CODEC-4. NUL handling differs by path.** Reads split at the first NUL (`SBT:671`).
  Notifications only `strip(b"\x00")` at both ends (`SBT:452`), so a NUL in the middle of a
  notification fails parsing. A leading NUL on a notification is untested.
- **G-CODEC-5. Malformed read responses.**
  - `get_machine_capabilities` on `[]` raises `IndexError` (`SBT:568`).
  - An unknown `MachineMode` string raises `ValueError` (`SBT:558`).
  - An unknown boiler `id` fails the mashumaro decode.
  - A non-JSON response raises `JSONDecodeError` (`SBT:657`).
  - None of these are `BleakError`/`TimeoutError`/`BluetoothConnectionFailed`, so
    `disconnect_on_exception` does **not** drop the link (`SBT:129`), and the device layer does
    **not** fall back to the cloud (`DM:1025`). The error propagates to the caller.
  - **Exception:** `get_plumbed_in`'s `ValueError` is swallowed only inside
    `get_dashboard_from_bluetooth` (`DM:357-362`).
- **G-CODEC-6. Command status parsing.** `BluetoothCommandStatus.from_json(result)` (`SBT:710`)
  on a non-JSON or missing-key reply raises, with the same non-fallback consequence as
  G-CODEC-5. Real error-reply shapes are UNVERIFIED.
- **G-CODEC-7. Telemetry decoding of `MachineStatistics`** when the string is not valid JSON:
  `json.loads` raises, and the **whole** notification is dropped, including any brewing keys in
  the same payload (`SBT:451-457`). Untested.
- **G-CODEC-8. `discover_devices`.** A device whose `name` is `None` is skipped (`SBT:534`).
  Called with no scanner, it builds a `BleakScanner()` (`SBT:529-530`). Both untested.

### 4.2 Client: connection, auth and reconnect

- **G-AUTH-1. Auth write failure.** A `BleakError`/`TimeoutError` during the auth write or read
  becomes `BluetoothConnectionFailed("Failed to connect to machine with Bluetooth: …")`, not the
  auth subclass (`SBT:649-652`). Untested.
- **G-AUTH-2. Auth retry timing.** 10 reads with 0.05 s between them is ≈ 0.45 s worst case
  (`SBT:642-645`). The interval is never asserted, only zeroed.
- **G-AUTH-3. When `authentication_failed` updates.** It is written on **every** auth read
  (`SBT:646`), so it reflects the last read. On a connect failure *before* auth (e.g.
  `BleakError` from `establish_connection`) it keeps its previous value. Untested.
- **G-CONN-1. `establish_connection` arguments.** `max_attempts=3`, a name fallback of
  `self._ble_device.name or "Unknown"`, and `disconnected_callback=self._on_bleak_disconnected`
  (`SBT:247-255`). Only `use_services_cache`, the device and `ble_device_callback` are asserted.
- **G-CONN-2. Resolution succeeding after `clear_cache()` in the same connection**
  (`SBT:729-735`). The fake cannot reach this path (§2.1). It matters for CoreBluetooth, where
  "clear cache" would mean re-running service discovery on the live connection.
- **G-CONN-3. Disconnect errors are swallowed.** Errors from `client.disconnect()` are logged
  and ignored (`SBT:307-310`), and errors are suppressed in the connect-failure cleanup
  (`SBT:262-263`) and in `stop_notify` (`SBT:399-400`). Untested.
- **G-CONN-4. Idle timer behaviour.** The idle timer is re-armed on a connection reused by
  `_ensure_connected` (`SBT:236-239`). It is armed only after a successful auth (`SBT:268`).
  The real 30 s value is never asserted.
- **G-CONN-5. `disconnect_on_exception` with the shot counter enabled but disconnected.** In
  that state, a failed command *does* schedule `_drop_connection` (`SBT:131`). Untested.
- **G-CONN-6. A characteristic-resolution failure drops the link even while the shot counter
  runs.** `_resolve_characteristic` schedules `asyncio.create_task(self._drop_connection())`
  unconditionally (`SBT:742-744`). This bypasses the decorator's "a single failed command must
  not kill a running shot counter" guard (`SBT:130-133`). The resulting
  `_handle_connection_lost` (`SBT:317`) then starts the reconnect loop. C48 only covers a
  failing *write*, and C15 only covers the case with no shot counter. Untested.
- **G-CONN-7. The idle timer survives a bleak-reported link loss.** `_on_bleak_disconnected`
  (`SBT:467-473`) does not cancel `_disconnect_task`. When the stale timer fires,
  `_drop_connection` runs against a dead link, and `_set_connected(False)` deduplicates
  (`SBT:210-211`). Harmless, but a Swift port should decide explicitly. Untested.
- **G-CONN-8. Two `_ensure_connected` calls per request.** One is on the write (`SBT:680`) and
  one on the read (`SBT:663`). If the link drops *between* the write and the read of one
  request, the read silently reconnects and re-authenticates. It then reads a status from a
  fresh connection, which is likely an empty or stale value. Untested. Behaviour on real
  hardware is UNVERIFIED.
- **G-RC-1. Reconnect backoff values.** The delay starts at 1 s, doubles **only after a
  connection-type failure** (`SBT:511`), and caps at 60 s. Auth failures do **not** double the
  delay (`SBT:496-506`). Because tests patch the start to 0, the sequence `1, 2, 4, 8, 16, 32,
  60, 60…` is never asserted.
- **G-RC-2. Auth-failure counting.** `auth_failures` is local to one reconnect task, and is not
  reset by intervening connection errors (`SBT:491, 497`). README says "3 failed logins in a row"
  (`README.md:269`), but the code counts 3 auth failures in total per reconnect task. The
  sequence auth-fail, BleakError, auth-fail, auth-fail gives up. Untested.
- **G-RC-3. Reconnect where the characteristic has disappeared.** `_subscribe_shot_counter`
  returns `False` → `break` → `_disable_shot_counter()` → idle timer re-armed (`SBT:512-520`).
  Untested. The connection callback is not called with `False` again, because
  `_shot_counter_subscribed` is already false.
- **G-RC-4. `start_shot_counter` when the initial connect or auth throws.** The `finally` block
  disables the shot counter and re-raises (`SBT:355-361`); no reconnect loop is started.
  Untested.
- **G-RC-5. `_handle_connection_lost` via `_drop_connection`** (idle or error path) while the
  shot counter is enabled schedules a reconnect (`SBT:313-317, 475-486`). This is only
  exercised through bleak's callback path.
- **G-SC-1. `stop_shot_counter()` with no shot counter running** is a no-op apart from re-arming
  the idle timer (`SBT:364-371`). Untested.
- **G-SC-2. Exceptions from the telemetry and connection callbacks** are contained by
  `_safe_call` (`SBT:67-74, 213-214, 437, 465, 484`). Only the shot callback is tested (C31).
- **G-SC-3. The brewing tracker resets on `start_shot_counter` resubscribe** (`SBT:428`) as well
  as on connection loss (`SBT:479`) and disable (`SBT:390`). Only the loss path is tested (C32).
- **G-SC-4. A notification arriving after `stop_shot_counter`** but before bleak's unsubscribe
  takes effect: the callbacks are already `None` (`SBT:387-389`), so it is a silent drop.
  Untested.
- **G-SC-5. A second `start_shot_counter` while subscribed** replaces the three callbacks
  (`SBT:350-352`), but returns at `SBT:413-414`. So:
  - the new `connection_callback(True)` is never called;
  - the tracker is not reset;
  - `_replay_pending` is not re-armed.

  C36 asserts only the brewing callback.
- **G-SC-6. `start_shot_counter` while a reconnect is pending.** The shot counter is enabled but
  not subscribed, and `_reconnect_task` is sleeping. The direct call and the reconnect loop both
  run `_subscribe_shot_counter`. They serialize on `_lock`, and the loser sees
  `_shot_counter_subscribed` and returns `True`. Untested race.
- **G-SC-7. The first sleep happens before the first reconnect attempt** (`SBT:492-493`), so
  even the first retry waits `RECONNECT_INITIAL_DELAY` (1 s). Tests zero it.

### 4.3 Device layer (`DM`)

- **G-DEV-1. Non-success BLE status with a cloud client present.** If
  `result.status.lower() != "success"`, the code **falls through to the cloud** (`DM:1023-1048`);
  it does not return `False`. D13 only covers the no-cloud case. The case-insensitive compare is
  also untested.
- **G-DEV-2. Errors other than `BleakError`/`BluetoothConnectionFailed`** (e.g. `TimeoutError`,
  decode errors) are **not** caught by the fallback (`DM:1025`), so they propagate. Note that
  `TimeoutError` is caught by the client decorator (`SBT:129`) and re-raised unchanged.
- **G-DEV-3. `get_dashboard_from_bluetooth` widget defaults** for the steam temperature widget
  on `LINEA_MINI` vs other models (`DM:448-462`) and the `EcoMode` coffee status are not
  snapshot-tested. Also untested:
  - the coffee boiler never shows `Off` (`DM:413`);
  - a `boilers` list without a steam entry keeps stale steam widgets;
  - order effects when the list has duplicates.
- **G-DEV-4. `_steam_level_from_temperature` edges** (`DM:78-84`): `130.5 → Level3`,
  negative → `Level3`, `127.99 → Level1`.
- **G-DEV-5. Cloud `get_dashboard()` replacing the dashboard object while a BLE override is
  active.** `_dashboard_config_updated` (`DT:141`) re-applies the override to the new widget
  (`DM:294-302`). Only the websocket-push variant is tested (M16).
- **G-DEV-6. `_on_shot_counter_connection(True)` is a no-op** (`DM:225`). The override survives
  reconnect only until the expiry timer runs. Untested.
- **G-DEV-7. Telemetry `MachineMode` while `MachineGroupStatus` is present** updates the group
  widget's mode too (`DM:487-492, 233-237`). Untested via telemetry; only via `set_power` (M29).
- **G-DEV-8. `set_smart_standby` minute formatting** for values ≥ 24 h, or with a remainder
  (`f"{minutes // 60:02d}:{minutes % 60:02d}"`, `DM:877`). Only `90 → "01:30"` is tested.
- **G-DEV-9. `bluetooth_connected`** (`DT:109-114`) is tested only with a mock attribute. There
  is no integration test with the real client.
- **G-DEV-10. `get_dashboard_from_bluetooth` ignores capabilities for `available_modes`.** A
  freshly created `MachineStatus` always gets `[BREWING_MODE, STANDBY]` (`DM:385`), even when
  the read `machine_mode` is `EcoMode` or capabilities list more modes. An existing widget's
  `available_modes` and `brewing_start_time` are left untouched. Untested.
- **G-DEV-11. `set_steam` updates both steam widgets if both exist** (`DM:777-780`). Only the
  level widget is tested (D09).
- **G-DEV-12. Device-layer callbacks run inside the client's `_safe_call`.** A throwing
  user telemetry or update callback is caught by the client (`SBT:463, 465`) *after* the
  device-layer state has been mutated (`DM:232-239`, `DM:211-221`). A Swift port must keep
  "state first, user callback last". Untested.
- **G-DEV-13. Expiry timer scheduling assumes the event-loop thread.** `call_later` is used
  from the notification callback (`DM:218`). The Swift port must hop to the device layer's
  actor (`@MainActor` in AngstromUI) before touching widgets or arming the 60 s expiry. This is
  a design constraint, not an upstream test.

---

## 5. Hardware captures and firmware/model hints found in tests and fixtures

1. **The only real capture is `REC`:** a Linea Micra, 2026-10-05, "local time" (`REC:1`). What it shows:
   - **Tick cadence.** `BrewingUpdateGroup1Time` ticks arrive about every 1.07 s. The first tick
     comes 70–150 ms after `BrewingStartedGroup1DoseIndex` (e.g. `REC:15-16`: 07:50:02.612 →
     07:50:02.682 with time 0.089).
   - **Flush vs shot.** A flush and a shot are indistinguishable until they stop: both start with
     `BrewingStartedGroup1DoseIndex:"ContinuousDose"`. A flush ends with
     `{"FlushStoppedGroup1DoseIndex":"ContinuousDose","FlushStoppedGroup1Time":…}` (`REC:18`).
     A shot ends with
     `{"BrewingStoppedGroup1StopType":"Continuous","BrewingStoppedGroup1StopReason":"Manual","BrewingStoppedGroup1DoseIndex":"ContinuousDose","BrewingStoppedGroup1Time":12.727}` (`REC:51`).
     The real stop type is `"Continuous"`; the synthetic test uses `"X"`.
   - **Ticks carry the full key set** (`Time`, `Ev`, `Backflush`). Upstream never observed a
     standalone `{"BrewingUpdateGroup1Ev":false}` in the capture; that payload is synthetic
     (`TBC:754`).
   - **Telemetry is integers in °C**, sent on change. The steam boiler oscillates 130 ↔ 133
     while idle (`REC:24-37`).
   - **Going to standby** sends `{"MachineMode":"StandBy"}` and `{"Sleep":"command"}` as two
     separate notifications 0–1 ms apart: both at 07:59:42.983 (`REC:71-72`), and at
     08:37:54.637 / .638 (`REC:82-83`). In session 2 the boiler temperatures keep rising after
     that `StandBy` (`REC:84-85`). What `Sleep:"command"` means, and why a `StandBy` mode arrives
     during warm-up, is UNVERIFIED.
   - **Notification delivery can lag.** The tick `{"BrewingUpdateGroup1Time":1.177,…}` arrived
     at 07:50:11.215, 1.855 s after its shot started at 07:50:09.360 (`REC:19,21`). The flush
     stop followed 3 ms later (`REC:22`). This is why the tracker keeps the *earliest* start
     estimate (`SBT:106-110`).
   - **The replay can be very stale.** The first session's replay is a brewing tick
     (`REC:6`); the second session's replay is `{"Sleep":"command"}`, about 37 minutes old
     (`REC:73`).
   - **JSON-encoded string payloads.** `SteamBoilerHeatingCoeff` and
     `CoffeeBoiler1HeatingCoeff` are JSON strings with the misspelled key `"coefficent"`
     (`REC:13, 78`). The values are "made up" (`REC:4-5`).
   - **`MachineStatistics`** is a JSON string with these keys: `groups[].doses[]` (`DoseA`…`DoseD`,
     `ContinuousDose`), `clean`, `ev_activations`, `ev_ontime`, `tot_doses`, `boilers[]`
     (`rsteam_ontime`, `rcoffee_ontime`), `tea{count, ev_activation, ev_ontime}`,
     `pump_ontime`, `machine_ontime`, `refill_ontime`, `count_liter` (`REC:23`). Upstream notes
     that "the meaning of the counters is unverified" (`MBT:209`).
2. **Capability families seen on BLE.** The commit `e0f0249` message says: "The machineCapabilities
   response over Bluetooth reports short family names. LINEA (original Linea Mini) and GS3 (GS3
   AV) were not mapped". The mapped BLE families are `LINEA`, `LINEAMINI2023`, `MICRA` and `GS3`
   (`CONST:202-211`, `TMO:407-414`). Whether the GS3 MP reports `"GS3"` or `"GS3MP"` over BLE is
   **UNVERIFIED**.
   The Micra capability sample (`TBC:342`) has `"schedulingType":"smartWakeUpSleep"`. The
   dashboard tests use `"weekly"` (`TBD:47`), which is synthetic.
3. **Which machines support the shot counter.** README (`README.md:229`): "an ESP-gateway
   machine (Linea Micra, Linea Mini, Linea Mini R, GS3 AV/MP) with shot counter firmware;
   `connect_bluetooth_shot_counter` returns `False` otherwise." It also says "the machine likely
   accepts only one central at a time" (`README.md:231`).
   The Strada X fixtures show `"gatewayHw": "LinuxLM"` (`tests/fixtures/machine/dashboard_strada_profile.json:8`)
   and carry a (zeroed) `bleAuthToken`, but `STRADA` is not in `BT_MODEL_PREFIXES` (`SBT:46`).
   BLE support on the Strada X is UNVERIFIED and effectively out of upstream's scope.
3a. **Gateway hardware and firmware in the cloud fixtures.**
   - A Linea Micra fixture reports `"gatewayHw": "Esp32"` together with a (zeroed) 64-character
     `bleAuthToken` (`tests/fixtures/machine/schedule_micra_new.json:6-8,18`). That supports the
     README's "ESP-gateway machine" requirement for the shot counter.
   - The Strada X fixtures report `"gatewayHw": "LinuxLM"`.
   - `settings_micra.json:16-37` shows Gateway firmware `v5.0.9` (update `v5.0.10` available) and
     Machine firmware `v1.17`.
   - **Which gateway or machine firmware first ships the shot-counter characteristic `0e0b…` is
     UNVERIFIED.** No fixture records it, and the cloud's `shotCounterSupported` is `false` in
     every fixture that carries it.
   - The same Micra fixture's `"smartWakeUpSleepSupported": true` (`schedule_micra_new.json:29`)
     matches the BLE capabilities sample's `"schedulingType":"smartWakeUpSleep"` (`TBC:342`),
     which suggests that sample is realistic.
   - Its cloud `smartStandBy` block gives `minutesMin 1`, `minutesMax 240`, `minutesStep 1` and
     `"after": "LastBrewing"` (`schedule_micra_new.json:20-27`). That is a plausible valid range
     for the BLE `SettingSmartStandby.minutes`. The BLE-side limits themselves are UNVERIFIED.
3b. **README hardware notes:**
   - "This removes the ~4 s delay of the cloud websocket for shot start/stop" (`README.md:225`).
   - "The Bluetooth token is printed as a QR code on a label inside the machine's chassis"
     (`README.md:120`).
   - The token can also be read over BLE "only … when the machine is in pairing mode"
     (`README.md:102-116`, `SBT:539-547`).
   - The BLE commits are dated 2026-10-03 to 2026-10-05 (`6754903` "Support Bluetooth shot
     timer", `09bc1d4`, `83289c6` "add bluetooth telemetry, fixes"). The fake-client test rewrite
     is `5c4f818` (2026-10-30): "Spec'd fake Bleak client, deterministic idle and shot counter
     timers". The recording date 2026-10-05 matches the telemetry commit.
4. **Token shape hint.** Redacted fixtures contain
   `"bleAuthToken": "0000000000000000000000000000000000000000000000000000000000000000"`
   (64 characters; `tests/fixtures/machine/dashboard_stradax.json:17`,
   `settings_strada.json:42`). That real tokens are 64-character hex is UNVERIFIED.
   Micra, Mini, Mini R and GS3 AV fixtures have `"bleAuthToken": null`
   (e.g. `dashboard_micra.json:15`).
5. **Legacy GATT layout.** `docs/legacy/bluetooth_characteristics.md:10-16` lists an older
   service `d30a7847-e12b-09a8-b04b-8e0922a9abab` with characteristics `030b…`, `040b…`,
   `090b…`, `050b…`, `060b…`, `070b…` (same `…7847-e12b-09a8-b04b-8e0922a9abab` suffix). The
   current client uses `0a0b…`–`0e0b…` and resolves them **by characteristic UUID only**, with
   no service UUID anywhere in source.
   - The service UUID that hosts the current characteristics is **UNVERIFIED**.
   - It matters for CoreBluetooth: `discoverServices(_:)` with a filter, and background scanning
     (`scanForPeripherals(withServices:)`), need a service UUID. Without it the Swift client must
     discover all services.
6. **Firmware variance hints in source comments:**
   - "older firmware might not know this setting" for `isPlumbedIn` (`DM:360`).
   - "Newer firmware pushes brewing events over Bluetooth" (`README.md:225`).
   - "proxies may deliver it after subscribing" for the replay (`TBC:818`).
   - Multi-read auth confirmation (C19) implies the machine can take more than one read to
     publish `0x01`.
   - Plumb-in and tank replies come as either JSON bools or JSON strings (C43–C46, C07).
7. **Platform caveat for discovery and identity.** Upstream identifies devices by a MAC-style
   `address` (`SBT:158, 549-553`; tests use `"test-address"`). CoreBluetooth exposes only a
   per-central `CBPeripheral.identifier` UUID, so `address` cannot be ported literally. Swift
   tests C51 and C50 should be keyed on whatever device handle the Swift seam defines.

---

## 6. Suggested Swift test file layout (for the implementation workflow)

| Swift test class | Rows |
|---|---|
| `BluetoothCodecTests` | C42, C25 (codec part), BT-REQ-*, BT-RSP-*, G-CODEC-* |
| `BluetoothReadTests` | C04–C08, C43–C46, G-CODEC-5 |
| `BluetoothCommandTests` | C01–C03, BT-REQ-002/005/006, G-CODEC-6 |
| `BluetoothAuthTests` | C09, C18, C19, C41, C49, C54, G-AUTH-* |
| `BluetoothConnectionTests` | C10–C17, C47, C51–C53, C55, G-CONN-1…5, G-CONN-7/8 |
| `BluetoothDiscoveryTests` | C50, G-CODEC-8 |
| `ShotCounterLifecycleTests` | C20–C23, C36–C38, C40, C48, G-SC-1/4/5/6 |
| `ShotCounterStateMachineTests` | C24–C27, C30, C31, BT-NTF-RESET-001, G-SC-2/3 |
| `ShotCounterTelemetryTests` | C28, G-CODEC-7 |
| `ShotCounterRecordedSessionTests` | C29 (+ golden §3.6) |
| `ShotCounterReconnectTests` | C32–C35, G-RC-*, G-SC-7, G-CONN-6 |
| `BluetoothModelsTests` | O01–O07, D03/M27 mapping parts |
| `BluetoothFallbackTests` (device layer) | M01–M13, M30–M32, G-DEV-1/2/8 |
| `BluetoothCommandSideEffectTests` (device layer) | D07–D14, M29, G-DEV-11 |
| `BluetoothDashboardTests` (device layer) | D01–D06, D15–D26, M26–M28, G-DEV-3/4/10 |
| `ShotCounterOverlayTests` (device layer) | C39, M14–M25, G-DEV-5/6/7/12/13 |
| `BluetoothDeviceStateTests` (device layer) | T01, T02, G-DEV-9 |

Shared test support to build first, since everything depends on it:
- `FakePeripheralLink` / `FakeConnector` (§2.1);
- a manual `TestClock` / `TestSleeper` with per-purpose timers (§2.2);
- a `now()` injection;
- a device-layer expiry-timer factory;
- the recorded fixture `shot_counter_2026-10-05.txt` copied verbatim with a Swift loader.

---

## 7. Open questions (for the plan owner / later hardware capture)

1. **String booleans.** Should Swift keep upstream's mashumaro decoding, where
   `bool("false") == True` for `smartStandBy.enabled`, `boilers[].isEnabled` and so on? Or
   should it diverge and use `_parse_bool` semantics everywhere? Recommendation: diverge, and
   document it in UPSTREAM.md (G-CODEC-3).
2. **Float formatting of `SettingBoilerTarget.value`.** Python emits `93` for an int and `93.0`
   for a float. Swift's `JSONEncoder` emits `93` for `93.0`. Does the machine accept both?
   UNVERIFIED (BT-REQ-006). Resolve with a capture or a hardware test.
3. **Key order.** The command JSON key order (`minutes, mode, enabled`; `identifier, value`;
   `identifier, state`) must be reproduced byte-for-byte to match the pinned vectors. Whether
   the machine itself cares about key order is UNVERIFIED.
4. **The service UUID** hosting `0a0b…`–`0e0b…` is not in source. It is needed for filtered
   CoreBluetooth discovery and background scanning. UNVERIFIED.
5. **Real advertised names** for discovery (`MICRA…`, `MINI…`, `LINEA…`, `GS3…`): the test names
   are synthetic. UNVERIFIED.
6. **Swift's equivalent of `eager_start`** for the re-entrancy tests (C37–C39). Is `Task.immediate`
   available on the macOS 14 / iOS 17 deployment targets? UNVERIFIED. Otherwise, the tests must
   be restated as "re-entrant stop is a no-op".
7. **Auth-failure counting.** Should Swift match the code (3 auth failures *total* per reconnect
   task) or the README ("3 failed logins in a row")? See G-RC-2.
8. **Whether to port the device-layer fallback semantics exactly.** A non-success BLE status
   falls through to the cloud (G-DEV-1). Non-BLE errors propagate without fallback (G-DEV-2).
9. **Upstream suite not re-run here.** Running the suite in an isolated venv was blocked by the
   permission system. A maintainer can confirm the 123 cases pass at `4c639ee` with:
   `uv run --frozen --extra dev pytest tests/test_bluetooth_client.py tests/test_bluetooth_dashboard.py tests/test_machine.py`.
