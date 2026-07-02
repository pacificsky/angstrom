# ``AngstromUI``

An observable device layer over the Angstrom cloud client, for SwiftUI.

## Overview

`AngstromUI` wraps the stateless `Angstrom` core in a `@MainActor @Observable`
``LaMarzoccoMachine`` you can bind directly in SwiftUI. It retains
`dashboard`/`settings`/`schedule`/`statistics`, iterates the live websocket and
merges pushes into `dashboard` (re-fetching the dashboard after every reconnect,
since the push feed is change-only), forwards commands with optimistic local
updates, and gates model-specific commands behind
`LaMarzoccoError.unsupportedModel`. `isConnected` and `lastUpdateAt` report
actual socket health and data freshness, alongside `isLive`'s
subscription intent.

```swift
import AngstromUI

let machine = LaMarzoccoMachine(
    serialNumber: serial,
    client: client,
    snapshot: loadSnapshot()   // optional: render stale state instantly on launch
)

try await machine.refreshAll()     // populate dashboard / settings / schedule
try await machine.start()          // live websocket; merges pushes into `dashboard`

try await machine.setPower(on: true)
try await machine.setSteamTargetLevel(.level3)   // throws .unsupportedModel off-model

persist(machine.snapshot)          // Codable; reload next launch
```

The core `Angstrom` client remains usable on its own (CLI/server) — this layer is
purely additive.

## Topics

### Device Layer

- ``LaMarzoccoMachine``
- ``MachineSnapshot``
