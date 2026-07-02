# Getting Started

Authenticate, read machine state, and send your first command.

## Overview

Angstrom talks to the La Marzocco cloud the same way the customer app does: each
install registers a cryptographic identity once, signs in with the owner's
credentials, and thereafter issues signed, token-authenticated requests. This
article walks through the minimal happy path.

Requires macOS 14+ / iOS 17+.

### Install

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/pacificsky/angstrom.git", from: "1.0.0")
```

Then depend on `"Angstrom"` for the stateless core client, and/or `"AngstromUI"`
for the observable device layer.

### Create an identity, once

``InstallationKey`` is the per-install cryptographic identity. Generate one the
first time, persist it (it's `Codable` — the Keychain is a good home), and reuse
it on every subsequent launch.

```swift
import Angstrom

let key = loadStoredKey() ?? .generate()
```

### Connect

Construct a ``LaMarzoccoCloudClient`` with the owner's credentials and the key,
then ``LaMarzoccoCloudClient/connect()``. Persist the `isRegistered` flag
afterward so later launches skip re-registration.

```swift
let client = LaMarzoccoCloudClient(
    username: email,
    password: password,
    installationKey: key,
    registered: wasRegistered   // false on first ever launch
)

let machines = try await client.connect()
persist(client.installationKey, registered: await client.isRegistered)
```

### Read state and send a command

```swift
let serial = machines[0].serialNumber

let state = try await client.powerState(serial: serial)   // .on / .off / .other / .unknown
try await client.setPower(serial: serial, on: true)
```

When the websocket is connected, ``LaMarzoccoCloudClient`` awaits the machine's
confirmation before a command returns; otherwise it falls back to
fire-and-forget. See ``CommandResponse`` and ``CommandStatus``.

### Live updates

Open the STOMP websocket, then consume the stream of dashboard deltas. The
connection reconnects and heartbeats automatically:

```swift
try await client.connectWebSocket(serial: serial)

for await update in client.dashboardUpdates() {
    dashboard = dashboard.applying(update)
}
```

The push feed is **change-only** — subscribing delivers no snapshot, so any
transition that happens while the socket is down is never re-pushed. Observe
``LaMarzoccoCloudClient/connectionEvents()`` and re-fetch the dashboard on each
`.connected` to reconcile state missed during a gap (`LaMarzoccoMachine` in
`AngstromUI` does this for you):

```swift
for await event in client.connectionEvents() {
    if event == .connected {
        dashboard = try await client.dashboard(serial: serial)
    }
}
```

### Next: the observable device layer

If you're building SwiftUI, reach for `LaMarzoccoMachine` in the `AngstromUI`
product — a `@MainActor @Observable` device layer that retains
`dashboard`/`settings`/`schedule`, merges live pushes for you, and applies
optimistic local updates on every command. The core client remains usable on its
own for CLI and server use.
