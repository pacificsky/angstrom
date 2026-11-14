# 06: CoreBluetooth on Apple platforms. Constraints and recommended architecture

> Research note for the Angstrom Bluetooth-parity plan. **Scope:** the Apple-platform
> design constraints for porting upstream's bleak-based BLE client
> (`LaMarzoccoBluetoothClient`) to CoreBluetooth inside a Swift 6, strict-concurrency
> SwiftPM library (macOS 14+, iOS 17+), and the architecture I recommend. Protocol bytes,
> the shot-counter state machine, the device layer and the upstream test inventory are
> covered by notes 01 to 05. This note cites them only where they decide an Apple-side
> question.
>
> **Reference of record:** pylamarzocco v2.5.6, commit `4c639ee`, the read-only clone at
> `$UPSTREAM`.
> Angstrom is v1.7.0 at `main` `e1bc403`.
>
> **Verification stance.** Every CoreBluetooth API claim was checked against the real SDK
> headers on this machine, not memory. Every concurrency claim was checked by compiling
> probes. The recommended design was **built and tested** as a scratch SwiftPM package (see
> §0.3). Anything I could not confirm locally is marked **UNVERIFIED**, with what would
> settle it.

---

## 0. Conventions, sources and verification artifacts

### 0.1 Abbreviations

| Abbrev. | Path |
|---|---|
| `BT` | upstream `src/pylamarzocco/clients/_bluetooth.py` (747 lines, read in full) |
| `EXC` | upstream `src/pylamarzocco/exceptions.py` |
| `README` | upstream `README.md` |
| `LEG` | upstream `docs/legacy/bluetooth_characteristics.md` |
| `TBT` | upstream `tests/test_bluetooth_client.py` |
| `PYPROJ`, `UVLOCK` | upstream `pyproject.toml`, `uv.lock` |
| `SDK/…h` | `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreBluetooth.framework/Headers/…h` |
| `CONC` | `MacOSX.sdk/usr/lib/swift/_Concurrency.swiftmodule/arm64e-apple-macos.swiftinterface` |
| `DISP` | `MacOSX.sdk/usr/lib/swift/Dispatch.swiftmodule/arm64e-apple-macos.swiftinterface` |
| `OSI` | `MacOSX.sdk/usr/lib/swift/os.swiftmodule/arm64e-apple-macos.swiftinterface` |
| `SYNC` | `MacOSX.sdk/usr/lib/swift/Synchronization.swiftmodule/arm64e-apple-macos.swiftinterface` |
| `BRC` | `bleak_retry_connector/__init__.py` (4.4.4) |
| `BRC-C` | `bleak_retry_connector/const.py` (4.4.4) |
| `BLEAK` | `bleak/__init__.py` (1.1.1) |
| `BLEAK-SC` | `bleak/backends/scanner.py` (1.1.1) |
| `B-CL` | `bleak/backends/corebluetooth/client.py` (1.1.1) |
| `B-CM` | `bleak/backends/corebluetooth/CentralManagerDelegate.py` (1.1.1) |
| `B-PD` | `bleak/backends/corebluetooth/PeripheralDelegate.py` (1.1.1) |
| `B-SC` | `bleak/backends/corebluetooth/scanner.py` (1.1.1) |

