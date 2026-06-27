# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Angstrom is a Swift Package Manager library (macOS 13+ / iOS 16+, Swift 6 with strict
concurrency) for the **La Marzocco** customer-app cloud API. It is an independent Swift
port of the cloud protocol and authentication from
[`pylamarzocco`](https://github.com/zweckj/pylamarzocco) (Josef Zweck). When changing
auth or proof logic, the Python source (`util/_authentication.py`) is the reference of
record — match it byte-for-byte.

## Commands

```bash
swift build                                   # build
swift test                                    # run all tests
swift test --filter ProofTests                # run one test case (by type name)
swift test --filter ProofTests/testRequestProofMatchesPythonReference   # one method
```

CI (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on macos-15, selecting
the newest installed Xcode so the SDK matches the package's deployment targets.

## Architecture

Four files in `Sources/Angstrom/`, layered from crypto identity up to the public client:

- **`InstallationKey.swift`** — the per-install cryptographic identity. A `Codable`/`Sendable`
  value type storing only the installation UUID and the raw 32-byte P-256 private-key
  scalar; everything else (public key DER, the 32-byte `secret`, the registration
  `baseString`, signatures) is *derived on demand*. Callers generate one with `.generate()`,
  persist it, and pass it back each launch.

- **`Proof.swift`** — La Marzocco's bespoke request-proof scheme. `requestProof` is a hand
  ported byte-mutation loop (XOR + rotate-left within a byte) over the input string,
  finalized as `base64(sha256(work))`. `requestHeaders` builds the signed headers
  (`X-App-Installation-Id`, `X-Timestamp`, `X-Nonce`, `X-Request-Signature`) carried on
  signin and every authed request. This is the most fragile code in the repo — it is
  verified against fixed vectors in `ProofTests`.

- **`LaMarzoccoCloudClient.swift`** — the public `actor`. Owns the URLSession and the
  in-memory token lifecycle. Tokens live only in memory and are **never persisted** — the
  client deliberately touches no disk; persisting `installationKey` + `isRegistered` is the
  caller's job. Auth flow: `ensureToken()` registers the key once (`/auth/init`) if
  `!registered`, then signs in (`/auth/signin`) if the token is missing/expired (assumed
  ~1h, refreshed at 50min). `authed(...)` wraps every endpoint call and retries signin once
  on a 401. Power state is read by scanning the dashboard JSON for the `CMMachineStatus`
  widget rather than a typed decode; `setPower` POSTs the `CoffeeMachineChangeMode` command.

- **`Models.swift`** — `Machine`, the `PowerState` enum, and `LaMarzoccoError`
  (`LocalizedError` with user-facing strings). `Machine`'s custom decoder tolerates missing
  `name`/`modelName`.

### Conventions worth keeping

- Network responses are parsed defensively (`JSONSerialization` + shape checks, optional
  decodes) — the cloud API shape is only partially known, so prefer tolerant parsing and a
  `LaMarzoccoError.decoding(...)` over a hard typed-decode failure.
- All thrown errors are `LaMarzoccoError` cases; map new failures into that enum.
- The client is an `actor`; `installationKey` is `nonisolated let` so it can be read for
  persistence without `await`.

## Status

v0.1 covers authentication, listing machines, reading power state, and on/off. Live-status
websocket, more commands, and Bluetooth are possible future additions from the
`pylamarzocco` surface.