**Toolchain and SDK used:** Xcode 27.2 (build 27B52), Apple Swift 6.4.2
(swiftlang-6.4.2.1.9), MacOSX SDK 27.2 and iPhoneOS SDK 27.2, host macOS 27.2. The
CoreBluetooth header directory is **byte-identical** between the macOS and iOS SDKs
(`diff -rq` reports no difference), so every header citation applies to both platforms.
No other Xcode or toolchain is installed. Behaviour with the Swift 6.0 compiler (the
package's `swift-tools-version: 6.0` floor) is **UNVERIFIED** (see §3.7).

**Dependency sources.** Upstream declares `"bleak >= 0.20.0"` and
`"bleak-retry-connector >= 4.0.0"` (`PYPROJ:22`) and locks `bleak` `1.1.1`
(`UVLOCK:140-141`) and `bleak-retry-connector` `4.4.4` (`UVLOCK:163-164`). I read those
exact versions from a scratch venv at
`$VENV/lib/python3.13/site-packages/`.
bleak's **CoreBluetooth backend** is the most useful reference here: it is exactly what
upstream runs on when a Python user runs it on a Mac today.

### 0.2 What upstream does that must be ported (I/O surface only)

| Upstream | Line | I/O it needs |
|---|---|---|
| UUIDs `0a0b…`/`0b0b…`/`0c0b…`/`0d0b…`/`0e0b7847-e12b-09a8-b04b-8e0922a9abab` | `BT:40-44` | resolve characteristics by UUID across all services (no service UUID anywhere) |
| `BT_MODEL_PREFIXES = ("MICRA", "MINI", "LINEA", "GS3")` | `BT:46` | scan, then filter by `device.name` prefix (`BT:534`) |
| `IDLE_TIMEOUT = 30  # seconds` | `BT:47` | timer, then disconnect |
| `AUTH_SUCCESS = b"\x01"`, `AUTH_READ_ATTEMPTS = 10`, `AUTH_READ_INTERVAL = 0.05  # seconds` | `BT:49-51` | write with response, then a polled read |
| `MAX_AUTH_FAILURES = 3`, `RECONNECT_INITIAL_DELAY = 1`, `RECONNECT_MAX_DELAY = 60` | `BT:52-54` | reconnect loop with exponential backoff |
| `establish_connection(BleakClientWithServiceCache, …, disconnected_callback=…, max_attempts=3, ble_device_callback=…, use_services_cache=…)` | `BT:247-255` | connect with retries, plus a disconnect callback |
| `_authenticate` | `BT:628-653` | write the token to AUTH (with response), then read AUTH up to 10× |
| `__write_bluetooth_message` | `BT:674-700` | append NUL, write with response |
| `_read_bluetooth_message` | `BT:659-671` | read, then cut at the first NUL |
| `_resolve_characteristic` | `BT:712-747` | characteristic lookup, `clear_cache()`, then disconnect on a miss |
| `_subscribe_shot_counter` | `BT:403-439` | `start_notify`, plus a services-cache retry (`clear_cache` + disconnect) |
| `_handle_shot_counter_notification` | `BT:441-465` | per-notification callback, timestamped first (`BT:445`) |
| `_stop_notify_internal` | `BT:396-401` | `stop_notify`, best effort (`suppress(Exception)`) |
| `_on_bleak_disconnected` | `BT:467-473` | disconnect callback with a stale-client guard (`client is not self._client`) |
| `discover_devices` | `BT:522-537` | `BleakScanner().discover()`, default 5 s (`BLEAK:220`) |
| `read_token` | `BT:539-547` | connect **without** auth, read GET_TOKEN, `.decode()` |
| `address` | `BT:549-553` | docstring says "BT MAC address". On Apple it is a UUID (§2.2) |

### 0.3 Verification artifacts (all in the scratchpad, none in the repo)

All of these live under
`docs/bluetooth/research/06-sketch/`:

| Artifact | What it proved |
|---|---|
| `btsketch/` (scratch SwiftPM package, tools 6.0, macOS 14 / iOS 17) | The recommended design builds **warning-free** in Swift 6 language mode. `swift build` passes on macOS. `xcodebuild -scheme btsketch-Package -destination 'generic/platform=iOS' build` reports **BUILD SUCCEEDED**. `swift test` passes **9/9** fake-driven protocol tests. Its full source is reproduced verbatim in Appendices A to E. |
| `probes/p3.swift`, `probes/p4.swift` | `CBPeripheral`, `CBCentralManager`, `CBCharacteristic` and `CBUUID` are **not `Sendable`**. Region-isolation errors (`sending 'p' risks causing data races`) appear only at SIL emission, never under `-typecheck` (§3.1). |
| `probes/p2_executor.swift` | Custom-executor actor and global-actor delegate variants (§3.3). |
| `probes/p5_main.swift` | Main-actor delegate variants compile (§3.3 option D). |
| `layout/` (scratch 2-target package) | A `package`-access seam in a core target, implemented by a leaf CoreBluetooth target and exposed through a public opaque handle, builds and tests. **Only the leaf object file carries a CoreBluetooth autolink** (§7). |
| `spmplist/` (scratch executable) | A SwiftPM executable can embed an `Info.plist` via `linkerSettings: .unsafeFlags(-sectcreate …)`. `Bundle.main` reads it, and `codesign -dv` shows it bound (§5.5). |
| `plisttest/` | A bare `swiftc` link with `-sectcreate` is **not** bound until re-signed (§5.5). A probe reading `CBManager.authorization` without allocating a manager returned `0` (`notDetermined`) (§5.2). |

---

## 1. TL;DR: decisions for the implementation plan

1. **Concurrency model (option A, recommended).** All CoreBluetooth objects and adapter
   state are confined to **one private serial `DispatchQueue`**, which is also the
   `CBCentralManager` delegate queue. The delegate objects are
   `final class … : NSObject, …Delegate, @unchecked Sendable`. Async callers enter through
   `withCheckedThrowingContinuation` plus `withTaskCancellationHandler`. In-flight operations
   live in a queue-confined **op table** whose single `finish` path removes the entry before
   resuming, which makes double resume impossible. The design is verified to build in
   Swift 6 mode for macOS 14 and iOS 17 (§3).
2. **Reject a custom-executor actor** for CoreBluetooth on these floors. A
   `DispatchSerialQueue` executor is available from macOS 14 / iOS 17 (`DISP:186-187`).
   But a delegate callback can only enter that actor synchronously via `assumeIsolated`,
   whose runtime check for custom executors is `SerialExecutor.checkIsolated()`. That is
   `@available(macOS 15.0, iOS 18.0, …)` (`CONC:1985-1986`). On macOS 14 / iOS 17 the check
   can fail and trap (**UNVERIFIED** on real macOS 14 hardware, §3.3).
3. **The seam:** two `package`-access protocols, `BluetoothCentral` and `BluetoothLink`
   (§4). They are the analogue of the internal `WebSocketChannel`
   (`Sources/Angstrom/WebSocket.swift:8-14`), plus a tagged `BluetoothSleeper` and a clock.
   Each link has **one ordered `AsyncStream<LinkEvent>`** (notifications, services
   invalidated, disconnected), so a disconnect can never overtake earlier notifications.
   All protocol logic (auth, framing, locks, idle timer, shot counter, reconnect) sits above
   the seam and is tested with an in-memory fake.
4. **Module layout:** the CoreBluetooth-free BT protocol logic and seam go **in the core
   `Angstrom` target**. The ~500-line CoreBluetooth adapter goes in a **new leaf product
   `AngstromBluetooth`** that exposes one public factory,
   `BluetoothTransport.coreBluetooth(…)`. Cloud-only consumers then never link
   CoreBluetooth and never inherit a Bluetooth purpose-string requirement (§7).
5. **No third-party BLE wrapper.** The library has zero runtime dependencies today. Exact
   upstream parity needs control over the semantics a wrapper hides (owed ATT replies,
   ordering, notify-vs-read routing, timeouts), and the adapter is small (§8).
6. **Identity:** a peripheral is identified by `CBPeer.identifier` (`SDK/CBPeer.h:19-24`).
   That is what bleak reports as `BLEDevice.address` on macOS (`B-SC:160`). It is **not** a
   MAC address and cannot be derived from one. Persist it, and reconnect via
   `retrievePeripherals(withIdentifiers:)` (`SDK/CBCentralManager.h:153`), with a
   scan-by-identifier fallback like bleak's `find_device_by_address` (`B-CL:101-104`).
7. **Timeouts are ours to add.** "Connection attempts never time out"
   (`SDK/CBCentralManager.h:201`). bleak adds 20 s on connect (`BRC:102`), 20 s on reads
   (`B-PD:170`), and nothing on writes, notify or discovery. My recommended values are in
   §2.4.
8. **Authorization:** map `CBManagerState` (`SDK/CBManager.h:32-39`) plus the
   `CBManager.authorization` class property (`SDK/CBManager.h:86`, readable before a manager
   exists) to typed errors. All of them count as "connection failed" for the cloud fallback,
   which matches bleak raising `BleakError` for each one (`B-CM:93-100`). Allocate the
   manager **lazily** (§5).
9. **Packaging.** Pronto (Developer ID, hardened runtime, **not sandboxed**) needs only
   `NSBluetoothAlwaysUsageDescription` added to the `Info.plist` heredoc in
   `$PRONTO/make-app.sh:125-143`. It needs no entitlement. The
   `com.apple.security.device.bluetooth` entitlement matters only if an app adopts App
   Sandbox. `angcli` should embed an `Info.plist` with the usage string via a
   `-sectcreate __TEXT __info_plist` linker flag. That approach is verified to work from a
   SwiftPM manifest (§5.5). The TCC attribution for a CLI run from a terminal is
   **UNVERIFIED** (§5.6).
10. **iOS:** v1 should be **foreground-only**. Background scanning needs a service UUID
    (`SDK/CBCentralManager.h:176-178`), and upstream doesn't have one. The adapter should
    accept a restore identifier and surface restored peripherals, but the library must not
    own app lifecycle (§6).
11. **Biggest hardware risks:** (a) the ATT MTU Apple negotiates with the machine's ESP32
    gateway. A 418-byte telemetry notification needs an MTU ≥ 421 to arrive whole, and
    upstream does no reassembly (note 02 §1). (b) The service UUID. (c) Whether the
    machine's single central slot (`README:231`) is held by the phone app. (d) TCC
    behaviour for `angcli`. The full checklist is in §9.

---

## 2. bleak → CoreBluetooth concept mapping

### 2.1 Summary table

| bleak / upstream | CoreBluetooth | Notes |
|---|---|---|
| `BleakScanner().discover()`, 5.0 s default (`BLEAK:220`), no UUID filter. Upstream filters `device.name.startswith(BT_MODEL_PREFIXES)` (`BT:534`) | `scanForPeripherals(withServices: nil, options: nil)` (`SDK/CBCentralManager.h:185`), then `stopScan()` (`:193`) after 5 s. `centralManager(_:didDiscover:advertisementData:rssi:)` (`:310`) | `nil` services is "strongly discouraged" and not allowed in the iOS background (`:173-178`). macOS cannot scan passively (`B-SC:88-89`). |
| `BLEDevice.name` | `CBPeripheral.name` (`SDK/CBPeripheral.h:80`) | On macOS, bleak sets `BLEDevice.name` from `p.name()` (`B-SC:162-165`), **not** from the advertised local name. For parity, filter on `peripheral.name`, falling back to `advertisementData[CBAdvertisementDataLocalNameKey]` (`SDK/CBAdvertisementData.h:23`). |
| `BLEDevice.address` (MAC on Linux) | `CBPeer.identifier: NSUUID` (`SDK/CBPeer.h:24`) | bleak on macOS uses `p.identifier().UUIDString()` (`B-SC:160`). The only way to get a real MAC is an undocumented private call, behind bleak's opt-in `use_bdaddr` (`B-SC:148-158`). **Do not port that.** |
| constructing a client from a stored address | `retrievePeripherals(withIdentifiers:)` (`SDK/CBCentralManager.h:153`). If that returns nothing, scan and match the identifier | bleak scans up to `timeout` (`BleakClient` default 10.0, `BLEAK:487`) via `find_device_by_address` when it has no `CBPeripheral` (`B-CL:101-110`). |
| `establish_connection(…, max_attempts=3)` (`BT:247-255`) | `connect(_:options:)` (`SDK/CBCentralManager.h:215`), then `didConnect` (`:321`) / `didFailToConnect` (`:334`). **Never times out** (`:201`). Cancel with `cancelPeripheralConnection` (`:228`) | The retry loop is protocol logic above the seam (§2.4). bleak's CB backend calls `cancelPeripheralConnection_` after its own timeout (`B-CM:168-180`). |
| `disconnected_callback` | `centralManager(_:didDisconnectPeripheral:error:)` (`SDK/CBCentralManager.h:348`). After it, "no more methods will be invoked on peripheral's CBPeripheralDelegate" (`:343-345`) | That is the point to fail every pending op. A state drop below `poweredOn` "implies … any connected peripherals have been disconnected" (`:264-268`), so synthesize disconnects there too. |
| `BleakClientWithServiceCache` / `use_services_cache` / `clear_cache()` | none (no app-visible GATT cache API) | In bleak 1.1.1, `BleakClientWithServiceCache.clear_cache` finds no `clear_cache` on the base client. It logs `"clear_cache not implemented in bleak version"` and returns `False` (`BRC:198-203`). `grep -r clear_cache bleak/` finds nothing. On macOS `_has_valid_services_in_cache` returns `True` (`BRC:255-257`). **On Apple the upstream cache dance is a no-op plus a reconnect.** Port it as: drop the per-link characteristic table, rediscover (`discoverServices`), and reconnect where upstream reconnects. |
| `client.services.get_characteristic(uuid)` | `peripheral.services[].characteristics[]` after `discoverServices` (`SDK/CBPeripheral.h:142`) and `discoverCharacteristics(_:for:)` (`:168`) | bleak discovers **all** services, characteristics and descriptors on every connect (`B-CL:219-275`) and forgets them on disconnect (`B-CL:121`). The adapter only needs the five characteristics; descriptors are not needed. |
| `read_gatt_char` | `readValue(for:)` (`SDK/CBPeripheral.h:179`), then `peripheral(_:didUpdateValueFor:error:)` (`:396`) | The same callback also carries notifications (`:394`). See §2.6. |
| `write_gatt_char(response=True)` (every upstream write: `BT:636-640`, `BT:696-700`) | `writeValue(_:for:type: .withResponse)` (`SDK/CBPeripheral.h:208`), then `peripheral(_:didWriteValueFor:error:)` (`:407`) | Upstream never uses `response=False`. Keep `.withoutResponse` in the seam only for completeness. |
| `start_notify` / `stop_notify` | `setNotifyValue(_:for:)` (`SDK/CBPeripheral.h:225`), then `didUpdateNotificationStateFor` (`:418`) | Values arrive on `didUpdateValueFor` (`:218-220`). |
| `mtu_size` (never called upstream) | `maximumWriteValueLength(for:)` (`SDK/CBPeripheral.h:188`) | bleak defines MTU as `maximumWriteValueLength(.withoutResponse) + 3` (`B-CL:176-187`). |
| `pair()` | none | bleak: `"Pairing is not available in Core Bluetooth."` (`B-CL:205`, `:217`), and `pair=True` is ignored with a debug log (`B-CL:97-98`). Upstream never pairs (§2.8). |
| `disconnect()` | `cancelPeripheralConnection` (`SDK/CBCentralManager.h:228`). "Non-blocking, and any CBPeripheral commands that are still pending … may or may not complete" (`:222-223`) | bleak waits for `didDisconnect` with no timeout (`B-CM:183-191`). Recommend bounding that wait at 5 s, matching bleak-retry-connector's `DISCONNECT_TIMEOUT = 5` (`BRC-C:8`). |

### 2.2 Identity: `BluetoothPeripheralID`

- **What it is.** `CBPeer.identifier` is documented only as "The unique, persistent
  identifier associated with the peer" (`SDK/CBPeer.h:19-24`). Apple generates it. It is
  **not** derivable from, or convertible to, a MAC address.
- **Scope.** Whether the identifier is the same across two different apps on the same Mac
  (Pronto vs `angcli`), and how long it survives (OS updates, Bluetooth resets, forgetting
  the device), is **UNVERIFIED**. Settle it on hardware by logging the identifier from both
  binaries and across a reboot and a Bluetooth toggle. It certainly differs across physical
  Apple devices, so it **must not** be synced via iCloud or the cloud.
- **Correlating a peripheral with a cloud machine.** The cloud `Thing` carries only
  `ble_auth_token` (`src/pylamarzocco/models/_general.py:128`). There is no BT address or
  BT name. Upstream correlates nothing; the user picks a device. Whether the advertised
  name embeds the serial number is **UNVERIFIED** (hardware: log `peripheral.name` and
  `kCBAdvDataLocalName` for a known machine).
- **API recommendation.** Expose a public
  `struct BluetoothPeripheralID: Hashable, Sendable, Codable` wrapping the UUID string.
  Consumers persist it next to the token. Do **not** reuse upstream's
  `address`-is-a-MAC docstring (`BT:549-553`).
- **`ble_device_callback`** (`BT:146`, `:245-246`) exists so Home Assistant can swap
  adapters or proxies. Apple has no equivalent. Drop it, and let the adapter re-resolve the
  `CBPeripheral` from the identifier on every connect (sketch: `CoreBluetoothCentral.connect`,
  Appendix B).

### 2.3 Retaining peripherals

- "A discovered peripheral must be retained in order to use it; otherwise … it will be
  cleaned up by the central manager" (`SDK/CBCentralManager.h:303-305`).
- "Pending attempts are cancelled automatically upon deallocation of *peripheral*"
  (`:203`).
- If the state "moves below `CBCentralManagerStatePoweredOff`, all `CBPeripheral` objects
  … become invalid and must be retrieved or discovered again" (`:266-268`).

The adapter therefore keeps a queue-confined `[UUID: CBPeripheral]`, and empties it on
`.unknown`, `.resetting`, `.unsupported` or `.unauthorized` (sketch: `centralManagerDidUpdateState`).

### 2.4 Connection, retries and timeouts

What bleak 1.1.1 and bleak-retry-connector 4.4.4 actually do on macOS:

| Phase | Upstream behaviour on macOS | Source |
|---|---|---|
| Manager readiness | blocks up to **1 s** for the first state update, then raises `BleakError("BLE is unsupported")` / `("BLE is not authorized - check macOS privacy settings")` / `("Bluetooth device is turned off")` | `B-CM:91`, `:93-100` |
| Connect attempt | `client.connect(timeout=BLEAK_TIMEOUT)` with `BLEAK_TIMEOUT = 20.0`, inside `asyncio_timeout(BLEAK_SAFETY_TIMEOUT)` with `BLEAK_SAFETY_TIMEOUT = 60.0`. Service discovery runs **inside** connect (`B-CL:142`), so it falls under the 60 s safety timeout | `BRC:102`, `:113`, `:468`, `:475` |
| On connect timeout | `cancelPeripheralConnection_` and await the disconnect | `B-CM:168-180` |
| Attempts | keep going while `timeouts + connect_errors < max_attempts and transient_errors < MAX_TRANSIENT_ERRORS`. Upstream passes `max_attempts=3`, and `MAX_TRANSIENT_ERRORS = 9` | `BRC:418-419`, `BT:252`, `BRC:94` |
| Backoff | 0.25 s after a timeout (`BLEAK_DBUS_BACKOFF_TIME`), 4.0 s after not-found, 0.1 s default | `BRC:327-330`, `:336-337`, `:350`, `:51-60` |
| Exhausted | a timeout becomes `BleakNotFoundError`. Either way it is a `BleakError` subclass, which the device layer treats as "fall back to cloud" | `BRC:427-440` (`raise BleakNotFoundError(msg)` at `:428`, `BleakConnectionError` at `:440`) |
| Read | 20 s timeout (`timeout: int = 20`) | `B-PD:166-186` |
| Write with response | **no timeout** (`await future`) | `B-PD:205-228` |
| Start/stop notify | **no timeout**. A second start raises `ValueError("Characteristic notifications already started")` | `B-PD:241-278`, `:249` |
| Discover services/characteristics/descriptors | **no timeout** (bounded only by the 60 s safety timeout during connect) | `B-PD:121-162` |

**Recommended Swift values.** These are named constants, overridable through a
`…ForTesting` hook in the house style
(`LaMarzoccoCloudClient.swift:459` `setWebSocketTimingForTesting`).

| Constant | Value | Rationale |
|---|---|---|
| `poweredOnWait` | 10 s | bleak's 1 s is tuned for a process that already has permission. First use may sit at `.unknown` while the TCC prompt is up (**UNVERIFIED**; measure on hardware). |
| `connectTimeout` | 20 s per attempt, then `cancelPeripheralConnection` | `BRC:102`, `B-CM:168-180` |
| `connectAttempts` | 3, backoff 0.25 s after a timeout, 0.1 s otherwise | `BT:252`, `BRC:327-330`, `BRC:350` |
| `opTimeout` (read, write, notify, each discovery step) | 20 s | Matches the read timeout (`B-PD:170`). Writes, notify and discovery have none upstream, but CoreBluetooth gives no guarantee a lost reply will ever surface as an error before the link drops. A bounded wait is a deliberate, documented **divergence**. |
| `disconnectWait` | 5 s, then treat the link as gone | `BRC-C:8` `DISCONNECT_TIMEOUT = 5` |
| `scanDuration` | 5 s | `BLEAK:220` |

**Timeouts vs cancellation in upstream's error taxonomy.** These must stay distinguishable.

- A **connect-phase** failure, timeouts included, surfaces as a `BleakError` or
  `BluetoothConnectionFailed`.
- A timeout **during auth** is wrapped as `BluetoothConnectionFailed` (`BT:649-652`).
- A timeout on a **request-phase** read propagates as a bare `TimeoutError`.
  `disconnect_on_exception` catches it only to drop the link, then re-raises (`BT:129-134`).
  Per note 03 (TL;DR item 3), the device layer does **not** fall back to the cloud on a
  `TimeoutError`.

The Swift error mapping (§5.3) therefore needs a separate "timed out" case.

### 2.5 MTU, long writes, long reads

- Upstream contains **no MTU logic** (note 01 §6, `grep -i mtu` is empty) and never calls
  `mtu_size`.
- CoreBluetooth negotiates the ATT MTU itself. An app **cannot request** an MTU (no API in
  `SDK/CBPeripheral.h`). The only window is `maximumWriteValueLength(for:)`
  (`SDK/CBPeripheral.h:188`). bleak computes MTU as `.withoutResponse` value + 3
  (`B-CL:176-187`).
- **Writes.** The longest upstream write is 90 bytes (note 01 §6.3). That is larger than 20
  bytes, the payload under the default ATT MTU of 23. Behaviour I rely on but could not
  confirm locally (**UNVERIFIED**, Apple documentation and experience, not headers):
  - `.withResponse` writes longer than MTU−3 are carried by the system as a long write
    (Prepare Write / Execute Write).
  - `maximumWriteValueLength(.withResponse)` reports 512.
  
  Whether the machine's ESP32 GATT server accepts Prepare Write is **UNVERIFIED**. If
  Apple's negotiated MTU is ≥ 93, no long write ever happens. The sketch's `write` guards
  `data.count <= maximumWriteValueLength(.withResponse)` and throws `valueTooLong` instead
  of silently truncating.
- **Reads.** The system issues Read Blob requests for values longer than MTU−1
  (**UNVERIFIED**, same caveat). The largest read vector is 201 bytes of capabilities
  (note 01). Do not chunk reads manually.

### 2.6 Notifications: framing, routing, chunking

- **One notification is one complete JSON object** to upstream: `json.loads(bytes(data).strip(b"\x00"))`
  (`BT:452`), with no reassembly. The largest real notification is 418 bytes
  (note 02 §1, fixture `tests/fixtures/machine/shot_counter_2026-10-05.txt:23`). So
  the capture link had an ATT MTU of at least 421.
  - CoreBluetooth delivers one `didUpdateValueFor` per ATT notification and **does not
    reassemble**.
  - **If Apple's negotiated MTU is below 421, that telemetry frame cannot arrive whole.**
    Whether the firmware then truncates, splits, or drops it is **UNVERIFIED**.
  - This is the top hardware risk for the telemetry half of the shot counter. Brewing events
    are much smaller.
  - Recommendation: keep upstream's parse-or-drop behaviour (parity). Log the observed MTU
    (`maximumWriteValueLength(.withoutResponse) + 3`) and any parse failure through the
    diagnostics tap, so a hardware run can settle it.
- **Reads and notifications share one callback** (`SDK/CBPeripheral.h:394`). bleak routes a
  value to a pending read future if one exists, else to the notify callback
  (`B-PD:398-440`). It warns about the ambiguity when both are possible.
  - Upstream never reads the shot-counter characteristic, so the routing is unambiguous.
  - The adapter routes to a pending read first, **including a read that timed out and still
    owes a reply**. Only otherwise does it route to the notification stream. The seam
    documents "never `read` a characteristic you are subscribed to".
- **Replay on subscribe.** The machine "first replays its last notification, which can be
  hours old" (`BT:429-431`). Upstream sets `_replay_pending = True` **before**
  `start_notify` (`BT:431-434`), because the replay can arrive before the subscribe call
  returns.
  - The adapter must therefore start routing notifications to the link's event stream
    **before** calling `setNotifyValue(true, …)`.
  - The protocol layer must set its replay flag before awaiting `subscribe`.
  - Both are done in the sketch. The test `firstNotificationAfterSubscribeIsDropped` covers
    it (Appendix E).
- **Timestamp.** Upstream takes `received_at = _utcnow()` first, even before the replay
  check (`BT:445`). The adapter stamps `receivedAt` inside the delegate callback, so actor
  hops can't skew brewing-start maths. The clock is injected.
- **Buffering.** Use `AsyncStream` with `.unbounded` buffering for link events (sketch). A
  notification every few hundred ms cannot grow the buffer meaningfully, and dropping one
  would break the brewing state machine.

### 2.7 Disconnects and Bluetooth state changes

- `didDisconnectPeripheral` (`SDK/CBCentralManager.h:348`) is final for that peripheral's
  delegate (`:343-345`). The adapter then fails every pending op for that peripheral, yields
  `.disconnected(error)`, and finishes the stream. Error codes come from `CBError`
  (`SDK/CBError.h:27-50`; e.g. `CBErrorPeripheralDisconnected = 7`,
  `CBErrorConnectionTimeout = 6`, `CBErrorConnectionFailed = 10`).
- A state change below `.poweredOn` disconnects everything (`SDK/CBCentralManager.h:264-268`).
  Whether `didDisconnectPeripheral` is still delivered in that case is **UNVERIFIED**, so
  the adapter synthesizes the disconnect itself. A guard makes it fire at most once per link.
- **Stale-link guard.** Upstream ignores a disconnect callback from an old client
  (`client is not self._client`, `BT:469-470`). It also detaches before disconnecting, "so
  bleak doesn't report this as a lost connection" (`BT:303-304`). The seam returns a **new
  `BluetoothLink` object per connection**, and the session compares by identity (`===`).
  Test: `staleLinkEventsAreIgnored`.
- `peripheral(_:didModifyServices:)` (`SDK/CBPeripheral.h:326`): "the designated CBService
  objects have been invalidated". The legacy GATT dump shows the Service Changed
  characteristic (`2a05`, indicate) is present (`LEG:6-8`), so this can happen. The adapter
  drops its characteristic table and yields `.servicesInvalidated`. The protocol layer then
  rediscovers before the next op.
- **`CBConnectPeripheralOptionEnableAutoReconnect`** is available exactly at our floors,
  `NS_AVAILABLE(14_0, 17_0)` (`SDK/CBCentralManagerConstants.h:212-222`). It comes with
  `didDisconnectPeripheral:timestamp:isReconnecting:error:` (`SDK/CBCentralManager.h:367`).
  **Do not use it in v1.** Upstream's reconnect loop re-authenticates on every connection
  (`BT:256`) and backs off on its own schedule (`BT:488-520`). A system-initiated reconnect
  would bring the link up unauthenticated, outside that state machine. Revisit after
  hardware testing.

### 2.8 Pairing and bonding

- Upstream does no OS-level pairing. Auth is application-level: write the token to the
  AUTH characteristic, then poll for `0x01` (`BT:628-653`). The "pairing mode" in
  `read_token` (`BT:539-547`, `README:100-116`) is a **machine** mode in which the GET_TOKEN
  characteristic becomes readable. It is not BLE bonding (an inference: nothing in source
  requests encryption).
- CoreBluetooth cannot pair explicitly (bleak: `B-CL:190-205`). Pairing happens implicitly
  if a characteristic requires encryption (ATT errors `CBATTErrorInsufficientAuthentication = 0x05`,
  `CBATTErrorInsufficientEncryption = 0x0F`, `SDK/CBError.h:60`, `:70`). The OS then shows
  its own pairing UI.
- The legacy dump shows no encryption-required properties (`LEG:10-16`). Whether current
  firmware ever triggers an OS pairing dialog is **UNVERIFIED** (hardware: watch for a
  system pairing alert, and check System Settings › Bluetooth for a bonded entry after
  first use).
- If the read in `read_token` fails with ATT `0x02` (`ReadNotPermitted`) or `0x05`/`0x0F`
  outside pairing mode, map it to a clear "machine not in pairing mode" error. Upstream
  surfaces a raw `BleakError`.

### 2.9 Single central per machine

The README warns of "a free, persistent Bluetooth connection slot (the machine likely
accepts only one central at a time)" (`README:231`). This is a product constraint on
Apple: while Pronto holds the shot-counter connection, the user's phone app (official or
Pronto-iOS) probably cannot connect, and vice versa. Connect failures will look like
`didFailToConnect` or a 20 s timeout. The **UNVERIFIED** part: which `CBError` code
appears, and whether the machine advertises at all while connected (hardware check §9).

---

## 3. Swift 6 concurrency design

### 3.1 Facts established by compiling probes

| Fact | Evidence |
|---|---|
| `CBPeripheral`, `CBCentralManager`, `CBCharacteristic`, `CBUUID` do **not** conform to `Sendable`. `CBManagerState`, `CBManagerAuthorization` and `CBError.Code` do (enums) | `probes/p3.swift`: `type 'CBPeripheral' does not conform to the 'Sendable' protocol` (likewise for the others). CoreBluetooth headers have no `NS_SWIFT_SENDABLE` or Swift concurrency annotations at all; the apinotes contain only error-domain mappings (`SDK/CoreBluetooth.apinotes`, 7 lines, same Headers directory). |
| Delegate protocol requirements are **nonisolated** | `probes/p2_executor.swift`: a `@BluetoothActor` class conforming without an isolated conformance fails with "global actor 'BluetoothActor'-isolated instance method … cannot satisfy nonisolated requirement". |
| Passing or returning CB objects across isolation is a **region-isolation error, but only at SIL time** | `probes/p4.swift`: `-typecheck` exits 0 with no diagnostics. `-emit-sil` reports `sending 'p' risks causing data races` and `non-Sendable 'CBPeripheral?'-typed result can not be returned from actor-isolated instance method 'get()' to nonisolated context`. **Implication:** editors and `-typecheck`-based linters will not flag these. Only a real `swift build` will. CI's `swift build` is sufficient. |
| `@preconcurrency import CoreBluetooth` is **not needed** | the full adapter (Appendix B) builds warning-free without it. Do not add it: it would downgrade exactly the diagnostics above to warnings. |
| `DispatchSerialQueue` is a `SerialExecutor` from macOS 14 / iOS 17 | `DISP:186-187` `@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) extension Dispatch::_DispatchSerialExecutorQueue : _Concurrency::SerialExecutor`. Its `checkIsolated()` is `dispatchPrecondition(condition: .onQueue(self))` (`DISP:190-192`). |
| `SerialExecutor.checkIsolated()` requirement is macOS 15 / iOS 18 | `CONC:1985-1986` `@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) func checkIsolated()` |
| `Mutex` is macOS 15+, `OSAllocatedUnfairLock` macOS 13+ | `SYNC:7838-7839`, `OSI:2394-2395`. Use `OSAllocatedUnfairLock` or `NSLock`. The house uses `NSLock` (`WebSocket.swift:56`). |
| Isolated conformances (`@MainActor CBCentralManagerDelegate`, `@BluetoothActor CBCentralManagerDelegate`) compile with Swift 6.4.2 for macOS 14 / iOS 17 | `probes/p2_executor.swift` (`Del3`), `probes/p5_main.swift` (`MainCentral2`). They are an SE-0470 feature (Swift 6.2+). The package's `swift-tools-version: 6.0` floor would not accept them on an older compiler (**UNVERIFIED**, no older toolchain here). |

### 3.2 Requirements the design must meet

- **R1. No CB object crosses an isolation boundary.** Only `Data`, `String`, UUIDs and
  enums cross (`Sendable` values).
- **R2. Delegate callbacks are handled synchronously, in order, on the CB queue.** ATT
  replies must be matched to requests, and a disconnect must fail the requests that
  preceded it. **Any `Task { await actor.handle(…) }` hop from a delegate callback gives up
  ordering.** It is the most common bug in Swift BLE code.
- **R3. Exactly-once resume** of every continuation across delegate reply, timeout,
  cancellation and disconnect.
- **R4. Owed replies.** An ATT request abandoned by timeout or cancellation still gets
  exactly one reply (or the link drops). That reply must be swallowed, not delivered to the
  next request with the same (peripheral, characteristic) key. bleak deletes the future and
  logs "Unexpected event" (`B-PD:433-439`); here the late reply must also not resolve a
  *newer* future.
- **R5. Works on the macOS 14 / iOS 17 runtime**, with no APIs or runtime checks from
  macOS 15 / iOS 18.
- **R6. Testable without CoreBluetooth** (§4).

### 3.3 Options compared

| | A. Serial queue + delegate object + continuations, wrapped by a protocol-logic actor **(recommended)** | B. Actor with a `DispatchSerialQueue` custom executor, the same queue given to `CBCentralManager` | C. Ad-hoc `@unchecked Sendable` boxes and locks around CB objects | D. Main-actor delegate (`queue: nil`, the main queue) |
|---|---|---|---|---|
| How callbacks enter | Run directly on the private queue that owns all state. No isolation hop. | Arrive on the actor's queue, but as plain GCD blocks, not Swift jobs. Entering the actor needs `assumeIsolated` (or an isolated conformance, which inserts the same dynamic check). | Any thread. Locks per field. | Main thread. `MainActor.assumeIsolated` works on every OS version (main-thread check). |
| R1 | Enforced by structure: CB objects are `private` and only touched in `queue` blocks | Enforced by the compiler | Not enforced. Easy to leak `CBPeripheral` | Enforced by the compiler |
| R2 ordering | Yes, a serial queue | Yes, but only if callbacks enter synchronously | Fragile | Yes |
| R5 macOS 14 / iOS 17 | Yes. Verified to compile. Uses only `OSAllocatedUnfairLock` (13+) and basic concurrency | **No / risky.** Entering a custom-executor actor from a raw GCD callback relies on `checkIsolated()`, which is macOS 15 / iOS 18 (`CONC:1985-1986`). On the 14/17 runtime I expect the isolation check to fail and trap (**UNVERIFIED**; verify by running `probes/p2_executor.swift`'s `D` path on a macOS 14 machine). Isolated conformances also need Swift ≥ 6.2. | Yes | Yes |
| Main-thread load | none | none | none | All BLE traffic on the main thread. Acceptable for this traffic volume, but it couples the core to the main actor and to `angcli`'s main-queue servicing. |
| Testability | Adapter behind the seam; logic actor fully faked | Same | Hard | Same as A |
| Compiler help | `@unchecked Sendable` on two adapter classes, justified by queue confinement and asserted with `dispatchPrecondition` | Best | None | Good |

**Recommendation: A.** It is the only option that satisfies R1 to R5 on the deployment
floors without APIs from newer OS versions, and its unsafety is confined to two adapter
classes. It also matches the house pattern. `URLSessionWebSocketChannel` is a
`final class …: WebSocketChannel, @unchecked Sendable` wrapping a non-Sendable framework
object, with a `ResumeOnce` latch against double resume (`WebSocket.swift:17-64`).

**When to revisit B.** If the deployment floor rises to macOS 15 / iOS 18, B becomes
viable and removes the `@unchecked`. Keep the seam unchanged so the swap stays local to
the adapter.

### 3.4 Architecture (layers)

```
 AngstromUI (LaMarzoccoMachine, @MainActor @Observable)       ← BT-first commands, shot-counter overlay (notes 02/03)
        │ async calls / AsyncStream
 Angstrom: LaMarzoccoBluetoothClient (public actor)           ← ALL protocol logic: locks, connect+retry, auth poll,
        │  package protocols                                    framing, idle timer, shot counter, reconnect, errors
        ▼
   BluetoothCentral / BluetoothLink / BluetoothSleeper        ← the seam (package access); fakes in tests
        ▲
 AngstromBluetooth: CoreBluetoothCentral / CoreBluetoothLink  ← ONLY CoreBluetooth code; serial queue; op table
        │ delegate callbacks on the private serial queue
   CBCentralManager / CBPeripheral
```

### 3.5 How the adapter works (sketch, full code in Appendix B)

**Op table.** Queue-confined, not thread-safe. Each entry is `(token, OpKey, completion)`.

- `OpKey` is `.connect(UUID)`, `.disconnect(UUID)`, `.discoverServices(UUID)`,
  `.discoverCharacteristics(UUID, service)`, `.read(UUID, char)`, `.write(UUID, char)`,
  `.notify(UUID, char)`, or `.poweredOn`.
- Delegate callbacks identify their op only by key, so ops with the same key resolve
  **FIFO**. CoreBluetooth queues same-characteristic requests and answers them in order.
  Upstream's request lock means at most one is in flight anyway.

**Exactly-once (R3).** Every completion path calls `OpTable.finish(token, …)`. `finish`
removes the entry first, then resumes. All paths run on the serial queue, so only the
first `finish` finds the entry; the rest are no-ops. That covers the delegate reply, the
`asyncAfter` timeout, the cancellation handler (dispatched onto the queue) and the
disconnect fan-out (`failAll`).

**Owed replies (R4).** When `finish` resolves an ATT op by **abandoning** it (timeout or
cancel), it increments `orphans[key]`. The next delegate reply for that key decrements the
count and is swallowed (`finishOldest`). `failAll` on disconnect clears the debts.
`owe(key)` records a debt for a request nobody awaits: `unsubscribe` sends
`setNotifyValue(false)` best-effort, mirroring `suppress(Exception)` at `BT:399-400`.

**Cancellation before registration.** `withTaskCancellationHandler`'s `onCancel` can run
before the queue block registers the op. A small `OSAllocatedUnfairLock<CancelBox>` holds
`cancelled` and `token`:

- The queue block checks `cancelled` and, if set, resumes with `CancellationError` without
  starting the op.
- `onCancel` sets `cancelled` and, if a token exists, dispatches `finish(token, CancellationError, abandoning: true)`
  onto the queue.

```swift
// condensed from Appendix B — CoreBluetoothCentral.perform
func perform<T: Sendable>(_ key: OpKey, timeout: Duration?, onTimeout: (@Sendable () -> Void)? = nil,
                          start: @escaping @Sendable () throws -> Void) async throws -> T {
    let box = OSAllocatedUnfairLock(initialState: CancelBox())
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
            queue.async {
                self.nextToken += 1; let token = self.nextToken
                let proceed = box.withLock { state -> Bool in        // onCancel may already have run
                    if state.cancelled { return false }
                    state.token = token
                    return true
                }
                guard proceed else { cont.resume(throwing: CancellationError()); return }
                self.ops.register(token, key: key) { result in /* resume cont exactly once */ }
                do { try start() } catch { self.ops.finish(token, .failure(error), abandoning: false); return }
                if let timeout {
                    self.queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                        if self.ops.finish(token, .failure(BluetoothTransportError.timedOut("\(key)")), abandoning: true) {
                            onTimeout?()   // connect: cancelPeripheralConnection (CB connects never time out)
                        }
                    }
                }
            }
        }
    } onCancel: {
        if let token = box.withLock({ s -> UInt64? in s.cancelled = true; return s.token }) {
            self.queue.async { self.ops.finish(token, .failure(CancellationError()), abandoning: true) }
        }
    }
}
```

**The six operations.** All of these are in Appendix B.

| Op | Start (on the queue) | Resolved by |
|---|---|---|
| connect | `requirePoweredOn()`, then `known[uuid] ?? retrievePeripherals(withIdentifiers:)`, then `connect(p, options: nil)`. Timeout calls `cancelPeripheralConnection`. | `didConnect`: creates a **new** `CoreBluetoothLink` and sets `peripheral.delegate = link`. If nobody is waiting any more (late connect after a timeout), it cancels the connection. `didFailToConnect` fails the op. |
| discover | `discoverServices(nil)`, then per service `discoverCharacteristics(wanted, for:)`. `refresh: false` returns the cached table if it already holds everything wanted | `didDiscoverServices`, `didDiscoverCharacteristicsFor` |
| read | `readValue(for:)` | `didUpdateValueFor` when a read is pending or owed |
| write (with response) | length guard against `maximumWriteValueLength(.withResponse)`, then `writeValue(_:for:type: .withResponse)` | `didWriteValueFor` |
| notify | `notifying.insert(char)` **before** `setNotifyValue(true, …)` | `didUpdateNotificationStateFor`; later values go to `events` as `.notification` |
| disconnect | `cancelPeripheralConnection`, bounded at 5 s | `didDisconnectPeripheral`, which then fails all pending ops, yields `.disconnected`, and finishes the stream |

**Lazy manager.** The adapter allocates `CBCentralManager` on first use, with
`CBCentralManagerOptionShowPowerAlertKey: false` (`SDK/CBCentralManagerConstants.h:24`).
Consumers can opt in via `coreBluetooth(showPowerAlert:)`. Allocation is what can trigger
the TCC prompt (§5.2), so a cloud-only session never prompts.

### 3.6 Protocol-logic actor (sketch, full code in Appendix C)

**Two explicit FIFO gates.** These are not `asyncio.Lock` ports via semaphores. They are
actor-isolated continuation queues.

- Upstream has `_lock` (connect/disconnect) and `_request_lock` (atomic write→read pairs)
  (`BT:162-163`, `:126-128`).
- Actor re-entrancy at every `await` means `actor` alone does **not** provide that
  atomicity. Test: `requestsAreSerialized`.
- Lock order is request, then connection, as upstream does (`BT:127` then `BT:235`).

**`ensureConnected`** does connect + retry, discover, then authenticate. On **any** error,
cancellation included, it disconnects the new link ("never keep an unauthenticated link",
`BT:257-264`). On success it starts a single watcher task that drains `link.events`
sequentially into the actor. That preserves order: one consumer, sequential `await`s.

**`connectWithRetry`** fails fast on a non-`poweredOn` availability. Upstream on macOS
burns its attempts on `BleakError("BLE is not authorized…")` (`B-CM:97`, an improvement
that's explicitly parity-neutral). Otherwise it retries up to 3 times with the bleak
backoffs.

**`request`** implements `disconnect_on_exception` (`BT:114-136`): on error, drop the link
unless the shot counter is active and connected.

**`startShotCounter`** sets `replayPending = true` **before** `subscribe`, and drops the
first notification. That matches `BT:431-434` and `BT:446-449`.

### 3.7 Things the sketch deliberately leaves to the plan

- The idle timer (`IDLE_TIMEOUT = 30`, `BT:47`, `BT:271-291`), the shot-counter reconnect
  loop (`BT:488-520`), `_BrewingTracker` (`BT:77-111`), connection callbacks (`BT:188-214`)
  and the services-cache retry (`BT:405-427`). These are pure protocol logic covered by
  notes 01 and 02. They all go through `BluetoothSleeper` (tagged `.idleDisconnect` and
  `.reconnectBackoff`) and are fakeable.
- Mapping `BluetoothSessionError` and `BluetoothTransportError` into `LaMarzoccoError`
  (§5.3).
- The adapter's **scan-by-identifier fallback** when `retrievePeripherals` returns empty.
  The sketch throws `unknownPeripheral`. bleak scans for up to 10 s (`B-CL:101-110`,
  `BLEAK:299`).
- Verifying the sketch with the **Swift 6.0** compiler (the package floor) and with
  whatever Xcode the `macos-15` CI runner selects (`.github/workflows/ci.yml:16-27`). It
  uses only Swift 5.9/6.0-era features (`package` access, `withTaskCancellationHandler`,
  `AsyncStream.makeStream`, `OSAllocatedUnfairLock`), but this is **UNVERIFIED** here.
- **Apple-specific improvement (flag as a divergence).** When the central returns to
  `.poweredOn` (wake from sleep, Bluetooth toggled), cut the reconnect backoff short.
  Otherwise upstream's doubling backoff, capped at 60 s (`BT:490-511`), can leave the shot
  counter dark for up to a minute after the Mac wakes. This should be a seam event
  (`BluetoothCentral.availabilityChanges()`). The sketch doesn't have it yet.

---

## 4. The testability seam

### 4.1 Shape (copied from Appendix A, which compiles)

```swift
package protocol BluetoothCentral: Sendable {
    func availability() async -> BluetoothAvailability
    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral]
    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink
}

package protocol BluetoothLink: AnyObject, Sendable {
    var peripheralID: BluetoothPeripheralID { get }
    var events: AsyncStream<LinkEvent> { get }      // .notification / .servicesInvalidated / .disconnected (terminal)
    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID>
    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data
    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws
    func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws
    func unsubscribe(_ characteristic: GATTUUID) async
    func disconnect() async
}

package protocol BluetoothSleeper: Sendable {
    func sleep(for duration: Duration, purpose: SleepPurpose) async throws   // .authPoll/.connectBackoff/.idleDisconnect/.reconnectBackoff
}

public struct BluetoothTransport: Sendable {           // public opaque handle; package init
    package let central: any BluetoothCentral
    package let sleeper: any BluetoothSleeper
    package let now: @Sendable () -> Date
}
```

### 4.2 Why each member exists

| Member | Upstream behaviour it carries |
|---|---|
| `availability()` | bleak's state checks (`B-CM:93-100`), and the fail-fast on unauthorized or off |
| `scan(for:)` | `discover_devices` (`BT:522-537`). The prefix filter `BT:534` stays above the seam, so it is tested. |
| `connect(to:timeout:)`, **one attempt** | `establish_connection`'s loop (`BRC:398-588`) is protocol logic above the seam, so attempt counting and backoff are tested |
| a new `BluetoothLink` object per connection | the stale-client guard (`BT:469-470`) and detach-before-disconnect (`BT:303-304`) |
| `events` (single ordered stream) | `disconnected_callback` (`BT:251`), `start_notify` callbacks (`BT:432-434`), and the services-changed indication (`LEG:7`) |
| `discover(_:refresh:timeout:)` | `services.get_characteristic` + `clear_cache` (`BT:712-747`, `BT:405-427`), as "which of these UUIDs exist, optionally after rediscovery" |
| `read` / `write(withResponse:)` | `read_gatt_char` / `write_gatt_char(response=True)` |
| `subscribe` / `unsubscribe` (best-effort, non-throwing) | `start_notify` / `stop_notify` in `suppress(Exception)` (`BT:396-401`) |
| `disconnect()` | `client.disconnect()` (`BT:308`) |
| `BluetoothSleeper` tagged by purpose | upstream tests patch `AUTH_READ_INTERVAL` and `RECONNECT_INITIAL_DELAY` to 0 and drive the idle timer by hand (note 04: `TBC:112,152`). Tags let a test fire only the idle timer. |
| `now` | `_utcnow()` (`BT:57-59`) for `received_at` and brewing start times. Mirrors `setClockForTesting` (`LaMarzoccoCloudClient.swift:298`). |

**Access level.** The protocols are `package`. That keeps them out of public API
(semver), exactly like the internal `WebSocketChannel`. It still lets the
`AngstromBluetooth` target implement them, and lets tests fake them via `@testable import`.
The public surface is `BluetoothTransport` (opaque), plus
`BluetoothTransport.coreBluetooth(showPowerAlert:)` from the leaf module. Verified in
`layout/` and `btsketch/`.

### 4.3 What the fake must be able to script

The scratch fake (Appendix D) implements the rows marked ✔. The rest are needed for the
full upstream test matrix in note 04.

| Scriptable | Why (upstream behaviour / test) | In sketch |
|---|---|---|
| availability (`poweredOn`, `poweredOff`, `unauthorized(.denied)`, …) and **changes over time** | fail-fast, reconnect-on-poweredOn | ✔ static; changes TODO |
| scan results (name, id, rssi) | the prefix filter `BT:534` (`MICRA`/`MINI`/`LINEA`/`GS3`, names without a prefix, `nil` name) | ✔ |
| per-attempt connect outcome: success(link), `.timedOut`, `.disconnected`, `.gatt`, `unknownPeripheral` | retry count `max_attempts=3`, backoff values | ✔ |
| which characteristics exist, and **different answers with `refresh: true`** | the stale-cache path (`BT:418-427`: missing, then `clear_cache`, then reconnect, then present) | ✔ present; refresh-dependent TODO |
| a read responder per characteristic, **stateful** (auth: `0x00` n times, then `0x01`; wrong token always `0x00`) | `TBT:617-649` (10 reads on reject, success on the 3rd read) | ✔ (`FakeLink.laMarzocco(token:confirmOnRead:)`) |
| a write responder: ack, or throw (`.gatt`, `.timedOut`, `.notConnected`) | `disconnect_on_exception` paths (`BT:129-134`), auth transport failure (`BT:649-652`) | ✔ |
| **holding an op in flight** (`beforeOp` hook + `Gate`) | request serialization (`BT:126-128`), cancellation, the idle timer firing mid-request | ✔ |
| notifications on demand with an explicit `receivedAt` | brewing-start maths (note 02), telemetry | ✔ |
| replay-on-subscribe (emitted before `subscribe` returns) | `BT:429-431`, `BT:446-449` | ✔ |
| link drop with or without an error, at any point, and late events from an old link | `_on_bleak_disconnected`, the stale guard, reconnect | ✔ |
| `.servicesInvalidated` | `didModifyServices` | TODO (event exists) |
| a full op log (connect, discover(refresh), read, write(bytes), subscribe, unsubscribe, disconnect) | byte-exact assertions like `TBT:304`, `:319`, `:333` (`b'{"name":"MachineChangeMode",…}\x00'`) | ✔ (`FakeOp`) |
| a recording sleeper that returns immediately, and a **manually fired** sleeper per purpose | auth-poll count (9 sleeps max), backoff sequence 1, 2, 4 … 60 (`BT:490-511`), the idle timer | ✔ recording; manual-fire TODO |
| an injected clock | `received_at`, the 60 s brewing-state timeout (note 02) | ✔ (`BluetoothTransport.now`) |

### 4.4 Tests the sketch already passes (`swift test`, 9/9)

`authSucceedsAfterPolling`, `authFailsAfterTenReadsAndDropsLink`,
`commandFramingIsJSONPlusNUL`, `requestsAreSerialized`, `reconnectsAfterLinkDrop`,
`connectRetriesThreeTimesThenFails`, `unavailableFailsFastWithoutConnecting`,
`firstNotificationAfterSubscribeIsDropped`, `staleLinkEventsAreIgnored` (Appendix E).
They use Swift Testing (`import Testing`). Angstrom's existing tests are XCTest
(`Tests/AngstromTests/*.swift`). Either works; follow the repo.

### 4.5 What stays untestable in CI, and how to cover it

- Only `CoreBluetoothCentral` and `CoreBluetoothLink` remain untested.
- **Never instantiate `CBCentralManager` in CI.** A headless `macos-15` runner has no
  Bluetooth permission and possibly no radio. Creating a manager may prompt, report
  `.unsupported` or `.unauthorized`, or hang. That outcome is **UNVERIFIED**, and it
  doesn't matter: just don't do it.
- Give `AngstromBluetooth` a **compile-only** test target, or none at all.
- The `OpTable` (pure Swift, no CB) **can** be unit-tested if it is moved to the core
  target, or into a small CB-free file in the leaf target. Tests should cover finish-once,
  orphans, FIFO and `failAll`. This is recommended: the table is the subtle part.
- Cover the adapter itself with the hardware checklist (§9), plus an opt-in manual
  integration command in `angcli` (`angcli bt probe`, §5.5).

---

## 5. Authorization, errors and packaging

### 5.1 State machine (`SDK/CBManager.h:32-39`, `:62-67`, `:86`)

`CBManagerState`: `Unknown = 0` ("update imminent"), `Resetting` ("momentarily lost,
update imminent"), `Unsupported`, `Unauthorized`, `PoweredOff`, `PoweredOn`.
`CBManagerAuthorization`: `NotDetermined = 0`, `Restricted`, `Denied`, `AllowedAlways`.

| `state` | `authorization` | Library behaviour | Error (proposal, §5.3) | Cloud fallback? |
|---|---|---|---|---|
| `.unknown`, `.resetting` | any | wait for `centralManagerDidUpdateState` up to `poweredOnWait` (10 s) | on timeout: `.bluetoothUnavailable(.unknown/.resetting)` | yes |
| `.poweredOn` | `.allowedAlways` | proceed | n/a | n/a |
| `.poweredOff` | any | fail fast. Reconnect loops **pause** (no backoff growth, no auth-failure count) and resume on `.poweredOn` | `.bluetoothUnavailable(.poweredOff)` | yes |
| `.unauthorized` | `.denied` / `.restricted` | fail fast, permanent until the user changes Settings | `.bluetoothUnavailable(.unauthorized(.denied/.restricted))` | yes |
| `.unauthorized` | `.notDetermined` | prompt pending or not yet shown: wait like `.unknown` | as above on timeout | yes |
| `.unsupported` | any | fail fast, permanent | `.bluetoothUnavailable(.unsupported)` | yes |

Every row maps to a fallback, because bleak raises `BleakError` for unsupported,
unauthorized and powered-off (`B-CM:93-100`). The device layer falls back to the cloud on
`BleakError` (note 03 TL;DR item 3).

### 5.2 When the permission prompt appears

- `CBManager.authorization` is a **class** property. "You can also use it to check
  authorization status before allocating CBManager" (`SDK/CBManager.h:83-86`). Expose it as
  `BluetoothAuthorization.current` (public, no manager allocated) so apps can gate UI.
- Probe: a plain CLI that only reads `CBManager.authorization.rawValue` printed `0`
  (`notDetermined`) on this machine, and allocated no manager.
- Allocating a `CBCentralManager` is what triggers the system prompt (Apple documentation;
  **UNVERIFIED locally**: no prompt was triggered in this session, deliberately). Hence the
  lazy allocation.
- Whether `state` sits at `.unknown` or reports `.unauthorized` while the first-run prompt
  is on screen is **UNVERIFIED** (hardware item H3).

### 5.3 Error mapping into `LaMarzoccoError`

The project rule is that all thrown errors are `LaMarzoccoError` cases (`CLAUDE.md`
conventions). `LaMarzoccoError` is a public, non-frozen enum
(`Sources/Angstrom/Models.swift:191-224`), so adding cases is **source-breaking** for
exhaustive switches. Per the project's versioning convention, that ships as a minor bump.
Add the cases **once**, in a single release. Proposal:

| New case | Upstream counterpart | Raised for |
|---|---|---|
| `bluetoothConnectionFailed(String)` | `BluetoothConnectionFailed` (`EXC:20`) and `BleakError` | connect exhausted, disconnected mid-op, characteristic missing (`BT:745-747`), ATT/CB errors, transport errors during auth (`BT:649-652`) |
| `bluetoothAuthenticationFailed` | `BluetoothAuthenticationFailed(BluetoothConnectionFailed)` (`EXC:46`) | 10 non-`0x01` auth reads (`BT:653`) |
| `bluetoothUnavailable(BluetoothAvailability)` | `BleakError` from `B-CM:93-100` | the §5.1 table |
| `bluetoothTimedOut(String)` | bare `TimeoutError` (`B-PD:170` and `async_timeout`) | request-phase read/write/notify timeouts. **Not** a fallback trigger (note 03). |

Add a helper, `var isBluetoothConnectionFailure: Bool { connectionFailed || authenticationFailed || unavailable }`.
It mirrors Python's `except (BleakError, BluetoothConnectionFailed)`, so the device
layer's fallback rule ports one-to-one. Whether `.bluetoothUnavailable` should instead
fold into `.bluetoothConnectionFailed` is an owner decision (§10).

### 5.4 Info.plist and entitlements (apps)

| Item | Needed by | Source / status |
|---|---|---|
| `NSBluetoothAlwaysUsageDescription` (Info.plist string) | every app or tool that allocates a `CBCentralManager`, on iOS 13+ and on macOS | Apple documentation. The key name is **not** in the local SDK (searched CoreBluetooth, Foundation and UIKit headers), so it is **UNVERIFIED locally**. On iOS a missing key is documented to terminate the app at first CB use. The macOS behaviour without it (crash vs silent deny) is **UNVERIFIED** (hardware item H5). |
| `com.apple.security.device.bluetooth` (entitlement) | **only** App Sandbox apps (macOS) | Apple documentation, not in the local SDK or Xcode resources (searched), so **UNVERIFIED locally**. Pronto is not sandboxed: `make-app.sh` signs with no `--entitlements` (`$PRONTO/make-app.sh:153-173`). |
| Hardened runtime | Pronto's Developer ID builds use `--options runtime --timestamp` (`make-app.sh:155-161`) | To my knowledge the hardened-runtime resource-access entitlements (camera, microphone, location, contacts, calendars, photos, Apple Events) do not include Bluetooth, so **no extra entitlement** (**UNVERIFIED**; verify by notarizing a build that scans). Notarization doesn't change TCC: the user still gets the prompt. |
| `UIBackgroundModes` → `bluetooth-central` | iOS apps that need BLE while backgrounded | The mode name appears in the headers (`SDK/CBCentralManager.h:176`, `SDK/CBCentralManagerConstants.h:80`). The plist key name is from Apple documentation. |

**Pronto concretely.** Add one line to the `Info.plist` heredoc in
`$PRONTO/make-app.sh:125-143`, e.g.
`<key>NSBluetoothAlwaysUsageDescription</key> <string>Pronto uses Bluetooth to talk to your espresso machine when it's nearby.</string>`.
That needs no entitlement, no sandbox change and no cask change.

Caveat for local dev builds: those are signed with a local self-signed identity
(`make-app.sh:167-172`) or ad-hoc (`make-app.sh:146`). TCC keys grants on the code signature, so expect the
Bluetooth grant to be **re-prompted when the signing identity changes**, and possibly on
every ad-hoc rebuild (**UNVERIFIED**, hardware item H6).

### 5.5 `angcli` (SwiftPM command-line tool)

What I verified locally (scratch `spmplist/` and `plisttest/`):

1. **Embedding works from the manifest.** This builds with Swift 6.4.2, both from the
   package directory and via `swift build --package-path …` from another directory (CI
   uses `--package-path cli`, `.github/workflows/ci.yml:37-41`). The path is resolved
   relative to the package root.

   ```swift
   .executableTarget(
       name: "angcli",
       dependencies: [ … ],
       linkerSettings: [
           .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                         "-Xlinker", "__info_plist", "-Xlinker", "Support/Info.plist"])
       ]
   )
   ```

   `Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription")` returns
   the string. `codesign -dv` shows `Identifier=<CFBundleIdentifier from the plist>` and
   `Info.plist entries=2`.
2. **`unsafeFlags` is acceptable here.** SwiftPM forbids them only in packages consumed as
   dependencies. `cli/` is a root package that nothing depends on
   (`cli/Package.swift:1-9` comments). The library's root `Package.swift` must **never**
   carry this flag.
3. **Signing binds the plist.** A bare `swiftc … -sectcreate` link produces a linker ad-hoc
   signature with `Info.plist=not bound` and `Identifier=<filename>`. After
   `codesign -f -s -` it is `Identifier=example.angcli` and `Info.plist entries=2`. The
   SwiftPM build above already produced the bound form. If `angcli` is ever distributed,
   sign it (Developer ID + hardened runtime) **after** linking.
4. Suggested `Support/Info.plist` keys: `CFBundleIdentifier` (a stable reverse-DNS id),
   `CFBundleName` = `angcli`, `NSBluetoothAlwaysUsageDescription`.

### 5.6 TCC for a CLI run from a terminal (UNVERIFIED, verify on hardware)

- macOS attributes TCC requests from a process launched in a terminal to the **responsible
  process**, normally the terminal app (Terminal, iTerm2, VS Code, …). The expected
  behaviour is a prompt reading "*Terminal* would like to use Bluetooth", with the grant
  recorded for the terminal app. Every CLI run from that terminal then shares it.
- This is how bleak works on macOS from a plain `python` in Terminal.
- Under `ssh` or `launchd` there is no GUI responsible app. Expect `.unauthorized`, or no
  prompt at all.
- Whether `angcli`'s own embedded `NSBluetoothAlwaysUsageDescription` is consulted, or
  only the responsible app's, is **UNVERIFIED**. Embed it regardless: it costs nothing and
  covers the case where the tool is its own responsible process.
- **To verify:** run `angcli bt scan` (proposed) on macOS 14 and 15. Try (a) a fresh
  Terminal, (b) iTerm2, (c) over ssh, (d) a build without the plist. Record the prompt
  text, the System Settings › Privacy & Security › Bluetooth entry that appears,
  `CBManager.authorization`, and whether (d) crashes.

---

## 6. iOS specifics

| Topic | Fact (cited) | What the library should do |
|---|---|---|
| Background scanning | "allowed to scan while backgrounded, with two caveats: the scan must specify one or more service types in serviceUUIDs, and the CBCentralManagerScanOptionAllowDuplicatesKey scan option will be ignored" (`SDK/CBCentralManager.h:176-178`) | Upstream scans with **no** service filter (`BT:532`), and the service UUID is **UNVERIFIED**. The legacy firmware's vendor service is `d30a7847-e12b-09a8-b04b-8e0922a9abab` (`LEG:10`), but its characteristics differ (`030b…`), so don't assume. **Document discovery as foreground-only.** Once a GATT dump confirms the service UUID, add it as an optional filter. |
| Background connection and notifications | the `bluetooth-central` mode (`SDK/CBCentralManagerConstants.h:78-82`) lets the app keep handling CB events while backgrounded. Without it the system can only show alerts on the app's behalf (`CBConnectPeripheralOptionNotifyOnConnectionKey`/`…DisconnectionKey`/`…NotificationKey`, `:87-115`) | Not the library's call. Document that a shot counter that survives backgrounding needs the app to declare `bluetooth-central`. Ensure the session survives suspension: the event stream simply resumes. |
| State restoration | `CBCentralManagerOptionRestoreIdentifierKey` (`SDK/CBCentralManagerConstants.h:26-37`) "must remain the same for subsequent application executions". `centralManager(_:willRestoreState:)` is "the first method invoked when your app is relaunched" (`SDK/CBCentralManager.h:277-292`). Restored peripherals arrive under `CBCentralManagerRestoredStatePeripheralsKey` with "services, characteristics … notification states" (`SDK/CBCentralManagerConstants.h:148-159`) | **Defer**, but keep the door open. Accept `coreBluetooth(restoreIdentifier: String?)`. In `willRestoreState`, retain the restored `CBPeripheral`s into `known`, create links for connected ones, and expose them via a `restoredPeripherals()` stream. Restoration requires the manager to exist at launch, which **conflicts with lazy allocation**: with a restore ID, the app must create the transport in `application(_:didFinishLaunchingWithOptions:)`. |
| Duplicate filtering | default coalesces discoveries. `AllowDuplicatesKey` reports every packet (`SDK/CBCentralManagerConstants.h:51-62`) | Not needed (no RSSI tracking upstream) |
| Media-only access | `CBCentralManagerOptionDeviceAccessForMedia`, `NS_AVAILABLE_IOS(16_0)`, "without prompting the user for Bluetooth generic TCC" (`SDK/CBCentralManagerConstants.h:39-48`) | Not applicable (generic GATT needs the full permission) |
| macOS-unavailable APIs | `registerForConnectionEvents`, `supports(_:)`, `connectionEventDidOccur` are `CB_CM_API_AVAILABLE` = `API_UNAVAILABLE(macos)` (`SDK/CBCentralManagerConstants.h:13`, `SDK/CBCentralManager.h:108`, `:242`, `:379`) | Don't use them. The adapter must compile for both platforms without `#if os` branches in the core paths. |
| What the library should **not** take on | n/a | `UIApplication` lifecycle, background-task assertions, local notifications, the Settings deep-link UI, `NSWorkspace` wake notifications. Expose state (`availability`, `BluetoothAuthorization.current`, connection events) and let apps react. |

Pronto is macOS-only, so all iOS background work is future scope. The adapter compiles for
iOS 17 today (verified build).

---

## 7. Module layout

### 7.1 Facts that decide it

- **The core is already Apple-only.** `Sources/Angstrom` imports `CryptoKit` in two files
  (`grep '^import'`), and CryptoKit isn't on Linux (swift-crypto is a separate module).
  It uses `URLSessionWebSocketTask` (`WebSocket.swift:18-20`) without
  `FoundationNetworking`. `Package.swift` declares only `.macOS(.v14)` and `.iOS(.v17)`.
  So "Linux/server consumers" is not a constraint today. `canImport(CoreBluetooth)` is
  **true on every platform the package supports**, so `#if canImport(CoreBluetooth)` by
  itself buys nothing now.
- **The real cost of CoreBluetooth in the core is linkage.** In the scratch `layout/`
  package, `Core.o` has **no** CoreBluetooth `LC_LINKER_OPTION` autolink entry, and
  `CoreBT.o` does. Any Swift object that references CB symbols makes every app that links
  it link CoreBluetooth.framework. App Store processing has historically flagged binaries
  that reference Bluetooth APIs without `NSBluetoothAlwaysUsageDescription` (ITMS-90683
  style warnings). That makes a purpose string effectively mandatory for **cloud-only**
  iOS consumers (**UNVERIFIED** for the current App Store pipeline; verify by uploading a
  TestFlight build of a cloud-only app linking each layout).
- `AngstromUI`'s `LaMarzoccoMachine` needs the BT client for BT-first commands and the
  shot-counter overlay (note 03). If the BT client lived in a CB-linking module,
  `AngstromUI` would force CoreBluetooth on all its users.

### 7.2 Options

| Option | Layout | Pros | Cons |
|---|---|---|---|
| **1 (recommended)** | Seam, protocol logic, models and errors in **`Angstrom`** (CB-free). CoreBluetooth adapter in a **new leaf target and product `AngstromBluetooth`** (depends on `Angstrom`), exposing only `extension BluetoothTransport { public static func coreBluetooth(…) }`. `AngstromUI` depends only on `Angstrom` and takes an optional `LaMarzoccoBluetoothClient`. | Cloud-only apps never link CB. All logic is tested in `AngstromTests` with fakes. The seam stays `package` (non-public). Apps opt in with one extra `import`. Verified in `layout/` and `btsketch/`. | One more product to document. BT API docs split across two DocC catalogs. A consumer can construct a client but must import the leaf to get a real transport. |
| 2 | Everything in `Angstrom` behind `#if canImport(CoreBluetooth)` | Simplest. One import. | Every consumer links CoreBluetooth (purpose-string exposure). The `#if` does nothing on supported platforms. |
| 3 | Everything BT, logic included, in `AngstromBluetooth` | Core untouched | `AngstromUI` must depend on `AngstromBluetooth` (forcing CB on UI users), or a fourth product `AngstromBluetoothUI` appears. Duplicated error types or a public seam. |
| 4 | Seam in core, adapter in a **separate package** | Strongest isolation | Version skew. The `package`-access seam doesn't work across packages, so it would have to become public API. Overkill. |

**Recommendation: option 1.**
- Products: `Angstrom`, `AngstromUI`, `AngstromBluetooth`.
- Targets: `Angstrom`, `AngstromUI`, `AngstromBluetooth`, plus test targets.
  `AngstromBluetoothTests` should be compile-only or exercise the CB-free `OpTable` (§4.5).
- **DocC:** add a "Bluetooth" article to `Sources/Angstrom/Documentation.docc`. It covers
  the client, errors, identity, packaging requirements and the Pronto recipe, and links to
  the leaf module. Give `AngstromBluetooth` a minimal catalog documenting `coreBluetooth(…)`
  and the platform requirements.
- **`angcli`:** depends on `AngstromBluetooth` (`cli/Package.swift` dependency list), plus
  the plist embedding from §5.5.
- **CI:** no change. `swift build` / `swift test` build the leaf target on macOS without
  instantiating CB.
- Keep `#if canImport(CoreBluetooth)` around the adapter file anyway. It's free hygiene if
  Linux support for the core ever arrives, and the sketch already does it.

---

## 8. Third-party Swift BLE wrappers

**Recommendation: none.** Write the ~500-line adapter (Appendix B is a working start).

1. **Zero runtime dependencies today** (`Package.swift`: only the build-time
   `swift-docc-plugin`). A BLE dependency would be the first runtime dependency of a
   library that Pronto statically links (`make-app.sh:150-151`).
2. **Parity needs the hidden details.** Owed-reply swallowing (R4), notify-before-ack
   routing for the replay (`BT:429-434`), read-vs-notification routing, one ordered event
   stream, our own timeouts and error taxonomy (§2.4, §5.3), and per-connection link
   identity. Wrappers make their own choices on each of these, and they would have to be
   audited anyway.
3. **Swift 6 strict concurrency.** A dependency would have to compile warning-free under
   `swift-tools-version: 6.0` language mode on the macOS 14 / iOS 17 floors, and avoid the
   custom-executor trap (§3.3). Many community wrappers (for example AsyncBluetooth,
   CombineCoreBluetooth, Bluejay, RxBluetoothKit) predate Swift 6 or use
   Combine/Rx/callbacks. I did **not** evaluate any of them in this session (no network
   fetch). Treat their Swift 6 status as **UNVERIFIED**.
4. **Testability is solved by the seam**, not by a wrapper. The fakes sit above our own
   protocol, which a wrapper wouldn't give us.
5. **The surface is tiny:** one central, one peripheral, five characteristics, no
   descriptors, no L2CAP, no peripheral role.

---

## 9. Risks, unknowns and a hardware verification checklist

### 9.1 Risks ranked

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R-1 | Apple-negotiated ATT MTU < 421. The 418-byte telemetry frame (note 02) can't arrive whole, and upstream does no reassembly | Telemetry (boiler temps, statistics) silently missing on Apple | Log MTU and parse failures. If confirmed, a firmware-side issue; report it upstream. Brewing events still work. |
| R-2 | Service UUID unknown | iOS background scanning impossible. `discoverServices(nil)` costs a little more time | GATT dump (H1). Optional scan filter later. |
| R-3 | The machine's single central slot is taken by a phone | Mac connect fails or times out, with UX confusion | Distinguishable error plus docs. Measure the failure signature (H8). |
| R-4 | Custom-executor or isolated-conformance designs trap on macOS 14 / iOS 17 | Crash in the field | Use option A. If B is ever tried, test on a macOS 14 machine first (H11). |
| R-5 | TCC attribution for `angcli`; re-prompts on ad-hoc dev builds | Developer friction | §5.5 plist embedding. Document "grant to your terminal". |
| R-6 | Long write (Prepare Write) unsupported by the firmware while MTU < 93 | 90-byte commands fail | Measured MTU makes it moot or real (H2). |
| R-7 | Mac sleep/wake and Bluetooth toggles leave the shot counter dark for up to 60 s (upstream backoff) | Missed shots | Reconnect immediately on `.poweredOn` (§3.7, a divergence). |
| R-8 | App Nap or timer coalescing for an `LSUIElement` menu-bar app delays the idle and reconnect timers | Late reconnects | **UNVERIFIED.** Measure. If needed, `ProcessInfo.beginActivity` while the shot counter runs (app side). |
| R-9 | `CBPeer.identifier` scope differs between Pronto and `angcli`, or changes after resets | "Unknown peripheral" after reset | Scan-by-identifier fallback, then a user re-pick flow |
| R-10 | Cancellation mid-request (write sent, read cancelled) leaves the machine's response buffer misaligned for the next request | A wrong status is returned | Recommend dropping the link on cancellation inside a request pair. That is stricter than upstream, whose `disconnect_on_exception` doesn't catch `CancelledError` (`BT:129`). Owner decision. |

### 9.2 Hardware verification checklist

Run each item on **macOS 14** (floor), **macOS 15**, the current macOS, and on iOS 17+
where noted. Record raw values in a hardware-findings note. `angcli` should grow a
`bt` subcommand group to drive these: `bt scan`, `bt gatt-dump`, `bt token`, `bt read <setting>`,
`bt cmd <json>`, `bt listen` (shot counter). The tap should log raw bytes in both
directions, like the existing `listen` does for STOMP. Mask the BLE token the way
`bleAuthToken` is masked today (`cli/SPEC.md:106`).

| ID | Check | How | Settles |
|---|---|---|---|
| H1 | **GATT dump**: services, characteristics, properties | `discoverServices(nil)` + `discoverCharacteristics(nil)`; print UUIDs and `properties` (`SDK/CBCharacteristic.h:34-44`) | service UUID (R-2); which chars are read/write/notify; encryption flags |
| H2 | **MTU** | log `maximumWriteValueLength(.withoutResponse)+3` and `(.withResponse)` after connect, on Mac and iPhone | R-1, R-6 |
| H3 | **First-run TCC** | fresh user account or `tccutil reset BluetoothAlways` (service name **UNVERIFIED**), run Pronto. Log `state` and `CBManager.authorization` over time while the prompt is up | the `poweredOnWait` value; the `.unknown` vs `.unauthorized` sequencing (§5.2) |
| H4 | **Denied / restricted / powered off** | deny in Settings; toggle Bluetooth off | the §5.1 mapping; that `didDisconnect` is or isn't delivered on power-off (§2.7) |
| H5 | **Missing usage string** | build Pronto and `angcli` without `NSBluetoothAlwaysUsageDescription` | crash vs silent deny on macOS |
| H6 | **Signing and TCC persistence** | ad-hoc rebuild, then self-signed, then Developer ID | whether grants survive rebuilds |
| H7 | **CLI attribution** | §5.6 matrix (Terminal, iTerm2, ssh, no plist) | R-5 |
| H8 | **Busy machine** | connect from the Mac while the official app or a phone is connected; reverse | R-3 error code and timing; whether the machine still advertises |
| H9 | **Identifier scope** | log `peripheral.identifier` from Pronto and `angcli`, before/after reboot, Bluetooth reset, "Forget device" | R-9 |
| H10 | **Advertised name** | log `peripheral.name` and `kCBAdvDataLocalName`; compare with the cloud serial | correlation (§2.2) |
| H11 | **Runtime isolation trap (only if option B is considered)** | run the custom-executor `assumeIsolated` probe on macOS 14 | R-4 |
| H12 | **Auth timing** | how many 50 ms polls until `0x01` | whether 10 × 50 ms (`BT:50-51`) is enough on Apple |
| H13 | **Replay on subscribe** | observe the first notification after subscribe; does it precede the `didUpdateNotificationStateFor` ack? | the ordering assumption in §2.6 |
| H14 | **Notification sizes** | `bt listen` during a shot and at idle; compare lengths with fixture line 23 (418 bytes) | R-1 |
| H15 | **Long write** | if MTU < 93, send the longest command (90 bytes) | R-6 |
| H16 | **Pairing UI** | watch for an OS pairing alert; check for a bonded entry | §2.8 |
| H17 | **`read_token` in pairing mode** | machine in pairing mode vs not: ATT error code outside pairing mode | the error mapping for `read_token` |
| H18 | **Sleep/wake** | shot counter running; sleep the Mac 5 min; wake; time to resubscribe. Repeat with Bluetooth toggled | R-7 |
| H19 | **App Nap** | menu-bar app idle and hidden for 30 min; is the 30 s idle disconnect late? | R-8 |
| H20 | **`didModifyServices`** | firmware update or reboot of the machine while connected | the `.servicesInvalidated` path |
| H21 | **iOS background** | iPhone app with and without `bluetooth-central`; background during a shot | §6 |

---

## 10. Open questions for the owner

1. Approve **option 1** (logic in `Angstrom`, adapter in a new `AngstromBluetooth`
   product)? It adds a third library product.
2. Error taxonomy (§5.3): four new `LaMarzoccoError` cases (`bluetoothConnectionFailed`,
   `bluetoothAuthenticationFailed`, `bluetoothUnavailable`, `bluetoothTimedOut`), or fold
   `unavailable` into `connectionFailed`? Either way it is one source-breaking minor bump.
3. Accept bounded timeouts on write, notify and discovery (20 s) where upstream has none
   (§2.4)?
4. Accept the Apple-specific divergence of an immediate reconnect on `.poweredOn` (§3.7,
   R-7)?
5. Cancellation inside a write→read pair: drop the link (safer), or mirror upstream
   (R-10)?
6. iOS: foreground-only for v1, with state restoration deferred (§6)?
7. Is a **Pronto** product decision needed on the single-central constraint (R-3) before
   enabling a persistent shot-counter connection by default?

---

## Appendix A: `Seam.swift` (verified: builds in Swift 6 mode for macOS 14 and iOS 17)

Source: `docs/bluetooth/research/06-sketch/btsketch/Sources/BTCore/Seam.swift`

```swift
import Foundation

// MARK: - The seam. Nothing in this file imports CoreBluetooth.
//
// Access levels: types a consumer must hold or persist are `public`; the transport
// protocols are `package`, so the CoreBluetooth adapter target (same package) can
// implement them and tests can fake them, but they are NOT public API — the same
// stance as the internal `WebSocketChannel` seam in Angstrom today.

/// Opaque, persistable identity of a peripheral. On Apple platforms this is the
/// `CBPeer.identifier` UUID (per Apple device + app install), NOT a MAC address.
public struct BluetoothPeripheralID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// A 128-bit GATT UUID, normalised to lowercase so the seam never needs `CBUUID`.
package struct GATTUUID: Hashable, Sendable, CustomStringConvertible {
    package let string: String
    package init(_ string: String) { self.string = string.lowercased() }
    package var description: String { string }
}

/// Mirror of `CBManagerAuthorization` (CBManager.h:62-67).
public enum BluetoothAuthorization: Sendable, Hashable {
    case notDetermined, restricted, denied, allowedAlways
}

/// Mirror of `CBManagerState` (CBManager.h:32-39), carrying the authorization when unauthorized.
public enum BluetoothAvailability: Sendable, Hashable {
    case unknown, resetting, unsupported, unauthorized(BluetoothAuthorization), poweredOff, poweredOn
}

public struct DiscoveredPeripheral: Sendable, Hashable {
    public let id: BluetoothPeripheralID
    /// `CBPeripheral.name` (what bleak's `BLEDevice.name` is on macOS), else the
    /// advertised local name.
    public let name: String?
    public let rssi: Int?
    package init(id: BluetoothPeripheralID, name: String?, rssi: Int?) {
        self.id = id; self.name = name; self.rssi = rssi
    }
}

/// A notification, timestamped where it entered the process (the delegate callback),
/// mirroring upstream's `received_at = _utcnow()` taken first (_bluetooth.py:445).
package struct GATTNotification: Sendable, Hashable {
    package let value: Data
    package let receivedAt: Date
    package init(value: Data, receivedAt: Date) { self.value = value; self.receivedAt = receivedAt }
}

package enum BluetoothTransportError: Error, Sendable, Equatable {
    case unavailable(BluetoothAvailability)
    case unknownPeripheral(BluetoothPeripheralID)
    case timedOut(String)
    case notConnected
    case characteristicNotFound(GATTUUID)
    case valueTooLong(Int, max: Int)
    /// Link dropped; `code` is the `CBError` code when CoreBluetooth gave one.
    case disconnected(code: Int?)
    /// A GATT/ATT/CB error from a callback (`CBErrorDomain` / `CBATTErrorDomain`).
    case gatt(domain: String, code: Int)
}

/// Everything a link reports, on ONE ordered stream, so a consumer can never see a
/// disconnect overtake the notifications that preceded it.
package enum LinkEvent: Sendable, Equatable {
    case notification(GATTUUID, GATTNotification)
    /// `peripheral(_:didModifyServices:)` — cached characteristic handles are stale.
    case servicesInvalidated
    /// Terminal. The stream finishes right after this event.
    case disconnected(BluetoothTransportError?)
}

/// Central-role entry point (`BleakScanner` + `establish_connection` analogue).
package protocol BluetoothCentral: Sendable {
    func availability() async -> BluetoothAvailability
    /// Foreground scan for `duration`, returning every peripheral seen (de-duplicated).
    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral]
    /// One connection attempt with our own timeout (CoreBluetooth connects never time
    /// out, CBCentralManager.h:201). Retries are protocol logic, above the seam.
    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink
}

/// One live connection (`BleakClient` analogue). A new object per connection, so
/// stale events from an old link can be ignored by identity (upstream:
/// `if client is not self._client: return`, _bluetooth.py:469).
package protocol BluetoothLink: AnyObject, Sendable {
    var peripheralID: BluetoothPeripheralID { get }
    /// Ordered lifecycle + notification events; finishes after `.disconnected`.
    var events: AsyncStream<LinkEvent> { get }
    /// Discover services/characteristics; returns which of `wanted` exist.
    /// `refresh: true` re-runs discovery (bleak `clear_cache` analogue).
    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID>
    func read(_ characteristic: GATTUUID, timeout: Duration) async throws -> Data
    func write(_ data: Data, to characteristic: GATTUUID, withResponse: Bool, timeout: Duration) async throws
    /// Enable notifications; values then arrive as `.notification` on `events`.
    func subscribe(_ characteristic: GATTUUID, timeout: Duration) async throws
    /// Best effort, never throws (upstream wraps stop_notify in suppress(), :399-400).
    func unsubscribe(_ characteristic: GATTUUID) async
    func disconnect() async
}

/// Tagged sleeps, so tests can see and fire individual timers (upstream patches
/// AUTH_READ_INTERVAL / RECONNECT_INITIAL_DELAY to 0 and fakes the idle timer).
package enum SleepPurpose: Sendable, Hashable { case authPoll, connectBackoff, idleDisconnect, reconnectBackoff }
package protocol BluetoothSleeper: Sendable {
    func sleep(for duration: Duration, purpose: SleepPurpose) async throws
}
package struct RealSleeper: BluetoothSleeper {
    package init() {}
    package func sleep(for duration: Duration, purpose: SleepPurpose) async throws {
        try await Task.sleep(for: duration)
    }
}

/// The public, opaque handle a consumer passes in. Built by the CoreBluetooth
/// adapter module (`.coreBluetooth()`), or from a fake in tests.
public struct BluetoothTransport: Sendable {
    package let central: any BluetoothCentral
    package let sleeper: any BluetoothSleeper
    package let now: @Sendable () -> Date
    package init(central: any BluetoothCentral,
                 sleeper: any BluetoothSleeper = RealSleeper(),
                 now: @escaping @Sendable () -> Date = { Date() }) {
        self.central = central; self.sleeper = sleeper; self.now = now
    }
}
```

## Appendix B: `CoreBluetoothAdapter.swift` (verified: builds warning-free in Swift 6 mode for macOS 14 and iOS 17; not runnable in CI by design)

Source: `docs/bluetooth/research/06-sketch/btsketch/Sources/BTCoreBluetooth/CoreBluetoothAdapter.swift`

```swift
#if canImport(CoreBluetooth)
import BTCore
import CoreBluetooth
import Foundation
import os

// The ONLY code that touches CoreBluetooth. Design: one private serial DispatchQueue
// is both the CBCentralManager delegate queue and the confinement domain for every
// CB object and every piece of adapter state. Async callers hop onto the queue;
// delegate callbacks resolve continuations from the queue. No actor executors.

extension BluetoothTransport {
    /// The only public symbol this module adds.
    public static func coreBluetooth(showPowerAlert: Bool = false) -> BluetoothTransport {
        BluetoothTransport(central: CoreBluetoothCentral(showPowerAlert: showPowerAlert))
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// What an in-flight operation waits for. Delegate callbacks identify their
/// operation only by (peripheral, characteristic), so same-key ops resolve FIFO —
/// CoreBluetooth answers ATT requests in order.
enum OpKey: Hashable, Sendable {
    case poweredOn
    case connect(UUID)
    case disconnect(UUID)
    case discoverServices(UUID)
    case discoverCharacteristics(UUID, service: String)
    case read(UUID, String)
    case write(UUID, String)
    case notify(UUID, String)

    var peripheral: UUID? {
        switch self {
        case .poweredOn: nil
        case .connect(let p), .disconnect(let p), .discoverServices(let p),
             .discoverCharacteristics(let p, _), .read(let p, _), .write(let p, _), .notify(let p, _): p
        }
    }

    /// An ATT request always gets exactly one response (or the link drops), so an op
    /// abandoned by timeout/cancel still "owes" one callback, which must be swallowed
    /// rather than resolve the next request with the same key.
    var isGATTRequest: Bool {
        switch self {
        case .read, .write, .notify, .discoverServices, .discoverCharacteristics: true
        default: false
        }
    }
}

/// Queue-confined table of in-flight operations (NOT thread-safe: adapter queue only).
/// Exactly-once resume: every completion path — delegate callback, timeout,
/// cancellation, disconnect — goes through `finish`, which REMOVES the entry before
/// calling it. On a serial queue only one path can win; the rest find nothing.
final class OpTable {
    typealias Completion = (Result<any Sendable, any Error>) -> Void
    private var entries: [UInt64: (key: OpKey, complete: Completion)] = [:]
    private var order: [UInt64] = []
    private var orphans: [OpKey: Int] = [:]

    func register(_ token: UInt64, key: OpKey, complete: @escaping Completion) {
        entries[token] = (key, complete)
        order.append(token)
    }

    @discardableResult
    func finish(_ token: UInt64, _ result: Result<any Sendable, any Error>, abandoning: Bool) -> Bool {
        guard let entry = entries.removeValue(forKey: token) else { return false }
        order.removeAll { $0 == token }
        if abandoning && entry.key.isGATTRequest { orphans[entry.key, default: 0] += 1 }
        entry.complete(result)
        return true
    }

    /// A request was sent without anyone awaiting it (e.g. best-effort unsubscribe):
    /// its callback must be swallowed, not delivered to the next op with this key.
    func owe(_ key: OpKey) { orphans[key, default: 0] += 1 }

    func isAwaiting(_ key: OpKey) -> Bool {
        (orphans[key] ?? 0) > 0 || order.contains { entries[$0]?.key == key }
    }

    /// Delegate-callback path: resolve the oldest op waiting on `key`; a late reply
    /// owed to an abandoned op is swallowed instead.
    @discardableResult
    func finishOldest(_ key: OpKey, _ result: Result<any Sendable, any Error>) -> Bool {
        if let owed = orphans[key], owed > 0 {
            orphans[key] = owed == 1 ? nil : owed - 1
            return true
        }
        guard let token = order.first(where: { entries[$0]?.key == key }) else { return false }
        return finish(token, result, abandoning: false)
    }

    func failAll(where match: (OpKey) -> Bool, _ error: any Error) {
        orphans = orphans.filter { !match($0.key) }
        for token in order where entries[token].map({ match($0.key) }) == true {
            finish(token, .failure(error), abandoning: false)
        }
    }
}

private struct CancelBox: Sendable {
    var cancelled = false
    var token: UInt64?
}

private func mapError(_ error: (any Error)?) -> BluetoothTransportError? {
    guard let error else { return nil }
    let ns = error as NSError
    if ns.domain == CBErrorDomain,
       ns.code == CBError.Code.peripheralDisconnected.rawValue || ns.code == CBError.Code.notConnected.rawValue {
        return .disconnected(code: ns.code)
    }
    return .gatt(domain: ns.domain, code: ns.code)
}

// MARK: - Central adapter

/// `@unchecked Sendable` is sound because every stored `var` and every CB object is
/// touched only on `queue` (asserted with dispatchPrecondition where cheap).
final class CoreBluetoothCentral: NSObject, BluetoothCentral, CBCentralManagerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "angstrom.bluetooth")
    let now: @Sendable () -> Date
    private let showPowerAlert: Bool

    // queue-confined
    private var manager: CBCentralManager?
    let ops = OpTable()
    private var nextToken: UInt64 = 0
    private var known: [UUID: CBPeripheral] = [:]   // must retain (CBCentralManager.h:203, :303-305)
    private var scanResults: [UUID: DiscoveredPeripheral] = [:]
    private var links: [UUID: CoreBluetoothLink] = [:]

    init(showPowerAlert: Bool, now: @escaping @Sendable () -> Date = { Date() }) {
        self.showPowerAlert = showPowerAlert
        self.now = now
        super.init()
    }

    /// Lazy: allocating the manager is what can surface the TCC prompt, so a
    /// consumer that never touches Bluetooth never prompts.
    private func ensureManager() -> CBCentralManager {
        dispatchPrecondition(condition: .onQueue(queue))
        if let manager { return manager }
        let m = CBCentralManager(delegate: self, queue: queue,
                                 options: [CBCentralManagerOptionShowPowerAlertKey: showPowerAlert])
        manager = m
        return m
    }

    func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: body()) } }
    }

    /// Bridge one delegate round-trip to async/await with timeout + cancellation.
    func perform<T: Sendable>(
        _ key: OpKey,
        timeout: Duration?,
        onTimeout: (@Sendable () -> Void)? = nil,
        start: @escaping @Sendable () throws -> Void
    ) async throws -> T {
        let box = OSAllocatedUnfairLock(initialState: CancelBox())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
                queue.async {
                    self.nextToken += 1
                    let token = self.nextToken
                    // onCancel may already have run (task cancelled before we got here).
                    let proceed = box.withLock { state -> Bool in
                        if state.cancelled { return false }
                        state.token = token
                        return true
                    }
                    guard proceed else { cont.resume(throwing: CancellationError()); return }
                    self.ops.register(token, key: key) { result in
                        switch result {
                        case .success(let value as T): cont.resume(returning: value)
                        case .success: cont.resume(throwing: BluetoothTransportError.gatt(domain: "angstrom", code: -1))
                        case .failure(let error): cont.resume(throwing: error)
                        }
                    }
                    do { try start() } catch {
                        self.ops.finish(token, .failure(error), abandoning: false)
                        return
                    }
                    if let timeout {
                        self.queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                            if self.ops.finish(token, .failure(BluetoothTransportError.timedOut("\(key)")), abandoning: true) {
                                onTimeout?()
                            }
                        }
                    }
                }
            }
        } onCancel: {
            let token = box.withLock { state -> UInt64? in
                state.cancelled = true
                return state.token
            }
            if let token {
                self.queue.async { self.ops.finish(token, .failure(CancellationError()), abandoning: true) }
            }
        }
    }

    // MARK: BluetoothCentral

    func availability() async -> BluetoothAvailability {
        await onQueue { Self.map(self.ensureManager().state) }
    }

    static func map(_ state: CBManagerState) -> BluetoothAvailability {
        switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized:
            switch CBManager.authorization {
            case .notDetermined: .unauthorized(.notDetermined)
            case .restricted: .unauthorized(.restricted)
            case .denied: .unauthorized(.denied)
            case .allowedAlways: .unauthorized(.allowedAlways)
            @unknown default: .unauthorized(.denied)
            }
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    /// Wait for `.poweredOn`, failing fast on terminal states. Generous default:
    /// on first use the state may sit at `.unknown` while TCC asks (UNVERIFIED).
    func requirePoweredOn(timeout: Duration = .seconds(30)) async throws {
        let _: Void = try await perform(.poweredOn, timeout: timeout) {
            let state = self.ensureManager().state
            switch state {
            case .poweredOn:
                self.queue.async { self.ops.finishOldest(.poweredOn, .success(())) }
            case .unknown, .resetting:
                break // wait for centralManagerDidUpdateState
            default:
                throw BluetoothTransportError.unavailable(Self.map(state))
            }
        }
    }

    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] {
        try await requirePoweredOn()
        await onQueue {
            self.scanResults = [:]
            // nil services: upstream filters by name only and the service UUID is
            // UNVERIFIED; CBCentralManager.h:173-178 — foreground-only on iOS.
            self.ensureManager().scanForPeripherals(withServices: nil, options: nil)
        }
        try? await Task.sleep(for: duration) // cancellation just ends the scan early
        return await onQueue {
            self.manager?.stopScan()
            return Array(self.scanResults.values)
        }
    }

    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        try await requirePoweredOn()
        guard let uuid = UUID(uuidString: id.rawValue) else { throw BluetoothTransportError.unknownPeripheral(id) }
        let link: CoreBluetoothLink = try await perform(
            .connect(uuid), timeout: timeout,
            onTimeout: { [weak self] in self?.cancelConnection(uuid) } // CB connects never time out (:201)
        ) {
            let manager = self.ensureManager()
            guard let p = self.known[uuid] ?? manager.retrievePeripherals(withIdentifiers: [uuid]).first else {
                throw BluetoothTransportError.unknownPeripheral(id)
            }
            self.known[uuid] = p
            manager.connect(p, options: nil)
        }
        return link
    }

    /// queue-only
    func cancelConnection(_ uuid: UUID) {
        if let p = known[uuid] { manager?.cancelPeripheralConnection(p) }
    }

    // MARK: CBCentralManagerDelegate (always on `queue`)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        switch state {
        case .poweredOn:
            while ops.finishOldest(.poweredOn, .success(())) {}
        case .unknown, .resetting:
            break
        default:
            ops.failAll(where: { $0 == .poweredOn }, BluetoothTransportError.unavailable(Self.map(state)))
        }
        if state != .poweredOn {
            // "A state below PoweredOn implies that scanning has stopped and any connected
            // peripherals have been disconnected" (CBCentralManager.h:264-268) — synthesize.
            for link in links.values { link.handleDisconnect(BluetoothTransportError.unavailable(Self.map(state))) }
            links.removeAll()
            ops.failAll(where: { if case .connect = $0 { true } else { false } },
                        BluetoothTransportError.unavailable(Self.map(state)))
            if state != .poweredOff { known.removeAll() } // below PoweredOff: CBPeripherals invalid
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        known[peripheral.identifier] = peripheral
        // bleak's BLEDevice.name on macOS is CBPeripheral.name; fall back to the adv local name.
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue // 127 = unavailable (CBCentralManager.h:300-301)
        scanResults[peripheral.identifier] = DiscoveredPeripheral(
            id: BluetoothPeripheralID(rawValue: peripheral.identifier.uuidString), name: name, rssi: rssi)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let link = CoreBluetoothLink(peripheral: peripheral, central: self)
        peripheral.delegate = link
        if ops.finishOldest(.connect(peripheral.identifier), .success(link)) {
            links[peripheral.identifier] = link
        } else {
            central.cancelPeripheralConnection(peripheral) // nobody wants it any more (timed out / cancelled)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        ops.finishOldest(.connect(peripheral.identifier),
                         .failure(mapError(error) ?? BluetoothTransportError.disconnected(code: nil)))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        ops.failAll(where: { $0 == .connect(peripheral.identifier) },
                    mapError(error) ?? BluetoothTransportError.disconnected(code: nil))
        links.removeValue(forKey: peripheral.identifier)?.handleDisconnect(mapError(error))
    }
}

// MARK: - Link adapter

final class CoreBluetoothLink: NSObject, BluetoothLink, CBPeripheralDelegate, @unchecked Sendable {
    let peripheralID: BluetoothPeripheralID
    let events: AsyncStream<LinkEvent>
    private let eventSink: AsyncStream<LinkEvent>.Continuation
    private let uuid: UUID
    private let central: CoreBluetoothCentral

    // queue-confined
    private let peripheral: CBPeripheral
    private var characteristics: [String: CBCharacteristic] = [:]
    private var notifying: Set<String> = []
    private var isDisconnected = false

    init(peripheral: CBPeripheral, central: CoreBluetoothCentral) {
        self.peripheral = peripheral
        self.central = central
        uuid = peripheral.identifier
        peripheralID = BluetoothPeripheralID(rawValue: peripheral.identifier.uuidString)
        (events, eventSink) = AsyncStream.makeStream(of: LinkEvent.self, bufferingPolicy: .unbounded)
        super.init()
    }

    private static func key(_ uuid: CBUUID) -> String { uuid.uuidString.lowercased() } // CBUUID strings are uppercase

    private func characteristic(_ id: GATTUUID) throws -> CBCharacteristic {
        if isDisconnected { throw BluetoothTransportError.notConnected }
        guard let ch = characteristics[id.string] else { throw BluetoothTransportError.characteristicNotFound(id) }
        return ch
    }

    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        let cached = await central.onQueue { wanted.filter { self.characteristics[$0.string] != nil } }
        if !refresh && cached == wanted { return cached }
        let _: Void = try await central.perform(.discoverServices(uuid), timeout: timeout) {
            if self.isDisconnected { throw BluetoothTransportError.notConnected }
            self.characteristics.removeAll()
            self.peripheral.discoverServices(nil) // service UUID UNVERIFIED upstream
        }
        let services = await central.onQueue { self.peripheral.services?.map { Self.key($0.uuid) } ?? [] }
        for service in services {
            let _: Void = try await central.perform(.discoverCharacteristics(uuid, service: service), timeout: timeout) {
                guard let svc = self.peripheral.services?.first(where: { Self.key($0.uuid) == service }) else {
                    throw BluetoothTransportError.notConnected
                }
                self.peripheral.discoverCharacteristics(wanted.map { CBUUID(string: $0.string) }, for: svc)
            }
        }
        return await central.onQueue { wanted.filter { self.characteristics[$0.string] != nil } }
    }

    func read(_ id: GATTUUID, timeout: Duration) async throws -> Data {
        try await central.perform(.read(uuid, id.string), timeout: timeout) {
            self.peripheral.readValue(for: try self.characteristic(id)) // long reads: system does Read Blob
        }
    }

    func write(_ data: Data, to id: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        guard withResponse else {
            // upstream never writes without response (_bluetooth.py:636-640, :696-700)
            try await central.onQueue { () -> Result<Void, BluetoothTransportError> in
                do {
                    self.peripheral.writeValue(data, for: try self.characteristic(id), type: .withoutResponse)
                    return .success(())
                } catch { return .failure(error as? BluetoothTransportError ?? .notConnected) }
            }.get()
            return
        }
        let _: Void = try await central.perform(.write(uuid, id.string), timeout: timeout) {
            let ch = try self.characteristic(id)
            let max = self.peripheral.maximumWriteValueLength(for: .withResponse)
            guard data.count <= max else { throw BluetoothTransportError.valueTooLong(data.count, max: max) }
            self.peripheral.writeValue(data, for: ch, type: .withResponse) // > MTU-3: system long write
        }
    }

    func subscribe(_ id: GATTUUID, timeout: Duration) async throws {
        do {
            let _: Void = try await central.perform(.notify(uuid, id.string), timeout: timeout) {
                let ch = try self.characteristic(id)
                // Route BEFORE enabling: the machine replays its last notification on
                // subscribe (_bluetooth.py:429-431), possibly before the CCCD write ack.
                self.notifying.insert(id.string)
                self.peripheral.setNotifyValue(true, for: ch)
            }
        } catch {
            await central.onQueue { _ = self.notifying.remove(id.string) }
            throw error
        }
    }

    func unsubscribe(_ id: GATTUUID) async {
        await central.onQueue {
            self.notifying.remove(id.string)
            if !self.isDisconnected, let ch = self.characteristics[id.string] {
                self.central.ops.owe(.notify(self.uuid, id.string)) // ack not awaited: swallow it
                self.peripheral.setNotifyValue(false, for: ch)      // best effort, like suppress()
            }
        }
    }

    func disconnect() async {
        let _: Void? = try? await central.perform(.disconnect(uuid), timeout: .seconds(5)) {
            if self.isDisconnected {
                self.central.queue.async { self.central.ops.finishOldest(.disconnect(self.uuid), .success(())) }
            } else {
                self.central.cancelConnection(self.uuid)
            }
        }
    }

    /// queue-only. Fails everything in flight, ends the stream, reports once.
    func handleDisconnect(_ error: BluetoothTransportError?) {
        guard !isDisconnected else { return }
        isDisconnected = true
        while central.ops.finishOldest(.disconnect(uuid), .success(())) {}
        central.ops.failAll(where: { $0.peripheral == self.uuid }, error ?? BluetoothTransportError.disconnected(code: nil))
        notifying.removeAll()
        eventSink.yield(.disconnected(error))
        eventSink.finish()
    }

    // MARK: CBPeripheralDelegate (always on the central's queue)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        central.ops.finishOldest(.discoverServices(uuid), error.map { .failure(mapError($0)!) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        for ch in service.characteristics ?? [] { characteristics[Self.key(ch.uuid)] = ch }
        central.ops.finishOldest(.discoverCharacteristics(uuid, service: Self.key(service.uuid)),
                                 error.map { .failure(mapError($0)!) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        characteristics.removeAll()
        eventSink.yield(.servicesInvalidated)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let key = Self.key(characteristic.uuid)
        let value = characteristic.value ?? Data()
        // One callback serves reads AND notifications. A pending (or owed) read wins;
        // upstream never reads a characteristic it is subscribed to, so this is unambiguous.
        if central.ops.isAwaiting(.read(uuid, key)) {
            central.ops.finishOldest(.read(uuid, key), error.map { .failure(mapError($0)!) } ?? .success(value))
        } else if error == nil, notifying.contains(key) {
            eventSink.yield(.notification(GATTUUID(key), GATTNotification(value: value, receivedAt: central.now())))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        central.ops.finishOldest(.write(uuid, Self.key(characteristic.uuid)),
                                 error.map { .failure(mapError($0)!) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        central.ops.finishOldest(.notify(uuid, Self.key(characteristic.uuid)),
                                 error.map { .failure(mapError($0)!) } ?? .success(()))
    }
}
#endif
```

## Appendix C: `Session.swift`, an illustrative protocol-logic actor (verified: builds; exercised by Appendix E)

A deliberately partial port, enough to prove the seam carries upstream semantics. The real `LaMarzoccoBluetoothClient` adds the idle timer, the reconnect loop, the brewing tracker, connection events and the services-cache retry (notes 01 and 02).

Source: `docs/bluetooth/research/06-sketch/btsketch/Sources/BTCore/Session.swift`

```swift
import Foundation

// MARK: - Protocol-logic actor (fully testable through the seam). Illustrative subset
// of upstream LaMarzoccoBluetoothClient: connect+retry, auth polling, request/response
// framing, shot-counter subscribe with replay drop, disconnect-on-error, stale-link guard.

package enum LMChar {
    // Verbatim from upstream src/pylamarzocco/clients/_bluetooth.py:40-44
    static let read = GATTUUID("0a0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let write = GATTUUID("0b0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let token = GATTUUID("0c0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let auth = GATTUUID("0d0b7847-e12b-09a8-b04b-8e0922a9abab")
    static let shotCounter = GATTUUID("0e0b7847-e12b-09a8-b04b-8e0922a9abab")
}

/// Sketch-local errors. The real port maps these into `LaMarzoccoError`.
public enum BluetoothSessionError: Error, Sendable, Equatable {
    /// upstream BluetoothConnectionFailed (exceptions.py:20)
    case connectionFailed(String)
    /// upstream BluetoothAuthenticationFailed(BluetoothConnectionFailed) (exceptions.py:46)
    case authenticationFailed
    case unavailable(BluetoothAvailability)
}

public actor BluetoothMachineSession {
    // Upstream constants (_bluetooth.py:49-51) and dependency defaults (see note §1.3).
    static let authSuccess = Data([0x01])                 // AUTH_SUCCESS = b"\x01"
    static let authReadAttempts = 10                      // AUTH_READ_ATTEMPTS = 10
    static let authReadInterval = Duration.milliseconds(50) // AUTH_READ_INTERVAL = 0.05
    static let maxConnectAttempts = 3                     // establish_connection(max_attempts=3), :252
    static let connectTimeout = Duration.seconds(20)      // BLEAK_TIMEOUT = 20.0 (bleak-retry-connector)
    static let opTimeout = Duration.seconds(20)           // bleak CB read timeout = 20; writes: none upstream

    private let central: any BluetoothCentral
    private let sleeper: any BluetoothSleeper
    private let peripheral: BluetoothPeripheralID
    private let token: String
    private var link: (any BluetoothLink)?
    private var watcher: Task<Void, Never>?
    private(set) var authenticationFailed = false

    // shot counter
    private var shotCounterEnabled = false
    private var shotCounterSubscribed = false
    private var replayPending = false
    private var notificationSink: AsyncStream<GATTNotification>.Continuation?

    // Actor re-entrancy means upstream's two asyncio.Locks must be explicit:
    // `_lock` (connect/disconnect) and `_request_lock` (atomic write->read pairs).
    private enum Gate { case connection, request }
    private var busy: Set<Gate> = []
    private var waiters: [Gate: [CheckedContinuation<Void, Never>]] = [:]

    private func acquire(_ gate: Gate) async {
        if busy.insert(gate).inserted { return }
        await withCheckedContinuation { waiters[gate, default: []].append($0) }
    }
    private func release(_ gate: Gate) {
        if var queue = waiters[gate], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[gate] = queue
            next.resume() // ownership handed over; gate stays busy (FIFO)
        } else {
            busy.remove(gate)
        }
    }

    public init(transport: BluetoothTransport, peripheral: BluetoothPeripheralID, token: String) {
        central = transport.central
        sleeper = transport.sleeper
        self.peripheral = peripheral
        self.token = token
    }

    public var isConnected: Bool { link != nil }

    // MARK: connection (upstream _ensure_connected, :233-269)

    func ensureConnected() async throws -> any BluetoothLink {
        await acquire(.connection)
        defer { release(.connection) }
        if let link { return link }
        let newLink = try await connectWithRetry()
        do {
            let found = try await newLink.discover([LMChar.auth, LMChar.read, LMChar.write, LMChar.shotCounter],
                                                   refresh: false, timeout: Self.opTimeout)
            guard found.contains(LMChar.auth) else {
                throw BluetoothSessionError.connectionFailed("Could not find characteristic \(LMChar.auth) on machine.")
            }
            try await authenticate(newLink)
        } catch {
            await newLink.disconnect() // never keep an unauthenticated link (:257-264), also on cancellation
            throw error
        }
        link = newLink
        let events = newLink.events
        watcher = Task { [weak self] in
            for await event in events { await self?.handle(event, from: newLink) }
        }
        return newLink
    }

    /// establish_connection(max_attempts=3) analogue; fail fast on non-transient states.
    private func connectWithRetry() async throws -> any BluetoothLink {
        var lastError: (any Error)?
        for attempt in 1...Self.maxConnectAttempts {
            switch await central.availability() {
            case .poweredOn: break
            case let state: throw BluetoothSessionError.unavailable(state)
            }
            do {
                return try await central.connect(to: peripheral, timeout: Self.connectTimeout)
            } catch let error as BluetoothTransportError {
                lastError = error
                if attempt == Self.maxConnectAttempts { break }
                // bleak-retry-connector: 0.25 s after a timeout, 0.1 s otherwise
                let backoff: Duration = if case .timedOut = error { .milliseconds(250) } else { .milliseconds(100) }
                try await sleeper.sleep(for: backoff, purpose: .connectBackoff)
            }
        }
        throw BluetoothSessionError.connectionFailed("Failed to connect: \(String(describing: lastError))")
    }

    /// upstream _authenticate (:628-653)
    private func authenticate(_ link: any BluetoothLink) async throws {
        do {
            try await link.write(Data(token.utf8), to: LMChar.auth, withResponse: true, timeout: Self.opTimeout)
            for attempt in 0..<Self.authReadAttempts {
                if attempt > 0 { try await sleeper.sleep(for: Self.authReadInterval, purpose: .authPoll) }
                let result = try await link.read(LMChar.auth, timeout: Self.opTimeout)
                authenticationFailed = result != Self.authSuccess
                if !authenticationFailed { return }
            }
        } catch let error as BluetoothTransportError {
            throw BluetoothSessionError.connectionFailed("Failed to connect to machine with Bluetooth: \(error)")
        }
        throw BluetoothSessionError.authenticationFailed
    }

    private func handle(_ event: LinkEvent, from source: any BluetoothLink) {
        guard source === link else { return } // stale link
        switch event {
        case .notification(let characteristic, let notification):
            guard characteristic == LMChar.shotCounter else { return }
            if replayPending { replayPending = false; return } // first notification is a replay (:446-449)
            notificationSink?.yield(notification)
        case .servicesInvalidated:
            break // real port: drop the characteristic table / force rediscovery
        case .disconnected:
            link = nil
            watcher = nil
            shotCounterSubscribed = false
            // real port: _set_connected(False), _handle_connection_lost() -> reconnect task
        }
    }

    // MARK: requests (upstream disconnect_on_exception + __send_command / __read_value_from_machine)

    /// Write `JSON + NUL` to WRITE, then read the status back from WRITE (:702-710).
    public func sendCommand(_ json: String) async throws -> String {
        try await request { link in
            try await link.write(Data(json.utf8) + [0x00], to: LMChar.write, withResponse: true, timeout: Self.opTimeout)
            return try await link.read(LMChar.write, timeout: Self.opTimeout)
        }
    }

    /// Write the setting name + NUL to READ, then read READ (:655-657).
    public func readSetting(_ setting: String) async throws -> String {
        try await request { link in
            try await link.write(Data(setting.utf8) + [0x00], to: LMChar.read, withResponse: true, timeout: Self.opTimeout)
            return try await link.read(LMChar.read, timeout: Self.opTimeout)
        }
    }

    private func request(_ body: (any BluetoothLink) async throws -> Data) async throws -> String {
        await acquire(.request)
        defer { release(.request) }
        do {
            let link = try await ensureConnected()
            let raw = try await body(link)
            // responses are NUL-terminated, ignore anything after it (:670-671)
            return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        } catch {
            // a single failed command must not kill a running shot counter (:130-133)
            if !(shotCounterEnabled && link != nil) { await dropConnection() }
            throw error
        }
    }

    // MARK: shot counter (upstream _subscribe_shot_counter, :403-439, minus the cache retry)

    package func shotCounterNotifications() -> AsyncStream<GATTNotification> {
        let (stream, sink) = AsyncStream.makeStream(of: GATTNotification.self)
        notificationSink = sink
        return stream
    }

    public func startShotCounter() async throws -> Bool {
        shotCounterEnabled = true
        let link = try await ensureConnected()
        if shotCounterSubscribed { return true }
        let found = try await link.discover([LMChar.shotCounter], refresh: false, timeout: Self.opTimeout)
        guard found.contains(LMChar.shotCounter) else { shotCounterEnabled = false; return false }
        replayPending = true // set BEFORE enabling: the replay can precede the CCCD ack
        try await link.subscribe(LMChar.shotCounter, timeout: Self.opTimeout)
        shotCounterSubscribed = true
        return true
    }

    public func disconnect() async {
        shotCounterEnabled = false
        if shotCounterSubscribed, let link { await link.unsubscribe(LMChar.shotCounter) }
        shotCounterSubscribed = false
        await dropConnection()
    }

    private func dropConnection() async {
        await acquire(.connection)
        defer { release(.connection) }
        let old = link
        link = nil // detach first so its .disconnected is ignored as stale (:303-304)
        watcher?.cancel()
        watcher = nil
        await old?.disconnect()
    }
}
```

## Appendix D: `FakeBluetooth.swift`, the in-memory fake (verified: builds; used by Appendix E)

Source: `docs/bluetooth/research/06-sketch/btsketch/Tests/BTCoreTests/FakeBluetooth.swift`

```swift
import Foundation
@testable import BTCore

/// Every operation the protocol layer performs, in order — the assertion surface.
enum FakeOp: Equatable, Sendable {
    case connect(BluetoothPeripheralID)
    case discover(refresh: Bool)
    case read(GATTUUID)
    case write(GATTUUID, Data)
    case subscribe(GATTUUID)
    case unsubscribe(GATTUUID)
    case disconnect
}

/// Scriptable central: availability, scan results, and one outcome per connect attempt.
final class FakeCentral: BluetoothCentral, @unchecked Sendable {
    private let lock = NSLock()
    private var _availability: BluetoothAvailability = .poweredOn
    private var _scan: [DiscoveredPeripheral] = []
    /// Popped per connect(); when empty, `makeLink()` is used.
    private var connectOutcomes: [Result<FakeLink, BluetoothTransportError>] = []
    private(set) var connectCount = 0
    private(set) var links: [FakeLink] = []
    var makeLink: @Sendable () -> FakeLink = { FakeLink.laMarzocco(token: "token") }

    func setAvailability(_ a: BluetoothAvailability) { lock.withLock { _availability = a } }
    func setScanResults(_ r: [DiscoveredPeripheral]) { lock.withLock { _scan = r } }
    func enqueueConnect(_ outcome: Result<FakeLink, BluetoothTransportError>) { lock.withLock { connectOutcomes.append(outcome) } }

    func availability() async -> BluetoothAvailability { lock.withLock { _availability } }
    func scan(for duration: Duration) async throws -> [DiscoveredPeripheral] { lock.withLock { _scan } }
    func connect(to id: BluetoothPeripheralID, timeout: Duration) async throws -> any BluetoothLink {
        let outcome: Result<FakeLink, BluetoothTransportError> = lock.withLock {
            connectCount += 1
            return connectOutcomes.isEmpty ? .success(makeLink()) : connectOutcomes.removeFirst()
        }
        let link = try outcome.get()
        lock.withLock { links.append(link) }
        return link
    }
}

/// A scriptable GATT server for one connection.
final class FakeLink: BluetoothLink, @unchecked Sendable {
    let peripheralID = BluetoothPeripheralID(rawValue: "00000000-0000-0000-0000-000000000001")
    let events: AsyncStream<LinkEvent>
    private let sink: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()

    // script
    var present: Set<GATTUUID> = [LMChar.auth, LMChar.read, LMChar.write, LMChar.shotCounter]
    /// Synchronous GATT-server behaviour. Throw a BluetoothTransportError to fail an op.
    var onRead: @Sendable (GATTUUID) throws -> Data = { _ in Data() }
    var onWrite: @Sendable (GATTUUID, Data) throws -> Void = { _, _ in }
    /// Async hook run before every op: await a gate here to hold an op in flight
    /// (serialization, cancellation and timeout tests).
    var beforeOp: (@Sendable (FakeOp) async -> Void)?
    /// Notifications to emit synchronously when a subscribe succeeds (the replay).
    var replayOnSubscribe: [Data] = []

    private(set) var ops: [FakeOp] = []
    private var dropped = false

    init() { (events, sink) = AsyncStream.makeStream(of: LinkEvent.self) }

    private func record(_ op: FakeOp) async throws {
        if let beforeOp { await beforeOp(op) }
        try lock.withLock {
            ops.append(op)
            if dropped && op != .disconnect { throw BluetoothTransportError.notConnected }
        }
    }

    func discover(_ wanted: Set<GATTUUID>, refresh: Bool, timeout: Duration) async throws -> Set<GATTUUID> {
        try await record(.discover(refresh: refresh))
        return lock.withLock { wanted.intersection(present) }
    }
    func read(_ c: GATTUUID, timeout: Duration) async throws -> Data {
        try await record(.read(c))
        return try onRead(c)
    }
    func write(_ data: Data, to c: GATTUUID, withResponse: Bool, timeout: Duration) async throws {
        try await record(.write(c, data))
        try onWrite(c, data)
    }
    func subscribe(_ c: GATTUUID, timeout: Duration) async throws {
        try await record(.subscribe(c))
        for value in replayOnSubscribe { notify(c, value, at: Date(timeIntervalSince1970: 0)) }
    }
    func unsubscribe(_ c: GATTUUID) async { try? await record(.unsubscribe(c)) }
    func disconnect() async {
        try? await record(.disconnect)
        drop(nil)
    }

    // test controls
    func notify(_ c: GATTUUID, _ value: Data, at date: Date) {
        sink.yield(.notification(c, GATTNotification(value: value, receivedAt: date)))
    }
    func drop(_ error: BluetoothTransportError?) {
        let first = lock.withLock { () -> Bool in defer { dropped = true }; return !dropped }
        guard first else { return }
        sink.yield(.disconnected(error))
        sink.finish()
    }
    var recordedOps: [FakeOp] { lock.withLock { ops } }

    /// A machine that accepts `token` and confirms auth on the `confirmOnRead`-th auth read,
    /// and answers commands with upstream's COMMAND_SUCCESS (tests/test_bluetooth_client.py:47).
    static func laMarzocco(token: String, confirmOnRead: Int = 1) -> FakeLink {
        final class AuthState: @unchecked Sendable {
            let lock = NSLock(); var tokenOK = false; var reads = 0
        }
        let link = FakeLink()
        let state = AuthState()
        link.onWrite = { c, data in
            if c == LMChar.auth { state.lock.withLock { state.tokenOK = data == Data(token.utf8); state.reads = 0 } }
        }
        link.onRead = { c in
            switch c {
            case LMChar.auth:
                return state.lock.withLock {
                    state.reads += 1
                    return Data([state.tokenOK && state.reads >= confirmOnRead ? 0x01 : 0x00])
                }
            case LMChar.write:
                return Data(#"{"id":"test-id","message":"Success","status":"success"}"#.utf8) + [0x00, 0x41]
            default:
                return Data("[]".utf8) + [0x00]
            }
        }
        return link
    }
}

/// Records every sleep and returns immediately (upstream patches the intervals to 0).
final class RecordingSleeper: BluetoothSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(Duration, SleepPurpose)] = []
    func sleep(for duration: Duration, purpose: SleepPurpose) async throws {
        lock.withLock { log.append((duration, purpose)) }
        try Task.checkCancellation()
    }
    func count(_ purpose: SleepPurpose) -> Int { lock.withLock { log.filter { $0.1 == purpose }.count } }
}

/// A one-shot async gate for holding an op in flight.
actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
```

## Appendix E: `SessionTests.swift` (verified: `swift test` passes 9/9)

Source: `docs/bluetooth/research/06-sketch/btsketch/Tests/BTCoreTests/SessionTests.swift`

```swift
import Foundation
import Testing
@testable import BTCore

private let machine = BluetoothPeripheralID(rawValue: "00000000-0000-0000-0000-000000000001")

private func makeSession(_ central: FakeCentral, _ sleeper: RecordingSleeper = RecordingSleeper(),
                         token: String = "token") -> BluetoothMachineSession {
    BluetoothMachineSession(transport: BluetoothTransport(central: central, sleeper: sleeper),
                            peripheral: machine, token: token)
}

@Test func authSucceedsAfterPolling() async throws {
    let central = FakeCentral()
    let sleeper = RecordingSleeper()
    central.makeLink = { FakeLink.laMarzocco(token: "token", confirmOnRead: 3) }
    let session = makeSession(central, sleeper)
    _ = try await session.ensureConnected()
    let ops = central.links[0].recordedOps
    #expect(ops.first == .discover(refresh: false))
    #expect(ops[1] == .write(LMChar.auth, Data("token".utf8)))   // token, no NUL (:636-640)
    #expect(ops.filter { $0 == .read(LMChar.auth) }.count == 3)
    #expect(sleeper.count(.authPoll) == 2)                         // no sleep before the first read
}

@Test func authFailsAfterTenReadsAndDropsLink() async throws {
    let central = FakeCentral()
    central.makeLink = { FakeLink.laMarzocco(token: "right") }
    let session = makeSession(central, token: "wrong")
    await #expect(throws: BluetoothSessionError.authenticationFailed) { _ = try await session.ensureConnected() }
    let ops = central.links[0].recordedOps
    #expect(ops.filter { $0 == .read(LMChar.auth) }.count == 10)   // AUTH_READ_ATTEMPTS
    #expect(ops.last == .disconnect)
    #expect(await session.authenticationFailed)
    #expect(await !session.isConnected)
}

@Test func commandFramingIsJSONPlusNUL() async throws {
    let central = FakeCentral()
    let session = makeSession(central)
    let status = try await session.sendCommand(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#)
    #expect(status == #"{"id":"test-id","message":"Success","status":"success"}"#) // cut at NUL
    let ops = central.links[0].recordedOps
    #expect(ops.suffix(2) == [
        .write(LMChar.write, Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]),
        .read(LMChar.write),
    ])
}

@Test func requestsAreSerialized() async throws {
    let central = FakeCentral()
    let gate = Gate()
    let link = FakeLink.laMarzocco(token: "token")
    central.enqueueConnect(.success(link))
    let session = makeSession(central)
    _ = try await session.ensureConnected()
    link.beforeOp = { op in if op == .write(LMChar.write, Data("A".utf8) + [0]) { await gate.wait() } }
    async let a = session.sendCommand("A")
    try await Task.sleep(for: .milliseconds(50))         // let A reach the gate
    async let b = session.sendCommand("B")
    try await Task.sleep(for: .milliseconds(50))
    #expect(!link.recordedOps.contains(.write(LMChar.write, Data("B".utf8) + [0])))
    await gate.release()
    _ = try await (a, b)
    let tail = Array(link.recordedOps.suffix(4))
    #expect(tail == [.write(LMChar.write, Data("A".utf8) + [0]), .read(LMChar.write),
                     .write(LMChar.write, Data("B".utf8) + [0]), .read(LMChar.write)])
}

@Test func reconnectsAfterLinkDrop() async throws {
    let central = FakeCentral()
    let session = makeSession(central)
    _ = try await session.sendCommand("A")
    central.links[0].drop(.disconnected(code: 7))         // CBErrorPeripheralDisconnected = 7
    try await Task.sleep(for: .milliseconds(50))         // watcher observes .disconnected
    #expect(await !session.isConnected)
    _ = try await session.sendCommand("B")
    #expect(central.connectCount == 2)
}

@Test func connectRetriesThreeTimesThenFails() async throws {
    let central = FakeCentral()
    let sleeper = RecordingSleeper()
    for _ in 0..<3 { central.enqueueConnect(.failure(.timedOut("connect"))) }
    let session = makeSession(central, sleeper)
    await #expect(throws: BluetoothSessionError.self) { _ = try await session.ensureConnected() }
    #expect(central.connectCount == 3)
    #expect(sleeper.count(.connectBackoff) == 2)
}

@Test func unavailableFailsFastWithoutConnecting() async throws {
    let central = FakeCentral()
    central.setAvailability(.unauthorized(.denied))
    let session = makeSession(central)
    await #expect(throws: BluetoothSessionError.unavailable(.unauthorized(.denied))) {
        _ = try await session.ensureConnected()
    }
    #expect(central.connectCount == 0)
}

@Test func firstNotificationAfterSubscribeIsDropped() async throws {
    let central = FakeCentral()
    let link = FakeLink.laMarzocco(token: "token")
    link.replayOnSubscribe = [Data(#"{"stale":true}"#.utf8)]
    central.enqueueConnect(.success(link))
    let session = makeSession(central)
    let stream = await session.shotCounterNotifications()
    #expect(try await session.startShotCounter())
    link.notify(LMChar.shotCounter, Data(#"{"fresh":true}"#.utf8), at: Date(timeIntervalSince1970: 42))
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.value == Data(#"{"fresh":true}"#.utf8))
    #expect(first?.receivedAt == Date(timeIntervalSince1970: 42))
}

@Test func staleLinkEventsAreIgnored() async throws {
    let central = FakeCentral()
    let session = makeSession(central)
    _ = try await session.sendCommand("A")
    let old = central.links[0]
    await session.disconnect()                           // detaches before disconnecting
    _ = try await session.sendCommand("B")              // new link
    old.drop(nil)                                        // late event from the old link
    try await Task.sleep(for: .milliseconds(50))
    #expect(await session.isConnected)
}
```

## Appendix F: scratch `Package.swift` for the verification package

```swift
// swift-tools-version: 6.0
// Scratch verification package for research note 06 (NOT part of Angstrom).
// BTCore          ~ the CoreBluetooth-free seam + protocol logic (would live in `Angstrom`)
// BTCoreBluetooth ~ the thin CoreBluetooth adapter (would be the `AngstromBluetooth` product)
import PackageDescription
let package = Package(
    name: "btsketch",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BTCore", targets: ["BTCore"]),
        .library(name: "BTCoreBluetooth", targets: ["BTCoreBluetooth"]),
    ],
    targets: [
        .target(name: "BTCore"),
        .target(name: "BTCoreBluetooth", dependencies: ["BTCore"]),
        .testTarget(name: "BTCoreTests", dependencies: ["BTCore"]),
    ]
)
```
