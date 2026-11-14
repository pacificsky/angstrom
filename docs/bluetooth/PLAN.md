# Angstrom Bluetooth — implementation plan

> **Status:** execution plan for the frozen design in [`SPEC.md`](SPEC.md). **Target:** Angstrom
> **v2.0.0**. **Reference of record:** `pylamarzocco` **v2.5.6 / `4c639ee`** (`$UPSTREAM`).
> **Baseline:** `main` @ `e1bc403` (v1.7.0). **Machine-readable twin:**
> [`work-packages.json`](work-packages.json). Both files are generated from one source, so ids,
> waves, dependencies and ownership agree exactly. If you change one, change the other.
>
> This plan is written for an orchestration workflow that runs dozens of coding agents in
> parallel. Every agent starts with **only** `CLAUDE.md`, `SPEC.md`, this plan and its own
> work-package brief. Agents work in separate git worktrees, cannot talk to each other, and have
> no Bluetooth hardware.

## 0. Inputs, conventions, and how this plan relates to the SPEC

- **SPEC is binding.** Every declaration in SPEC §6, and every behaviour in SPEC §3–§4, is
  frozen. This plan does not change any of them. It **refines SPEC §7** (the file map and its 17
  coarse work packages) into 45 packages with exclusive file ownership, and freezes a few extra
  plan-level contracts (§3) that the SPEC left to the implementer, so packages can run in
  parallel. §3.6 lists every refinement.
- **Environment the orchestrator provides to every agent:**
  - `$UPSTREAM`: a read-only clone of pylamarzocco at v2.5.6 / `4c639ee`. Source is under
    `src/pylamarzocco`, tests under `tests/`. SPEC §0.1 abbreviations (`BT`, `MBT`, `MACH`,
    `TBC`, …) are paths relative to it.
  - `$RESEARCH` (optional): the planning research notes `01-protocol.md` … `06-corebluetooth.md`
    and `06-sketch/`. They are not in the repository, and nothing depends on them: SPEC §5.4 is the
    complete adapter requirement, and every brief is complete without them. Only BT-W1-07 and
    BT-W1-08 can use them, as an optional starting point (SPEC §5.4).
  - Citations to `BRC` and `BLEAK` (bleak-retry-connector 4.4.4, bleak 1.1.1) point to
    dependency sources that are **not** in `$UPSTREAM`. For those, the SPEC values (§2.2, §4.2,
    §5.4) are authoritative.
- **Package ids:** `BT-W<wave>-<nn>`. **Kinds:** `implement` (code + its tests), `docs`, `verify`
  (an independent reviewer that owns no files), `integrate` (final gates; owns no files).
- **Sizes:** S ≈ under 300 changed lines, M ≈ 300–900, L ≈ 900–2000. Nothing is larger than L.
- **SPEC work package → plan packages:**

| SPEC WP (§7.2) | Plan packages |
|---|---|
| F0 core foundation | BT-W0-01 (contracts, leaf implementations), BT-W1-01 (leaf tests) |
| T0 test support | BT-W0-03 (fakes), BT-W0-04 (UI harness) |
| B1 codec + decoders | BT-W1-02, BT-W1-03 |
| B2 state machine | BT-W1-04 |
| B3 client | BT-W1-09 (main), BT-W2-01 (+Requests), BT-W2-02 (+ShotCounter) |
| B6 discovery/token/GATT | BT-W1-10 |
| B7 adapter | BT-W1-07 (op table), BT-W1-08 (CoreBluetooth) |
| B8 dashboard transforms | BT-W1-05 |
| B9 cloud token | BT-W1-06 |
| C0 CLI foundation | BT-W1-12 |
| C1 CLI `ble` subcommands | BT-W2-03, BT-W2-04, BT-W2-05, BT-W2-06 |
| U1 UI foundation | BT-W0-02 (declarations), BT-W1-11 (funnel + routing), BT-W3-06, BT-W3-07, BT-W3-08 |
| U2 UI shot counter | BT-W3-09 |
| T1–T4 client suites | BT-W3-01 … BT-W3-05 |
| T5/T6 UI suites | owned by the UI implementation packages BT-W3-06 … BT-W3-09 |
| D1 docs | BT-W2-07, BT-W2-08 |
| — (new) | verify packages BT-W2-09 … BT-W2-12, BT-W3-10, BT-W4-01 … BT-W4-06; integrate BT-W5-01 |

---

## 1. Execution model

### 1.1 Branches and worktrees

- **Integration branch:** `bluetooth/integration`, created from `main` @ `e1bc403`. Its first
  commit adds `docs/bluetooth/SPEC.md`, `PLAN.md` and `work-packages.json` **after a human
  approves them** (see §8, approval A0). It is the only branch packages merge into, and it is
  merged to `main` as one PR at the end (approval A4).
- **Package branches:** `bt/<id-lowercased>` (e.g. `bt/bt-w1-02`). Each one is checked out in its
  own worktree, `.claude/worktrees/<id>/angstrom` inside the repo (git-ignored; the directory must
  be named `angstrom` because `cli/Package.swift` refers to its parent package by directory
  name). Its base is the
  integration HEAD **at the start of the wave**. In Wave 0 (dag) and Wave 5 (serial), a package's
  base is the integration HEAD when it starts, after all of its dependencies have merged.
- **Cleanup:** once a wave has merged into `bluetooth/integration`, every worktree of that wave
  is removed (`git worktree remove`), including reviewer and verify worktrees. The `bt/<id>`
  branches stay as local history.
- **Fix branches:** `bt/<id>-fix<n>`, based on the current integration HEAD (§5.3).
- **Commits:** agents commit on their own branch with message `<id>: <summary>`. They end the
  message with the repository's required attribution trailer. Agents never push, rebase the
  integration branch, or touch another branch.
- Exports for every agent process: `UPSTREAM=<path>`, `PATH=<build-slot wrapper dir>:$PATH` (§1.8),
  optionally `RESEARCH=<path>`.

### 1.2 Per-package lifecycle

```
implement (agent A, own worktree)
  → package review (agent B, fresh context, disposable worktree, no commits; §5.1)
  → fix loop: up to 2 rounds of (agent A' with findings → agent B' re-review)
  → mechanical checks by the orchestrator (§1.4 items 2–3)
  → merge into bluetooth/integration
```

`verify`-kind packages skip the package review. Their findings drive fix jobs (§5.3).

### 1.3 Merging and conflicts

- **Order:** the orchestrator merges with `git merge --no-ff bt/<id>`, in ascending package-id
  order, at the wave barrier. Waves 0 and 5 merge each package as soon as it passes.
- **Conflicts are impossible by construction.** Within a wave, no two packages own the same path
  (validated mechanically, §8). Shared files (`Package.swift`, `Models.swift`, `Commands.swift`,
  `LaMarzoccoMachine.swift`, `cli/Package.swift`, `AngCLI.swift`, `Output.swift`, `CLAUDE.md`,
  `README.md`, `UPSTREAM.md`, workflows) each have exactly one owner per wave, and most are
  pre-landed in Wave 0 or Wave 1.
- **Nobody hand-resolves a conflict.** A conflict, or a diff path outside the package's `owns`
  lists, is an **ownership violation**. The orchestrator rejects the branch and re-runs the
  package once with the violation quoted. A second violation escalates to a human (approval A3).
- `Package.resolved` and `.build/` are git-ignored and must never be committed.

### 1.4 Definition of done (per package)

1. Every command in the package's `acceptance` list exits 0 in the package worktree.
2. `git diff --name-only <base>...HEAD` is a subset of `owns.create ∪ owns.modify`.
3. No `unimplemented: <own id>` marker remains anywhere (`grep -rn`).
4. The package review is PASS, or its findings are only `minor`.
5. The agent's final report lists: changed files, exact names of the tests it added, deviations,
   `BLOCKED-BY` items (§1.6) and open questions.
6. Every parity test carries the doc-comment header from §3.5, so coverage can be checked
   mechanically.

### 1.5 Gates

Global gate commands (`meta.gates` in the manifest). Run them from the repo root in a **fresh**
worktree of the integration branch:

```sh
# G1–G4 — build and test, library then CLI:
swift build --build-tests
swift test
swift build --package-path cli
swift test --package-path cli
# G5 — no warnings in new or changed Bluetooth code (from-scratch build in its own scratch path):
bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
# G5' — the same for the angcli Bluetooth files:
bash -c 'set -o pipefail; mkdir -p cli/.build; rm -rf cli/.build/g5; NO_COLOR=1 swift build --package-path cli --build-tests --scratch-path cli/.build/g5 2>&1 | tee cli/.build/bt-warnings.log && ! grep -E "/cli/(Sources/angcli/Ble/|Sources/angcli/Output\.swift|Sources/angcli/AngCLI\.swift|Tests/angcliTests/Ble)[^:]*:[0-9]+:[0-9]+: warning:" cli/.build/bt-warnings.log'
# G6 — no test parked on an unfixed defect:
bash -c '! grep -rn "BLOCKED-BY" Tests cli/Tests'
# G7 — no stub left (final form; wave gates use the wave-scoped form):
bash -c '! grep -rn "unimplemented: BT-" Sources Tests cli/Sources'
```

G5 builds **from scratch** (`rm -rf .build/g5`, `--scratch-path .build/g5`): SwiftPM prints a warning only
when it compiles the file, so a G5 that reused the tree G1 had just built would be a null build that sees
nothing. The separate scratch path also makes G5 independent of the order of the gate list. G5 judges only
warnings in Bluetooth code and in `Sources/AngstromUI`; G5' does the same for `cli/Sources/angcli/Ble/`,
`Output.swift`, `AngCLI.swift` and the `Ble*` CLI tests. If either flags a warning that already exists at
`e1bc403` (the agent checks by building the base commit), the agent reports it as `BASELINE-WARNING` instead of
fixing a file it does not own. The orchestrator then excludes that file/line from G5 (approval A3).

**Wave gates** (`waves[].gate`) run after every package of the wave has merged and after the
defect-fix step (§1.6). Each one is G1–G6 (with G5') plus a wave-scoped stub check: no marker
`unimplemented: BT-W<k>-` may remain for any `k ≤` the wave number. Wave 0 instead checks that
every remaining marker names a real later owner. Wave 5 adds the docs build, the iOS build, the
release build and the coverage check. **A wave starts only after the previous wave's gate is
green.** That is the barrier.

### 1.6 Defects in code from an earlier package (BLOCKED-BY protocol)

Agents may only edit the files they own. When an agent proves that a file from an earlier package
is wrong, it:

1. keeps the test that shows the defect, starting the test body with
   `throw XCTSkip("BLOCKED-BY <owner-id>: <one line>")`;
2. reports it under `BLOCKED-BY` in its final report.

At the wave barrier, the orchestrator groups all `BLOCKED-BY` reports by **fix owner** (Appendix
A). It runs one fix job per owner (§5.3), serially when two jobs touch the same file. The fix job
must also delete the `XCTSkip` line, so the test runs. Gate G6 makes the wave fail while any marker
remains.

### 1.7 SPEC defects (STOP protocol)

If a frozen contract cannot be implemented as written, or two SPEC sections contradict each other,
the agent **stops** without improvising and reports `SPEC-DEFECT: <section>: <problem>: <proposed
amendment>`. The orchestrator pauses dependants of that package and asks a human (approval A3).
After an amendment, the human bumps the SPEC status line ("amended <date>: <section>"), and the
orchestrator re-issues the affected briefs. Packages that are already merged are re-verified by
their wave's verify packages.

### 1.8 Build hygiene

- Use one SwiftPM cache for all worktrees (the default `~/Library/Caches/org.swift.swiftpm`), so
  `swift-docc-plugin` and `swift-argument-parser` resolve once. Warm it before Wave 0 with
  `swift package resolve` and `swift package --package-path cli resolve`.
- Every worktree has its own `.build`. Limit concurrent builds to `BUILD_SLOTS = max(2, ncpu / 4)`,
  not to the number of agents. Agents run `swift` through their own shell, so the orchestrator
  enforces the limit with wrappers: it puts a directory first on every agent's `PATH` that holds
  `swift` and `xcodebuild` wrapper scripts. Each wrapper takes an exclusive `fcntl.flock` on one of
  `BUILD_SLOTS` slot files (blocking until one is free), keeps that descriptor open across `exec`,
  and execs the real binary by absolute path (`xcrun -f swift`, `/usr/bin/xcodebuild`). The lock is
  released when the build exits. Agent timeouts (§8.2) count from the agent's start, so a queued
  build eats into them; the S/M/L timeouts allow for that.
- Reviewer and verify worktrees are **disposable**, not read-only filesystems: reviewers build and
  test in them (`.build/` is git-ignored). The rule is "no commit and no change to tracked
  files": the orchestrator rejects a review whose worktree shows `git status --porcelain` output.
- Test suites must be deterministic: no wall-clock sleeps, no sleep-polling (SPEC §9.1). BT-W4-03
  runs the Bluetooth suites five times and under the Thread Sanitizer to catch flakiness.

---

## 2. Waves

Dependency-ordered. Every package depends only on packages in the same or an earlier wave. In the parallel
waves every dependency points to an earlier wave, so the packages of a wave are independent. In the **dag** wave
(Wave 0) a package starts as soon as every dependency has merged, so packages with no path between them run
concurrently and own disjoint files. The serial wave runs one package at a time. A wave starts only after the
previous wave's gate is green.

| Wave | Name | Mode | Packages | Width |
|---|---|---|---|---|
| 0 | Contracts | dag | BT-W0-01, BT-W0-02, BT-W0-03, BT-W0-04 | 4 |
| 1 | Core protocol pieces, client core, adapter, UI funnel, CLI scaffolding | parallel | BT-W1-01, BT-W1-02, BT-W1-03, BT-W1-04, BT-W1-05, BT-W1-06, BT-W1-07, BT-W1-08, BT-W1-09, BT-W1-10, BT-W1-11, BT-W1-12 | 12 |
| 2 | Client behaviours, CLI commands, docs; review of Wave 1 | parallel | BT-W2-01, BT-W2-02, BT-W2-03, BT-W2-04, BT-W2-05, BT-W2-06, BT-W2-07, BT-W2-08, BT-W2-09, BT-W2-10, BT-W2-11, BT-W2-12 | 12 |
| 3 | Client parity suites and the AngstromUI Bluetooth layer; review of the CLI | parallel | BT-W3-01, BT-W3-02, BT-W3-03, BT-W3-04, BT-W3-05, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09, BT-W3-10 | 10 |
| 4 | Independent area verification | parallel | BT-W4-01, BT-W4-02, BT-W4-03, BT-W4-04, BT-W4-05, BT-W4-06 | 6 |
| 5 | Final integration | serial | BT-W5-01 | 1 |

Total: **45 packages in 6 waves**. The widest waves are Wave 1, Wave 2 (12 packages each).

**Why this shape.**

- **Wave 0** (dag) lands every SPEC §6 declaration and every PLAN §3 contract, as real code or as
  an owner-tagged stub, plus working fakes, the UI harness and placeholder test files. After it,
  every later package compiles, and the tests it writes can run in isolation. BT-W0-02 (UI
  declarations) and BT-W0-03 (test support) need only BT-W0-01 and run side by side; BT-W0-04 (UI
  harness) needs both.
- **Wave 1** builds everything that depends only on Wave 0: the pure protocol pieces, the client
  core, the adapter, the AngstromUI funnel and the CLI scaffolding.
- **Wave 2** adds the two client files that need the Wave 1 core (requests, shot counter), the CLI
  commands and the docs. Four reviewers check Wave 1 at the same time.
- **Wave 3** holds the independently written client parity suites, and the AngstromUI behaviours
  that need a working client.
- **Wave 4** is reviewers only. **Wave 5** is the final integration.

```
W0  BT-W0-01 ─▶ { BT-W0-02 ∥ BT-W0-03 } ─▶ BT-W0-04                          (dag)
W1  W1-01 W1-02 W1-03 W1-04 W1-05 W1-06 W1-07 W1-08 W1-09 W1-10 W1-11 W1-12
W2  W2-01(←W1-02,03,09) W2-02(←W1-04,09) W2-03..06(←W1-12) W2-07 W2-08 | verify W2-09..12(←W1)
W3  W3-01..05(←W2-01/02) W3-06..09(←W1-11 + W2-01/02 + W0-04) | verify W3-10(←CLI)
W4  verify W4-01..06
W5  BT-W5-01
```

### 2.1 Dependency list

| Package | Depends on |
|---|---|
| BT-W0-01 | — |
| BT-W0-02 | BT-W0-01 |
| BT-W0-03 | BT-W0-01 |
| BT-W0-04 | BT-W0-02, BT-W0-03 |
| BT-W1-01 | BT-W0-01, BT-W0-03 |
| BT-W1-02 | BT-W0-01, BT-W0-03 |
| BT-W1-03 | BT-W0-01, BT-W0-03 |
| BT-W1-04 | BT-W0-01, BT-W0-03 |
| BT-W1-05 | BT-W0-01, BT-W0-03 |
| BT-W1-06 | BT-W0-01, BT-W0-03 |
| BT-W1-07 | BT-W0-01, BT-W0-03 |
| BT-W1-08 | BT-W0-01 |
| BT-W1-09 | BT-W0-01, BT-W0-03 |
| BT-W1-10 | BT-W0-01, BT-W0-03 |
| BT-W1-11 | BT-W0-02, BT-W0-04 |
| BT-W1-12 | BT-W0-01 |
| BT-W2-01 | BT-W1-02, BT-W1-03, BT-W1-09, BT-W0-03 |
| BT-W2-02 | BT-W1-04, BT-W1-09, BT-W0-03 |
| BT-W2-03 | BT-W1-12 |
| BT-W2-04 | BT-W1-12 |
| BT-W2-05 | BT-W1-12 |
| BT-W2-06 | BT-W1-12 |
| BT-W2-07 | BT-W0-01 |
| BT-W2-08 | BT-W0-02, BT-W1-12 |
| BT-W2-09 | BT-W1-01, BT-W1-02, BT-W1-03, BT-W1-06, BT-W1-10 |
| BT-W2-10 | BT-W1-04, BT-W1-05, BT-W1-11 |
| BT-W2-11 | BT-W1-07, BT-W1-08 |
| BT-W2-12 | BT-W1-09 |
| BT-W3-01 | BT-W1-09, BT-W2-01, BT-W2-02, BT-W0-03 |
| BT-W3-02 | BT-W2-01, BT-W2-02, BT-W0-03 |
| BT-W3-03 | BT-W2-01, BT-W2-02, BT-W0-03 |
| BT-W3-04 | BT-W1-04, BT-W2-02, BT-W0-03 |
| BT-W3-05 | BT-W2-02, BT-W0-03 |
| BT-W3-06 | BT-W1-11, BT-W2-01, BT-W0-04 |
| BT-W3-07 | BT-W1-11, BT-W2-01, BT-W0-04 |
| BT-W3-08 | BT-W1-05, BT-W1-11, BT-W2-01, BT-W0-04 |
| BT-W3-09 | BT-W1-05, BT-W1-11, BT-W2-02, BT-W0-04 |
| BT-W3-10 | BT-W1-12, BT-W2-03, BT-W2-04, BT-W2-05, BT-W2-06 |
| BT-W4-01 | BT-W1-10, BT-W3-01, BT-W3-02, BT-W3-03, BT-W3-04, BT-W3-05 |
| BT-W4-02 | BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 |
| BT-W4-03 | BT-W1-08, BT-W3-01, BT-W3-02, BT-W3-03, BT-W3-04, BT-W3-05, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 |
| BT-W4-04 | BT-W1-08, BT-W2-03, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 |
| BT-W4-05 | BT-W1-06, BT-W3-02, BT-W3-10 |
| BT-W4-06 | BT-W2-07, BT-W2-08, BT-W1-08, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 |
| BT-W5-01 | BT-W4-01, BT-W4-02, BT-W4-03, BT-W4-04, BT-W4-05, BT-W4-06 |

---

## 3. Plan-level contracts (frozen by Wave 0)

These declarations are as binding as SPEC §6. The access rule for everything an agent adds is the
one in SPEC §6: `private`/`fileprivate` in library and test-support sources; internal `XCTestCase`
classes and `test…` methods (private helpers) in test files; internal command types and their
`@Option`/`@Flag`/`@Argument` properties in `cli/`.

### 3.0 Stub conventions

After Wave 0, **every** declaration of SPEC §6 and of §3.1–§3.3 below exists with its exact
signature, and the package builds. Bodies follow these rules:

- **Real in Wave 0:** every initialiser, every stored property, every constant, and the leaf
  value types (SPEC §6.1, §6.2, §6.3, §6.4, §6.5, §6.6 types, §6.7, §6.9 types incl.
  `isEmpty`/`merging`/subscript, §6.10, §6.12 `BluetoothDashboardState`, §6.15). Also
  `BluetoothCodec.readRequestFrame` and `BluetoothCodec.authFrame`, which are one-liners the client
  core needs in Wave 1.
- **Stub:** the body names its owner. A throwing function does
  `throw LaMarzoccoError.operationNotAvailable("unimplemented: BT-W1-09")`. A non-throwing one does
  `fatalError("unimplemented: BT-W1-09")`. A CLI `run()` does
  `throw CLIError("unimplemented: BT-W2-04")`.
- **Inert stubs.** These must not trap, because constructors or other packages' tests reach them
  before their owner lands:

| Declaration | Body until its owner lands | Owner |
|---|---|---|
| `LaMarzoccoBluetoothClient.init`, `isConnected` (`link != nil`), `shotCounterActive` (`shotCounterEnabled && shotCounterSubscribed && link != nil`), `authenticationFailed`, `setTimingForTesting` | real | BT-W0-01 |
| `LaMarzoccoBluetoothClient.disableShotCounter()` | `guard shotCounterEnabled else { return false }`, then the stub trap | BT-W2-02 |
| `LaMarzoccoBluetoothClient.stopNotifyInternal()` | trap if `shotCounterSubscribed && link != nil`, else `shotCounterSubscribed = false` | BT-W2-02 |
| `LaMarzoccoBluetoothClient.handleShotCounterNotification(_:)` | `guard shotCounterEnabled else { return }`, then the stub trap | BT-W2-02 |
| `BrewingTracker.init()` | real (empty data, nil start) | BT-W0-01 |
| `BluetoothOpTable.init()` | real (empty tables) | BT-W0-01 |
| `LaMarzoccoMachine` initialisers, `client` accessor, `hasCloudClient`, `hasBluetoothClient`, `setBaseDashboard`, `updateBaseDashboard`, `renderDashboard`, `setBluetoothBrewingExpiryForTesting` | real | BT-W0-02 |
| `LaMarzoccoMachine.startObservingBluetoothConnection()` | no-op | BT-W3-06 |
| `LaMarzoccoMachine.bluetoothFirst(bluetooth:cloud:)` | real when `bluetooth == nil` (`guard let cloud = cloudClient else { throw LaMarzoccoError.cloudOnlyFunctionality }; return try await cloudOperation(cloud)`), trap otherwise | BT-W3-07 |

Wave gates grep for markers (§1.5). Wave 0's gate also checks that every remaining marker names
one of the owners listed in §2.

### 3.1 `BluetoothOpTable` (`Sources/Angstrom/Bluetooth/BluetoothOpTable.swift`)

SPEC §6.10 leaves the exact generic signature to the adapter's owner. To let BT-W1-07 (the table)
and BT-W1-08 (the adapter) run in parallel, it is frozen here. It is note 06 Appendix B's
`OpTable`, generalised over the key:

```swift
/// Queue-confined table of in-flight operations (NOT thread-safe: adapter queue only).
/// Exactly-once: every completion path goes through `finish`, which removes the entry
/// BEFORE calling `complete`.
package final class BluetoothOpTable<Key: Hashable & Sendable> {
    package typealias Completion = (Result<any Sendable, any Error>) -> Void
    package init()
    /// Register an in-flight op. `isGATTRequest`: an abandoned op still owes one delegate callback.
    package func register(_ token: UInt64, key: Key, isGATTRequest: Bool, complete: @escaping Completion)
    /// Remove + complete. `abandoning: true` (timeout/cancel) records an owed reply for GATT requests.
    @discardableResult
    package func finish(_ token: UInt64, _ result: Result<any Sendable, any Error>, abandoning: Bool) -> Bool
    /// Delegate-callback path: swallow one owed reply for `key` if any, else finish the OLDEST op with `key`.
    @discardableResult
    package func finishOldest(_ key: Key, _ result: Result<any Sendable, any Error>) -> Bool
    /// A request was sent without anyone awaiting it (e.g. best-effort unsubscribe).
    package func owe(_ key: Key)
    /// An op or an owed reply is outstanding for `key`.
    package func isAwaiting(_ key: Key) -> Bool
    /// Fail every op whose key matches, and drop owed replies for matching keys.
    package func failAll(where match: (Key) -> Bool, _ error: any Error)
}
```

### 3.2 angcli internal API (`cli/Sources/angcli/Ble/`)

Landed by BT-W1-12 as stubs (types and signatures exact). They are implemented by BT-W2-03 and
used by BT-W2-04/05/06.

```swift
// Ble.swift (complete in BT-W1-12)
struct Ble: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ble",
        abstract: "Talk to a nearby La Marzocco machine over Bluetooth (debugging).",
        subcommands: [BleScan.self, BleGatt.self, BleToken.self, BleRead.self, BleCmd.self, BleListen.self])
}

// BleSession.swift (BT-W2-03)
/// Options shared by every subcommand that talks to one machine (use with @OptionGroup).
struct BleTargetOptions: ParsableArguments {
    @Option(name: .long, help: "Peripheral identifier from `angcli ble scan` (a CoreBluetooth UUID, not a MAC).")
    var peripheral: String?
    @Option(name: .long, help: "Machine serial number; used to fetch the Bluetooth token from the cloud.")
    var serial: String?
    @Option(name: .customLong("ble-token"), help: "Bluetooth token. Discouraged: it lands in your shell history; prefer LAMARZOCCO_BLE_TOKEN.")
    var bleToken: String?
    init() {}
}
enum BleTokenSource: String, Equatable, Sendable { case flag, environment, cloud }
enum BleSession {
    static let tokenEnvironmentVariable = "LAMARZOCCO_BLE_TOKEN"
    /// `BluetoothTransport.coreBluetooth()`, created once per process.
    static func makeTransport() -> BluetoothTransport
    /// Pure precedence (SPEC §10.2): non-empty flag, then non-empty env var; nil → ask the cloud.
    static func localToken(flag: String?, environment: [String: String]) -> (token: BluetoothAuthToken, source: BleTokenSource)?
    /// localToken, else Bootstrap.connect() + MachineSelector.choose(serial:) + bluetoothAuthToken(serial:).
    static func resolveToken(_ options: BleTargetOptions,
                             environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> BluetoothAuthToken
    /// Pure rule: exactly one → it; none → throws CLIError("No La Marzocco machine found nearby"); several → nil (caller prompts).
    static func selectPeripheral(from found: [DiscoveredPeripheral]) throws -> DiscoveredPeripheral?
    /// --peripheral, else a 5 s discoverMachines scan + selectPeripheral + an interactive pick on stderr.
    static func resolvePeripheral(_ options: BleTargetOptions, transport: BluetoothTransport) async throws -> BluetoothPeripheralID
    static func makeClient(_ options: BleTargetOptions, transport: BluetoothTransport) async throws -> LaMarzoccoBluetoothClient
    /// SPEC §10.3 error texts for .bluetoothUnavailable; other errors → their errorDescription.
    static func cliError(_ error: any Error) -> CLIError
}

// BleOutput.swift (BT-W2-03). Every function returns one JSON line (SPEC §10.3) or nil if encoding fails.
enum BleOutput {
    static func rawLine(_ frame: RawBluetoothFrame, ts: String = Timestamp.now()) -> String?
    static func shotCounterLine(_ event: ShotCounterEvent, ts: String = Timestamp.now()) -> String?
    static func connectionLine(_ event: ConnectionEvent, ts: String = Timestamp.now()) -> String?
    static func peripheralLine(_ peripheral: DiscoveredPeripheral) -> String?
    static func gattLines(_ services: [BluetoothGATTService]) -> [String]
    static func readLine<D: Encodable>(setting: BluetoothReadSetting, raw: Data, decoded: D?,
                                       ts: String = Timestamp.now()) -> String?
    static func commandLine(command: String, status: BluetoothCommandStatus, ts: String = Timestamp.now()) -> String?
    /// {"token":"**REDACTED**","length":n} unless showSecret.
    static func tokenLine(_ token: BluetoothAuthToken, showSecret: Bool) -> String?
}

// Output.swift addition (complete in BT-W1-12): SPEC §10.4.
extension Redact {
    static func bluetoothFrame(_ frame: RawBluetoothFrame) -> (hex: String, text: String?)
}
```

`BleScan`, `BleGatt`, `BleToken`, `BleRead`, `BleCmd` and `BleListen` are `AsyncParsableCommand`
structs, each in its own file. Their options belong to their implementing package (SPEC §10.1).

### 3.3 UI test harness (`Tests/AngstromUITests/Bluetooth/BluetoothMachineHarness.swift`)

Landed complete by BT-W0-04 and used by every AngstromUI Bluetooth test. It builds a **real**
`LaMarzoccoBluetoothClient` over the AngstromTestSupport fakes (SPEC §9.2: no mocked client), and
optionally a cloud client over the existing `MockBackend`/`MockURLProtocol`
(`Tests/AngstromUITests/MockTransport.swift`, unchanged).

```swift
@MainActor
final class BluetoothMachineHarness {
    enum Seed { case standard, empty, none, custom(Dashboard) }   // .standard leaves connectionDate nil; upstream's snapshot
                                                                  // fixture also sets connection_date (TBD:64-65): use .custom for that
    enum BluetoothFailure: Equatable {
        case none
        case connect                                   // every connect attempt fails .disconnected(code: 7) — via central.connectFailure
        case commandWrite                              // writes to 0b0b… throw .gatt(domain: "CBATTErrorDomain", code: 14)
        case commandTimeout                            // writes to 0b0b… throw .timedOut("write")
        case unavailable(BluetoothAvailability)        // central reports this availability
    }
    static let serial: String                         // "MR123456"
    let central: FakeBluetoothCentral
    let sleeper: ManualBluetoothSleeper               // manual: [.idleDisconnect]
    let clock: BluetoothTestClock                     // starts 2026-01-01T12:00:00Z
    let backend: MockBackend?                         // nil when cloud == false
    let bluetooth: LaMarzoccoBluetoothClient?         // nil when bluetooth == false
    let machine: LaMarzoccoMachine
    /// `.standard` seeds BT-DASH-SEED-001 (SPEC §9.3.6) for `model` through a MachineSnapshot;
    /// `.empty` seeds Dashboard(machine: Machine(serialNumber:, model:), widgets: []); `.none` seeds nothing.
    init(model: Model = .lineaMicra, seed: Seed = .standard, cloud: Bool = true, bluetooth: Bool = true,
         token: String = "token",                      // the token the scripted machine ACCEPTS; the client always sends "token"
         settingResponses: [BluetoothReadSetting: Data] = [:],
         commandResponse: Data = BluetoothTestVectors.commandSuccess, failure: BluetoothFailure = .none)
    /// BT-DASH-SEED-001: CMMachineStatus(standby,[brewing,standby],standby), CMCoffeeBoiler(standby, enabled,
    /// enabledSupported false, 93.0, 80…100 step 0.1), CMSteamBoilerLevel(standby, enabled, true, level1, true),
    /// CMSteamBoilerTemperature(standby, enabled, false, 126.0, 126…131 step 1.0, true); all index 1.
    static func seedDashboard(model: Model) -> Dashboard
    var links: [FakeBluetoothLink] { get }                          // central.links
    func bluetoothWrites(to characteristic: GATTUUID) -> [Data]     // across all links, in order
    func cloudCommandCount(_ name: String) -> Int                   // backend path suffix "/command/<name>"
    func cloudCommandBody(_ name: String) throws -> [String: Any]?  // JSON body of the last such command
}
```

The cloud backend answers `/auth/init`, `/auth/signin`, `/dashboard`, `/settings`,
`/scheduling` and `/stats` from the existing `Tests/AngstromUITests/Fixtures`, and acknowledges
every `/command/` with `[{"id":"cmd1","status":"Pending"}]`. That mirrors `fixtureBackend()` in
`LaMarzoccoMachineTests.swift:14-33`.

### 3.4 Test-file inventory

BT-W0-03 creates every library file below as a placeholder (imports plus an empty
`final class <Name>: XCTestCase {}` whose doc comment names the owner), BT-W0-04 every UI file,
and BT-W1-12 every CLI file. The owner replaces the placeholder. The manifest lists each file under
its owner's `owns.modify`.

| File | Owner |
|---|---|
| `Tests/AngstromTests/Bluetooth/FakeBluetoothTests.swift` | BT-W0-03 (creates, complete) |
| `Tests/AngstromTests/Bluetooth/BluetoothEnumsTests.swift`, `BluetoothWireCoercionTests.swift`, `BluetoothModelsTests.swift` | BT-W1-01 |
| `…/BluetoothCodecTests.swift` | BT-W1-02 |
| `…/BluetoothResponseDecoderTests.swift` | BT-W1-03 |
| `…/BrewingStateMachineTests.swift`, `ShotCounterNotificationDecoderTests.swift` | BT-W1-04 |
| `…/DashboardBluetoothTests.swift` | BT-W1-05 |
| `…/BluetoothTokenTests.swift` | BT-W1-06 |
| `…/BluetoothOpTableTests.swift` | BT-W1-07 |
| `…/BluetoothClientCoreTests.swift` | BT-W1-09 |
| `…/BluetoothDiscoveryTests.swift` | BT-W1-10 |
| `…/BluetoothClientRequestsSmokeTests.swift` | BT-W2-01 |
| `…/BluetoothClientShotCounterSmokeTests.swift` | BT-W2-02 |
| `…/BluetoothConnectionTests.swift`, `BluetoothAuthTests.swift` | BT-W3-01 |
| `…/BluetoothRequestTests.swift`, `BluetoothDiagnosticsTests.swift` | BT-W3-02 |
| `…/ShotCounterLifecycleTests.swift` | BT-W3-03 |
| `…/ShotCounterNotificationTests.swift`, `ShotCounterRecordedSessionTests.swift` | BT-W3-04 |
| `…/ShotCounterReconnectTests.swift` | BT-W3-05 |
| `Tests/AngstromUITests/Bluetooth/BluetoothMachineHarness.swift`, `BluetoothMachineHarnessTests.swift` | BT-W0-04 (creates, complete) |
| `Tests/AngstromUITests/Bluetooth/MachineTransportRoutingTests.swift` | BT-W1-11 |
| `…/BluetoothDeviceStateTests.swift` | BT-W3-06 |
| `…/BluetoothFallbackTests.swift`, `BluetoothCommandSideEffectTests.swift` | BT-W3-07 |
| `…/BluetoothDashboardRefreshTests.swift` | BT-W3-08 |
| `…/ShotCounterOverlayTests.swift` | BT-W3-09 |
| `cli/Tests/angcliTests/BleSessionTests.swift`, `BleOutputTests.swift` | BT-W2-03 |
| `cli/Tests/angcliTests/BleDiscoveryCommandTests.swift` | BT-W2-04 |
| `cli/Tests/angcliTests/BleRequestCommandTests.swift` | BT-W2-05 |
| `cli/Tests/angcliTests/BleListenTests.swift` | BT-W2-06 |

No existing test file changes (SPEC §7.1).

### 3.5 Test conventions and the gap-test glossary

- XCTest only. `final class …Tests: XCTestCase`. AngstromUITests classes are `@MainActor`. Use
  `@testable import Angstrom` (and `@testable import AngstromUI`) and `import AngstromTestSupport`.
- **Doc-comment header (checked mechanically by BT-W5-01):**
  - A parity test starts with `/// Upstream: <test function> (<path>:<line>) [<case ids>]`, for
    example `/// Upstream: test_ble_set_power (tests/test_bluetooth_client.py:295) [C01]`. The
    path is relative to `$UPSTREAM`. The line is the `def` line listed in §7.2.
  - An Angstrom-only test starts with `/// Angstrom-only: <G-… or D… id> — <one line>`. Where no
    G-/D- id applies (test-support self-tests, and tests a brief names without an id), the id is the
    SPEC section the test pins: `/// Angstrom-only: §6.17 — <one line>`.
- Timing comes only from `ManualBluetoothSleeper`, `BluetoothTestClock` and
  `setBluetoothBrewingExpiryForTesting`. Await background work with
  `drainBackgroundWorkForTesting()`, and await stream events by iterating the stream (with a
  bounded `XCTestExpectation` timeout of ≤ 5 s as a hang guard only).
- **Gap-test glossary.** These are upstream behaviours that no upstream test covers (research note
  04 §4), restated for Swift. Every id has exactly one owner.

| Id | Behaviour to assert (Swift terms) | Owner |
|---|---|---|
| G-CODEC-1 | `readToken`: one connect attempt (10 s), no auth, reads `0c0b…`, strict UTF-8, **no** NUL stripping, always disconnects | BT-W1-10 |
| G-CODEC-2 | Bytes of `setSteam(on:)` and `setPower(on: false)` (BT-REQ-005, BT-REQ-002) | BT-W1-02 |
| G-CODEC-3 | Coercion rules of SPEC §3.10, incl. `"false"` → false (D5a), container truthiness, required-string `null` → `"None"`, container → JSON text (D5c), int truncation and range (D5d), non-finite and `_` strings rejected (D5e/f), numeric strings | BT-W1-01 |
| G-CODEC-4 | Reads cut at the first NUL. Notifications strip NULs at both ends only; an inner NUL drops the notification | BT-W1-02 (reads), BT-W1-04 (notifications) |
| G-CODEC-5 | Malformed read responses (`[]` capabilities, unknown mode, non-JSON) throw `.decoding`, do **not** drop the link | BT-W3-02 |
| G-CODEC-6 | Command status with a missing key or non-object → `.decoding("bluetooth command: …")` | BT-W1-03 |
| G-CODEC-7 | `MachineStatistics`: absent or `null` → unset and the rest of the notification is processed; a JSON string → its parsed content, a parsed `null` → unset; any other value, or an unparseable string, drops the whole notification, brewing keys included (BT-NTF-COERCE-002…005) | BT-W1-04 |
| G-CODEC-8 | Discovery skips a peripheral whose name is nil or empty | BT-W1-10 |
| G-AUTH-1 | A transport error during the auth write or read → `.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: …")`, not the auth case | BT-W3-01 |
| G-AUTH-2 | Auth poll interval: 9 `.authPoll` sleeps of 50 ms for 10 reads | BT-W3-01 |
| G-AUTH-3 | `authenticationFailed` reflects the last auth read and is unchanged by a pre-auth connect failure | BT-W3-01 |
| G-CONN-1 | Connect: 3 attempts, 20 s timeout each, backoff 0.25 s after `.timedOut`, else 0.1 s | BT-W1-09 |
| G-CONN-2 | A characteristic found by the in-place rediscovery serves the request on the same link (D7b) | BT-W3-01 |
| G-CONN-3 | Teardown completes and emits its events on every path when the link is already dead (its ops throw `.notConnected`). The seam's `disconnect()`/`unsubscribe` are non-throwing, so there is nothing to swallow | BT-W1-09 |
| G-CONN-4 | The idle timer is re-armed on a reused link, armed only after auth, and requests 30 s | BT-W3-01 |
| G-CONN-5 | With the shot counter enabled but no link, a failed request **does** drop (schedules `dropConnectionInBackground`) | BT-W3-01 |
| G-CONN-6 | A missing characteristic drops the link even while the shot counter runs, which then starts the reconnect loop | BT-W3-03 |
| G-CONN-7 | A link loss cancels the idle task (D16) | BT-W3-01 |
| G-CONN-8 | A link drop between a request's write and read fails the request; no silent reconnect (D7a) | BT-W3-01 |
| G-RC-1 | Reconnect backoff `1,2,4,8,16,32,60,60` s, doubling only after connection-class failures | BT-W3-05 |
| G-RC-2 | Auth failures are cumulative per loop run: auth, conn, auth, auth → gives up | BT-W3-05 |
| G-RC-3 | The characteristic disappears during a reconnect → give up, idle timer re-armed, no second `.unsubscribed` | BT-W3-05 |
| G-RC-4 | `startShotCounter()` throws when the first connect/auth fails, disables the counter, starts no loop | BT-W3-03 |
| G-RC-5 | An idle or error-path drop while the counter is enabled starts the reconnect loop | BT-W3-05 |
| G-SC-1 | `stopShotCounter()` with no counter running only re-arms the idle timer | BT-W3-03 |
| G-SC-2 | (callbacks) not applicable (D4). Covered by C31 restated | BT-W3-04 |
| G-SC-3 | The tracker resets on every successful subscribe | BT-W3-04 |
| G-SC-4 | A notification after `stopShotCounter()` is silently dropped | BT-W3-03 |
| G-SC-5 | A second start while subscribed: no resubscribe, no `.subscribed`, tracker and replay flag kept | BT-W3-03 |
| G-SC-6 | `startShotCounter()` while a reconnect is pending: both serialise on the connection gate; one subscribe | BT-W3-03 |
| G-SC-7 | The reconnect loop sleeps before its first attempt | BT-W3-05 |
| G-DEV-1 | A non-success BLE status falls through to the cloud when a cloud client exists | BT-W3-07 |
| G-DEV-2 | `.bluetoothTimedOut` and `.decoding` from BLE propagate with no cloud call | BT-W3-07 |
| G-DEV-3 | BLE widget defaults (Mini vs others), coffee never `.off`, missing steam entry keeps stale steam widgets, duplicate ids: last wins | BT-W1-05 |
| G-DEV-4 | Steam-level edges: 130.5 → level3, −1 → level3, 127.99 → level1 (on `Double` targets; the upstream decode path truncates first, D9) | BT-W1-01 |
| G-DEV-5 | A REST `refreshDashboard()` during an active overlay re-applies the overlay to the new widget | BT-W3-09 |
| G-DEV-6 | `.subscribed` after a reconnect does not clear the overlay; only expiry or loss does | BT-W3-09 |
| G-DEV-7 | Telemetry `MachineMode` also updates `CMMachineGroupStatus.mode` | BT-W3-09 |
| G-DEV-8 | Auto-standby `"HH:MM"`: 1440 → `"24:00"`, 61 → `"01:01"`, 0 → `"00:00"` | BT-W3-07 |
| G-DEV-9 | `isBluetoothConnected` follows the real client's connection events | BT-W3-06 |
| G-DEV-10 | A created `CMMachineStatus` gets `[brewing, standby]`; an existing one keeps `availableModes`/`brewingStartTime` | BT-W1-05 |
| G-DEV-11 | `setSteam` updates both steam widgets when both exist | BT-W3-07 |
| G-DEV-12 | Device state is mutated **before** the `bluetoothEvents()` event is emitted | BT-W3-09 |
| G-DEV-13 | Every client event is handled on the MainActor before widgets or the expiry are touched (design check) | BT-W4-03 |

### 3.6 Refinements of SPEC §7 (file map and work packages)

| # | Refinement | Why |
|---|---|---|
| R1 | No `Sources/AngstromBluetooth/Placeholder.swift`. BT-W0-01 instead creates `BluetoothTransport+CoreBluetooth.swift` with the two §6.14 public declarations as stubs. BT-W1-08 adds the adapter files. | The target compiles from Wave 0, and no file is created only to be deleted. |
| R2 | `BluetoothOpTable`'s generic signature is frozen in §3.1 instead of being left to the adapter's owner. | It lets the table and the adapter be built in parallel. |
| R3 | The SPEC's "U1" splits into BT-W0-02 (declarations), BT-W1-11 (the dashboard funnel and the BLE-first routing of the six methods in `LaMarzoccoMachine.swift`), and BT-W3-06/07/08 (one extension file each). `LaMarzoccoMachine.swift` has exactly one owner after Wave 0. | Parallelism without sharing the main file. |
| R4 | The SPEC's "T5/T6" suites are owned by the UI packages that implement the behaviour. | Avoids a sixth wave. Independence comes from BT-W4-02. |
| R5 | `BluetoothClientSmokeTests.swift` becomes `BluetoothClientCoreTests.swift` (W1-09), `BluetoothClientRequestsSmokeTests.swift` (W2-01) and `BluetoothClientShotCounterSmokeTests.swift` (W2-02). | One test file per client file owner. |
| R6 | C51 (`test_ble_device_callback`) moves from `BluetoothDiscoveryTests` to `BluetoothConnectionTests` (BT-W3-01). M15 moves from `ShotCounterOverlayTests` to `BluetoothDeviceStateTests` (BT-W3-06). | Each test needs code from its new owner's wave. |
| R7 | Upstream `test_cloud_only_without_cloud_client` (`tests/test_thing.py:29`) is added to the matrix as **T00**, owned by BT-W1-11. | The SPEC matrix omitted it, but it pins the `@cloud_only` behaviour (Q3). |
| R8 | `cli/Tests/angcliTests/BleTests.swift` is split into five files (§3.4). | One file per CLI package. |
| R9 | The UI test harness (§3.3) and the angcli internal API (§3.2) are frozen by the plan. | Shared helpers without shared ownership. |
| R10 | Gates G5/G5' (no warnings, from-scratch build) and the doc-comment headers (§3.5) are plan rules. | They make "no orphan test" and "Swift 6 clean" mechanical. |
| R11 | The SPEC's "T0" splits into BT-W0-03 (AngstromTestSupport and the library placeholders, needs only BT-W0-01) and BT-W0-04 (the UI harness and UI placeholders, needs BT-W0-02). Wave 0 runs as a dag, so BT-W0-02 and BT-W0-03 run side by side. | Shortens the critical path by one package. |

---

## 4. Work packages

Each manifest `brief` is one prompt that can be handed to an agent verbatim. It is built from a common preamble,
the package's **Task** text (shown below), its **Tests** and its **Acceptance** commands. The preamble covers the
role, worktree, files to read, `$UPSTREAM`, the frozen-contract rule, the exact owned paths, the platform rules,
the test doc-comment headers, and the STOP and BLOCKED-BY protocols. There are three preambles, for implement/docs,
verify and integrate packages. They are spelled out in full in every manifest brief.

### Wave 0 — Contracts (dag)

#### BT-W0-01 — Core contracts: Package.swift, errors, seam, leaf types, every core stub

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 0 | implement | L | — |

- **Owns, create:** `Sources/Angstrom/Bluetooth/BluetoothConstants.swift`, `Sources/Angstrom/Bluetooth/BluetoothTransport.swift`, `Sources/Angstrom/Bluetooth/BluetoothAuthToken.swift`, `Sources/Angstrom/Bluetooth/BluetoothEnums.swift`, `Sources/Angstrom/Bluetooth/BluetoothModels.swift`, `Sources/Angstrom/Bluetooth/BluetoothWireCoercion.swift`, `Sources/Angstrom/Bluetooth/BluetoothShotCounterModels.swift`, `Sources/Angstrom/Bluetooth/BluetoothDiagnostics.swift`, `Sources/Angstrom/Bluetooth/BluetoothCodec.swift`, `Sources/Angstrom/Bluetooth/BluetoothResponseDecoder.swift`, `Sources/Angstrom/Bluetooth/BrewingStateMachine.swift`, `Sources/Angstrom/Bluetooth/Dashboard+Bluetooth.swift`, `Sources/Angstrom/Bluetooth/BluetoothOpTable.swift`, `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient.swift`, `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Requests.swift`, `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+ShotCounter.swift`, `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Discovery.swift`, `Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift`, `Sources/AngstromBluetooth/BluetoothTransport+CoreBluetooth.swift`, `Tests/AngstromTestSupport/AngstromTestSupport.swift`, `Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt`
- **Owns, modify:** `Package.swift`, `Sources/Angstrom/Models.swift`, `Sources/Angstrom/Commands.swift`
- **SPEC:** §3.10; §4.11 (merge rule); §5.1; §5.3; §6.1–§6.15; §7.1; §12 D8; PLAN §3.0; PLAN §3.1
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:40-54`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:57-64`; `$UPSTREAM/src/pylamarzocco/const.py:11-31`; `$UPSTREAM/src/pylamarzocco/const.py:141-146`; `$UPSTREAM/src/pylamarzocco/const.py:182`; `$UPSTREAM/src/pylamarzocco/const.py:198-218`; `$UPSTREAM/src/pylamarzocco/const.py:260-275`; `$UPSTREAM/src/pylamarzocco/const.py:307-339`; `$UPSTREAM/src/pylamarzocco/models/_bluetooth.py:22-213`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:58-84`; `$UPSTREAM/src/pylamarzocco/exceptions.py:20-47`; `$UPSTREAM/src/pylamarzocco/models/_general.py:128-136`; `$UPSTREAM/tests/fixtures/machine/shot_counter_2026-10-05.txt`
- **Deliverables:**
  - Package.swift: AngstromBluetooth product + target; AngstromTestSupport target (path Tests/AngstromTestSupport, resources [.copy("Fixtures")]); both test targets depend on it.
  - LaMarzoccoError: five new cases, verbatim errorDescription texts, isBluetoothConnectionFailure; Machine doc-comment rewording.
  - CommandResponse package init.
  - Fully implemented leaf types: constants, timing, seam types/protocols, RealSleeper, token, enums + mappings, models, wire coercion, shot-counter models (isEmpty/merging), RawBluetoothFrame, BluetoothDashboardState, BluetoothCodec.readRequestFrame/authFrame.
  - Stub files with frozen signatures for codec, decoder, state machine, dashboard transforms, cloud token, op table, CoreBluetooth transport, and the four client files (stored state + init real).
  - AngstromTestSupport skeleton + verbatim REC fixture.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test
  swift build --package-path cli
  swift test --package-path cli
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c 'cmp Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt "$UPSTREAM/tests/fixtures/machine/shot_counter_2026-10-05.txt"'
  bash -c '! grep -rnE "^(@preconcurrency )?import CoreBluetooth" Sources/Angstrom Sources/AngstromUI'
  bash -c '! grep -rn "import XCTest" Tests/AngstromTestSupport'
  bash -c 'grep -q "AngstromBluetooth" Package.swift && grep -q "AngstromTestSupport" Package.swift && ! grep -q unsafeFlags Package.swift'
  bash -c '! grep -rhoE "unimplemented: BT-W[0-9]-[0-9]+" Sources Tests | sed "s/unimplemented: //" | sort -u | grep -vxE "BT-W1-(0[2-9]|10)|BT-W2-0[12]"'
  ```
- **Risks:**
  - A trapping stub reachable from a constructor breaks every later test. Follow the PLAN §3.0 inert list exactly.
  - New LaMarzoccoError cases break exhaustive switches. The only in-repo switch is errorDescription; check cli/ too (`grep -rn "case .operationNotAvailable" Sources cli`).
  - The CFBoolean hazard in coercion: `as? Bool` also matches the numbers 0 and 1.
- **Task (brief body):** Land the compile-time skeleton of the whole core Bluetooth surface so every later package compiles and can be tested in isolation. (1) Package.swift exactly per the SPEC §7.1 row: add product `.library(name: "AngstromBluetooth", targets: ["AngstromBluetooth"])`, target `.target(name: "AngstromBluetooth", dependencies: ["Angstrom"])`, target `.target(name: "AngstromTestSupport", dependencies: ["Angstrom"], path: "Tests/AngstromTestSupport", resources: [.copy("Fixtures")])`, and add "AngstromTestSupport" to the dependencies of BOTH test targets. No unsafeFlags, no new package dependency. (2) Sources/Angstrom/Models.swift: SPEC §6.4 verbatim. Append the five cases at the END of LaMarzoccoError, add their errorDescription texts character for character, add `isBluetoothConnectionFailure` (true for .bluetoothConnectionFailed, .bluetoothAuthenticationFailed, .bluetoothUnavailable), and reword the doc comments at Models.swift:25-26 and :29-31. Do not add a Machine field or change coding. Sources/Angstrom/Commands.swift: add §6.15 `package init(id: String, status: CommandStatus, errorCode: String?)` inside CommandResponse. (3) Fully implement the 'real in Wave 0' items of PLAN §3.0. BluetoothConstants.swift (§6.1): UUIDs and constants copied from $UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:40-54; BluetoothTiming defaults exactly as §6.1. BluetoothTransport.swift (§6.2): every public/package value type, the three protocols, RealSleeper via `Task.sleep(for:)`, and BluetoothTransportError.description. BluetoothAuthToken.swift (§6.3): description "**REDACTED**", debugDescription "BluetoothAuthToken(**REDACTED**)", empty Mirror, NOT Codable. BluetoothEnums.swift (§6.5): raw values from const.py:322-339 and :307-311. Model(bluetoothFamily:) uppercases, removes ALL whitespace, then applies the table in the §6.5 doc comment (const.py:198-218 including the e0f0249 aliases "GS3"→.gs3AV and "LINEA"→.lineaMini; Model.match stays unchanged, D8). Also Model.steamLevelModels/steamTemperatureModels, MachineState(bluetoothMode:) and BoilerStatus(bluetoothMode:) (_machine.py:65-75), and the SteamLevel mappings (_machine.py:58-62 and :78-84: 0 < t < 128 → .level1; 128 ≤ t ≤ 130 → .level2; else .level3). BluetoothModels.swift (§6.6): types and memberwise public inits; isSuccess = status.lowercased() == "success". BluetoothWireCoercion.swift (§6.7): implement the SPEC §3.10 table exactly, including the hazard rule (a JSON boolean only when CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(); integer vs float via CFNumberIsFloatType). Failure.detail texts are free-form. BluetoothShotCounterModels.swift (§6.9): every type; isEmpty; merging(_:) where other's non-nil fields overwrite and a merge never clears (§4.11); the BluetoothJSONValue subscript; BluetoothShotCounterUpdate.init that fills brewingStartTime = receivedAt − timerValue when it is nil, state == .brewing and timerValue != nil; DecodedShotCounterNotification. BluetoothDiagnostics.swift (§6.10): RawBluetoothFrame with the exact marker strings; mtuMarker(n) = "[mtu \(n)]". In Dashboard+Bluetooth.swift, BluetoothDashboardState (§6.12) is real. In BluetoothCodec.swift, readRequestFrame (UTF8(rawValue)+[0x00]) and authFrame (UTF8(token.rawValue), no NUL) are real. (4) Stub everything else with the exact frozen signatures and owner markers (PLAN §3.0). Owners: the rest of BluetoothCodec.swift → BT-W1-02; BluetoothResponseDecoder.swift → BT-W1-03; BrewingStateMachine.swift (deriveState, BrewingTracker with a real init and private stored data, ShotCounterNotificationDecoder) → BT-W1-04; the Dashboard+Bluetooth.swift extension methods → BT-W1-05; LaMarzoccoCloudClient+BluetoothToken.swift → BT-W1-06; BluetoothOpTable.swift with the PLAN §3.1 signature (real init) → BT-W1-07; Sources/AngstromBluetooth/BluetoothTransport+CoreBluetooth.swift with the two §6.14 public declarations → BT-W1-08 (no CoreBluetooth import needed yet). LaMarzoccoBluetoothClient.swift: every §6.11 public member SPEC assigns to main, ALL frozen internal stored state, a real init (timing = BluetoothTiming(), empty listener and task tables, tracker = BrewingTracker(), every flag false, central/sleeper/now taken from the transport), the [main] helper and test-seam stubs → BT-W1-09, and the inert members of PLAN §3.0. LaMarzoccoBluetoothClient+Requests.swift: the [+Requests] members → BT-W2-01. +ShotCounter.swift: the [+ShotCounter] members, including the inert fast paths of PLAN §3.0 → BT-W2-02. +Discovery.swift → BT-W1-10. Put every declaration in the file SPEC §6.11 assigns it to. (5) Test-support skeleton: Tests/AngstromTestSupport/AngstromTestSupport.swift containing only `import Angstrom` and a module doc comment (it must NOT import XCTest), and a byte-identical copy of $UPSTREAM/tests/fixtures/machine/shot_counter_2026-10-05.txt at Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt (85 lines). Write no new tests (BT-W1-01 tests the leaf types). The existing 177 library and 15 CLI tests must stay green. In your report, list every existing `switch` over LaMarzoccoError that needed new arms.

#### BT-W0-02 — AngstromUI contracts: optional cloud client, BLE state, extension-file stubs

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 0 | implement | M | BT-W0-01 |

- **Owns, create:** `Sources/AngstromUI/MachineBluetoothEvent.swift`, `Sources/AngstromUI/LaMarzoccoMachine+BluetoothCommands.swift`, `Sources/AngstromUI/LaMarzoccoMachine+BluetoothDashboard.swift`, `Sources/AngstromUI/LaMarzoccoMachine+BluetoothConnection.swift`, `Sources/AngstromUI/LaMarzoccoMachine+ShotCounter.swift`
- **Owns, modify:** `Sources/AngstromUI/LaMarzoccoMachine.swift`
- **SPEC:** §4.15; §5.8; §6.16; §13; PLAN §3.0
- **Upstream:** `$UPSTREAM/src/pylamarzocco/devices/_thing.py:27-38`; `$UPSTREAM/src/pylamarzocco/devices/_thing.py:73-126`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:88`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:132-156`
- **Deliverables:**
  - LaMarzoccoMachine compiles against SPEC §6.16: cloudClient/bluetooth/client accessor, designated + convenience init, widened setters, base/overlay storage and funnel functions, BLE observable state and plumbing.
  - MachineBluetoothEvent.swift complete.
  - Four extension files with frozen signatures (stubs; bluetoothFirst's no-Bluetooth path real).
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -n "private let client" Sources/AngstromUI/LaMarzoccoMachine.swift'
  bash -c '! grep -rnE "^(@preconcurrency )?import CoreBluetooth" Sources/AngstromUI'
  bash -c '! grep -rhoE "unimplemented: BT-W[0-9]-[0-9]+" Sources/AngstromUI | sed "s/unimplemented: //" | sort -u | grep -vxE "BT-W3-0[6-9]"'
  ```
- **Risks:**
  - Changing `client` to a throwing accessor can silently change control flow in non-throwing contexts (stop(), Task closures). Keep behaviour identical when a cloud client is present.
  - Pre-existing warnings in LaMarzoccoMachine.swift would trip gate G5. Report them (PLAN §9.2).
- **Task (brief body):** Make AngstromUI compile against SPEC §6.16 without changing any cloud behaviour. In Sources/AngstromUI/LaMarzoccoMachine.swift: replace `private let client: LaMarzoccoCloudClient` with `let cloudClient: LaMarzoccoCloudClient?`, `public let bluetooth: LaMarzoccoBluetoothClient?` and `var client: LaMarzoccoCloudClient { get throws }`, which throws LaMarzoccoError.cloudOnlyFunctionality when cloudClient is nil. Widen dashboard, settings, schedule, statistics, isLive, isConnected, lastUpdateAt and lastError from `public private(set)` to `public internal(set)`. Add `var baseDashboard: Dashboard?`, the five new observable properties and the six @ObservationIgnored plumbing properties with exactly the §6.16 types and defaults. Add the designated `public init(serialNumber:client:bluetooth:snapshot:)` and turn the existing initialiser into a `public convenience init(serialNumber:client:snapshot:)` that delegates to it. Snapshot seeding is unchanged, but it must also set baseDashboard. If `bluetooth != nil`, the designated init calls startObservingBluetoothConnection(). Implement for real: hasCloudClient, hasBluetoothClient, setBaseDashboard(_:) (sets baseDashboard, then renderDashboard()), updateBaseDashboard(_:) (applies the transform to baseDashboard if non-nil, then renders), and renderDashboard() (`dashboard = bluetoothBrewingUpdate == nil ? baseDashboard : baseDashboard?.overlayingBluetoothBrewing(bluetoothBrewingUpdate)`). Make requireModel and capturing `internal`. clientForTesting returns `cloudClient!`. Make only the minimal call-site edits needed to compile (`try client` in throwing paths; stop() uses `cloudClient?`). Do NOT convert the existing `dashboard = …` assignment sites and do NOT route the six BLE-first commands: that is BT-W1-11. Create MachineBluetoothEvent.swift, complete per §6.16. Create the four extension files with the exact frozen signatures. In +BluetoothCommands.swift, bluetoothFirst implements the no-Bluetooth path for real (PLAN §3.0) and traps with owner BT-W3-07 otherwise. +BluetoothDashboard.swift → BT-W3-08. +BluetoothConnection.swift: startObservingBluetoothConnection is a no-op and bluetoothConnectionEvents is a stub, owner BT-W3-06. +ShotCounter.swift: setBluetoothBrewingExpiryForTesting is real (assigns the two properties), everything else is a stub, owner BT-W3-09. Record in your report every compiler warning in LaMarzoccoMachine.swift that existed before your change: run `swift build` on the base commit first. The unmodified Tests/AngstromUITests/LaMarzoccoMachineTests.swift must pass.

#### BT-W0-03 — Test support: fakes, sleeper, clock, vectors, recording, library test placeholders

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 0 | implement | L | BT-W0-01 |

- **Owns, create:** `Tests/AngstromTestSupport/FakeBluetoothCentral.swift`, `Tests/AngstromTestSupport/FakeBluetoothLink.swift`, `Tests/AngstromTestSupport/ManualBluetoothSleeper.swift`, `Tests/AngstromTestSupport/BluetoothTestClock.swift`, `Tests/AngstromTestSupport/BluetoothTestVectors.swift`, `Tests/AngstromTestSupport/ShotCounterRecording.swift`, `Tests/AngstromTests/Bluetooth/FakeBluetoothTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothEnumsTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothWireCoercionTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothModelsTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothCodecTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothResponseDecoderTests.swift`, `Tests/AngstromTests/Bluetooth/BrewingStateMachineTests.swift`, `Tests/AngstromTests/Bluetooth/ShotCounterNotificationDecoderTests.swift`, `Tests/AngstromTests/Bluetooth/DashboardBluetoothTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothTokenTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothOpTableTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothClientCoreTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothDiscoveryTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothClientRequestsSmokeTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothClientShotCounterSmokeTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothConnectionTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothAuthTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothRequestTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothDiagnosticsTests.swift`, `Tests/AngstromTests/Bluetooth/ShotCounterLifecycleTests.swift`, `Tests/AngstromTests/Bluetooth/ShotCounterNotificationTests.swift`, `Tests/AngstromTests/Bluetooth/ShotCounterRecordedSessionTests.swift`, `Tests/AngstromTests/Bluetooth/ShotCounterReconnectTests.swift`
- **Owns, modify:** —
- **SPEC:** §4.2 step 3; §5.3; §6.17; §9.1; §9.2; §9.3.4 (harness); PLAN §3.4; PLAN §3.5
- **Upstream:** `$UPSTREAM/tests/test_bluetooth_client.py:40-59`; `$UPSTREAM/tests/test_bluetooth_client.py:86-154`; `$UPSTREAM/tests/test_bluetooth_client.py:157-292`; `$UPSTREAM/tests/test_bluetooth_client.py:886-909`; `$UPSTREAM/tests/fixtures/machine/shot_counter_2026-10-05.txt`
- **Deliverables:**
  - Working AngstromTestSupport per SPEC §6.17 (package access, no XCTest import).
  - Self-tests for the fakes.
  - Every library placeholder test file of PLAN §3.4.
- **Tests:**
  - FakeBluetoothTests.testCentralPopsQueuedOutcomesThenMakeLink
  - FakeBluetoothTests.testConnectCountAndTimeoutsRecorded
  - FakeBluetoothTests.testAvailabilityUpdatesYieldOnSet
  - FakeBluetoothTests.testLinkRecordsOpsInOrder
  - FakeBluetoothTests.testDiscoverHonoursPresentAndPresentAfterRefresh
  - FakeBluetoothTests.testScriptedAuthConfirmsOnNthRead
  - FakeBluetoothTests.testScriptedSettingAndCommandResponses
  - FakeBluetoothTests.testReplayDeliveredBeforeSubscribeReturns
  - FakeBluetoothTests.testDefaultReplayIsTick334 (TBC:176; `[]` delivers nothing)
  - FakeBluetoothTests.testReplayStampedWithTransportClock
  - FakeBluetoothTests.testDropYieldsDisconnectedOnceAndFinishes
  - FakeBluetoothTests.testOpsAfterDropThrowNotConnected
  - FakeBluetoothTests.testUserDisconnectYieldsDisconnected
  - FakeBluetoothTests.testBeforeOpHoldsOperation
  - FakeBluetoothTests.testManualSleeperFireAndCancel
  - FakeBluetoothTests.testNonManualSleepRecordsDuration
  - FakeBluetoothTests.testClockSetAndAdvance
  - FakeBluetoothTests.testTickRendersPythonSeparators
  - FakeBluetoothTests.testRecordingHasTwoSessionsAndEightyNotifications
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'FakeBluetoothTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "import XCTest" Tests/AngstromTestSupport'
  bash -c 'for f in Tests/AngstromTests/Bluetooth/BluetoothEnumsTests.swift Tests/AngstromTests/Bluetooth/BluetoothWireCoercionTests.swift Tests/AngstromTests/Bluetooth/BluetoothModelsTests.swift Tests/AngstromTests/Bluetooth/BluetoothCodecTests.swift Tests/AngstromTests/Bluetooth/BluetoothResponseDecoderTests.swift Tests/AngstromTests/Bluetooth/BrewingStateMachineTests.swift Tests/AngstromTests/Bluetooth/ShotCounterNotificationDecoderTests.swift Tests/AngstromTests/Bluetooth/DashboardBluetoothTests.swift Tests/AngstromTests/Bluetooth/BluetoothTokenTests.swift Tests/AngstromTests/Bluetooth/BluetoothOpTableTests.swift Tests/AngstromTests/Bluetooth/BluetoothClientCoreTests.swift Tests/AngstromTests/Bluetooth/BluetoothDiscoveryTests.swift Tests/AngstromTests/Bluetooth/BluetoothClientRequestsSmokeTests.swift Tests/AngstromTests/Bluetooth/BluetoothClientShotCounterSmokeTests.swift Tests/AngstromTests/Bluetooth/BluetoothConnectionTests.swift Tests/AngstromTests/Bluetooth/BluetoothAuthTests.swift Tests/AngstromTests/Bluetooth/BluetoothRequestTests.swift Tests/AngstromTests/Bluetooth/BluetoothDiagnosticsTests.swift Tests/AngstromTests/Bluetooth/ShotCounterLifecycleTests.swift Tests/AngstromTests/Bluetooth/ShotCounterNotificationTests.swift Tests/AngstromTests/Bluetooth/ShotCounterRecordedSessionTests.swift Tests/AngstromTests/Bluetooth/ShotCounterReconnectTests.swift; do test -f "$f" || { echo "missing $f"; exit 1; }; done'
  ```
- **Risks:**
  - Every client test depends on these fakes. A subtle fake bug shows up as false failures in Waves 1–3. Self-test every behaviour listed.
  - AngstromTestSupport is a regular (non-test) target: importing XCTest there breaks linking.
  - The default replay (tick 3.34) is load-bearing: upstream tests C22, C24, C25, C28, C30–C32 and C36 rely on it consuming the replay flag.
- **Task (brief body):** Implement the frozen test-support API of SPEC §6.17 fully, because every later client test runs on it, and create the library placeholder test files of PLAN §3.4. The UI harness is BT-W0-04's (it needs BT-W0-02, which runs concurrently with you). Files under Tests/AngstromTestSupport/: FakeBluetoothCentral.swift; FakeBluetoothLink.swift (with FakeOp and `laMarzocco(token:confirmOnRead:commandResponse:settingResponses:)`); ManualBluetoothSleeper.swift; BluetoothTestClock.swift (also `BluetoothTransport.fake(_:sleeper:clock:)` and `BluetoothPeripheralID.fake` = "00000000-0000-0000-0000-000000000001"); BluetoothTestVectors.swift; ShotCounterRecording.swift. Every §6.17 member is `package` exactly as declared (including `package static` on BluetoothTestVectors), and nothing imports XCTest. Semantics come from the SPEC §6.17 doc comments and the §9.2 mapping (upstream FakeBleakClient $UPSTREAM/tests/test_bluetooth_client.py:157-292, IdleTimer :108-154, FakeClock :86-105). Clock plumbing (§6.17): `BluetoothTransport.fake(_:sleeper:clock:)` sets `central.now = clock.now` and builds the transport with the same sleeper and `now: clock.now`; FakeBluetoothCentral.connect sets `link.now = self.now` on every link it returns (queued or made) before returning it. FakeBluetoothLink: awaits beforeOp, then appends every op to recordedOps in order. disconnect() records .disconnect, then yields `.disconnected(nil)` once and finishes `events`, as bleak reports user disconnects through the callback. drop(_:) yields `.disconnected(error)` once and finishes. Any op after a drop or disconnect throws `.notConnected`. subscribe(_) delivers every replayOnSubscribe value as `.notification` stamped with `now()` BEFORE it returns. replayOnSubscribe defaults to `[BluetoothTestVectors.tick("3.34")]`, exactly upstream's `self.replay = _tick(3.34)` ($UPSTREAM/tests/test_bluetooth_client.py:176, delivered inside start_notify at :272-273); `[]` means no replay. discover(wanted, refresh:) returns `wanted ∩ (refresh ? (presentAfterRefresh ?? present) : present)`. notify(_:_:at:) yields one `.notification`. invalidateServices() yields `.servicesInvalidated`. The scripted machine `laMarzocco(token:)` follows the §6.17 comment: an auth read returns [0x01] from the confirmOnRead-th read after a write to 0d0b… whose bytes equal UTF8(token), and [0x00] otherwise; reads of 0b0b… return commandResponse; reads of 0a0b… return settingResponses[the setting named by the last write to 0a0b…, NUL removed] ?? Data("[]".utf8). FakeBluetoothCentral: availability defaults to .poweredOn. setAvailability sets the state and yields it on every availabilityUpdates() stream. connect pops enqueueConnect outcomes, else calls makeLink(), records connectCount and connectTimeouts, and appends successful links to `links`. The default makeLink is `.laMarzocco(token: "token")`. ManualBluetoothSleeper: purposes in `manual` suspend until fire(_:) (oldest first) or task cancellation; cancellation throws CancellationError and removes the sleep from pending. Other purposes return immediately (so with the default `manual`, a `.poweredOnWait` sleep ends at once, SPEC §6.17). Every requested duration is recorded per purpose. waitForPending(_:count:) suspends without polling until that many are pending. BluetoothTestVectors: commandSuccess and started verbatim from tests/test_bluetooth_client.py:47-48. tick(_:backflush:) renders Python json.dumps default separators exactly, e.g. tick("3.34") = `{"BrewingUpdateGroup1Time": 3.34, "BrewingUpdateGroup1Ev": true, "BrewingUpdateGroup1Backflush": false}` (_tick, :51-59). ShotCounterRecording.sessions() ports _load_sessions (tests/test_bluetooth_client.py:894-909). Skip lines starting with '#'. Split each other line at the first space into time and payload. A payload ending in `# replay` starts a new session whose replay is that payload with the suffix removed and stripped (isReplay = true). Times are UTC on 2026-10-05, format HH:MM:SS.fff. Load the file through Bundle.module. Write Tests/AngstromTests/Bluetooth/FakeBluetoothTests.swift, which drives the fakes by hand (the client is still a stub). Create every library placeholder test file of PLAN §3.4 (not the UI or CLI ones). Each contains the imports and one empty `final class <FileName>: XCTestCase {}` whose doc comment names the owner package.

#### BT-W0-04 — UI test harness and UI test placeholders

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 0 | implement | M | BT-W0-02, BT-W0-03 |

- **Owns, create:** `Tests/AngstromUITests/Bluetooth/BluetoothMachineHarness.swift`, `Tests/AngstromUITests/Bluetooth/BluetoothMachineHarnessTests.swift`, `Tests/AngstromUITests/Bluetooth/MachineTransportRoutingTests.swift`, `Tests/AngstromUITests/Bluetooth/BluetoothDeviceStateTests.swift`, `Tests/AngstromUITests/Bluetooth/BluetoothFallbackTests.swift`, `Tests/AngstromUITests/Bluetooth/BluetoothCommandSideEffectTests.swift`, `Tests/AngstromUITests/Bluetooth/BluetoothDashboardRefreshTests.swift`, `Tests/AngstromUITests/Bluetooth/ShotCounterOverlayTests.swift`
- **Owns, modify:** —
- **SPEC:** §6.16; §6.17; §9.2; §9.3.6 (seed); PLAN §3.3; PLAN §3.4; PLAN §3.5
- **Upstream:** `$UPSTREAM/tests/test_bluetooth_dashboard.py:68-105`; `$UPSTREAM/tests/test_machine.py:99-131`
- **Deliverables:**
  - BluetoothMachineHarness per PLAN §3.3.
  - Self-tests for the harness.
  - Every UI placeholder test file of PLAN §3.4.
- **Tests:**
  - BluetoothMachineHarnessTests.testStandardSeedMatchesSeed001
  - BluetoothMachineHarnessTests.testHarnessWithoutCloudOrBluetooth
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothMachineHarnessTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c 'for f in Tests/AngstromUITests/Bluetooth/MachineTransportRoutingTests.swift Tests/AngstromUITests/Bluetooth/BluetoothDeviceStateTests.swift Tests/AngstromUITests/Bluetooth/BluetoothFallbackTests.swift Tests/AngstromUITests/Bluetooth/BluetoothCommandSideEffectTests.swift Tests/AngstromUITests/Bluetooth/BluetoothDashboardRefreshTests.swift Tests/AngstromUITests/Bluetooth/ShotCounterOverlayTests.swift; do test -f "$f" || { echo "missing $f"; exit 1; }; done'
  ```
- **Risks:**
  - Every UI Bluetooth test depends on the harness. Keep its seeds and failure modes exactly as PLAN §3.3.
- **Task (brief body):** Create Tests/AngstromUITests/Bluetooth/BluetoothMachineHarness.swift exactly per PLAN §3.3, on the AngstromTestSupport fakes (BT-W0-03) and the BT-W0-02 LaMarzoccoMachine declarations. It reuses MockBackend/MockURLProtocol and the UI Fixtures, which you must not modify. BT-DASH-SEED-001 is $UPSTREAM/tests/test_bluetooth_dashboard.py:68-105. Write BluetoothMachineHarnessTests.swift: construction with and without each client, and the standard seed. Create every UI placeholder test file of PLAN §3.4. Each contains the imports and one empty `@MainActor final class <FileName>: XCTestCase {}` whose doc comment names the owner package.

### Wave 1 — Core protocol pieces, client core, adapter, UI funnel, CLI scaffolding (parallel)

#### BT-W1-01 — Leaf types: parity tests and fixes (enums, coercion, models, errors)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | M | BT-W0-01, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/Bluetooth/BluetoothConstants.swift`, `Sources/Angstrom/Bluetooth/BluetoothTransport.swift`, `Sources/Angstrom/Bluetooth/BluetoothAuthToken.swift`, `Sources/Angstrom/Bluetooth/BluetoothEnums.swift`, `Sources/Angstrom/Bluetooth/BluetoothModels.swift`, `Sources/Angstrom/Bluetooth/BluetoothWireCoercion.swift`, `Sources/Angstrom/Bluetooth/BluetoothShotCounterModels.swift`, `Sources/Angstrom/Bluetooth/BluetoothDiagnostics.swift`, `Sources/Angstrom/Models.swift`, `Tests/AngstromTests/Bluetooth/BluetoothEnumsTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothWireCoercionTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothModelsTests.swift`
- **SPEC:** §2.2; §2.3; §3.10; §4.11; §6.1–§6.7; §6.9; §6.10; §12 D5 D8
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:40-54`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:62-64`; `$UPSTREAM/src/pylamarzocco/const.py:198-218`; `$UPSTREAM/src/pylamarzocco/const.py:307-339`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:58-84`; `$UPSTREAM/src/pylamarzocco/models/_bluetooth.py:73-87`; `$UPSTREAM/tests/test_models.py:391-418`; `$UPSTREAM/tests/test_bluetooth_dashboard.py:636-670`
- **Deliverables:**
  - Tests that pin every Wave 0 leaf implementation to SPEC/upstream; fixes to those leaf files if they deviate.
- **Tests:**
  - D20–D25 (6 cases) `test_get_dashboard_from_bluetooth_steam_level` (tests/test_bluetooth_dashboard.py:650) → BluetoothEnumsTests.testSteamLevelFromTarget
  - O01–O03 (true/false already covered by ModelsTests) `test_shot_counter_supported` (tests/test_models.py:395) → BluetoothEnumsTests.testShotCounterSupportedNull
  - O04–O07 `test_model_name_from_bluetooth_family` (tests/test_models.py:416) → BluetoothEnumsTests.testFamilyMapping
  - BluetoothEnumsTests.testConstantsVerbatim
  - BluetoothEnumsTests.testReadSettingRawValues
  - BluetoothEnumsTests.testBrewingStateRawValues
  - BluetoothEnumsTests.testBoilerTypeRoundTrip
  - BluetoothEnumsTests.testCloudModelMatchUnchanged (Angstrom-only: D8)
  - BluetoothEnumsTests.testMachineStateFromBluetoothMode
  - BluetoothEnumsTests.testBoilerStatusFromBluetoothMode
  - BluetoothEnumsTests.testSteamLevelToTarget
  - BluetoothEnumsTests.testSteamLevelEdges (Angstrom-only: G-DEV-4)
  - BluetoothWireCoercionTests.testParseBool
  - BluetoothWireCoercionTests.testRequiredBoolStringFalseIsFalse (Angstrom-only: D5, G-CODEC-3)
  - BluetoothWireCoercionTests.testCFBooleanHazard
  - BluetoothWireCoercionTests.testDoubleRule
  - BluetoothWireCoercionTests.testIntRuleTruncates
  - BluetoothWireCoercionTests.testStringRule
  - BluetoothWireCoercionTests.testBoolContainerTruthiness
  - BluetoothWireCoercionTests.testRequiredStringNullIsNone
  - BluetoothWireCoercionTests.testStringFromContainerIsCompactJSON (Angstrom-only: D5c)
  - BluetoothWireCoercionTests.testIntRejectsOutOfRangeAndNonFinite (Angstrom-only: D5d)
  - BluetoothWireCoercionTests.testDoubleRejectsNonFiniteAndUnderscoreStrings (Angstrom-only: D5e, D5f)
  - BluetoothWireCoercionTests.testIntExactAtIntBounds (Angstrom-only: §3.10 amendment)
  - BluetoothWireCoercionTests.testDoubleRejectsHexFloatString (Angstrom-only: §3.10 amendment)
  - BluetoothWireCoercionTests.testStringFromHugeIntegerIsDigits (Angstrom-only: §3.10 amendment)
  - BluetoothModelsTests.testBrewingMergeNeverClears
  - BluetoothModelsTests.testIsEmpty
  - BluetoothModelsTests.testTelemetryMerge
  - BluetoothModelsTests.testUpdateDefaultStartTime
  - BluetoothModelsTests.testCommandStatusIsSuccessCaseInsensitive
  - BluetoothModelsTests.testJSONValueSubscript
  - BluetoothModelsTests.testRawFrameMarkers
  - BluetoothModelsTests.testErrorDescriptionsVerbatim
  - BluetoothModelsTests.testIsBluetoothConnectionFailure
  - BluetoothModelsTests.testTransportErrorDescriptions
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothEnumsTests|BluetoothWireCoercionTests|BluetoothModelsTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-01" Sources Tests cli/Sources'
  ```
- **Risks:**
  - Python bool("false") is True upstream. Angstrom deliberately diverges (D5a). Assert the Angstrom behaviour and cite D5.
  - `Int(_:)` on a Double outside Int range traps. Range-check before converting (SPEC §3.10 int rule).
- **Task (brief body):** Write the parity and unit tests for the leaf types that BT-W0-01 implemented, and fix those files wherever they deviate from the SPEC. You own the leaf source files only for fixes; do not change any frozen signature. SPEC §3.10 was amended after BT-W0-01 merged, so BluetoothWireCoercion.swift implements the OLD rules in three places; bring it into line and pin each with the test named below: (1) int: try the exact `Int(n.stringValue)` path first for a non-float number, so 9223372036854775807 and -9223372036854775808 decode exactly instead of throwing; (2) double: a string containing x or X (a hex float such as "0x1p3") is an error; (3) string: an integer literal too large for UInt64 (a non-fractional NSDecimalNumber) renders as its decimal digits, not float text. BluetoothEnumsTests: the five characteristic UUIDs and every §2.2 constant, verbatim against $UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:40-54; BluetoothReadSetting and BluetoothBrewingState raw values (const.py:322-339); BluetoothBoilerType raw round-trip including .other; Model(bluetoothFamily:) for every row of the §6.5 table plus whitespace and case normalisation; Model(code: "GS3") is still .gs3 (Model.match is private, so test it through the public initialiser; D8); MachineState/BoilerStatus(bluetoothMode:) for all four MachineMode cases; SteamLevel ↔ temperature both ways; a null shotCounterSupported in a Machine payload decodes as false. BluetoothWireCoercionTests: every row of the SPEC §3.10 table. Include JSON true/false versus the numbers 1/0 (the CFBoolean hazard), "false" → false for wire and notification bools (D5a), array/object truthiness for both bool rules ([] → false, {"a":1} → true), int truncation 93.5 → 93, int("93.5") fails, int from 1e300 and from 12345678901234567890 throws without trapping (D5d), float("abc") fails, "nan"/"inf" strings fail (D5e), "1_0" fails (D5f), numeric strings for doubles, str() of bool → "True"/"False", a required string that is null → "None" and absent → throws, an optional string that is null → nil, and an array/object string → its compact sorted-keys JSON text (D5c). BluetoothModelsTests: merging never clears and false/0/"" count as set; isEmpty; telemetry merge; the BluetoothShotCounterUpdate default start time; isSuccess is case-insensitive; the BluetoothJSONValue subscript; RawBluetoothFrame marker texts and mtuMarker; every §6.4 errorDescription verbatim; isBluetoothConnectionFailure for every case; BluetoothTransportError.description is non-empty for every case.

#### BT-W1-02 — BluetoothCodec: ordered command writer, frames, NUL handling, ensure_ascii

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | M | BT-W0-01, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/Bluetooth/BluetoothCodec.swift`, `Tests/AngstromTests/Bluetooth/BluetoothCodecTests.swift`
- **SPEC:** §3.5; §3.6; §3.7; §3.9; §6.8; §9.3.1; §12 D6
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:596-626`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:655-710`; `$UPSTREAM/src/pylamarzocco/const.py:322-330`; `$UPSTREAM/tests/test_bluetooth_client.py:295-336`; `$UPSTREAM/tests/test_bluetooth_client.py:1223-1231`
- **Deliverables:**
  - BluetoothCodec complete: commandFrame, the four command builders, responseText, jsonString (Python ensure_ascii), integral-double rule.
- **Tests:**
  - BluetoothCodecTests.testCommandFramesMatchPinnedVectors (BT-REQ-001…006; supplementary to C01–C03)
  - BluetoothCodecTests.testSetSteamAndPowerOffBytes (Angstrom-only: G-CODEC-2)
  - BluetoothCodecTests.testReadRequestFrames (BT-READ-REQ-001…006)
  - BluetoothCodecTests.testAuthFrameHasNoTerminator (BT-AUTH-001)
  - BluetoothCodecTests.testResponseTextCutsAtFirstNul (BT-RSP-MODE-002; Angstrom-only: G-CODEC-4 reads)
  - BluetoothCodecTests.testResponseTextInvalidUTF8
  - BluetoothCodecTests.testJSONStringEnsureASCII (incl. U+007F → \u007f, / unescaped, a surrogate pair)
  - BluetoothCodecTests.testIntegralDoubleRule (Angstrom-only: D6)
  - BluetoothCodecTests.testKeyOrderIsNotSorted
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothCodecTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-02" Sources Tests cli/Sources'
  bash -c '! grep -n "JSONEncoder" Sources/Angstrom/Bluetooth/BluetoothCodec.swift'
  ```
- **Risks:**
  - Swift's String(describing: Double) and Python repr agree on shortest round-trip output for normal values. Keep the 1e15 boundary exactly as SPEC §3.9.
- **Task (brief body):** Implement the rest of Sources/Angstrom/Bluetooth/BluetoothCodec.swift (SPEC §6.8). It is the ONLY producer of BLE command bytes and must never use JSONEncoder. commandFrame(name:parameter:) writes `{"name":<name>,"parameter":{…}}` with no whitespace, keys in the given order, then exactly one 0x00 (_bluetooth.py:702-710, `separators=(",", ":")`). jsonString follows Python json.dumps(ensure_ascii=True) as in SPEC §3.9: escape " and \ ; use \b \f \n \r \t; other code points < U+0020 become \u00xx; every code point ≥ U+007F (U+007F included: json.dumps("\x7f") is "\u007f") becomes \uxxxx in lowercase hex, with a surrogate pair above U+FFFF; do not escape /. Doubles: a finite integral value with abs < 1e15 is written as an integer (`90`); otherwise as String(describing:) (`96.5`). Callers guarantee finiteness (D6). The four builders produce exactly BT-REQ-001…006 (SPEC §3.7), with key orders mode / identifier,state / minutes,mode,enabled / identifier,value. responseText(_:context:) keeps the bytes before the first 0x00 and decodes them strictly as UTF-8; failure throws LaMarzoccoError.decoding("bluetooth \(context): invalid UTF-8"). Keep the Wave 0 readRequestFrame/authFrame, and fix them if wrong.

#### BT-W1-03 — BluetoothResponseDecoder: read-setting and command-status decoding

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | M | BT-W0-01, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/Bluetooth/BluetoothResponseDecoder.swift`, `Tests/AngstromTests/Bluetooth/BluetoothResponseDecoderTests.swift`
- **SPEC:** §3.6; §3.7 (status); §3.10; §6.6; §9.3.2; §12 D5 D9
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:555-594`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:702-710`; `$UPSTREAM/src/pylamarzocco/models/_bluetooth.py:22-65`; `$UPSTREAM/src/pylamarzocco/const.py:198-218`; `$UPSTREAM/tests/test_bluetooth_client.py:338-430`; `$UPSTREAM/tests/test_bluetooth_client.py:1234-1250`; `$UPSTREAM/tests/conftest.py:183-195`; `$UPSTREAM/tests/test_bluetooth_dashboard.py:517-519`
- **Deliverables:**
  - BluetoothResponseDecoder: machineMode, capabilities, bool, boilers, smartStandby, commandStatus with SPEC §3.10 rules and `.decoding("bluetooth <rawValue|command>: …")` errors.
- **Tests:**
  - BluetoothResponseDecoderTests.testCapabilitiesMicra (BT-RSP-CAP-001)
  - BluetoothResponseDecoderTests.testCapabilitiesFamilies (BT-RSP-CAP-002)
  - BluetoothResponseDecoderTests.testBoilers (BT-RSP-BOIL-001)
  - BluetoothResponseDecoderTests.testSmartStandbyStringTrue (BT-RSP-SSB-001)
  - BluetoothResponseDecoderTests.testSmartStandbyStringFalseIsFalse (Angstrom-only: D5, BT-RSP-SSB-002)
  - BluetoothResponseDecoderTests.testTankAndPlumbBools (BT-RSP-TANK-001, BT-RSP-PLUMB-001…004)
  - BluetoothResponseDecoderTests.testMachineMode (BT-RSP-MODE-001)
  - BluetoothResponseDecoderTests.testEmptyBoilers (BT-RSP-EMPTY-001)
  - BluetoothResponseDecoderTests.testCommandStatus (BT-RSP-CMD-001, BT-CMDSTATUS-CONF)
  - BluetoothResponseDecoderTests.testCommandStatusMissingKey (Angstrom-only: G-CODEC-6)
  - BluetoothResponseDecoderTests.testMalformedResponsesThrowDecoding (empty capabilities, unknown mode, non-JSON)
  - BluetoothResponseDecoderTests.testUnknownBoilerIdTolerated (Angstrom-only: D5)
  - BluetoothResponseDecoderTests.testFractionalBoilerTarget (Angstrom-only: D9)
  - BluetoothResponseDecoderTests.testResponseCoercionVectors (BT-COERCE-001…011; D5, D9 rows marked)
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothResponseDecoderTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-03" Sources Tests cli/Sources'
  ```
- **Risks:**
  - Do not reuse CommandStatus(rawValue:) for BLE statuses (SPEC §3.7).
- **Task (brief body):** Implement Sources/Angstrom/Bluetooth/BluetoothResponseDecoder.swift (SPEC §6.6). The input is NUL-truncated UTF-8 text. Parse it with JSONSerialization(.fragmentsAllowed) and coerce with BluetoothWireCoercion (§3.10). machineMode: a JSON string "BrewingMode"/"EcoMode"/"StandBy" → MachineMode; anything else → .decoding (ValueError parity, _bluetooth.py:558). capabilities: an array; element [0]; an empty array → .decoding (IndexError parity). family goes through Model(bluetoothFamily:), and an unknown family throws exactly `.decoding("bluetooth machineCapabilities: Invalid model name: <raw>")`. Required ints and wire bool per §3.10. machineModes entries keep .other (D5). bool(_:setting:): parseBool. boilers: an array in wire order; id → BluetoothBoilerType (unknown → .other, D5); target/current as Double (D9). smartStandby: an object; mode → SmartStandbyAfter (unknown → .decoding); minutes int; enabled wire bool ("true" → true; "false" → false, D5). commandStatus: an object with required id/message/status coerced with the required-string rule (null → "None", so {"id":"a","message":null,"status":"success"} is a success); a missing key or a non-object → `.decoding("bluetooth command: …")`. Pin every BT-COERCE-001…011 row of SPEC §9.3.2 (the Angstrom column). Every error is LaMarzoccoError.decoding("bluetooth <setting rawValue | command>: <detail>").

#### BT-W1-04 — Brewing state machine, tracker and shot-counter notification decoder

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | L | BT-W0-01, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/Bluetooth/BrewingStateMachine.swift`, `Tests/AngstromTests/Bluetooth/BrewingStateMachineTests.swift`, `Tests/AngstromTests/Bluetooth/ShotCounterNotificationDecoderTests.swift`
- **SPEC:** §3.8; §3.10; §4.11; §4.12; §6.9; §9.3.3; §9.3.4; §12 D5
- **Upstream:** `$UPSTREAM/src/pylamarzocco/models/_bluetooth.py:68-213`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:77-111`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:441-465`; `$UPSTREAM/tests/test_bluetooth_client.py:745-781`; `$UPSTREAM/tests/test_bluetooth_client.py:848-884`; `$UPSTREAM/tests/test_bluetooth_client.py:894-976`; `$UPSTREAM/tests/test_bluetooth_client.py:980-1006`; `$UPSTREAM/tests/fixtures/machine/shot_counter_2026-10-05.txt`
- **Deliverables:**
  - deriveState(receivedAt:), BrewingTracker.process(_:receivedAt:), ShotCounterNotificationDecoder.decode(_:) per SPEC §3.8/§4.11.
- **Tests:**
  - BrewingStateMachineTests.testTransitionTable (every row of SPEC §4.11)
  - BrewingStateMachineTests.testSequenceAtTrackerLevel (BT-NTF-SEQ-001; supplementary to C24)
  - BrewingStateMachineTests.testEarliestStartTime (BT-NTF-START-001 at tracker level)
  - BrewingStateMachineTests.testLateTickAfterStopReentersBrewing (BT-NTF-LATE-001)
  - BrewingStateMachineTests.testFragmentAccumulates (BT-NTF-FRAG-001)
  - BrewingStateMachineTests.testEvFalseStringIsStop (Angstrom-only: D5, BT-NTF-COERCE-001)
  - BrewingStateMachineTests.testRecordedMorningPureGolden (supplementary to C29)
  - ShotCounterNotificationDecoderTests.testMalformedDropped (BT-NTF-SEQ-002 at decoder level)
  - ShotCounterNotificationDecoderTests.testNulStrippedBothEndsOnly (Angstrom-only: G-CODEC-4 notifications)
  - ShotCounterNotificationDecoderTests.testTelemetryKeys (BT-NTF-TEL-001…005 at decoder level)
  - ShotCounterNotificationDecoderTests.testMachineStatisticsRule (Angstrom-only: G-CODEC-7, BT-NTF-COERCE-002…005)
  - ShotCounterNotificationDecoderTests.testNotificationCoercionVectors (BT-NTF-COERCE-006…010; D5 rows marked)
  - ShotCounterNotificationDecoderTests.testUnknownMachineModeIsNil
  - ShotCounterNotificationDecoderTests.testHeatingCoefficientIgnored
  - ShotCounterNotificationDecoderTests.testNumericStringTime
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BrewingStateMachineTests|ShotCounterNotificationDecoderTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-04" Sources Tests cli/Sources'
  ```
- **Risks:**
  - The hand-traced golden (SPEC U22) may be wrong. Assertions 1–6 are authoritative; escalate rather than adjust the golden.
- **Task (brief body):** Implement Sources/Angstrom/Bluetooth/BrewingStateMachine.swift (SPEC §6.9). deriveState(receivedAt:) applies the §4.11 rule table in order and fills the update fields exactly as §4.11 (timerValue only for .brewing, defaulting to 0.0; finalShotTime = brewingStoppedTime in any state; brewingStartTime = receivedAt − timerValue for .brewing). BrewingTracker.process ports _BrewingTracker ($UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:77-111) line for line: reset on startedDoseIndex; merge; derive; keep fragments when there is no state; reset after .flushed or .brewingStopped; keep the earliest start estimate S and write it into the update. ShotCounterNotificationDecoder.decode (§3.8): strip 0x00 from both ends only, then parse a JSON object. Decode the brewing keys and telemetry keys of the §3.8 tables with the §3.10 rules (notification bool, double, string; MachineMode unknown or non-string → nil; MachineStatistics: absent or JSON null → unset with the rest of the notification processed, a JSON string → its parsed content with a parsed `null` → unset, any other value or an unparseable string → drop). If either part fails, return nil. Unknown keys are ignored. Unit-test every row of the §4.11 transition table. Also add the pure recorded-session golden: run every notification of the REC fixture (ShotCounterRecording, replays skipped) through decoder + tracker, and assert SPEC §9.3.4 assertions 1–4 and the finer golden (≤ 1 ms). This test is supplementary to C29, which BT-W3-04 owns through the client. If the golden table disagrees while assertions 1–4 hold, report it and do NOT edit the expected values (SPEC U22).

#### BT-W1-05 — Dashboard transforms: BLE widget synthesis and the shot-counter overlay

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | M | BT-W0-01, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/Bluetooth/Dashboard+Bluetooth.swift`, `Tests/AngstromTests/Bluetooth/DashboardBluetoothTests.swift`
- **SPEC:** §4.17 (pure part); §4.19 (overlay); §6.12; §9.3.6; §12 D12
- **Upstream:** `$UPSTREAM/src/pylamarzocco/devices/_machine.py:58-84`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:287-323`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:350-492`; `$UPSTREAM/tests/__snapshots__/test_bluetooth_dashboard.ambr:2-145`; `$UPSTREAM/tests/test_bluetooth_dashboard.py:560-689`
- **Deliverables:**
  - Dashboard.upserting, removingWidgets, settingMachineState, applyingBluetoothState(_:model:), overlayingBluetoothBrewing(_:).
- **Tests:**
  - DashboardBluetoothTests.testUpsertingKeepsIndex
  - DashboardBluetoothTests.testRemovingWidgets
  - DashboardBluetoothTests.testSettingMachineStateOnlyMachineStatus
  - DashboardBluetoothTests.testApplyMicraSnapshot (BT-DASH-SNAP-001)
  - DashboardBluetoothTests.testApplyEmptyMiniR (BT-DASH-SNAP-002)
  - DashboardBluetoothTests.testApplyGS3UsesTemperature (BT-DASH-GS3-001)
  - DashboardBluetoothTests.testApplyOriginalMiniDefaults (BT-DASH-MINI-001)
  - DashboardBluetoothTests.testStatusTable (BT-DASH-STATUS-001…005)
  - DashboardBluetoothTests.testPlumbInFalseTankFalseRaisesAlarm (BT-DASH-PLUMB-001)
  - DashboardBluetoothTests.testWidgetDefaultsAndEdgeCases (Angstrom-only: G-DEV-3)
  - DashboardBluetoothTests.testAvailableModesKept (Angstrom-only: G-DEV-10)
  - DashboardBluetoothTests.testUnknownWidgetCountsAsAbsent
  - DashboardBluetoothTests.testOverlayTable (Angstrom-only: D12)
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'DashboardBluetoothTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-05" Sources Tests cli/Sources'
  ```
- **Risks:**
  - Keep upstream's BLE widget defaults even where they differ from cloud fixtures (Q12).
- **Task (brief body):** Implement the Dashboard extension in Sources/Angstrom/Bluetooth/Dashboard+Bluetooth.swift (SPEC §6.12) using the internal widget memberwise initialisers. upserting replaces the first widget with the same code, keeping its index, else appends. removingWidgets(code:) removes all of them. settingMachineState sets only CMMachineStatus.status. applyingBluetoothState follows the §4.17 table exactly: waterOK = isPlumbedIn || tankStatus; boilerStatus(enabled); an 'existing W' must have the matching typed kind (an .unknown widget counts as absent); append index 1 in the order CMMachineStatus, CMCoffeeBoiler, steam widget, CMNoWater; upstream defaults kept (coffee 80/110/0.1; Mini steam 95/140 supported=false; other steam 20/134 supported=true; enabledSupported per table); the coffee boiler never shows .off; duplicate boiler ids: last wins; .other ids ignored; the level path removes every CMSteamBoilerTemperature and the temperature path removes every CMSteamBoilerLevel; CMMachineGroupStatus is untouched. overlayingBluetoothBrewing follows the §4.19 table: nil → self; no CMMachineStatus → self; .brewing → status .brewing and brewingStartTime = update.brewingStartTime; any other state (including .backflushing) → status = (base.status == .brewing ? .poweredOn : base.status) and the base brewingStartTime. Test the pure snapshots BT-DASH-SNAP-001/002, GS3-001, MINI-001, PLUMB-001 and STATUS-001…005 (supplementary to the UI-level D01–D06/D15–D19 owned by BT-W3-08) and every overlay row.

#### BT-W1-06 — Cloud: bluetoothAuthToken(serial:) from GET /things

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | S | BT-W0-01, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift`, `Tests/AngstromTests/Bluetooth/BluetoothTokenTests.swift`
- **SPEC:** §2.6; §3.3; §4.21; §6.3; §6.13; §12 D2
- **Upstream:** `$UPSTREAM/src/pylamarzocco/models/_general.py:128-136`; `$UPSTREAM/src/pylamarzocco/clients/_cloud.py:84-92`; `$UPSTREAM/tests/test_cloud_client.py:322`; `$UPSTREAM/README.md:78-98`
- **Deliverables:**
  - LaMarzoccoCloudClient.bluetoothAuthToken(serial:) per SPEC §4.21.
- **Tests:**
  - X01 `test_debug_log_masks_bluetooth_token` (tests/test_cloud_client.py:322) → BluetoothTokenTests.testTokenDescriptionIsRedacted, BluetoothTokenTests.testBluetoothAuthTokenFromThings
  - BluetoothTokenTests.testMissingSerialThrows
  - BluetoothTokenTests.testWrongShapeThrows
  - BluetoothTokenTests.testTokenIsNotEncodableAndMirrorIsEmpty (Angstrom-only: D2)
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothTokenTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-06" Sources Tests cli/Sources'
  ```
- **Risks:**
  - Do not add a field to Machine (D2).
- **Task (brief body):** Implement Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift (SPEC §6.13, §4.21). Make an authenticated GET /things through the existing internal `authed(path:method:)`. Parse with JSONSerialization: the body must be an array of objects, else `.decoding("things shape")`. Find the first object whose serialNumber == serial, else `.decoding("things: no thing with serial <serial>")`. Its top-level `bleAuthToken`: a non-empty JSON string → BluetoothAuthToken; null, absent or "" → nil. Never log or print the value. Tests use the existing Tests/AngstromTests/Support/MockTransport.swift (read-only; do not modify) with a small inline /things body. Include the 64 × "0" placeholder token present in Tests/AngstromTests/Fixtures/dashboard_strada_profile.json. Port the intent of upstream's masking test: the token's description, debugDescription and Mirror never reveal the value, and it is not Encodable.

#### BT-W1-07 — BluetoothOpTable: exactly-once in-flight operation table

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | M | BT-W0-01, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/Bluetooth/BluetoothOpTable.swift`, `Tests/AngstromTests/Bluetooth/BluetoothOpTableTests.swift`
- **SPEC:** §5.4; §6.10 (op table); PLAN §3.1
- **Upstream:** `(no upstream counterpart: Apple-specific; reference = $RESEARCH/06-corebluetooth.md Appendix B `OpTable`, if provided)`
- **Deliverables:**
  - BluetoothOpTable per PLAN §3.1 with unit tests.
- **Tests:**
  - BluetoothOpTableTests.testFinishRemovesBeforeComplete
  - BluetoothOpTableTests.testFinishUnknownTokenReturnsFalse
  - BluetoothOpTableTests.testAbandonedGATTRequestOwesOneReply
  - BluetoothOpTableTests.testAbandonedNonGATTOwesNothing
  - BluetoothOpTableTests.testOweSwallowsNextReply
  - BluetoothOpTableTests.testFinishOldestIsFIFO
  - BluetoothOpTableTests.testFailAllMatchingClearsOrphans
  - BluetoothOpTableTests.testIsAwaiting
  - BluetoothOpTableTests.testCompletionMayReenterTable
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothOpTableTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-07" Sources Tests cli/Sources'
  bash -c '! grep -nE "^(@preconcurrency )?import CoreBluetooth" Sources/Angstrom/Bluetooth/BluetoothOpTable.swift'
  ```
- **Task (brief body):** Implement Sources/Angstrom/Bluetooth/BluetoothOpTable.swift with exactly the PLAN §3.1 signature (generic over Key). It is a queue-confined, non-thread-safe table. register stores (key, isGATTRequest, completion) and appends the token to a FIFO order. finish removes the entry BEFORE calling completion, returns false if the token is unknown, and when abandoning a GATT request records one owed reply for its key. finishOldest first swallows one owed reply for the key if any (returning true); otherwise it finishes the oldest registered op with that key. owe adds an owed reply. isAwaiting is true if an owed reply or a registered op exists for the key. failAll drops owed replies for matching keys and finishes every matching op with .failure(error). No CoreBluetooth import. Reference: $RESEARCH/06-corebluetooth.md Appendix B, if provided. Unit-test exactly-once completion across reply/timeout/cancel/fan-out orderings.

#### BT-W1-08 — AngstromBluetooth: CoreBluetooth adapter (central, link, transport factory)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | L | BT-W0-01 |

- **Owns, create:** `Sources/AngstromBluetooth/CoreBluetoothCentral.swift`, `Sources/AngstromBluetooth/CoreBluetoothLink.swift`, `Sources/AngstromBluetooth/Documentation.docc/AngstromBluetooth.md`
- **Owns, modify:** `Sources/AngstromBluetooth/BluetoothTransport+CoreBluetooth.swift`
- **SPEC:** §3.1; §3.2; §5.1; §5.3; §5.4; §5.5; §6.2; §6.14; §8.1; §8.2; §8.6; §11 (AngstromBluetooth.md); PLAN §3.1
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:233-269`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:396-439`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:522-547`; `$UPSTREAM/docs/legacy/bluetooth_characteristics.md:10`; `BLEAK 1.1.1 backends/corebluetooth (not in $UPSTREAM; SPEC §5.4 is authoritative)`
- **Deliverables:**
  - CoreBluetoothCentral + CoreBluetoothLink implementing the §6.2 seam on one private serial queue; BluetoothTransport.coreBluetooth(showPowerAlert:) and BluetoothAuthorization.current; DocC landing page.
- **Tests:**
  - (compile-only: no test may construct CBCentralManager/CBPeripheral; behaviour is verified by BT-W2-11 review and hardware items H1–H28)
- **Acceptance:**

  ```sh
  swift build --build-tests
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-08" Sources Tests cli/Sources'
  bash -c '! grep -rnE "^@preconcurrency import CoreBluetooth" Sources'
  bash -c '! grep -rlE "^(@preconcurrency )?import CoreBluetooth" Sources | grep -v "^Sources/AngstromBluetooth/"'
  bash -c 'for f in Sources/AngstromBluetooth/*.swift; do grep -q "canImport(CoreBluetooth)" "$f" || { echo "no canImport guard: $f"; exit 1; }; done'
  bash -c '! grep -rnE "EnableAutoReconnect|Mutex<" Sources/AngstromBluetooth | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(//|///|\*)"'
  xcodebuild -scheme Angstrom-Package -destination 'generic/platform=iOS Simulator' -quiet build
  ```
- **Risks:**
  - Swift 6 region-isolation errors for CB objects appear only on a full `swift build` (not -typecheck).
  - The xcodebuild scheme name may differ. Run `xcodebuild -list` and use the package scheme (report the name).
  - No runtime test exists. Hardware items H1–H4, H8–H10, H13–H20 exercise this code before release.
- **Task (brief body):** Implement the CoreBluetooth adapter in the new AngstromBluetooth target. This is the ONLY place that may `import CoreBluetooth`. Wrap every file in `#if canImport(CoreBluetooth)`. Follow SPEC §5.4 bullet by bullet. One private serial DispatchQueue(label: "angstrom.bluetooth") is both the CBCentralManager delegate queue and the confinement domain. CoreBluetoothCentral and CoreBluetoothLink are `final class …: NSObject, …Delegate, @unchecked Sendable`; justify the @unchecked conformance in a comment and assert `dispatchPrecondition(condition: .onQueue(queue))`. Bridge async calls with withTaskCancellationHandler + withCheckedThrowingContinuation, and register every in-flight op in a queue-confined BluetoothOpTable (PLAN §3.1 signature; it is implemented in parallel by BT-W1-07, so rely only on its documented semantics). Required behaviours: owed replies swallowed; a read resolves before a notification; notifications are routed BEFORE setNotifyValue(true) is acknowledged; the manager is created lazily with CBCentralManagerOptionShowPowerAlertKey; a [UUID: CBPeripheral] retention table, emptied on .unknown/.resetting/.unsupported/.unauthorized; resolve on connect via known ?? retrievePeripherals, else a ≤ 10 s scan for that identifier, else .unknownPeripheral; connect timeout via cancelPeripheralConnection, and a late didConnect is cancelled; a non-poweredOn state synthesises .disconnected once per live link, fails pending connects with .unavailable and multicasts availabilityUpdates(); didModifyServices → drop the characteristic table and yield .servicesInvalidated; .withResponse writes longer than maximumWriteValueLength(for: .withResponse) throw .valueTooLong; disconnect waits ≤ 5 s; scan has no service filter, de-duplicates and keeps first-seen order, names come from CBPeripheral.name else CBAdvertisementDataLocalNameKey; discover(_:refresh:timeout:) runs discoverServices(nil) and then discoverCharacteristics on every service and matches by characteristic UUID (never assume the legacy service d30a…, SPEC §3.1); attMTU() = maximumWriteValueLength(.withoutResponse) + 3; gattTable lists every service/characteristic with the §6.2 property names; stamp GATTNotification.receivedAt with the transport's now() inside the delegate callback. Never use CBConnectPeripheralOptionEnableAutoReconnect, `@preconcurrency import CoreBluetooth`, Mutex, an actor with a custom executor, or a Task hop inside a delegate callback. Use no macOS-unavailable connection-event APIs. Public surface: only BluetoothTransport.coreBluetooth(showPowerAlert:) and BluetoothAuthorization.current (from CBManager.authorization, which allocates no manager). Everything else is internal. Write Documentation.docc/AngstromBluetooth.md: the factory, BluetoothAuthorization.current, and the Info.plist/entitlement table of SPEC §8.2. If $RESEARCH is provided, start from $RESEARCH/06-corebluetooth.md Appendix B and $RESEARCH/06-sketch/btsketch/Sources/BTCoreBluetooth/CoreBluetoothAdapter.swift, and adapt them to the frozen seam (add availabilityUpdates, attMTU, gattTable, the scan-by-identifier fallback and first-seen order; use BluetoothOpTable). No unit tests are possible (no test may construct CBCentralManager). Acceptance is a warning-free build for macOS and iOS.

#### BT-W1-09 — LaMarzoccoBluetoothClient core: gates, connect, auth, idle, teardown, events, raw tap

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | L | BT-W0-01, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient.swift`, `Tests/AngstromTests/Bluetooth/BluetoothClientCoreTests.swift`
- **SPEC:** §3.4; §4.1–§4.8; §4.4.1; §4.13 (handleConnectionLost); §5.5; §5.6; §5.7; §6.11 [main]; §8.1; §12 D1 D7 D10 D11 D16 D19
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:114-136`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:142-325`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:467-486`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:549-553`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:628-653`; `BRC 4.4.4 (not in $UPSTREAM; SPEC §2.2/§4.2 values are authoritative)`
- **Deliverables:**
  - Every [main] member of SPEC §6.11 implemented: FIFO gates, ensureConnected, authenticate, idle timer, teardown, link-event watcher, connection events, raw tap, error mapping, test seams.
- **Tests:**
  - BluetoothClientCoreTests.testEnsureConnectedDiscoversAndAuthenticates
  - BluetoothClientCoreTests.testGatesAreFIFOAndOrdered
  - BluetoothClientCoreTests.testAvailabilityFailFast (Angstrom-only: D10)
  - BluetoothClientCoreTests.testAvailabilityWaitsForPoweredOn (manual: [.idleDisconnect, .poweredOnWait])
  - BluetoothClientCoreTests.testAvailabilityWaitTimesOut (fires .poweredOnWait by hand; asserts requested(.poweredOnWait) == [10 s])
  - BluetoothClientCoreTests.testConnectRetriesThreeTimesWithBackoff (Angstrom-only: G-CONN-1, D1)
  - BluetoothClientCoreTests.testUnknownPeripheralIsTerminal
  - BluetoothClientCoreTests.testMissingAuthCharacteristic
  - BluetoothClientCoreTests.testFailedConnectDisconnectsLinkWithoutEvent
  - BluetoothClientCoreTests.testCancellationDuringConnectDisconnects
  - BluetoothClientCoreTests.testSetConnectedIsEdgeTriggered
  - BluetoothClientCoreTests.testIdleTimerFiresDisconnect
  - BluetoothClientCoreTests.testIdleTaskDoesNotCancelItself
  - BluetoothClientCoreTests.testLinkLossFromCurrentLink
  - BluetoothClientCoreTests.testStaleLinkEventsIgnored
  - BluetoothClientCoreTests.testServicesInvalidatedSetsRediscovery
  - BluetoothClientCoreTests.testMapTransportErrorTable
  - BluetoothClientCoreTests.testDisconnectIsIdempotent
  - BluetoothClientCoreTests.testTeardownCompletesOnDeadLink (Angstrom-only: G-CONN-3)
  - BluetoothClientCoreTests.testRawFrameLifecycleMarkers
  - BluetoothClientCoreTests.testAuthWriteIsSecretOnRawTap
  - BluetoothClientCoreTests.testLogNeverContainsToken
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothClientCoreTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-09" Sources Tests cli/Sources'
  swift test --sanitize=thread --filter 'BluetoothClientCoreTests'
  ```
- **Risks:**
  - Actor re-entrancy at every await. Request atomicity depends on the gates, not on the actor.
  - A cleanup path missing on cancellation leaves an unauthenticated link up (C41).
- **Task (brief body):** Implement every [main] member of Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient.swift (SPEC §6.11) exactly per §4.1–§4.8. acquire/release are two FIFO continuation gates (.connection, .request); the lock order is always request → connection. ensureConnected(refresh:) follows §4.2 steps 1–8: availability per §8.1 — create the availabilityUpdates() stream BEFORE reading availability(), and for unknown/resetting/notDetermined race that stream against `sleeper.sleep(for: timing.poweredOnWait, purpose: .poweredOnWait)` in a task group (first finisher decides, the other is cancelled), failing fast on every other state; ≤ timing.connectAttempts single attempts with timing.connectTimeout, sleeping (.connectBackoff) 0.25 s after .timedOut else 0.1 s; .unknownPeripheral is terminal; the final message is `Failed to connect to <peripheral> after <n> attempts: <last error>`; discover the four session characteristics; a missing auth characteristic → `Could not find characteristic 0d0b7847-e12b-09a8-b04b-8e0922a9abab on machine.`; raw markers [connecting]/[connected]/[mtu n]/[authenticated]; on ANY error from step 4 on, including CancellationError, disconnect the new link and emit no event; on success set link, start the watcher, clear needsRediscovery, resetIdleTimer(), setConnected(true). authenticate follows §3.4 exactly: write UTF8(token) with response to 0d0b…; ≤ 10 reads with an .authPoll sleep of 50 ms before every read except the first; authenticationFailed = (bytes != [0x01]) after EVERY read; 10 misses → .bluetoothAuthenticationFailed; transport errors → `.bluetoothConnectionFailed("Failed to connect to machine with Bluetooth: <e>")`, unavailable → .bluetoothUnavailable; the auth write is tapped with isSecret: true. Idle timer per §4.6 (it never cancels itself; suppressed while shotCounterEnabled). Teardown paths and link events per the §4.7 table, including the stale-link identity guard, D16 (a loss cancels the idle task) and servicesInvalidated → needsRediscovery. The link watcher is exactly the SPEC §5.5 form `Task { [weak self] in for await e in link.events { await self?.handleLinkEvent(e, from: link) } }` (a strong self makes the await a G5 warning). Step 1 trusts the stored link (I1, D7e). setConnected is edge-triggered. connectionEvents()/rawFrames() are multiplexed AsyncStreams (the house pattern of LaMarzoccoCloudClient.swift:488-498), and emitRaw costs nothing without listeners. handleConnectionLost per §4.13 (it starts `reconnectTask = Task { await reconnectLoop() }`; reconnectLoop is BT-W2-02's). mapTransportError implements every cell of the §4.4.1 table. Test seams: drainBackgroundWorkForTesting awaits every tracked task (drops, reconnect) except the idle task; hasBackgroundWorkForTesting includes idle and reconnect; logHandler output never contains the token. Do not implement +Requests/+ShotCounter/+Discovery members. Your tests drive the client through the internal ensureConnected()/disconnect()/link events, using the AngstromTestSupport fakes.

#### BT-W1-10 — Discovery, pairing-mode token read and GATT table (static)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | M | BT-W0-01, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Discovery.swift`, `Tests/AngstromTests/Bluetooth/BluetoothDiscoveryTests.swift`
- **SPEC:** §3.2; §3.3; §4.14; §6.11 (+Discovery); §12 D3 D20
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:46`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:522-547`; `$UPSTREAM/tests/test_bluetooth_client.py:1326-1342`
- **Deliverables:**
  - static scanAll(transport:duration:), discoverMachines(transport:duration:), readToken(transport:peripheral:), gattTable(transport:peripheral:).
- **Tests:**
  - C50 `test_discover_devices_prefixes` (tests/test_bluetooth_client.py:1326) → BluetoothDiscoveryTests.testNamePrefixFilter
  - BluetoothDiscoveryTests.testNilOrEmptyNameSkipped (Angstrom-only: G-CODEC-8)
  - BluetoothDiscoveryTests.testFirstSeenOrderDeduplicated (Angstrom-only: D3)
  - BluetoothDiscoveryTests.testDiscoveryUnavailableThrows
  - BluetoothDiscoveryTests.testScanAllIsUnfiltered (Angstrom-only: U3/H10; nil, empty and OTHER names kept in first-seen order)
  - BluetoothDiscoveryTests.testDiscoveryAvailabilityWaitTimesOut (fires .poweredOnWait by hand)
  - BluetoothDiscoveryTests.testReadTokenOneAttemptNoAuth (Angstrom-only: G-CODEC-1)
  - BluetoothDiscoveryTests.testReadTokenKeepsNul
  - BluetoothDiscoveryTests.testReadTokenInvalidUTF8
  - BluetoothDiscoveryTests.testReadTokenATTErrorMessage (Angstrom-only: D20)
  - BluetoothDiscoveryTests.testReadTokenAlwaysDisconnects
  - BluetoothDiscoveryTests.testReadTokenMissingCharacteristic
  - BluetoothDiscoveryTests.testGattTableOneConnectNoAuth
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothDiscoveryTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-10" Sources Tests cli/Sources'
  ```
- **Task (brief body):** Implement Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Discovery.swift (SPEC §4.14). The members are static and touch no instance state or raw tap; they use default BluetoothTiming() and the transport's sleeper. Write your own fileprivate availability wait, the same rule as §4.2 step 3 including the `.poweredOnWait` sleep on the transport's sleeper (do not depend on the [main] helpers, which are implemented in parallel). scanAll: availability, then central.scan(for:duration) returned unchanged (no name filter). discoverMachines: scanAll, then keep a peripheral iff its name is non-nil, non-empty and case-sensitively starts with one of BluetoothConstants.machineNamePrefixes ("LINEAR_4" matches). Keep first-seen order, de-duplicated. readToken: availability; ONE connect with timing.tokenReadConnectTimeout (10 s); no auth; discover({token}, refresh: false), and a missing characteristic → `Could not find characteristic 0c0b7847-e12b-09a8-b04b-8e0922a9abab on machine.`; read; strict UTF-8 with NO NUL stripping, invalid → `.decoding("bluetooth token: invalid UTF-8")`; a .gatt error with ATT code 2/5/8/15 → `.bluetoothConnectionFailed("Could not read the Bluetooth token (ATT error <code>). Is the machine in pairing mode?")`; always disconnect. The token read is never printed. gattTable: one connect with timing.connectTimeout, link.gattTable(timeout:), disconnect; no auth.

#### BT-W1-11 — AngstromUI: base-dashboard funnel, cloud-only accessor use, BLE-first routing

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | M | BT-W0-02, BT-W0-04 |

- **Owns, create:** —
- **Owns, modify:** `Sources/AngstromUI/LaMarzoccoMachine.swift`, `Tests/AngstromUITests/Bluetooth/MachineTransportRoutingTests.swift`
- **SPEC:** §1.4; §4.15; §4.16 (routing table); §4.19 (base model); §4.20; §6.16 (main-file changes); §13
- **Upstream:** `$UPSTREAM/src/pylamarzocco/devices/_thing.py:27-38`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:494-509`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:764-841`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:870-892`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:983-1049`; `$UPSTREAM/tests/test_thing.py:29-34`
- **Deliverables:**
  - All ~33 dashboard writes through setBaseDashboard/updateBaseDashboard, reading only baseDashboard (SPEC §4.19 read rule); snapshot from baseDashboard; gating sets from core; the six methods call bluetoothFirst with the §4.16 mapping; cloud-only operations throw .cloudOnlyFunctionality without a cloud client.
- **Tests:**
  - T00 (added by plan, R7) `test_cloud_only_without_cloud_client` (tests/test_thing.py:29) → MachineTransportRoutingTests.testCloudOnlyWithoutCloudClientThrows
  - MachineTransportRoutingTests.testStartWithoutCloudThrowsAndStopIsNoOp
  - MachineTransportRoutingTests.testDashboardEqualsBaseWithoutOverlay
  - MachineTransportRoutingTests.testWidgetlessPushKeepsBaseWidgets
  - MachineTransportRoutingTests.testSnapshotPersistsBaseDashboard
  - MachineTransportRoutingTests.testSixCommandsWithoutBluetoothUseCloud
  - MachineTransportRoutingTests.testSmartStandbyAutoStandbyStaysCloudOnly
  - MachineTransportRoutingTests.testGatingUsesCoreModelSets
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'MachineTransportRoutingTests|LaMarzoccoMachineTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W1-11" Sources Tests cli/Sources'
  bash -c 'n=$(grep -cE "(^|[^A-Za-z_])(self\.)?dashboard = " Sources/AngstromUI/LaMarzoccoMachine.swift); test "$n" -eq 1 || { echo "dashboard assignments: $n"; exit 1; }'
  ```
- **Risks:**
  - About 33 sites in a 774-line file. A missed site makes the overlay and snapshot wrong only in BLE scenarios, which existing tests never see. Use the mechanical count.
- **Task (brief body):** You are the only owner of Sources/AngstromUI/LaMarzoccoMachine.swift after Wave 0. Apply the SPEC §6.16 'main-file behaviour changes'. (1) Every `dashboard = …` write becomes setBaseDashboard(…) (the three wholesale sites: snapshot seed, refreshDashboard, refreshAll) or updateBaseDashboard { … } (the push merge in start() and every optimistic site). The push merge is NOT wholesale: `if let current = self.dashboard { self.dashboard = current.applying(update); self.lastUpdateAt = Date() }` becomes `if self.baseDashboard != nil { self.updateBaseDashboard { $0.applying(update) }; self.lastUpdateAt = Date() }`, so a widget-less push keeps the base widgets. SPEC §4.19 read rule: every value that feeds a base write is read from baseDashboard, never from the rendered dashboard (that includes guard reads such as `dashboard?.groupDoses` and `dashboard?.grinderDoses?.mode` in the optimistic paths); otherwise the overlay's .brewing status leaks into the base and the snapshot. Afterwards the only assignment to `dashboard` in the file is inside renderDashboard(). (2) `snapshot` persists baseDashboard. (3) Self.steamLevelModels/steamTemperatureModels become Model.steamLevelModels/Model.steamTemperatureModels; the other gating sets stay. (4) setPower, setSteam, setSteamTargetLevel, setCoffeeTargetTemperature, setSteamTargetTemperature and setSmartStandby call bluetoothFirst(bluetooth:cloud:) inside their existing capturing{}, after gating, with exactly the BLE and cloud calls of the §4.16 table (the BLE argument order is (enabled, mode: after, minutes); setSteamTargetLevel sends Double(level.bluetoothTargetTemperature); no rounding on the BLE leg). setSmartStandby with schedule?.autoStandBySupported == true stays cloud-only via `try client` ("HH:MM" = String(format: "%02d:%02d", minutes / 60, minutes % 60), or "Off"). Optimistic updates stay after the call. (5) Every other cloud method resolves `try client`, so a machine without a cloud client throws .cloudOnlyFunctionality and records lastError through capturing. start() resolves the client first; stop() is a no-op without one. bluetoothFirst's BLE branch is BT-W3-07's; your tests use machines without a Bluetooth client, through BluetoothMachineHarness(bluetooth: false) or the existing MockBackend. Existing tests (LaMarzoccoMachineTests.swift, unmodified) must stay green.

#### BT-W1-12 — angcli scaffolding: package, Info.plist, Ble command tree, redaction, internal API stubs

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 1 | implement | M | BT-W0-01 |

- **Owns, create:** `cli/Support/Info.plist`, `cli/Sources/angcli/Ble/Ble.swift`, `cli/Sources/angcli/Ble/BleSession.swift`, `cli/Sources/angcli/Ble/BleOutput.swift`, `cli/Sources/angcli/Ble/BleScan.swift`, `cli/Sources/angcli/Ble/BleGatt.swift`, `cli/Sources/angcli/Ble/BleToken.swift`, `cli/Sources/angcli/Ble/BleRead.swift`, `cli/Sources/angcli/Ble/BleCmd.swift`, `cli/Sources/angcli/Ble/BleListen.swift`, `cli/Tests/angcliTests/BleSessionTests.swift`, `cli/Tests/angcliTests/BleOutputTests.swift`, `cli/Tests/angcliTests/BleDiscoveryCommandTests.swift`, `cli/Tests/angcliTests/BleRequestCommandTests.swift`, `cli/Tests/angcliTests/BleListenTests.swift`
- **Owns, modify:** `cli/Package.swift`, `cli/Sources/angcli/AngCLI.swift`, `cli/Sources/angcli/Output.swift`
- **SPEC:** §8.4; §10.1; §10.4; §10.5; §10.6; PLAN §3.2; PLAN §3.4
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_cloud.py:84-92`
- **Deliverables:**
  - cli/Package.swift (AngstromBluetooth dep + -sectcreate), cli/Support/Info.plist, Ble parent + six subcommand stubs, BleSession/BleOutput stubs, Redact.bluetoothFrame (complete), CLI test placeholders.
- **Tests:**
  - (scaffolding: behaviour tests belong to BT-W2-03…06; Redact.bluetoothFrame is tested by BT-W2-03)
- **Acceptance:**

  ```sh
  swift build --package-path cli
  swift test --package-path cli
  bash -c 'set -o pipefail; mkdir -p cli/.build; rm -rf cli/.build/g5; NO_COLOR=1 swift build --package-path cli --build-tests --scratch-path cli/.build/g5 2>&1 | tee cli/.build/bt-warnings.log && ! grep -E "/cli/(Sources/angcli/Ble/|Sources/angcli/Output\.swift|Sources/angcli/AngCLI\.swift|Tests/angcliTests/Ble)[^:]*:[0-9]+:[0-9]+: warning:" cli/.build/bt-warnings.log'
  swift build --build-tests
  bash -c '! grep -rn "unimplemented: BT-W1-12" Sources Tests cli/Sources'
  plutil -lint cli/Support/Info.plist
  bash -c 'grep -q NSBluetoothAlwaysUsageDescription cli/Support/Info.plist'
  bash -c '! grep -q unsafeFlags Package.swift'
  bash -c '! grep -rhoE "unimplemented: BT-W[0-9]-[0-9]+" cli/Sources | sed "s/unimplemented: //" | sort -u | grep -vxE "BT-W2-0[3-6]"'
  bash -c 'for f in cli/Tests/angcliTests/BleSessionTests.swift cli/Tests/angcliTests/BleOutputTests.swift cli/Tests/angcliTests/BleDiscoveryCommandTests.swift cli/Tests/angcliTests/BleRequestCommandTests.swift cli/Tests/angcliTests/BleListenTests.swift; do test -f "$f" || { echo "missing $f"; exit 1; }; done'
  ```
- **Risks:**
  - unsafeFlags is allowed only because cli/ is always a root package (SPEC §8.4). Never add it to the root Package.swift.
- **Task (brief body):** Prepare the angcli package for the `ble` command tree (SPEC §10) so BT-W2-03…06 can work in parallel. cli/Package.swift: add `.product(name: "AngstromBluetooth", package: "Angstrom")` to the angcli target, and `linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Support/Info.plist"])]` (SPEC §8.4). If the relative path does not resolve, the allowed fallback is `"\(Context.packageDirectory)/Support/Info.plist"`; report which one you used. cli/Support/Info.plist: CFBundleIdentifier `angstrom.angcli`, CFBundleName `angcli`, NSBluetoothAlwaysUsageDescription `angcli talks to your La Marzocco machine over Bluetooth for debugging.` AngCLI.swift: subcommands [Listen.self, Dump.self, Machines.self, Ble.self]; mention Bluetooth in abstract/discussion; version "2.0.0". Output.swift: add Redact.bluetoothFrame(_:) per SPEC §10.4. If frame.isSecret, OR the frame is a write to 0d0b7847-e12b-09a8-b04b-8e0922a9abab, OR a read of 0c0b7847-e12b-09a8-b04b-8e0922a9abab, both hex and text are Redact.placeholder. Otherwise hex is lowercase hex and text is the UTF-8 string or nil. Redact.secrets(in:) is unchanged. Create Ble/Ble.swift complete per PLAN §3.2. Create Ble/BleSession.swift and Ble/BleOutput.swift with exactly the PLAN §3.2 declarations as stubs (owner BT-W2-03); BleTargetOptions is complete. Create BleScan/BleGatt/BleToken (owner BT-W2-04), BleRead/BleCmd (BT-W2-05) and BleListen (BT-W2-06) as AsyncParsableCommand structs whose configuration has an abstract and whose run() throws CLIError("unimplemented: <owner>"). Create the CLI test placeholders of PLAN §3.4. Existing CLI tests must pass.

### Wave 2 — Client behaviours, CLI commands, docs; review of Wave 1 (parallel)

#### BT-W2-01 — Client requests: request wrapper, resolution, reads, commands, rawRead

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | implement | M | BT-W1-02, BT-W1-03, BT-W1-09, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Requests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothClientRequestsSmokeTests.swift`
- **SPEC:** §3.5–§3.7; §4.4; §4.4.1; §4.5; §6.11 (+Requests); §12 D7 D19
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:114-136`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:555-626`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:655-747`; `$UPSTREAM/tests/test_bluetooth_client.py:295-430`; `$UPSTREAM/tests/test_bluetooth_client.py:1223-1302`
- **Deliverables:**
  - request(_:frame:), resolve(_:on:), readSetting, sendCommand, the six reads, the four commands, rawRead(_:).
- **Tests:**
  - BluetoothClientRequestsSmokeTests.testEachReadDecodes
  - BluetoothClientRequestsSmokeTests.testEachCommandWritesFrameAndReturnsStatus
  - BluetoothClientRequestsSmokeTests.testNonSuccessStatusIsReturned
  - BluetoothClientRequestsSmokeTests.testDecodeErrorKeepsLink
  - BluetoothClientRequestsSmokeTests.testDropClassErrorDropsIdleLink
  - BluetoothClientRequestsSmokeTests.testSmokeMissingCharacteristicDrops
  - BluetoothClientRequestsSmokeTests.testLinkDropBetweenWriteAndReadFails
  - BluetoothClientRequestsSmokeTests.testNonFiniteTemperatureRejected
  - BluetoothClientRequestsSmokeTests.testRawReadIsVerbatim
  - BluetoothClientRequestsSmokeTests.testRequestTimeoutIsBluetoothTimedOut
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothClientRequestsSmokeTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W2-01" Sources Tests cli/Sources'
  ```
- **Task (brief body):** Implement Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Requests.swift (SPEC §6.11 [+Requests]). request(_:frame:) is exactly §4.4 steps 1–7: the request gate held end to end; ensureConnected; resolve; a write with response (operationTimeout) tapped as .write; the same-link check `self.link !== link` → `.bluetoothConnectionFailed("Client is not connected")` (D7a), else resetIdleTimer(); a read of the same characteristic tapped as .read; on error mapTransportError(phase: .request), then dropConnectionInBackground() for drop-class errors unless `shotCounterEnabled && link != nil`; rethrow. resolve(_:on:) is exactly §4.5, including one in-place rediscovery and an unconditional drop when the characteristic is still missing. readSetting writes BluetoothCodec.readRequestFrame to 0a0b… and returns BluetoothCodec.responseText (context = setting rawValue). Decoding happens AFTER the gate is released, so a decode error never drops the link. sendCommand writes the frame to 0b0b…, reads 0b0b…, and decodes with BluetoothResponseDecoder.commandStatus. A non-success status is RETURNED, not thrown. setTemperature rejects a non-finite value with `.operationNotAvailable("temperature must be finite")` before any I/O (D21), and does not round. rawRead returns the verbatim bytes before NUL truncation. Write narrow smoke tests only; the parity suites are BT-W3-01/02/03.

#### BT-W2-02 — Client shot counter: subscribe, notifications, stop, reconnect loop

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | implement | L | BT-W1-04, BT-W1-09, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+ShotCounter.swift`, `Tests/AngstromTests/Bluetooth/BluetoothClientShotCounterSmokeTests.swift`
- **SPEC:** §3.8; §4.9; §4.10; §4.12; §4.13; §6.11 (+ShotCounter); §12 D4 D14 D15
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:327-465`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:475-520`; `$UPSTREAM/tests/test_bluetooth_client.py:652-1191`
- **Deliverables:**
  - startShotCounter, stopShotCounter, shotCounterEvents, subscribeShotCounter, disableShotCounter, stopNotifyInternal, handleShotCounterNotification, reconnectLoop.
- **Tests:**
  - BluetoothClientShotCounterSmokeTests.testStartAuthenticatesThenSubscribes
  - BluetoothClientShotCounterSmokeTests.testReplayIsDropped
  - BluetoothClientShotCounterSmokeTests.testBrewingEmittedBeforeTelemetry
  - BluetoothClientShotCounterSmokeTests.testStopUnsubscribesAndRearmsIdle
  - BluetoothClientShotCounterSmokeTests.testLossReconnectsAndResubscribes
  - BluetoothClientShotCounterSmokeTests.testGiveUpEmitsGaveUp
  - BluetoothClientShotCounterSmokeTests.testUnsupportedReturnsFalse
  - BluetoothClientShotCounterSmokeTests.testSmokePoweredOnCutsBackoff (no polling: make .reconnectBackoff manual and `await sleeper.waitForPending(.reconnectBackoff, count: 1)`; SPEC §4.13 creates the availability stream before the first sleep, so it exists by then — assert central.availabilitySubscriberCount >= 1, then setAvailability)
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothClientShotCounterSmokeTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W2-02" Sources Tests cli/Sources'
  swift test --sanitize=thread --filter 'BluetoothClientShotCounterSmokeTests'
  ```
- **Risks:**
  - The D14 availability race with the backoff sleep. Implement it as a task group or a cancellation of the sleep, never by polling.
  - Emitting .unsubscribed at give-up would duplicate the event already sent at loss time (§4.13).
- **Task (brief body):** Implement Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+ShotCounter.swift (SPEC §6.11 [+ShotCounter]) exactly per §4.9, §4.10 and §4.13. Replace the Wave 0 inert fast paths with the full behaviour. startShotCounter: enabled = true; subscribe; on a throw or false, disable (and resetIdleTimer if linked), then rethrow or return false; a second call while subscribed returns true with no new .subscribed. subscribeShotCounter: the [false, true] refresh loop of §4.9, under the connection gate; tracker reset and replayPending = true BEFORE link.subscribe; .subscribed is emitted after releasing the gate. stopShotCounter and disableShotCounter per §4.9: state is mutated before any event. stopNotifyInternal is best effort. handleShotCounterNotification per §4.10: raw tap first, then the replay drop, then decode, then brewing before telemetry; emit only while enabled. reconnectLoop: the §4.13 pseudocode verbatim. Sleep (.reconnectBackoff) BEFORE every attempt. D14: the sleep ends early, resetting the delay to reconnectInitialDelay, when central.availabilityUpdates() yields .poweredOn after a non-poweredOn value seen during this loop. Auth failures are counted cumulatively and do not double the delay. Other errors disconnect under the gate and double the delay up to 60 s. An unsupported result gives up. Giving up clears reconnectTask, disables the counter, re-arms the idle timer if linked, and emits .gaveUp(lastError) when the counter was still enabled (D15). CancellationError returns silently. shotCounterEvents() is multiplexed like connectionEvents(). Write narrow smoke tests only; the parity suites are BT-W3-03/04/05.

#### BT-W2-03 — angcli: BleSession (selection, token precedence) and BleOutput (lines, redaction)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | implement | M | BT-W1-12 |

- **Owns, create:** —
- **Owns, modify:** `cli/Sources/angcli/Ble/BleSession.swift`, `cli/Sources/angcli/Ble/BleOutput.swift`, `cli/Tests/angcliTests/BleSessionTests.swift`, `cli/Tests/angcliTests/BleOutputTests.swift`
- **SPEC:** §8.7; §10.2; §10.3; §10.4; PLAN §3.2
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_cloud.py:84-92`; `$UPSTREAM/README.md:78-125`
- **Deliverables:**
  - BleSession and BleOutput implemented per PLAN §3.2 and SPEC §10.2–§10.4, with tests.
- **Tests:**
  - BleSessionTests.testTokenPrecedenceFlagThenEnvironment
  - BleSessionTests.testEmptyLocalTokensFallThroughToCloud
  - BleSessionTests.testSelectPeripheralNoneOneMany
  - BleSessionTests.testUnavailableErrorTexts
  - BleSessionTests.testTargetOptionsParse
  - BleOutputTests.testRawLineShape
  - BleOutputTests.testSecretFrameRedacted
  - BleOutputTests.testAuthWriteRedactedByUUID
  - BleOutputTests.testTokenReadRedactedByUUID
  - BleOutputTests.testNonUTF8RawHasNoText
  - BleOutputTests.testDecodedLineShapes
  - BleOutputTests.testTokenLineMaskedByDefault
  - BleOutputTests.testExistingRedactSecretsUnchanged
- **Acceptance:**

  ```sh
  swift build --package-path cli
  swift test --package-path cli --filter 'BleSessionTests|BleOutputTests'
  swift test --package-path cli
  bash -c 'set -o pipefail; mkdir -p cli/.build; rm -rf cli/.build/g5; NO_COLOR=1 swift build --package-path cli --build-tests --scratch-path cli/.build/g5 2>&1 | tee cli/.build/bt-warnings.log && ! grep -E "/cli/(Sources/angcli/Ble/|Sources/angcli/Output\.swift|Sources/angcli/AngCLI\.swift|Tests/angcliTests/Ble)[^:]*:[0-9]+:[0-9]+: warning:" cli/.build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W2-03" Sources Tests cli/Sources'
  ```
- **Task (brief body):** Implement cli/Sources/angcli/Ble/BleSession.swift and BleOutput.swift with exactly the PLAN §3.2 declarations. BleSession: token precedence --ble-token → LAMARZOCCO_BLE_TOKEN → cloud (Bootstrap.connect() + MachineSelector.choose(serial:) + bluetoothAuthToken(serial:)). A nil cloud token → CLIError("The cloud has no Bluetooth token for <serial>. Use 'angcli ble token' in pairing mode or the QR label."). Peripheral selection per §10.2 with an interactive pick on stderr. Never persist the token or the peripheral id. cliError maps .bluetoothUnavailable(.unauthorized(_)) and .poweredOff to the exact §10.3 texts. BleOutput: one JSON object per line. A raw line is {"ts","dir":">>"|"<<","kind":"write|read|notification|event","char","hex","text"} built through Redact.bluetoothFrame (never bypass it). Decoded lines are {"ts","event","value"} with CLI-local Encodable mirrors of BluetoothShotCounterUpdate/BluetoothMachineTelemetry. tokenLine is masked unless showSecret. Reuse Stdout/Stderr/Timestamp from Output.swift (read-only for you). Tests cover only pure functions: no CoreBluetooth and no network. Build DiscoveredPeripheral, BluetoothGATTService and BluetoothGATTCharacteristic values with their public inits (SPEC §6.2); angcli is a separate package and cannot see `package` declarations.

#### BT-W2-04 — angcli: ble scan, ble gatt, ble token

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | implement | S | BT-W1-12 |

- **Owns, create:** —
- **Owns, modify:** `cli/Sources/angcli/Ble/BleScan.swift`, `cli/Sources/angcli/Ble/BleGatt.swift`, `cli/Sources/angcli/Ble/BleToken.swift`, `cli/Tests/angcliTests/BleDiscoveryCommandTests.swift`
- **SPEC:** §10.1; §10.3; §10.4; §9.6 (H1, H10, H17); PLAN §3.2
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:522-547`
- **Deliverables:**
  - BleScan (--duration, --all via scanAll), BleGatt (--peripheral), BleToken (--peripheral, --show-secret).
- **Tests:**
  - BleDiscoveryCommandTests.testScanParsesDurationAndAll
  - BleDiscoveryCommandTests.testGattRequiresPeripheral
  - BleDiscoveryCommandTests.testTokenShowSecretDefaultsOff
- **Acceptance:**

  ```sh
  swift build --package-path cli
  swift test --package-path cli --filter 'BleDiscoveryCommandTests'
  swift test --package-path cli
  bash -c 'set -o pipefail; mkdir -p cli/.build; rm -rf cli/.build/g5; NO_COLOR=1 swift build --package-path cli --build-tests --scratch-path cli/.build/g5 2>&1 | tee cli/.build/bt-warnings.log && ! grep -E "/cli/(Sources/angcli/Ble/|Sources/angcli/Output\.swift|Sources/angcli/AngCLI\.swift|Tests/angcliTests/Ble)[^:]*:[0-9]+:[0-9]+: warning:" cli/.build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W2-04" Sources Tests cli/Sources'
  ```
- **Task (brief body):** Implement cli/Sources/angcli/Ble/BleScan.swift, BleGatt.swift and BleToken.swift (SPEC §10.1) on top of the PLAN §3.2 API (BleSession/BleOutput are implemented in parallel by BT-W2-03: only call their declared signatures). scan: `--duration <s>` (default 5). Without `--all` it calls LaMarzoccoBluetoothClient.discoverMachines; with `--all` it calls the public LaMarzoccoBluetoothClient.scanAll (unfiltered, SPEC §4.14) and prints the count to stderr. It prints one peripheralLine per peripheral (name may be null with --all). Only public Angstrom API is visible from cli/ (no `package` access). gatt: requires --peripheral and prints gattLines. token: requires --peripheral, calls LaMarzoccoBluetoothClient.readToken, prints tokenLine masked unless `--show-secret`, which prints to stdout only. Map errors through BleSession.cliError. Tests are argument-parsing only (`Ble*.parse([...])`); no hardware.

#### BT-W2-05 — angcli: ble read, ble cmd (with --confirm)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | implement | M | BT-W1-12 |

- **Owns, create:** —
- **Owns, modify:** `cli/Sources/angcli/Ble/BleRead.swift`, `cli/Sources/angcli/Ble/BleCmd.swift`, `cli/Tests/angcliTests/BleRequestCommandTests.swift`
- **SPEC:** §10.1; §10.3; §9.6 (H22–H27); PLAN §3.2
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:555-626`; `$UPSTREAM/src/pylamarzocco/const.py:322-330`
- **Deliverables:**
  - BleRead (<setting|all>) and BleCmd (power/steam/temp/standby subcommands, refusing without --confirm).
- **Tests:**
  - BleRequestCommandTests.testReadParsesSettingAndAll
  - BleRequestCommandTests.testCmdRefusesWithoutConfirm
  - BleRequestCommandTests.testCmdSubcommandsParse
  - BleRequestCommandTests.testTempRejectsNonFinite
- **Acceptance:**

  ```sh
  swift build --package-path cli
  swift test --package-path cli --filter 'BleRequestCommandTests'
  swift test --package-path cli
  bash -c 'set -o pipefail; mkdir -p cli/.build; rm -rf cli/.build/g5; NO_COLOR=1 swift build --package-path cli --build-tests --scratch-path cli/.build/g5 2>&1 | tee cli/.build/bt-warnings.log && ! grep -E "/cli/(Sources/angcli/Ble/|Sources/angcli/Output\.swift|Sources/angcli/AngCLI\.swift|Tests/angcliTests/Ble)[^:]*:[0-9]+:[0-9]+: warning:" cli/.build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W2-05" Sources Tests cli/Sources'
  ```
- **Task (brief body):** Implement cli/Sources/angcli/Ble/BleRead.swift and BleCmd.swift (SPEC §10.1). read <setting|all> takes @OptionGroup BleTargetOptions. For each setting it calls rawRead and then the typed read, and prints BleOutput.readLine with `raw` = the UTF-8 text of the verbatim bytes (hex if not UTF-8) and a CLI-local Encodable mirror as `decoded`. cmd has nested subcommands: `power <on|off>`, `steam <on|off>`, `temp <coffee|steam> <celsius>`, `standby --enabled <bool> --minutes <n> --mode <LastBrewing|PowerOn>`. Each requires `--confirm`, enforced in validate() with a ValidationError (it actuates hardware), and prints BleOutput.commandLine with success = status.isSuccess. Use only the PLAN §3.2 signatures of BleSession/BleOutput (implemented in parallel by BT-W2-03). Tests are parsing/validation only.

#### BT-W2-06 — angcli: ble listen (raw + decoded, SIGINT teardown)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | implement | M | BT-W1-12 |

- **Owns, create:** —
- **Owns, modify:** `cli/Sources/angcli/Ble/BleListen.swift`, `cli/Tests/angcliTests/BleListenTests.swift`
- **SPEC:** §10.1; §10.3; §9.6 (H2, H12–H14, H18, H20); PLAN §3.2
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:327-465`
- **Deliverables:**
  - BleListen: registers rawFrames/connectionEvents/shotCounterEvents BEFORE startShotCounter, prints until SIGINT, then stopShotCounter + disconnect and exits 0.
- **Tests:**
  - BleListenTests.testListenDefaultsToBoth
  - BleListenTests.testListenRawOnly
  - BleListenTests.testListenAcceptsTargetOptions
- **Acceptance:**

  ```sh
  swift build --package-path cli
  swift test --package-path cli --filter 'BleListenTests'
  swift test --package-path cli
  bash -c 'set -o pipefail; mkdir -p cli/.build; rm -rf cli/.build/g5; NO_COLOR=1 swift build --package-path cli --build-tests --scratch-path cli/.build/g5 2>&1 | tee cli/.build/bt-warnings.log && ! grep -E "/cli/(Sources/angcli/Ble/|Sources/angcli/Output\.swift|Sources/angcli/AngCLI\.swift|Tests/angcliTests/Ble)[^:]*:[0-9]+:[0-9]+: warning:" cli/.build/bt-warnings.log'
  bash -c '! grep -rn "unimplemented: BT-W2-06" Sources Tests cli/Sources'
  ```
- **Task (brief body):** Implement cli/Sources/angcli/Ble/BleListen.swift (SPEC §10.1, §10.3). It takes @OptionGroup BleTargetOptions and `--raw` / `--decoded` (reuse OutputMode from AngCLI.swift; both are shown by default). Register client.rawFrames(), connectionEvents() and shotCounterEvents() BEFORE startShotCounter(), so the auth and subscribe frames are captured. Print through BleOutput (rawLine / connectionLine / shotCounterLine). Install SignalHandler(SIGINT) → stopShotCounter() + disconnect(), mirroring Listen.swift:34-38, and exit 0. If startShotCounter returns false, print `Shot counter not supported by this machine` to stderr and exit non-zero. Use only the PLAN §3.2 signatures (BT-W2-03 implements them in parallel). Tests are parsing only.

#### BT-W2-07 — Process docs: CLAUDE.md, UPSTREAM.md (divergence register), workflows

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | docs | M | BT-W0-01 |

- **Owns, create:** —
- **Owns, modify:** `CLAUDE.md`, `UPSTREAM.md`, `.github/workflows/upstream-drift.yml`, `.github/workflows/docs.yml`
- **SPEC:** §11; §12; §13; §14
- **Upstream:** `$UPSTREAM/README.md:229-269`
- **Deliverables:**
  - CLAUDE.md Bluetooth architecture/conventions/status; UPSTREAM.md 'Bluetooth port (v2.0.0)' section with D1–D22 and the UNVERIFIED list; workflow edits.
- **Tests:**
  - (docs: verified by the acceptance greps and by BT-W4-06)
- **Acceptance:**

  ```sh
  bash -c 'grep -q "<!-- upstream-version: v2.5.6 -->" UPSTREAM.md && grep -q "<!-- upstream-sha: 4c639ee -->" UPSTREAM.md'
  bash -c 'for i in $(seq 1 22); do grep -qE "D$i([^0-9]|$)" UPSTREAM.md || { echo "missing D$i"; exit 1; }; done'
  bash -c '! grep -n "Bluetooth is explicitly out of scope" CLAUDE.md && ! grep -n "Bluetooth remains out of scope" CLAUDE.md'
  bash -c 'grep -q -- "--target AngstromBluetooth" .github/workflows/docs.yml'
  bash -c '! grep -n "skip Bluetooth-only" .github/workflows/upstream-drift.yml'
  bash -c 'git diff --quiet e1bc403 -- .github/workflows/ci.yml'
  ```
- **Task (brief body):** Apply the SPEC §11 rows for CLAUDE.md, UPSTREAM.md, .github/workflows/upstream-drift.yml and .github/workflows/docs.yml, writing from the frozen SPEC (the code is being built in parallel). CLAUDE.md: replace the out-of-scope sentence at :12 with the §11 text; add Sources/Angstrom/Bluetooth/, Sources/AngstromBluetooth/, AngstromTestSupport, the new AngstromUI files and `angcli ble` to the Architecture section; add the three conventions; add a v2.0.0 Status paragraph; remove 'Bluetooth remains out of scope'. UPSTREAM.md: keep the markers `<!-- upstream-version: v2.5.6 -->` and `<!-- upstream-sha: 4c639ee -->` byte-identical; update the Scope row and :26-31 to 'cloud and Bluetooth parity'; add a 'Bluetooth port (v2.0.0)' section listing D1–D22 (with D5's six and D7's five sub-items) and their SPEC §12 rationale and the SPEC §14.2 UNVERIFIED items; append a pointer after the historical out-of-scope notes (:119-163) without rewriting them; extend the e0f0249 note to say the BLE aliases live in Model(bluetoothFamily:); change the runbook triage line (:253-255) and the review-surface diff to include clients/_bluetooth.py, models/_bluetooth.py and the BT paths in devices/. upstream-drift.yml: line 97 → 'port cloud and Bluetooth changes'; fix the :60 comment. docs.yml: add `--target AngstromBluetooth` next to the existing --target flags. Do not touch ci.yml.

#### BT-W2-08 — User docs: README, DocC catalogs and Bluetooth article, angcli docs

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | docs | L | BT-W0-02, BT-W1-12 |

- **Owns, create:** `Sources/Angstrom/Documentation.docc/Bluetooth.md`
- **Owns, modify:** `README.md`, `Sources/Angstrom/Documentation.docc/Angstrom.md`, `Sources/Angstrom/Documentation.docc/GettingStarted.md`, `Sources/AngstromUI/Documentation.docc/AngstromUI.md`, `cli/SPEC.md`, `cli/README.md`
- **SPEC:** §5.8; §8; §10; §11; §13
- **Upstream:** `$UPSTREAM/README.md:78-125`; `$UPSTREAM/README.md:225-269`
- **Deliverables:**
  - README Bluetooth section; DocC topic group + Bluetooth.md article + 2.0.0 getting-started; AngstromUI catalog additions; cli/SPEC.md + cli/README.md ble sections.
- **Tests:**
  - (docs: verified by the docs build and by BT-W4-06)
- **Acceptance:**

  ```sh
  swift package --allow-writing-to-directory .build/bt-docs generate-documentation --target Angstrom --target AngstromUI --target AngstromBluetooth --enable-experimental-combined-documentation --disable-indexing --output-path .build/bt-docs
  bash -c 'grep -q "from: \"2.0.0\"" README.md'
  bash -c '! grep -n "Bluetooth is out of scope" Sources/Angstrom/Documentation.docc/Angstrom.md'
  bash -c 'grep -q "ble" cli/README.md && grep -q "ble" cli/SPEC.md'
  ```
- **Task (brief body):** Write the user-facing docs from the frozen SPEC. The code is built in parallel; every public symbol already exists as a stub, so DocC links resolve. README.md (§11): cloud AND Bluetooth at :5 and :21-24; a Bluetooth section covering the products, token sources (cloud bleAuthToken via bluetoothAuthToken(serial:), pairing-mode readToken, the QR label), the shot counter, app requirements (§8.2), the single-central caveat (README:231 upstream) and identity persistence (§8.7); install snippet `from: "2.0.0"`. Sources/Angstrom/Documentation.docc/Angstrom.md: drop the out-of-scope sentence at :7-11; add a `### Bluetooth` topic group with the §11 symbols. New Bluetooth.md article: tokens, discovery and identity, lifecycle (lazy connect, 30 s idle, shot counter), errors and fallback, platform requirements, and the §5.8 recipe. GettingStarted.md: version 2.0.0 plus a link to the article. Sources/AngstromUI/Documentation.docc/AngstromUI.md: BLE-first commands, refreshDashboardFromBluetooth, the shot counter, bluetoothEvents(), isBluetoothConnected. cli/SPEC.md and cli/README.md: a `ble` section (the §10.1 tree, §10.2 selection, TCC notes from §8.4, the §10.4 redaction rules, and that `ble cmd` needs --confirm). Never show a real token in examples; use `**REDACTED**`.

#### BT-W2-09 — Verify: wire-level parity of constants, codec, decoders, coercion, enums, token, discovery

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | verify | M | BT-W1-01, BT-W1-02, BT-W1-03, BT-W1-06, BT-W1-10 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §2.2; §2.3; §3; §4.14; §4.21; §6.1–§6.8; §6.13; §9.3.1; §9.3.2; §9.3.5
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:40-64`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:522-626`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:655-710`; `$UPSTREAM/src/pylamarzocco/models/_bluetooth.py:22-87`; `$UPSTREAM/src/pylamarzocco/const.py:11-31`; `$UPSTREAM/src/pylamarzocco/const.py:141-339`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:58-84`; `$UPSTREAM/src/pylamarzocco/models/_general.py:128-136`; `$UPSTREAM/src/pylamarzocco/exceptions.py:20-47`; `$UPSTREAM/tests/test_bluetooth_client.py:40-59`; `$UPSTREAM/tests/test_bluetooth_client.py:295-430`; `$UPSTREAM/tests/test_bluetooth_client.py:1223-1250`; `$UPSTREAM/tests/test_bluetooth_client.py:1326-1342`; `$UPSTREAM/tests/test_models.py:391-418`
- **Deliverables:**
  - §5.2 JSON report: per-constant and per-vector diff, coercion table walk-through, findings with fix owners.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothEnumsTests|BluetoothWireCoercionTests|BluetoothModelsTests|BluetoothCodecTests|BluetoothResponseDecoderTests|BluetoothTokenTests|BluetoothDiscoveryTests'
  bash -c 'for u in 0a0b 0b0b 0c0b 0d0b 0e0b; do grep -q "${u}7847-e12b-09a8-b04b-8e0922a9abab" Sources/Angstrom/Bluetooth/BluetoothConstants.swift || { echo "missing $u"; exit 1; }; done'
  ```
- **Task (brief body):** Adversarially diff the Swift wire layer against upstream, line by line. Files: BluetoothConstants, BluetoothTransport (error descriptions), BluetoothAuthToken, BluetoothEnums, BluetoothModels, BluetoothWireCoercion, BluetoothShotCounterModels (merge), BluetoothDiagnostics markers, BluetoothCodec, BluetoothResponseDecoder, LaMarzoccoCloudClient+BluetoothToken, LaMarzoccoBluetoothClient+Discovery, and the §6.4 error texts in Models.swift. For EVERY UUID, JSON key, raw value, enum mapping, error message and timing constant, quote the $UPSTREAM line and the Swift line side by side. Re-derive every BT-REQ/BT-READ-REQ/BT-AUTH/BT-RSP vector by hand from upstream and compare it with the bytes the Swift tests assert. Walk every row of the SPEC §3.10 coercion table against the implementation, and confirm that D5 (a–f), D6, D8, D9 and D21 are the ONLY departures from Python semantics; spot-check BT-COERCE rows against upstream with the X3 command (PLAN §6.1) if `uv` is available. Check the ensure_ascii escaping (lowercase hex, U+007F escaped, surrogates), the integral-double rule, and that the int rule cannot trap. Write throwaway probes in your temp dir if useful (for example a tiny swift test via `swift test --filter`), but never commit.

#### BT-W2-10 — Verify: state machine, dashboard transforms and the UI funnel against upstream

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | verify | M | BT-W1-04, BT-W1-05, BT-W1-11 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §3.8; §4.11; §4.15–§4.20; §6.9; §6.12; §6.16; §9.3.3; §9.3.6; §9.3.8; §12 D12 D17 D18
- **Upstream:** `$UPSTREAM/src/pylamarzocco/models/_bluetooth.py:68-213`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:77-111`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:441-465`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:58-88`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:287-323`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:350-509`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:764-892`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:983-1049`; `$UPSTREAM/src/pylamarzocco/devices/_thing.py:27-38`; `$UPSTREAM/src/pylamarzocco/devices/_thing.py:73-126`; `$UPSTREAM/tests/test_bluetooth_dashboard.py:560-689`
- **Deliverables:**
  - §5.2 JSON report including a rule-by-rule equivalence table for derive_state/_BrewingTracker and the overlay-equivalence argument for D12.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BrewingStateMachineTests|ShotCounterNotificationDecoderTests|DashboardBluetoothTests|MachineTransportRoutingTests|LaMarzoccoMachineTests'
  bash -c 'n=$(grep -cE "(^|[^A-Za-z_])(self\.)?dashboard = " Sources/AngstromUI/LaMarzoccoMachine.swift); test "$n" -eq 1'
  ```
- **Task (brief body):** Review BrewingStateMachine.swift, Dashboard+Bluetooth.swift and Sources/AngstromUI/LaMarzoccoMachine.swift (BT-W1-11's funnel and routing) against upstream. (1) Map every branch of MBT derive_state and _BrewingTracker.process to the Swift code, including the reset points and the earliest-start rule; produce the table. (2) Check every cell of the §4.17 widget-synthesis table and the §4.19 overlay table against _machine.py:287-323 and :350-492. Argue (or refute) that the base + overlay model reproduces upstream's object-identity bookkeeping for vectors D1–D14 of SPEC §9.3.8. (3) Confirm that every `dashboard` write in LaMarzoccoMachine.swift goes through the funnel (exactly one assignment, in renderDashboard), that snapshot persists baseDashboard, that the six methods use exactly the §4.16 BLE/cloud calls with gating BEFORE any transport, and that every other method throws .cloudOnlyFunctionality without a cloud client (THING:27-38).

#### BT-W2-11 — Verify: CoreBluetooth adapter and op table — Swift 6 concurrency and SPEC §5.4 conformance

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | verify | M | BT-W1-07, BT-W1-08 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §5.1; §5.3; §5.4; §5.5; §6.2; §6.14; §8.1; §8.6; PLAN §3.1
- **Upstream:** `(Apple-specific; reference = SPEC §5.4 and, if provided, $RESEARCH/06-corebluetooth.md §3 and Appendix B)`
- **Deliverables:**
  - §5.2 JSON report: a §5.4 bullet-by-bullet conformance table plus a data-race analysis of every mutable adapter field.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothOpTableTests'
  xcodebuild -scheme Angstrom-Package -destination 'generic/platform=iOS Simulator' -quiet build
  bash -c '! grep -rnE "^@preconcurrency import|Mutex<|Task\.immediate|EnableAutoReconnect" Sources/AngstromBluetooth Sources/Angstrom/Bluetooth | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(//|///|\*)"'
  ```
- **Task (brief body):** Review Sources/AngstromBluetooth/* and Sources/Angstrom/Bluetooth/BluetoothOpTable.swift as a Swift 6 concurrency expert. Check each SPEC §5.4 bullet and report pass/fail with the code line. For every mutable stored property in the adapter, show that it is touched only on the private queue (or is immutable/Sendable). Show that no CBPeripheral/CBCharacteristic/CBCentralManager value escapes to another isolation domain. Show that every continuation is resumed exactly once across the reply/timeout/cancellation/disconnect/state-drop paths (trace through BluetoothOpTable). Check that owed replies cannot resolve a newer op, that notifications are routed before the CCCD ack, and that a late didConnect after a timeout is cancelled. Check that there is no `@preconcurrency import CoreBluetooth`, no `Mutex`, no `Task.immediate`, no custom executor, no Task hop inside delegate callbacks, and no API newer than macOS 14/iOS 17. Build for macOS and iOS.

#### BT-W2-12 — Verify: client core lifecycle (gates, connect, auth, idle, teardown, events) against upstream

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 2 | verify | M | BT-W1-09 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §3.4; §4.1–§4.8; §4.4.1; §5.5; §5.7; §6.11; §8.1; §12 D1 D7 D10 D11 D16 D19
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:114-325`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:467-486`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:628-653`
- **Deliverables:**
  - §5.2 JSON report: an invariant check (I1–I6), an error-mapping cell-by-cell table, and a re-entrancy analysis of every await in the main file.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothClientCoreTests'
  swift test --sanitize=thread --filter 'BluetoothClientCoreTests'
  ```
- **Task (brief body):** Review Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient.swift against _bluetooth.py:114-325, :467-486 and :628-653 and SPEC §4.1–§4.8. Verify invariants I1–I6, with evidence for each. For every `await` in the actor, state what other actor work can interleave and why the gates keep request atomicity (TBC:1253-1284) and the lock order request → connection. Check every cell of the §4.4.1 mapping table and every verbatim error text. Check the cleanup-on-error path including CancellationError (TBC:1197-1220), the edge-triggered events, that the idle timer never cancels itself (83289c6), that D16 cancels it on loss, and that the auth-poll timing and the authenticationFailed update rule match _bluetooth.py:636-653 exactly. Run the core tests under the Thread Sanitizer.

### Wave 3 — Client parity suites and the AngstromUI Bluetooth layer; review of the CLI (parallel)

#### BT-W3-01 — Parity suite: connection lifecycle and authentication

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 3 | implement | L | BT-W1-09, BT-W2-01, BT-W2-02, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Tests/AngstromTests/Bluetooth/BluetoothConnectionTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothAuthTests.swift`
- **SPEC:** §3.4; §4.2–§4.8; §4.4.1; §9.2; §9.4 (T1 rows); §12 D7 D11 D16 D19; PLAN §3.5
- **Upstream:** `$UPSTREAM/tests/test_bluetooth_client.py:157-292`; `$UPSTREAM/tests/test_bluetooth_client.py:434-649`; `$UPSTREAM/tests/test_bluetooth_client.py:1197-1220`; `$UPSTREAM/tests/test_bluetooth_client.py:1253-1284`; `$UPSTREAM/tests/test_bluetooth_client.py:1305-1323`; `$UPSTREAM/tests/test_bluetooth_client.py:1345-1435`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:114-325`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:628-653`
- **Deliverables:**
  - BluetoothConnectionTests and BluetoothAuthTests porting every assigned upstream test plus the assigned gap/divergence tests.
- **Tests:**
  - C09 `test_persistent_connection_auto_connect` (tests/test_bluetooth_client.py:434) → BluetoothConnectionTests.testFirstCommandConnectsAndAuthenticates
  - C10 `test_persistent_connection_reuse` (tests/test_bluetooth_client.py:454) → BluetoothConnectionTests.testSequentialCommandsReuseConnection
  - C11 `test_auto_disconnect_after_idle` (tests/test_bluetooth_client.py:475) → BluetoothConnectionTests.testIdleTimeoutDisconnects
  - C12 (restated) `test_timer_reset_on_new_command` (tests/test_bluetooth_client.py:493) → BluetoothConnectionTests.testCommandRestartsIdleTimer
  - C13 `test_concurrent_commands_thread_safe` (tests/test_bluetooth_client.py:516) → BluetoothConnectionTests.testConcurrentCommandsConnectOnce
  - C14 `test_exception_triggers_disconnect` (tests/test_bluetooth_client.py:544) → BluetoothConnectionTests.testCommandErrorDropsIdleConnection
  - C15 `test_characteristic_resolution_failure_clears_cache` (tests/test_bluetooth_client.py:565) → BluetoothConnectionTests.testMissingCharacteristicRediscoversThenDrops
  - C16 `test_is_connected_property` (tests/test_bluetooth_client.py:584) → BluetoothConnectionTests.testIsConnectedLifecycle
  - C17 `test_reconnect_after_disconnect` (tests/test_bluetooth_client.py:600) → BluetoothConnectionTests.testCommandAfterManualDisconnectReconnects
  - C18 `test_auth_read_back_failure` (tests/test_bluetooth_client.py:617) → BluetoothAuthTests.testWrongTokenReadsTenTimesThenFails
  - C19 `test_auth_read_back_retries_until_confirmed` (tests/test_bluetooth_client.py:636) → BluetoothAuthTests.testAuthRetriesUntilConfirmed
  - C41 `test_cancelled_connect_does_not_keep_unauthenticated_link` (tests/test_bluetooth_client.py:1197) → BluetoothAuthTests.testCancellationDuringAuthDropsLink
  - C47 `test_requests_are_atomic` (tests/test_bluetooth_client.py:1253) → BluetoothConnectionTests.testRequestWriteReadPairsAreAtomic
  - C49 `test_authentication_failed_flag` (tests/test_bluetooth_client.py:1305) → BluetoothAuthTests.testAuthenticationFailedFlagSetAndCleared
  - C51 (restated, D3) `test_ble_device_callback` (tests/test_bluetooth_client.py:1345) → BluetoothConnectionTests.testConnectUsesStoredPeripheralID
  - C52 `test_connection_callback_connect_and_idle_disconnect` (tests/test_bluetooth_client.py:1361) → BluetoothConnectionTests.testConnectionEventsConnectAndIdle
  - C53 `test_connection_callback_connection_lost` (tests/test_bluetooth_client.py:1382) → BluetoothConnectionTests.testConnectionEventsDeduplicate
  - C54 `test_connection_callback_not_called_on_failed_authentication` (tests/test_bluetooth_client.py:1405) → BluetoothAuthTests.testUnauthenticatedLinkNeverReportedConnected
  - C55 (restated, D4) `test_connection_callback_unregister` (tests/test_bluetooth_client.py:1424) → BluetoothConnectionTests.testCancelledEventStreamStopsDelivery
  - BluetoothAuthTests.testTransportErrorDuringAuthIsConnectionFailed (Angstrom-only: G-AUTH-1)
  - BluetoothAuthTests.testAuthPollIntervalIs50ms (Angstrom-only: G-AUTH-2)
  - BluetoothAuthTests.testAuthenticationFailedUnchangedByPreAuthFailure (Angstrom-only: G-AUTH-3)
  - BluetoothConnectionTests.testRediscoveredCharacteristicServesRequest (Angstrom-only: G-CONN-2, D7b)
  - BluetoothConnectionTests.testIdleTimerArmedAfterAuthAndReusedLink (Angstrom-only: G-CONN-4)
  - BluetoothConnectionTests.testFailedRequestDropsWhenShotCounterEnabledButUnlinked (Angstrom-only: G-CONN-5)
  - BluetoothConnectionTests.testLinkLossCancelsIdleTask (Angstrom-only: G-CONN-7, D16)
  - BluetoothConnectionTests.testLinkDropBetweenWriteAndReadFailsRequest (Angstrom-only: G-CONN-8, D7a)
  - BluetoothConnectionTests.testServicesInvalidatedForcesRediscovery (Angstrom-only: D7c)
  - BluetoothConnectionTests.testCancellationInsideRequestDrops (Angstrom-only: D7d)
  - BluetoothConnectionTests.testRequestInDisconnectWindowFailsThenReconnects (Angstrom-only: D7e; the link's ops throw .disconnected(code: 7) before any event is yielded → .bluetoothConnectionFailed, one drop, the next request reconnects)
  - BluetoothConnectionTests.testIsConnectedOnlyAfterAuth (Angstrom-only: D11)
  - BluetoothConnectionTests.testOperationTimeoutsMapPerPhase (Angstrom-only: D19; also assert every FakeBluetoothLink.requestedTimeouts entry equals timing.operationTimeout)
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothConnectionTests|BluetoothAuthTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  swift test --sanitize=thread --filter 'BluetoothConnectionTests|BluetoothAuthTests'
  ```
- **Task (brief body):** Port the upstream connection and auth tests assigned below into Tests/AngstromTests/Bluetooth/BluetoothConnectionTests.swift and BluetoothAuthTests.swift, against the real LaMarzoccoBluetoothClient over the AngstromTestSupport fakes. Read each upstream test in full first, and assert the same observable behaviour (op sequences via FakeBluetoothLink.recordedOps, connectCount, events, flags, sleeper durations). Restated tests follow the SPEC §9.4 wording: C12 = exactly one pending idle sleep after each command, and firing it disconnects; C51 = connect(to: peripheral) uses the stored id on every reconnect; C55 = a cancelled event-stream iteration stops delivery to that consumer only. Also write the Angstrom-only tests listed below. You own test files only. If behaviour deviates from SPEC, apply the BLOCKED-BY protocol (PLAN §1.6) against the fix owner (BT-W1-09 main, BT-W2-01 requests, BT-W2-02 shot counter, BT-W0-03 fakes).

#### BT-W3-02 — Parity suite: reads, commands, framing and the raw diagnostics tap

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 3 | implement | M | BT-W2-01, BT-W2-02, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Tests/AngstromTests/Bluetooth/BluetoothRequestTests.swift`, `Tests/AngstromTests/Bluetooth/BluetoothDiagnosticsTests.swift`
- **SPEC:** §3.5–§3.7; §3.10; §4.4; §5.7; §6.10; §9.3.1; §9.3.2; §9.4 (T2 rows); PLAN §3.5
- **Upstream:** `$UPSTREAM/tests/test_bluetooth_client.py:40-59`; `$UPSTREAM/tests/test_bluetooth_client.py:295-430`; `$UPSTREAM/tests/test_bluetooth_client.py:1223-1250`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:555-626`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:655-710`
- **Deliverables:**
  - BluetoothRequestTests (C01–C08, C42–C46 + gap tests) and BluetoothDiagnosticsTests.
- **Tests:**
  - C01 `test_ble_set_power` (tests/test_bluetooth_client.py:295) → BluetoothRequestTests.testSetPowerOnWritesMachineChangeMode
  - C02 `test_ble_set_temperature` (tests/test_bluetooth_client.py:310) → BluetoothRequestTests.testSetTemperatureSteamWritesSettingBoilerTarget
  - C03 `test_ble_set_smart_standby` (tests/test_bluetooth_client.py:324) → BluetoothRequestTests.testSetSmartStandbyWritesMinutesModeEnabled
  - C04 `test_ble_get_machine_capability` (tests/test_bluetooth_client.py:338) → BluetoothRequestTests.testGetMachineCapabilitiesDecodesFirstElement
  - C05 `test_ble_get_boiler_details` (tests/test_bluetooth_client.py:361) → BluetoothRequestTests.testGetBoilersDecodesList
  - C06 `test_ble_get_smart_standby_details` (tests/test_bluetooth_client.py:388) → BluetoothRequestTests.testGetSmartStandbyAcceptsStringBool
  - C07 `test_ble_get_tank_status` (tests/test_bluetooth_client.py:406) → BluetoothRequestTests.testGetTankStatusStringTrue
  - C08 `test_get_machine_mode` (tests/test_bluetooth_client.py:420) → BluetoothRequestTests.testGetMachineModeBrewing
  - C42 `test_read_response_is_nul_terminated` (tests/test_bluetooth_client.py:1223) → BluetoothRequestTests.testReadResponseCutAtFirstNul
  - C43–C46 (4 cases) `test_get_plumbed_in` (tests/test_bluetooth_client.py:1238) → BluetoothRequestTests.testGetPlumbedIn
  - BluetoothRequestTests.testMalformedReadsThrowDecodingAndKeepLink (Angstrom-only: G-CODEC-5)
  - BluetoothRequestTests.testDerivedCommandFramesAtClientLevel (BT-REQ-002/005/006)
  - BluetoothRequestTests.testNonFiniteTemperatureWritesNothing
  - BluetoothRequestTests.testNonSuccessStatusReturned
  - BluetoothRequestTests.testSmartStandbyStringFalse (Angstrom-only: D5)
  - BluetoothDiagnosticsTests.testAuthWriteIsSecretOthersNot
  - BluetoothDiagnosticsTests.testFramesVerbatimAndDirectional
  - BluetoothDiagnosticsTests.testNotificationTappedBeforeReplayDrop
  - BluetoothDiagnosticsTests.testLifecycleMarkerOrder
  - BluetoothDiagnosticsTests.testNoBufferingWithoutListeners
  - BluetoothDiagnosticsTests.testTwoListenersBothReceive
  - BluetoothDiagnosticsTests.testRawReadBeforeNulTruncation
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothRequestTests|BluetoothDiagnosticsTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  ```
- **Task (brief body):** Port the upstream request tests assigned below into BluetoothRequestTests.swift. Assert the exact bytes written (FakeBluetoothLink.recordedOps), the characteristic used, and the decoded values (SPEC §9.3.1/§9.3.2 vectors). Also write the gap tests: G-CODEC-5 (malformed reads throw .decoding and do NOT drop the link); the derived frames BT-REQ-002/005/006 at client level; a non-finite temperature rejected with no write; a non-success status returned not thrown; the smartStandBy "enabled":"false" → false (D5). BluetoothDiagnosticsTests covers rawFrames(): the auth write has isSecret == true and every other frame false; write/read frames are verbatim and directional; a shot-counter notification is tapped BEFORE the replay drop ([replay dropped] marker follows); the lifecycle markers appear in order; no frames are buffered for a listener that subscribes later; two listeners both receive frames; rawRead returns bytes before NUL truncation. You own test files only; use BLOCKED-BY against BT-W2-01/BT-W1-09/BT-W1-02/BT-W1-03 for defects.

#### BT-W3-03 — Parity suite: shot-counter lifecycle (start, stop, subscribe, rediscovery)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 3 | implement | M | BT-W2-01, BT-W2-02, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Tests/AngstromTests/Bluetooth/ShotCounterLifecycleTests.swift`
- **SPEC:** §4.4; §4.5; §4.9; §9.4 (T3 lifecycle rows); §12 D4; PLAN §3.5
- **Upstream:** `$UPSTREAM/tests/test_bluetooth_client.py:652-742`; `$UPSTREAM/tests/test_bluetooth_client.py:1108-1195`; `$UPSTREAM/tests/test_bluetooth_client.py:1287-1302`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:327-439`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:712-747`
- **Deliverables:**
  - ShotCounterLifecycleTests porting the assigned upstream tests + gap tests.
- **Tests:**
  - C20 `test_start_shot_counter_characteristic_missing` (tests/test_bluetooth_client.py:652) → ShotCounterLifecycleTests.testMissingCharacteristicReturnsFalseAfterOneRediscovery
  - C21 `test_start_shot_counter_rediscovers_services` (tests/test_bluetooth_client.py:677) → ShotCounterLifecycleTests.testStaleServiceCacheRediscoversCharacteristic
  - C22 `test_start_shot_counter` (tests/test_bluetooth_client.py:699) → ShotCounterLifecycleTests.testStartSubscribesAndDisconnectUnsubscribes
  - C23 `test_shot_counter_suppresses_auto_disconnect` (tests/test_bluetooth_client.py:719) → ShotCounterLifecycleTests.testShotCounterSuppressesIdleDisconnect
  - C36 (restated, D4) `test_start_shot_counter_twice` (tests/test_bluetooth_client.py:1108) → ShotCounterLifecycleTests.testStartTwiceSubscribesOnce
  - C37 [stop_shot_counter], C38 [disconnect] (restated, D4) `test_stop_shot_counter_reentrant` (tests/test_bluetooth_client.py:1126) → ShotCounterLifecycleTests.testStopFromEventConsumerIsNoOp
  - C40 `test_stop_shot_counter_notifies_connection_callback` (tests/test_bluetooth_client.py:1183) → ShotCounterLifecycleTests.testDisconnectReportsUnsubscribed
  - C48 `test_command_error_keeps_shot_counter_connection` (tests/test_bluetooth_client.py:1287) → ShotCounterLifecycleTests.testCommandErrorKeepsShotCounterLink
  - ShotCounterLifecycleTests.testMissingCharacteristicDropsEvenWithShotCounter (Angstrom-only: G-CONN-6)
  - ShotCounterLifecycleTests.testStopWithoutCounterOnlyRearmsIdle (Angstrom-only: G-SC-1)
  - ShotCounterLifecycleTests.testNotificationAfterStopDropped (Angstrom-only: G-SC-4)
  - ShotCounterLifecycleTests.testSecondStartKeepsTrackerAndReplayFlag (Angstrom-only: G-SC-5)
  - ShotCounterLifecycleTests.testStartWhileReconnectPendingSubscribesOnce (Angstrom-only: G-SC-6)
  - ShotCounterLifecycleTests.testStartFailureThrowsAndDisables (Angstrom-only: G-RC-4)
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'ShotCounterLifecycleTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  ```
- **Task (brief body):** Port the shot-counter lifecycle tests assigned below into ShotCounterLifecycleTests.swift. Restated tests follow SPEC §9.4: C36 = one subscribe, no second .subscribed, returns true; C37/C38 = a consumer of shotCounterEvents() that calls stopShotCounter() (case 1) or disconnect() (case 2) on .unsubscribed causes exactly one unsubscribe, and the events are [.subscribed, .unsubscribed]. C20 asserts connects with refresh [false, true], one extra disconnect, still connected, idle re-armed. Also write the gap tests below. You own the test file only; use BLOCKED-BY against BT-W2-02/BT-W2-01/BT-W1-09 for defects.

#### BT-W3-04 — Parity suite: shot-counter notifications and the recorded Linea Micra session

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 3 | implement | L | BT-W1-04, BT-W2-02, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Tests/AngstromTests/Bluetooth/ShotCounterNotificationTests.swift`, `Tests/AngstromTests/Bluetooth/ShotCounterRecordedSessionTests.swift`
- **SPEC:** §3.8; §4.10; §4.11; §4.12; §9.3.3; §9.3.4; §9.4 (T3 notification rows); §14.2 U22; PLAN §3.5
- **Upstream:** `$UPSTREAM/tests/test_bluetooth_client.py:745-1020`; `$UPSTREAM/tests/fixtures/machine/shot_counter_2026-10-05.txt`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:441-465`; `$UPSTREAM/src/pylamarzocco/models/_bluetooth.py:90-213`
- **Deliverables:**
  - ShotCounterNotificationTests and ShotCounterRecordedSessionTests through the real client.
- **Tests:**
  - C24 [sequence], C25 [malformed] `test_shot_counter_state_machine` (tests/test_bluetooth_client.py:784) → ShotCounterNotificationTests.testSequence, ShotCounterNotificationTests.testMalformedPayloadsAreDropped
  - C26 [during_subscribe], C27 [after_subscribe] `test_shot_counter_discards_replay` (tests/test_bluetooth_client.py:822) → ShotCounterNotificationTests.testReplayDuringSubscribeIsDropped, ShotCounterNotificationTests.testReplayAfterSubscribeIsDropped
  - C28 `test_shot_counter_telemetry` (tests/test_bluetooth_client.py:848) → ShotCounterNotificationTests.testTelemetryRoutingAndParsing
  - C29 `test_shot_counter_recorded_sessions` (tests/test_bluetooth_client.py:912) → ShotCounterRecordedSessionTests.testRecordedMorning20261005
  - C30 `test_shot_counter_brewing_start_time` (tests/test_bluetooth_client.py:980) → ShotCounterNotificationTests.testBrewingStartTimeIsEarliestEstimate
  - C31 (restated, D4) `test_shot_counter_callback_exception_is_caught` (tests/test_bluetooth_client.py:1009) → ShotCounterNotificationTests.testCancelledConsumerDoesNotAffectClient
  - ShotCounterNotificationTests.testTrackerResetOnResubscribe (Angstrom-only: G-SC-3)
  - ShotCounterNotificationTests.testEvFalseStringStopsAtClientLevel (Angstrom-only: D5, BT-NTF-COERCE-001)
  - ShotCounterNotificationTests.testStatisticsObjectDropped (BT-NTF-COERCE-002)
  - ShotCounterNotificationTests.testStatisticsNullIsUnset (BT-NTF-COERCE-003, BT-NTF-COERCE-004)
  - ShotCounterNotificationTests.testLateTickReentersBrewing (Angstrom-only: BT-NTF-LATE-001, Q9)
  - ShotCounterNotificationTests.testFragmentsAccumulate (Angstrom-only: BT-NTF-FRAG-001)
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'ShotCounterNotificationTests|ShotCounterRecordedSessionTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  ```
- **Risks:**
  - SPEC U22: the per-line golden was hand-traced. Escalate rather than edit.
- **Task (brief body):** Port the notification tests assigned below into ShotCounterNotificationTests.swift, driving notifications through FakeBluetoothLink.notify(_:_:at:) on a started client and asserting shotCounterEvents(). Use the exact vectors of SPEC §9.3.3 (BluetoothTestVectors.started/tick). The fake link's default replayOnSubscribe is tick("3.34") (upstream's fake, TBC:176), which consumes the client's replay flag, so the first notify(…) after start is processed exactly as upstream's tests expect; set `replayOnSubscribe = []` only where the upstream test sets `replay = None`. C31 is restated: a consumer that stops iterating does not affect other listeners or the client. Also add G-SC-3 and the client-level vectors BT-NTF-COERCE-001…004, LATE-001 and FRAG-001. ShotCounterRecordedSessionTests.testRecordedMorning20261005 replays REC per §9.3.4. For each session: startShotCounter() with the session's replay as replayOnSubscribe, each line delivered at its UTC timestamp, then stopShotCounter(). Assert upstream assertions 1–6 exactly, and the finer golden table with ≤ 1 ms tolerance. If the golden disagrees while assertions 1–6 hold, do NOT change expected values. Mark only the golden sub-assertion with BLOCKED-BY "SPEC U22" and report it for a human decision. You own test files only; use BLOCKED-BY against BT-W2-02/BT-W1-04 for defects.

#### BT-W3-05 — Parity suite: shot-counter reconnect loop

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 3 | implement | M | BT-W2-02, BT-W0-03 |

- **Owns, create:** —
- **Owns, modify:** `Tests/AngstromTests/Bluetooth/ShotCounterReconnectTests.swift`
- **SPEC:** §4.13; §9.2; §9.3.3 (RESET-001); §9.4 (T4 rows); §12 D14 D15; PLAN §3.5
- **Upstream:** `$UPSTREAM/tests/test_bluetooth_client.py:1022-1105`; `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:475-520`; `$UPSTREAM/README.md:269`
- **Deliverables:**
  - ShotCounterReconnectTests porting C32–C35 + reconnect gap/divergence tests with asserted backoff values.
- **Tests:**
  - C32 `test_shot_counter_reconnects_after_disconnect` (tests/test_bluetooth_client.py:1022) → ShotCounterReconnectTests.testReconnectsAndResetsTrackerAfterLinkLoss
  - C33 (restated counts) `test_shot_counter_reconnect_retries_failed_connections` (tests/test_bluetooth_client.py:1053) → ShotCounterReconnectTests.testReconnectRetriesThroughConnectErrors
  - C34 `test_shot_counter_gives_up_after_auth_failures` (tests/test_bluetooth_client.py:1072) → ShotCounterReconnectTests.testGivesUpAfterThreeAuthFailures
  - C35 `test_shot_counter_no_reconnect_after_disconnect` (tests/test_bluetooth_client.py:1094) → ShotCounterReconnectTests.testUserDisconnectDoesNotReconnect
  - ShotCounterReconnectTests.testBackoffSequence (Angstrom-only: G-RC-1)
  - ShotCounterReconnectTests.testAuthFailuresAreCumulative (Angstrom-only: G-RC-2, D15)
  - ShotCounterReconnectTests.testCharacteristicGoneGivesUp (Angstrom-only: G-RC-3)
  - ShotCounterReconnectTests.testIdleOrErrorDropWhileEnabledReconnects (Angstrom-only: G-RC-5)
  - ShotCounterReconnectTests.testFirstAttemptWaitsInitialDelay (Angstrom-only: G-SC-7)
  - ShotCounterReconnectTests.testPoweredOnCutsBackoffShort (Angstrom-only: D14; no polling: after `await sleeper.waitForPending(.reconnectBackoff, count: 1)` the §4.13 availability stream exists — assert central.availabilitySubscriberCount >= 1, then setAvailability)
  - ShotCounterReconnectTests.testGaveUpCarriesLastError (Angstrom-only: D15)
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'ShotCounterReconnectTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  swift test --sanitize=thread --filter 'ShotCounterReconnectTests'
  ```
- **Risks:**
  - The C33 connect count was flagged for a second look in the SPEC author's report.
- **Task (brief body):** Port the reconnect tests assigned below into ShotCounterReconnectTests.swift. Use ManualBluetoothSleeper.requested(.reconnectBackoff) to assert backoff values (closing G-RC-1). C33 is restated per SPEC §9.4: enqueue 3 × .disconnected(code: 7), then 3 × .timedOut, then success; expect connectCount == 8, events [.subscribed, .unsubscribed, .subscribed], and requested(.reconnectBackoff) == [1 s, 2 s, 4 s]. Derive the expected count yourself from SPEC §4.2 (3 attempts per ensureConnected) and §4.13. If your derivation disagrees with 8, report SPEC-DEFECT (PLAN §1.7) instead of changing the number. C34: connectCount == 4, requested(.reconnectBackoff) == [1 s, 1 s, 1 s], authenticationFailed, not active, not connected, hasBackgroundWorkForTesting == false, plus .gaveUp(.bluetoothAuthenticationFailed). C32 includes BT-NTF-RESET-001. Also write G-RC-1/2/3/5, G-SC-7, D14 and D15. You own the test file only; use BLOCKED-BY against BT-W2-02/BT-W1-09.

#### BT-W3-06 — AngstromUI: Bluetooth connection observation and device-state properties

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 3 | implement | S | BT-W1-11, BT-W2-01, BT-W0-04 |

- **Owns, create:** —
- **Owns, modify:** `Sources/AngstromUI/LaMarzoccoMachine+BluetoothConnection.swift`, `Tests/AngstromUITests/Bluetooth/BluetoothDeviceStateTests.swift`
- **SPEC:** §2.5; §4.15; §6.16 (+BluetoothConnection); §12 D11; PLAN §3.3
- **Upstream:** `$UPSTREAM/src/pylamarzocco/devices/_thing.py:99-126`; `$UPSTREAM/tests/test_thing.py:36-64`; `$UPSTREAM/tests/test_machine.py:765-781`
- **Deliverables:**
  - startObservingBluetoothConnection(), bluetoothConnectionEvents(), isBluetoothConnected behaviour.
- **Tests:**
  - M15 (restated, D4; moved R6) `test_register_bluetooth_connection_callback` (tests/test_machine.py:765) → BluetoothDeviceStateTests.testBluetoothConnectionEventsForwardOrFinish
  - T01 `test_connection_properties_without_clients` (tests/test_thing.py:36) → BluetoothDeviceStateTests.testPropertiesWithoutClients
  - T02 `test_connection_properties_with_clients` (tests/test_thing.py:48) → BluetoothDeviceStateTests.testPropertiesWithClients
  - BluetoothDeviceStateTests.testIsBluetoothConnectedFollowsRealClient (Angstrom-only: G-DEV-9, D11)
  - BluetoothDeviceStateTests.testObservationStopsWhenMachineDeallocates
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothDeviceStateTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  ```
- **Task (brief body):** Implement Sources/AngstromUI/LaMarzoccoMachine+BluetoothConnection.swift. startObservingBluetoothConnection() (called from init when bluetooth != nil) starts bluetoothConnectionTask: a MainActor Task with [weak self] that iterates `await bluetooth.connectionEvents()` and sets isBluetoothConnected (true on .connected, false on .disconnected). bluetoothConnectionEvents() returns the client's stream, or an already-finished stream without a client (upstream returns a no-op unregister, _thing.py:116-126). Tests use BluetoothMachineHarness. Trigger a connection with a client read (e.g. `try await harness.bluetooth!.machineMode()`), never through UI commands (BT-W3-07 builds those in parallel). Port T01/T02/M15 and add G-DEV-9.

#### BT-W3-07 — AngstromUI: BLE-first commands with cloud fallback and their side effects

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 3 | implement | L | BT-W1-11, BT-W2-01, BT-W0-04 |

- **Owns, create:** —
- **Owns, modify:** `Sources/AngstromUI/LaMarzoccoMachine+BluetoothCommands.swift`, `Tests/AngstromUITests/Bluetooth/BluetoothFallbackTests.swift`, `Tests/AngstromUITests/Bluetooth/BluetoothCommandSideEffectTests.swift`
- **SPEC:** §1.4; §4.16; §4.20; §6.16 (+BluetoothCommands); §9.3.6 (SNAP-003…005); §9.3.7; §12 D10 D18; PLAN §3.3
- **Upstream:** `$UPSTREAM/src/pylamarzocco/devices/_machine.py:494-509`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:764-892`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:983-1049`; `$UPSTREAM/tests/test_machine.py:134-237`; `$UPSTREAM/tests/test_machine.py:486-497`; `$UPSTREAM/tests/test_machine.py:1089-1160`; `$UPSTREAM/tests/test_bluetooth_dashboard.py:396-560`; `$UPSTREAM/tests/__snapshots__/test_bluetooth_dashboard.ambr:110-145`; `$UPSTREAM/tests/conftest.py:183-195`
- **Deliverables:**
  - bluetoothFirst(bluetooth:cloud:) per §4.16, BluetoothFallbackTests, BluetoothCommandSideEffectTests.
- **Tests:**
  - D07 `test_set_power_updates_dashboard` (tests/test_bluetooth_dashboard.py:396) → BluetoothCommandSideEffectTests.testSetPowerUpdatesModeOnly
  - D08 `test_set_power_off_updates_dashboard` (tests/test_bluetooth_dashboard.py:414) → BluetoothCommandSideEffectTests.testSetPowerOffUpdatesMode
  - D09 `test_set_steam_updates_dashboard` (tests/test_bluetooth_dashboard.py:436) → BluetoothCommandSideEffectTests.testSetSteamUpdatesEnabled
  - D10 `test_set_coffee_temp_updates_dashboard` (tests/test_bluetooth_dashboard.py:452) → BluetoothCommandSideEffectTests.testSetCoffeeTempUpdatesWidget
  - D11 `test_set_steam_level_updates_dashboard` (tests/test_bluetooth_dashboard.py:470) → BluetoothCommandSideEffectTests.testSetSteamLevelUpdatesWidget
  - D12 `test_set_steam_temp_updates_dashboard` (tests/test_bluetooth_dashboard.py:488) → BluetoothCommandSideEffectTests.testSetSteamTempUpdatesWidget
  - D13 (restated, D18) `test_failed_command_does_not_update_dashboard` (tests/test_bluetooth_dashboard.py:506) → BluetoothCommandSideEffectTests.testNonSuccessStatusWithoutCloudThrowsCommandFailed
  - D14 (restated, D18) `test_bluetooth_exception_does_not_update_dashboard` (tests/test_bluetooth_dashboard.py:533) → BluetoothCommandSideEffectTests.testBluetoothErrorWithoutCloudRethrows
  - M01–M12 (6 commands × {bluetooth, cloud}) `test_bluetooth_command_with_cloud_fallback` (tests/test_machine.py:206) → BluetoothFallbackTests.testCommandUsesBluetoothThenCloud
  - M13 (restated, D18) `test_failing_command` (tests/test_machine.py:486) → BluetoothFallbackTests.testBothTransportsFailThrowsCloudError
  - M29 `test_set_power_updates_group_status` (tests/test_machine.py:1089) → BluetoothCommandSideEffectTests.testSetPowerUpdatesGroupStatus
  - M30–M31 (2 cases) `test_set_smart_standby_auto_standby` (tests/test_machine.py:1137) → BluetoothFallbackTests.testSmartStandbyUsesCloudAutoStandbyWhenSupported
  - M32 (restated, D18) `test_bluetooth_failure_without_cloud` (tests/test_machine.py:1155) → BluetoothFallbackTests.testBluetoothFailureWithoutCloudRethrows
  - BluetoothFallbackTests.testNonSuccessStatusFallsBackToCloud (Angstrom-only: G-DEV-1)
  - BluetoothFallbackTests.testTimeoutAndDecodeErrorsDoNotFallBack (Angstrom-only: G-DEV-2, D19)
  - BluetoothFallbackTests.testAutoStandbyMinuteFormatting (Angstrom-only: G-DEV-8)
  - BluetoothFallbackTests.testUnavailableBluetoothFallsBack (Angstrom-only: D10)
  - BluetoothFallbackTests.testNeitherClientThrowsCloudOnly (Angstrom-only: D18)
  - BluetoothFallbackTests.testGatingRunsBeforeAnyTransport
  - BluetoothCommandSideEffectTests.testSetSteamUpdatesBothSteamWidgets (Angstrom-only: G-DEV-11)
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothFallbackTests|BluetoothCommandSideEffectTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  ```
- **Task (brief body):** Implement the Bluetooth branch of bluetoothFirst(bluetooth:cloud:) in Sources/AngstromUI/LaMarzoccoMachine+BluetoothCommands.swift, exactly per the SPEC §4.16 pseudocode. When a BLE client exists, ALWAYS try it first (no isBluetoothConnected check). On isSuccess, return CommandResponse(id: status.id, status: .success, errorCode: nil). On a non-success status, fall through to the cloud, or without a cloud client throw .commandFailed(status: status.status, errorCode: status.message) (D18). Catch only errors whose isBluetoothConnectionFailure is true: rethrow when there is no cloud client, else log the upstream message and fall back. Every other error (.bluetoothTimedOut, .decoding, CancellationError) propagates with NO cloud call. With neither client, throw .cloudOnlyFunctionality. The six call sites and their gating/optimistic updates already exist (BT-W1-11). Do not edit LaMarzoccoMachine.swift; if a call site is wrong, BLOCKED-BY BT-W1-11. Tests use BluetoothMachineHarness with its failure modes: assert the BLE frames (BT-FALLBACK-001…006 bytes via bluetoothWrites(to:)), the cloud command names/bodies (cloudCommandCount/cloudCommandBody), and the optimistic widget values (SNAP-003…005). M01–M12 is one parametrised test over six commands × {BLE ok → no cloud call; BLE .bluetoothConnectionFailed → exactly one cloud call}.

#### BT-W3-08 — AngstromUI: dashboard and model from Bluetooth

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 3 | implement | M | BT-W1-05, BT-W1-11, BT-W2-01, BT-W0-04 |

- **Owns, create:** —
- **Owns, modify:** `Sources/AngstromUI/LaMarzoccoMachine+BluetoothDashboard.swift`, `Tests/AngstromUITests/Bluetooth/BluetoothDashboardRefreshTests.swift`
- **SPEC:** §4.17; §4.18; §6.16 (+BluetoothDashboard); §9.3.6; §12 D17; §14.1 Q11; PLAN §3.3
- **Upstream:** `$UPSTREAM/src/pylamarzocco/devices/_machine.py:325-492`; `$UPSTREAM/tests/test_bluetooth_dashboard.py:110-390`; `$UPSTREAM/tests/test_bluetooth_dashboard.py:560-689`; `$UPSTREAM/tests/test_machine.py:1049-1088`; `$UPSTREAM/tests/__snapshots__/test_bluetooth_dashboard.ambr:2-108`
- **Deliverables:**
  - refreshDashboardFromBluetooth() and refreshModelFromBluetooth() + BluetoothDashboardRefreshTests.
- **Tests:**
  - D01 `test_get_dashboard_from_bluetooth` (tests/test_bluetooth_dashboard.py:110) → BluetoothDashboardRefreshTests.testRefreshMicraFromBluetooth
  - D02 `test_get_dashboard_no_bluetooth` (tests/test_bluetooth_dashboard.py:183) → BluetoothDashboardRefreshTests.testRefreshWithoutClientThrows
  - D03 `test_get_model_info_from_bluetooth` (tests/test_bluetooth_dashboard.py:189) → BluetoothDashboardRefreshTests.testModelInfoFromCapabilities
  - D04 `test_get_dashboard_initializes_missing_widgets` (tests/test_bluetooth_dashboard.py:213) → BluetoothDashboardRefreshTests.testRefreshCreatesMissingWidgetsMiniR
  - D05 `test_get_dashboard_without_steam_level_support` (tests/test_bluetooth_dashboard.py:269) → BluetoothDashboardRefreshTests.testRefreshGS3UsesSteamTemperature
  - D06 `test_get_dashboard_mini_original_temperature_only` (tests/test_bluetooth_dashboard.py:334) → BluetoothDashboardRefreshTests.testRefreshOriginalMiniUsesSteamTemperature
  - D15–D19 (5 cases) `test_get_dashboard_from_bluetooth_statuses` (tests/test_bluetooth_dashboard.py:606) → BluetoothDashboardRefreshTests.testStatusDerivation
  - D26 `test_get_dashboard_from_bluetooth_plumb_in_unsupported` (tests/test_bluetooth_dashboard.py:674) → BluetoothDashboardRefreshTests.testPlumbInUnsupportedFallsBackToTank
  - M26 `test_get_model_info_from_bluetooth_errors` (tests/test_machine.py:1049) → BluetoothDashboardRefreshTests.testModelInfoErrors
  - M27 (restated) `test_get_model_info_from_bluetooth_unknown_model` (tests/test_machine.py:1063) → BluetoothDashboardRefreshTests.testUnknownFamilyThrowsAndKeepsModel
  - M28 `test_get_dashboard_from_bluetooth_error` (tests/test_machine.py:1079) → BluetoothDashboardRefreshTests.testRefreshErrorPropagatesWithoutMutation
  - BluetoothDashboardRefreshTests.testUnknownModelReadsCapabilitiesFirst (Angstrom-only: D17)
  - BluetoothDashboardRefreshTests.testKnownModelSkipsCapabilities
  - BluetoothDashboardRefreshTests.testReadOrder
  - BluetoothDashboardRefreshTests.testDoesNotStampLastUpdateAt (Angstrom-only: Q11)
  - BluetoothDashboardRefreshTests.testRefreshReappliesActiveOverlay
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothDashboardRefreshTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  ```
- **Task (brief body):** Implement Sources/AngstromUI/LaMarzoccoMachine+BluetoothDashboard.swift per SPEC §4.17 and §4.18. refreshDashboardFromBluetooth: without a BLE client throw `.bluetoothConnectionFailed("Bluetooth client not initialized")`; if model is nil or .unknown, run refreshModelFromBluetooth() first (D17), otherwise read no capabilities; read machineMode, isPlumbedIn (.decoding → false; other errors propagate), tankStatus, boilers, in that order; any error propagates with NO mutation; then setBaseDashboard((baseDashboard ?? Dashboard(machine: Machine(serialNumber:model:), widgets: [])).applyingBluetoothState(state, model:)). Do not stamp lastUpdateAt (Q11); do not touch settings/schedule/connected. Return the rendered dashboard. refreshModelFromBluetooth: read machineCapabilities and set only machine.model on the base (rebuild Dashboard(machine:widgets:)); errors propagate; return the capabilities. Tests use BluetoothMachineHarness with settingResponses scripted with the exact upstream payloads. To cover the interaction with an active shot-counter overlay without depending on BT-W3-09 (built in parallel), set `machine.bluetoothBrewingUpdate` directly and call `machine.renderDashboard()`, then refresh and assert the overlay is re-applied over the new base.

#### BT-W3-09 — AngstromUI: shot counter, overlay, telemetry merge and 60 s expiry

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 3 | implement | L | BT-W1-05, BT-W1-11, BT-W2-02, BT-W0-04 |

- **Owns, create:** —
- **Owns, modify:** `Sources/AngstromUI/LaMarzoccoMachine+ShotCounter.swift`, `Tests/AngstromUITests/Bluetooth/ShotCounterOverlayTests.swift`
- **SPEC:** §4.19; §5.6; §6.16 (+ShotCounter); §9.3.8; §12 D4 D12 D13 D15; PLAN §3.3
- **Upstream:** `$UPSTREAM/src/pylamarzocco/devices/_machine.py:88`; `$UPSTREAM/src/pylamarzocco/devices/_machine.py:128-323`; `$UPSTREAM/tests/test_machine.py:99-131`; `$UPSTREAM/tests/test_machine.py:745-1047`; `$UPSTREAM/tests/test_bluetooth_client.py:1156-1180`
- **Deliverables:**
  - startShotCounter/stopShotCounter/bluetoothEvents/handleShotCounterEvent/clearBluetoothBrewingState/armBluetoothBrewingExpiry + ShotCounterOverlayTests.
- **Tests:**
  - C39 (restated, D4) `test_machine_stop_from_update_callback` (tests/test_bluetooth_client.py:1156) → ShotCounterOverlayTests.testStopFromEventConsumerDoesNotRecurse
  - M14 `test_connect_bluetooth_shot_counter` (tests/test_machine.py:745) → ShotCounterOverlayTests.testStartIgnoresCloudSupportFlag
  - M16 `test_shot_counter_overrides_machine_status` (tests/test_machine.py:784) → ShotCounterOverlayTests.testOverrideLifecycle
  - M17 (restated, D13) `test_shot_counter_falls_back_to_websocket_callback` (tests/test_machine.py:835) → ShotCounterOverlayTests.testBrewingUpdateRendersObservableDashboard
  - M18 `test_disconnect_bluetooth_shot_counter` (tests/test_machine.py:853) → ShotCounterOverlayTests.testStopRestoresSilently
  - M19 `test_shot_counter_state_expires` (tests/test_machine.py:882) → ShotCounterOverlayTests.testStaleStateExpiresAfter60s
  - M20 `test_bluetooth_refresh_after_shot_replaces_cloud_status` (tests/test_machine.py:917) → ShotCounterOverlayTests.testBluetoothRefreshBecomesBaseline
  - M21 `test_bluetooth_refresh_while_brewing_keeps_cloud_start_time` (tests/test_machine.py:940) → ShotCounterOverlayTests.testBluetoothRefreshKeepsCloudStartTime
  - M22 `test_bluetooth_telemetry` (tests/test_machine.py:961) → ShotCounterOverlayTests.testTelemetryMergeAndModeApply
  - M23 `test_bluetooth_machine_mode_during_shot` (tests/test_machine.py:995) → ShotCounterOverlayTests.testModeDuringShotAppliedAfterShot
  - M24 (restated, D13) `test_bluetooth_machine_mode_falls_back_to_websocket_callback` (tests/test_machine.py:1014) → ShotCounterOverlayTests.testTemperatureTelemetryDoesNotChangeDashboard
  - M25 `test_bluetooth_shot_counter_active` (tests/test_machine.py:1036) → ShotCounterOverlayTests.testShotCounterActiveMirrorsClient
  - ShotCounterOverlayTests.testRestRefreshReappliesOverlay (Angstrom-only: G-DEV-5)
  - ShotCounterOverlayTests.testResubscribeKeepsOverlayUntilExpiry (Angstrom-only: G-DEV-6)
  - ShotCounterOverlayTests.testTelemetryModeUpdatesGroupWidget (Angstrom-only: G-DEV-7)
  - ShotCounterOverlayTests.testStateMutatedBeforeEventEmitted (Angstrom-only: G-DEV-12)
  - ShotCounterOverlayTests.testGaveUpSurfacesShotCounterStopped (Angstrom-only: D15)
  - ShotCounterOverlayTests.testSnapshotNeverPersistsOverlay (Angstrom-only: D12)
  - ShotCounterOverlayTests.testWidgetlessPushDuringOverlayDoesNotLeakIntoBase (Angstrom-only: SPEC §4.19 read rule; active .brewing overlay, a widget-less push, then expiry → rendered and snapshot status equal the pre-shot base status)
  - ShotCounterOverlayTests.testLastShotTimeNeverReset
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'ShotCounterOverlayTests'
  swift test
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  swift test --sanitize=thread --filter 'ShotCounterOverlayTests'
  ```
- **Task (brief body):** Implement Sources/AngstromUI/LaMarzoccoMachine+ShotCounter.swift per SPEC §4.19. startShotCounter: false without a BLE client; subscribe to bluetooth.shotCounterEvents() BEFORE starting; consume it in a MainActor Task ([weak self]) calling handleShotCounterEvent; on a throw or false, cancel the listener and rethrow or return false; on true set isShotCounterActive. Do not gate on shotCounterSupported or the model. stopShotCounter: cancel the listener FIRST, await bluetooth?.stopShotCounter(), reset telemetry, clearBluetoothBrewingState(notify: false), isShotCounterActive = false; keep lastShotTime. handleShotCounterEvent follows the §4.19 event table exactly. Mutate state BEFORE emitting on bluetoothEvents() (G-DEV-12). Re-arm the expiry on EVERY brewing update and never on telemetry. Telemetry mode → updateBaseDashboard { $0.settingMachineMode(m).settingMachineState(MachineState(bluetoothMode: m)) }. .gaveUp → isShotCounterActive = false, lastError, .shotCounterStopped. Expiry: a MainActor task sleeping bluetoothBrewingStateTimeout through brewingExpirySleep, then clearBluetoothBrewingState(notify: true). bluetoothEvents() is a multiplexed stream. Tests drive the expiry with setBluetoothBrewingExpiryForTesting and a gate-controlled sleep, and drive cloud pushes through the existing MockWebSocket. Use the BT-OVL-001 and D7–D13 vectors of §9.3.8 verbatim. Simulate the BLE refresh in M20/M21 with `machine.updateBaseDashboard { $0.applyingBluetoothState(state, model: …) }` (exactly §4.17 step 6), because refreshDashboardFromBluetooth is built in parallel by BT-W3-08. C39 is restated: a bluetoothEvents() consumer calling stopShotCounter() does not recurse or deadlock.

#### BT-W3-10 — Verify: angcli ble commands, redaction and TCC packaging

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 3 | verify | S | BT-W1-12, BT-W2-03, BT-W2-04, BT-W2-05, BT-W2-06 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §8.4; §10; PLAN §3.2
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_cloud.py:84-92`
- **Deliverables:**
  - §5.2 JSON report: §10 conformance table (every subcommand, option, output field, error text) and a redaction audit.
- **Acceptance:**

  ```sh
  swift build --package-path cli
  swift test --package-path cli
  bash -c 'set -o pipefail; mkdir -p cli/.build; rm -rf cli/.build/g5; NO_COLOR=1 swift build --package-path cli --build-tests --scratch-path cli/.build/g5 2>&1 | tee cli/.build/bt-warnings.log && ! grep -E "/cli/(Sources/angcli/Ble/|Sources/angcli/Output\.swift|Sources/angcli/AngCLI\.swift|Tests/angcliTests/Ble)[^:]*:[0-9]+:[0-9]+: warning:" cli/.build/bt-warnings.log'
  plutil -lint cli/Support/Info.plist
  bash -c '! grep -q unsafeFlags Package.swift'
  ```
- **Task (brief body):** Review every file under cli/ changed by BT-W1-12 and BT-W2-03…06 against SPEC §8.4 and §10 and PLAN §3.2. Check: the command tree and options; peripheral and token selection precedence; that `ble cmd` refuses without --confirm in validate(); the exact error texts; the JSON line shapes; that EVERY raw frame passes through Redact.bluetoothFrame, which redacts isSecret frames AND writes to 0d0b… AND reads of 0c0b… regardless of isSecret; that `ble token` masks unless --show-secret and prints secrets only to stdout; that nothing persists the token or the peripheral id; that unsafeFlags appears only in cli/Package.swift; that the Info.plist keys match §8.4; and that SIGINT teardown mirrors Listen.swift.

### Wave 4 — Independent area verification (parallel)

#### BT-W4-01 — Verify: full LaMarzoccoBluetoothClient parity with _bluetooth.py (line by line)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 4 | verify | L | BT-W1-10, BT-W3-01, BT-W3-02, BT-W3-03, BT-W3-04, BT-W3-05 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §2.1; §2.2; §3; §4.1–§4.14; §6.11; §12
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:1-747`; `$UPSTREAM/src/pylamarzocco/models/_bluetooth.py:1-213`; `$UPSTREAM/tests/test_bluetooth_client.py:1-1435`
- **Deliverables:**
  - §5.2 JSON report with a function-by-function map of _bluetooth.py (every def and branch) → Swift (file:line) → test name.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'Bluetooth|ShotCounter'
  ```
- **Task (brief body):** Produce a complete map of $UPSTREAM/src/pylamarzocco/clients/_bluetooth.py: every function, every branch, every log-relevant decision, mapped to the Swift implementation (all four LaMarzoccoBluetoothClient*.swift files) and to the test that pins it. Every branch must be either matched, or a listed SPEC divergence (D1–D22), or a finding. Pay special attention to: the disconnect_on_exception drop rule including the shot-counter exemption; the characteristic resolution drop that ignores that exemption; the replay flag armed before subscribe; tracker reset points; the reconnect loop's sleep-first, cumulative auth counting, delay doubling only for connection errors, and give-up bookkeeping; the edge-triggered connection events; and stop/disconnect emitting .unsubscribed only when subscribed. Also confirm that every upstream test in tests/test_bluetooth_client.py has its Swift counterpart named in PLAN §7.2, asserting the same thing.

#### BT-W4-02 — Verify: device-layer parity with _machine.py/_thing.py (fallback, BLE dashboard, overlay, expiry)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 4 | verify | L | BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §1.4; §2.5; §4.15–§4.20; §6.12; §6.16; §9.3.6–§9.3.8; §12 D12 D13 D15 D17 D18
- **Upstream:** `$UPSTREAM/src/pylamarzocco/devices/_machine.py:1-1092`; `$UPSTREAM/src/pylamarzocco/devices/_thing.py:1-226`; `$UPSTREAM/tests/test_machine.py:1-1195`; `$UPSTREAM/tests/test_bluetooth_dashboard.py:1-689`; `$UPSTREAM/tests/test_thing.py:29-64`
- **Deliverables:**
  - §5.2 JSON report with a method-by-method map of the BT paths of _machine.py/_thing.py → Swift → test.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'AngstromUITests'
  bash -c 'git diff --quiet e1bc403 -- Tests/AngstromUITests/LaMarzoccoMachineTests.swift Tests/AngstromUITests/MockTransport.swift Tests/AngstromUITests/MockWebSocket.swift'
  ```
- **Task (brief body):** Map every Bluetooth path of $UPSTREAM/src/pylamarzocco/devices/_machine.py and _thing.py to Sources/AngstromUI (main file + the four extension files) and Dashboard+Bluetooth.swift, and to the pinning test. Verify the fallback matrix exactly (which errors fall back, which propagate, non-success status behaviour, no-cloud and no-BLE cases with D18), the gating-before-transport order, the read order and the no-mutation-on-error of refreshDashboardFromBluetooth, the model refresh writing only the model, the overlay/expiry/telemetry event table (state before events, expiry re-armed only by brewing updates), stopShotCounter's silent clear, and the base/overlay equivalence (D12) under websocket pushes (including widget-less pushes during an overlay), REST refreshes and BLE refreshes, with every base write reading baseDashboard (SPEC §4.19 read rule). Confirm that cloud-only behaviour is unchanged (§13): the existing LaMarzoccoMachineTests pass unmodified, and dashboard == baseDashboard whenever no overlay is held.

#### BT-W4-03 — Verify: Swift 6 concurrency and data races across client, UI and adapter (TSan + repeat runs)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 4 | verify | M | BT-W1-08, BT-W3-01, BT-W3-02, BT-W3-03, BT-W3-04, BT-W3-05, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §4.1 (I1–I6); §5.4; §5.5; §6.11; §6.16; §6.17
- **Upstream:** `(Swift-specific; upstream ordering reference: $UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:114-136, :233-325)`
- **Deliverables:**
  - §5.2 JSON report: isolation table per type, Task-lifetime audit, TSan output, repeat-run flakiness report; G-DEV-13 design check.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --sanitize=thread --filter 'Bluetooth|ShotCounter|MachineTransportRouting|DashboardBluetooth'
  bash -c 'for i in 1 2 3 4 5; do swift test --filter "Bluetooth|ShotCounter|MachineTransportRouting" || exit 1; done'
  bash -c '! grep -rnE "Task\.immediate|Mutex<|^@preconcurrency import CoreBluetooth" Sources Tests | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(//|///|\*)"'
  ```
- **Task (brief body):** Audit concurrency across LaMarzoccoBluetoothClient (actor, two FIFO gates, unstructured background Tasks, stream continuations), LaMarzoccoMachine's Bluetooth extensions (MainActor Tasks, [weak self], cancellation on stop), the CoreBluetooth adapter (queue confinement) and the AngstromTestSupport fakes (@unchecked Sendable soundness). For each type, state its isolation and why every mutable field is safe. Find leaked Tasks, continuations that may never resume, and streams that never finish. Confirm G-DEV-13 (every client event is handled on the MainActor before widgets or the expiry are touched). Run the Bluetooth suites under the Thread Sanitizer, and run them five times to detect flakiness. Any nondeterministic failure is a major finding, with the fix owner being the test file's owner or the code's owner.

#### BT-W4-04 — Verify: public/package API conformance with SPEC §6 and PLAN §3; source compatibility (§13)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 4 | verify | M | BT-W1-08, BT-W2-03, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §6 (all); §13; PLAN §3
- **Upstream:** `(API shape only; no upstream counterpart)`
- **Deliverables:**
  - §5.2 JSON report: a table of every SPEC §6 / PLAN §3 declaration → present/mismatch (with the symbol-graph or source line), extra non-private declarations, and a §13 compatibility diff against e1bc403.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift package dump-symbol-graph --minimum-access-level internal
  ```
- **Task (brief body):** Mechanically compare the code with every declaration in SPEC §6 and PLAN §3.1–§3.3: name, argument labels, types, access level, async/throws, protocol conformances (Sendable, Hashable, Codable or deliberately NOT Codable for BluetoothAuthToken), and the default argument values. Use `swift package dump-symbol-graph --minimum-access-level internal` and/or direct source reading. Flag any added declaration that is not private/fileprivate and not in the SPEC. Compare the public API of Angstrom and AngstromUI with main @ e1bc403 (check out e1bc403 into a temporary worktree outside the repo). The ONLY breaking change allowed is the five new LaMarzoccoError cases (§13); every existing public signature must be unchanged.

#### BT-W4-05 — Verify: secrecy of the BLE token (library, logs, errors, snapshots, CLI)

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 4 | verify | S | BT-W1-06, BT-W3-02, BT-W3-10 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §2.6; §3.3; §5.7; §6.3; §8.7; §10.4; §12 D2
- **Upstream:** `$UPSTREAM/src/pylamarzocco/clients/_cloud.py:84-92`; `$UPSTREAM/tests/test_cloud_client.py:322`
- **Deliverables:**
  - §5.2 JSON report: every place token bytes flow (sources → sinks) with a verdict.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test --filter 'BluetoothTokenTests|BluetoothDiagnosticsTests|BluetoothClientCoreTests'
  swift test --package-path cli --filter 'BleOutputTests'
  bash -c '! grep -rn "Codable" Sources/Angstrom/Bluetooth/BluetoothAuthToken.swift'
  ```
- **Task (brief body):** Trace every flow of BluetoothAuthToken.rawValue and token bytes in Sources/ and cli/Sources/: authFrame, the auth write, readToken, logHandler messages, error messages, description/debugDescription/Mirror, Codable conformances (MachineSnapshot must never contain it), the raw tap (isSecret on the auth write and the token read), and CLI output (Redact.bluetoothFrame, `ble token --show-secret`). Any interpolation of the raw value into a string that is not the auth frame or the explicit --show-secret output is a blocker. Run the token, diagnostics and CLI redaction tests.

#### BT-W4-06 — Verify: docs accuracy, divergence register and DocC build

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 4 | verify | S | BT-W2-07, BT-W2-08, BT-W1-08, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §11; §12; §13; §14
- **Upstream:** `$UPSTREAM/README.md:78-125`; `$UPSTREAM/README.md:225-269`
- **Deliverables:**
  - §5.2 JSON report: every doc claim checked against the code; D1–D22 present in UPSTREAM.md; DocC build log with no unresolved Bluetooth symbol links.
- **Acceptance:**

  ```sh
  swift package --allow-writing-to-directory .build/bt-docs generate-documentation --target Angstrom --target AngstromUI --target AngstromBluetooth --enable-experimental-combined-documentation --disable-indexing --output-path .build/bt-docs
  bash -c 'grep -q "<!-- upstream-version: v2.5.6 -->" UPSTREAM.md && grep -q "<!-- upstream-sha: 4c639ee -->" UPSTREAM.md'
  ```
- **Task (brief body):** Check every Bluetooth statement in CLAUDE.md, README.md, UPSTREAM.md, the three DocC catalogs (including the AngstromBluetooth landing page), cli/SPEC.md and cli/README.md against the merged code and SPEC. Check that the watermark markers are unchanged, that all of D1–D22 and the UNVERIFIED list are recorded, that the version strings say 2.0.0 (library) and 2.0.0 (angcli), that code samples compile in principle against the real signatures, and that no example shows a real-looking token. Build the combined DocC archive and report any warning that mentions a Bluetooth symbol.

### Wave 5 — Final integration (serial)

#### BT-W5-01 — Final integration: all gates, docs, iOS, release build, coverage and ownership audits

| Wave | Kind | Size | Depends on |
|---|---|---|---|
| 5 | integrate | M | BT-W4-01, BT-W4-02, BT-W4-03, BT-W4-04, BT-W4-05, BT-W4-06 |

- **Owns, create:** —
- **Owns, modify:** —
- **SPEC:** §7; §9.4; §9.5; §13; PLAN §1.5; PLAN §7
- **Upstream:** `$UPSTREAM/tests/test_bluetooth_client.py`; `$UPSTREAM/tests/test_bluetooth_dashboard.py`; `$UPSTREAM/tests/test_machine.py`; `$UPSTREAM/tests/test_thing.py`; `$UPSTREAM/tests/test_models.py`; `$UPSTREAM/tests/test_cloud_client.py`
- **Deliverables:**
  - Release-candidate report (§5.2 schema, plus `gates`, `coverage` and `hardwareHandoff` arrays); no repository change.
- **Acceptance:**

  ```sh
  swift build --build-tests
  swift test
  swift build --package-path cli
  swift test --package-path cli
  bash -c 'set -o pipefail; mkdir -p .build; rm -rf .build/g5; NO_COLOR=1 swift build --build-tests --scratch-path .build/g5 2>&1 | tee .build/bt-warnings.log && ! grep -E "/(Sources/Angstrom/Bluetooth/|Sources/Angstrom/LaMarzoccoCloudClient\+BluetoothToken\.swift|Sources/AngstromBluetooth/|Sources/AngstromUI/|Tests/AngstromTestSupport/|Tests/AngstromTests/Bluetooth/|Tests/AngstromUITests/Bluetooth/)[^:]*:[0-9]+:[0-9]+: warning:" .build/bt-warnings.log'
  bash -c 'set -o pipefail; mkdir -p cli/.build; rm -rf cli/.build/g5; NO_COLOR=1 swift build --package-path cli --build-tests --scratch-path cli/.build/g5 2>&1 | tee cli/.build/bt-warnings.log && ! grep -E "/cli/(Sources/angcli/Ble/|Sources/angcli/Output\.swift|Sources/angcli/AngCLI\.swift|Tests/angcliTests/Ble)[^:]*:[0-9]+:[0-9]+: warning:" cli/.build/bt-warnings.log'
  bash -c '! grep -rn "BLOCKED-BY" Tests cli/Tests'
  bash -c '! grep -rn "unimplemented: BT-" Sources Tests cli/Sources'
  swift package --allow-writing-to-directory .build/bt-docs generate-documentation --target Angstrom --target AngstromUI --target AngstromBluetooth --enable-experimental-combined-documentation --disable-indexing --output-path .build/bt-docs
  xcodebuild -scheme Angstrom-Package -destination 'generic/platform=iOS Simulator' -quiet build
  swift build -c release
  bash -c 'm=0; for t in test_auth_read_back_failure test_auth_read_back_retries_until_confirmed test_authentication_failed_flag test_auto_disconnect_after_idle test_ble_device_callback test_ble_get_boiler_details test_ble_get_machine_capability test_ble_get_smart_standby_details test_ble_get_tank_status test_ble_set_power test_ble_set_smart_standby test_ble_set_temperature test_bluetooth_command_with_cloud_fallback test_bluetooth_exception_does_not_update_dashboard test_bluetooth_failure_without_cloud test_bluetooth_machine_mode_during_shot test_bluetooth_machine_mode_falls_back_to_websocket_callback test_bluetooth_refresh_after_shot_replaces_cloud_status test_bluetooth_refresh_while_brewing_keeps_cloud_start_time test_bluetooth_shot_counter_active test_bluetooth_telemetry test_cancelled_connect_does_not_keep_unauthenticated_link test_characteristic_resolution_failure_clears_cache test_cloud_only_without_cloud_client test_command_error_keeps_shot_counter_connection test_concurrent_commands_thread_safe test_connect_bluetooth_shot_counter test_connection_callback_connect_and_idle_disconnect test_connection_callback_connection_lost test_connection_callback_not_called_on_failed_authentication test_connection_callback_unregister test_connection_properties_with_clients test_connection_properties_without_clients test_debug_log_masks_bluetooth_token test_disconnect_bluetooth_shot_counter test_discover_devices_prefixes test_exception_triggers_disconnect test_failed_command_does_not_update_dashboard test_failing_command test_get_dashboard_from_bluetooth test_get_dashboard_from_bluetooth_error test_get_dashboard_from_bluetooth_plumb_in_unsupported test_get_dashboard_from_bluetooth_statuses test_get_dashboard_from_bluetooth_steam_level test_get_dashboard_initializes_missing_widgets test_get_dashboard_mini_original_temperature_only test_get_dashboard_no_bluetooth test_get_dashboard_without_steam_level_support test_get_machine_mode test_get_model_info_from_bluetooth test_get_model_info_from_bluetooth_errors test_get_model_info_from_bluetooth_unknown_model test_get_plumbed_in test_is_connected_property test_machine_stop_from_update_callback test_model_name_from_bluetooth_family test_persistent_connection_auto_connect test_persistent_connection_reuse test_read_response_is_nul_terminated test_reconnect_after_disconnect test_register_bluetooth_connection_callback test_requests_are_atomic test_set_coffee_temp_updates_dashboard test_set_power_off_updates_dashboard test_set_power_updates_dashboard test_set_power_updates_group_status test_set_smart_standby_auto_standby test_set_steam_level_updates_dashboard test_set_steam_temp_updates_dashboard test_set_steam_updates_dashboard test_shot_counter_brewing_start_time test_shot_counter_callback_exception_is_caught test_shot_counter_discards_replay test_shot_counter_falls_back_to_websocket_callback test_shot_counter_gives_up_after_auth_failures test_shot_counter_no_reconnect_after_disconnect test_shot_counter_overrides_machine_status test_shot_counter_reconnect_retries_failed_connections test_shot_counter_reconnects_after_disconnect test_shot_counter_recorded_sessions test_shot_counter_state_expires test_shot_counter_state_machine test_shot_counter_supported test_shot_counter_suppresses_auto_disconnect test_shot_counter_telemetry test_start_shot_counter test_start_shot_counter_characteristic_missing test_start_shot_counter_rediscovers_services test_start_shot_counter_twice test_stop_shot_counter_notifies_connection_callback test_stop_shot_counter_reentrant test_timer_reset_on_new_command; do grep -rqF "Upstream: $t (" Tests || { echo "MISSING $t"; m=1; }; done; exit $m'
  bash -c 'm=0; for t in BluetoothAuthTests.testAuthRetriesUntilConfirmed BluetoothAuthTests.testAuthenticationFailedFlagSetAndCleared BluetoothAuthTests.testCancellationDuringAuthDropsLink BluetoothAuthTests.testUnauthenticatedLinkNeverReportedConnected BluetoothAuthTests.testWrongTokenReadsTenTimesThenFails BluetoothCommandSideEffectTests.testBluetoothErrorWithoutCloudRethrows BluetoothCommandSideEffectTests.testNonSuccessStatusWithoutCloudThrowsCommandFailed BluetoothCommandSideEffectTests.testSetCoffeeTempUpdatesWidget BluetoothCommandSideEffectTests.testSetPowerOffUpdatesMode BluetoothCommandSideEffectTests.testSetPowerUpdatesGroupStatus BluetoothCommandSideEffectTests.testSetPowerUpdatesModeOnly BluetoothCommandSideEffectTests.testSetSteamLevelUpdatesWidget BluetoothCommandSideEffectTests.testSetSteamTempUpdatesWidget BluetoothCommandSideEffectTests.testSetSteamUpdatesEnabled BluetoothConnectionTests.testCancelledEventStreamStopsDelivery BluetoothConnectionTests.testCommandAfterManualDisconnectReconnects BluetoothConnectionTests.testCommandErrorDropsIdleConnection BluetoothConnectionTests.testCommandRestartsIdleTimer BluetoothConnectionTests.testConcurrentCommandsConnectOnce BluetoothConnectionTests.testConnectUsesStoredPeripheralID BluetoothConnectionTests.testConnectionEventsConnectAndIdle BluetoothConnectionTests.testConnectionEventsDeduplicate BluetoothConnectionTests.testFirstCommandConnectsAndAuthenticates BluetoothConnectionTests.testIdleTimeoutDisconnects BluetoothConnectionTests.testIsConnectedLifecycle BluetoothConnectionTests.testMissingCharacteristicRediscoversThenDrops BluetoothConnectionTests.testRequestWriteReadPairsAreAtomic BluetoothConnectionTests.testSequentialCommandsReuseConnection BluetoothDashboardRefreshTests.testModelInfoErrors BluetoothDashboardRefreshTests.testModelInfoFromCapabilities BluetoothDashboardRefreshTests.testPlumbInUnsupportedFallsBackToTank BluetoothDashboardRefreshTests.testRefreshCreatesMissingWidgetsMiniR BluetoothDashboardRefreshTests.testRefreshErrorPropagatesWithoutMutation BluetoothDashboardRefreshTests.testRefreshGS3UsesSteamTemperature BluetoothDashboardRefreshTests.testRefreshMicraFromBluetooth BluetoothDashboardRefreshTests.testRefreshOriginalMiniUsesSteamTemperature BluetoothDashboardRefreshTests.testRefreshWithoutClientThrows BluetoothDashboardRefreshTests.testStatusDerivation BluetoothDashboardRefreshTests.testUnknownFamilyThrowsAndKeepsModel BluetoothDeviceStateTests.testBluetoothConnectionEventsForwardOrFinish BluetoothDeviceStateTests.testPropertiesWithClients BluetoothDeviceStateTests.testPropertiesWithoutClients BluetoothDiscoveryTests.testNamePrefixFilter BluetoothEnumsTests.testFamilyMapping BluetoothEnumsTests.testShotCounterSupportedNull BluetoothEnumsTests.testSteamLevelFromTarget BluetoothFallbackTests.testBluetoothFailureWithoutCloudRethrows BluetoothFallbackTests.testBothTransportsFailThrowsCloudError BluetoothFallbackTests.testCommandUsesBluetoothThenCloud BluetoothFallbackTests.testSmartStandbyUsesCloudAutoStandbyWhenSupported BluetoothRequestTests.testGetBoilersDecodesList BluetoothRequestTests.testGetMachineCapabilitiesDecodesFirstElement BluetoothRequestTests.testGetMachineModeBrewing BluetoothRequestTests.testGetPlumbedIn BluetoothRequestTests.testGetSmartStandbyAcceptsStringBool BluetoothRequestTests.testGetTankStatusStringTrue BluetoothRequestTests.testReadResponseCutAtFirstNul BluetoothRequestTests.testSetPowerOnWritesMachineChangeMode BluetoothRequestTests.testSetSmartStandbyWritesMinutesModeEnabled BluetoothRequestTests.testSetTemperatureSteamWritesSettingBoilerTarget BluetoothTokenTests.testBluetoothAuthTokenFromThings BluetoothTokenTests.testTokenDescriptionIsRedacted MachineTransportRoutingTests.testCloudOnlyWithoutCloudClientThrows ShotCounterLifecycleTests.testCommandErrorKeepsShotCounterLink ShotCounterLifecycleTests.testDisconnectReportsUnsubscribed ShotCounterLifecycleTests.testMissingCharacteristicReturnsFalseAfterOneRediscovery ShotCounterLifecycleTests.testShotCounterSuppressesIdleDisconnect ShotCounterLifecycleTests.testStaleServiceCacheRediscoversCharacteristic ShotCounterLifecycleTests.testStartSubscribesAndDisconnectUnsubscribes ShotCounterLifecycleTests.testStartTwiceSubscribesOnce ShotCounterLifecycleTests.testStopFromEventConsumerIsNoOp ShotCounterNotificationTests.testBrewingStartTimeIsEarliestEstimate ShotCounterNotificationTests.testCancelledConsumerDoesNotAffectClient ShotCounterNotificationTests.testMalformedPayloadsAreDropped ShotCounterNotificationTests.testReplayAfterSubscribeIsDropped ShotCounterNotificationTests.testReplayDuringSubscribeIsDropped ShotCounterNotificationTests.testSequence ShotCounterNotificationTests.testTelemetryRoutingAndParsing ShotCounterOverlayTests.testBluetoothRefreshBecomesBaseline ShotCounterOverlayTests.testBluetoothRefreshKeepsCloudStartTime ShotCounterOverlayTests.testBrewingUpdateRendersObservableDashboard ShotCounterOverlayTests.testModeDuringShotAppliedAfterShot ShotCounterOverlayTests.testOverrideLifecycle ShotCounterOverlayTests.testShotCounterActiveMirrorsClient ShotCounterOverlayTests.testStaleStateExpiresAfter60s ShotCounterOverlayTests.testStartIgnoresCloudSupportFlag ShotCounterOverlayTests.testStopFromEventConsumerDoesNotRecurse ShotCounterOverlayTests.testStopRestoresSilently ShotCounterOverlayTests.testTelemetryMergeAndModeApply ShotCounterOverlayTests.testTemperatureTelemetryDoesNotChangeDashboard ShotCounterReconnectTests.testGivesUpAfterThreeAuthFailures ShotCounterReconnectTests.testReconnectRetriesThroughConnectErrors ShotCounterReconnectTests.testReconnectsAndResetsTrackerAfterLinkLoss ShotCounterReconnectTests.testUserDisconnectDoesNotReconnect ShotCounterRecordedSessionTests.testRecordedMorning20261005; do c=${t%%.*}; f=${t#*.}; files=$(grep -rlE "class $c[^A-Za-z0-9_]" Tests); { [ -n "$files" ] && grep -qE "func $f\(" $files; } || { echo "MISSING $t"; m=1; }; done; exit $m'
  python3 -c 'import json,subprocess,sys; d=json.load(open("docs/bluetooth/work-packages.json")); own={p for k in d["packages"] for p in k["owns"]["create"]+k["owns"]["modify"]}|{"docs/bluetooth/SPEC.md","docs/bluetooth/PLAN.md","docs/bluetooth/work-packages.json"}; ch=subprocess.run(["git","diff","--name-only","e1bc403...HEAD"],capture_output=True,text=True,check=True).stdout.split(); bad=[p for p in ch if p not in own]; print("\n".join(bad)); sys.exit(1 if bad else 0)'
  bash -c 'git diff --quiet e1bc403 -- Sources/Angstrom/Widgets.swift Sources/Angstrom/Enums.swift Sources/Angstrom/Optimistic.swift Sources/Angstrom/WebSocket.swift Sources/Angstrom/LaMarzoccoCloudClient.swift Sources/Angstrom/Diagnostics.swift Sources/AngstromUI/MachineSnapshot.swift Sources/Angstrom/Stomp.swift Sources/Angstrom/Proof.swift Sources/Angstrom/InstallationKey.swift Sources/Angstrom/Statistics.swift Sources/Angstrom/Settings.swift .github/workflows/ci.yml && test -z "$(git diff --name-only --diff-filter=MD e1bc403 -- Tests/AngstromTests Tests/AngstromUITests cli/Tests | grep -v /Bluetooth/)"'
  ```
- **Task (brief body):** On a fresh worktree of bluetooth/integration, run every acceptance command below and report each command with its exit status and a log excerpt. Coverage audit: every upstream test function in PLAN §7.2 has a Swift test whose doc comment starts `/// Upstream: <function> (`, and every Swift test of PLAN §7.2 exists as `func <method>(` in a file that declares `class <Class>`. Ownership audit: every path changed since e1bc403 is owned by some package in work-packages.json (or is one of the three docs/bluetooth files). Confirm that ci.yml is unchanged and that none of the SPEC §7.1 'MUST NOT change' files changed. Then prepare the hardware handoff: list H1–H28 and X1–X6 (PLAN §6) with the exact command lines for the human, and say whether an iOS app for H2/H21 exists. You change nothing; failures become findings with fix owners (Appendix A).

---

## 5. Verification packages and the fix loop

Verification happens at three levels. None of the reviewers wrote the code they review, and none
sees the implementer's conversation.

1. **Package review** (§5.1). The orchestrator runs it automatically for every `implement`/`docs`
   package, before merging.
2. **Area reviews** (§5.4). These are named `verify` packages in the manifest. Each one runs in the
   wave **after** the code it reviews, in parallel with that wave's implementers (Wave 2 reviews
   Wave 1, Wave 3 reviews Wave 2's CLI), and Wave 4 reviews everything.
3. **Integration** (BT-W5-01): every gate, the docs build, the iOS build, the release build, and
   the coverage and ownership audits.

### 5.1 Package review (orchestrator-generated, one per implement/docs package)

The prompt, handed verbatim with `{…}` filled in:

> You are an independent reviewer of work package {id} ("{title}") of the Angstrom Bluetooth
> port. You did not write it. Do not trust its comments or its tests. Work in a disposable worktree
> of branch `bt/{id}`. You may build and test there (`.build/` is git-ignored), but do not commit
> and do not change any tracked file. Read CLAUDE.md, docs/bluetooth/SPEC.md
> {specRefs}, docs/bluetooth/PLAN.md §1, §3 and the package brief below. The upstream reference of
> record is pylamarzocco v2.5.6 (4c639ee), read-only at $UPSTREAM.
>
> Check, and report each violation as a finding:
> (a) `git diff --name-only {base}...HEAD` ⊆ the owned paths {owns};
> (b) every acceptance command exits 0 (re-run them);
> (c) every declaration in the owned files that SPEC §6 or PLAN §3 freezes matches character for
>     character (name, labels, types, access, `async`/`throws`). Every other added declaration
>     follows the SPEC §6 access rule: `private`/`fileprivate` in `Sources/Angstrom`,
>     `Sources/AngstromBluetooth`, `Sources/AngstromUI` and `Tests/AngstromTestSupport`; in test
>     files, `XCTestCase` subclasses and `test…` methods are internal and helpers private; in
>     `cli/`, command types and their `@Option`/`@Flag`/`@Argument` properties may be internal;
> (d) every wire value (UUID, JSON key, raw value, error text, timing, count, order) matches SPEC
>     §2–§4 and the cited $UPSTREAM line verbatim;
> (e) every test named in the brief exists with that exact name and the §3.5 doc-comment header,
>     and asserts the behaviour the SPEC vector states (not a weaker property);
> (f) Swift 6 rules: no CoreBluetooth outside Sources/AngstromBluetooth, no Mutex, no
>     Task.immediate, no `@preconcurrency import CoreBluetooth`, no `nonisolated(unsafe)` without a
>     justification comment, no sleep-polling in tests;
> (g) the token never appears in a log line, error, description, or Codable output;
> (h) no behaviour change on cloud-only paths (the existing tests are unmodified and pass).
>
> Output only the §5.2 JSON object.

### 5.2 Reviewer output schema (package reviews and verify packages)

```json
{
  "package": "BT-W2-09",
  "verdict": "PASS | FAIL",
  "reviewed": ["paths or package ids reviewed"],
  "checks": [{"name": "UUIDs verbatim", "result": "pass | fail", "evidence": "command + excerpt"}],
  "findings": [{
    "severity": "blocker | major | minor",
    "file": "Sources/Angstrom/Bluetooth/BluetoothCodec.swift",
    "line": 42,
    "specRef": "SPEC §3.9",
    "upstreamRef": "$UPSTREAM/src/pylamarzocco/clients/_bluetooth.py:707 `separators=(\",\", \":\")`",
    "summary": "one sentence",
    "failureScenario": "concrete input → wrong output",
    "suggestedFix": "one or two sentences",
    "fixOwner": "BT-W1-02",
    "evidence": "failing command or a test that would fail"
  }]
}
```

`verdict` is FAIL if and only if there is at least one `blocker` or `major` finding.
Intentional divergences D1–D22 (SPEC §12) are not findings, unless the code implements them
differently from the SPEC. A reviewer that cannot settle a point from `$UPSTREAM` and the SPEC
reports it as `minor`, with `"summary": "UNVERIFIED: …"`.

### 5.3 Fix loop

```
findings (blocker|major) from a package review → fix job for that package (same brief + findings)
findings from a verify package / BLOCKED-BY reports → group by fixOwner (Appendix A)
  for each fixOwner (serially if two owners' fix jobs touch one file — impossible by Appendix A,
                     but checked anyway):
      fix job: owner's brief + the grouped findings + "fix exactly these; for every blocker/major
               add or un-skip a regression test in a file you own; remove the matching XCTSkip
               BLOCKED-BY lines; do not touch other files"
      → package review of the fix diff (§5.1)
      → the reporting verify package re-checks only its findings
  max 2 rounds per (reporter, fixOwner); still FAIL → escalate to a human (approval A3)
merge fix branches in fixOwner-id order → wave gate
```

A fix job may need to change a test file it does not own (for example, a W3 suite that asserts a
wrong vector). In that case the finding is routed to that test file's owner as well, as a second
fix job.


### 5.4 Named verify packages

| Package | Wave | Reviews (dependsOn) | Focus | Output |
|---|---|---|---|---|
| BT-W2-09 | 2 | BT-W1-01, BT-W1-02, BT-W1-03, BT-W1-06, BT-W1-10 | Verify: wire-level parity of constants, codec, decoders, coercion, enums, token, discovery | §5.2 JSON report: per-constant and per-vector diff, coercion table walk-through, findings with fix owners. |
| BT-W2-10 | 2 | BT-W1-04, BT-W1-05, BT-W1-11 | Verify: state machine, dashboard transforms and the UI funnel against upstream | §5.2 JSON report including a rule-by-rule equivalence table for derive_state/_BrewingTracker and the overlay-equivalence argument for D12. |
| BT-W2-11 | 2 | BT-W1-07, BT-W1-08 | Verify: CoreBluetooth adapter and op table — Swift 6 concurrency and SPEC §5.4 conformance | §5.2 JSON report: a §5.4 bullet-by-bullet conformance table plus a data-race analysis of every mutable adapter field. |
| BT-W2-12 | 2 | BT-W1-09 | Verify: client core lifecycle (gates, connect, auth, idle, teardown, events) against upstream | §5.2 JSON report: an invariant check (I1–I6), an error-mapping cell-by-cell table, and a re-entrancy analysis of every await in the main file. |
| BT-W3-10 | 3 | BT-W1-12, BT-W2-03, BT-W2-04, BT-W2-05, BT-W2-06 | Verify: angcli ble commands, redaction and TCC packaging | §5.2 JSON report: §10 conformance table (every subcommand, option, output field, error text) and a redaction audit. |
| BT-W4-01 | 4 | BT-W1-10, BT-W3-01, BT-W3-02, BT-W3-03, BT-W3-04, BT-W3-05 | Verify: full LaMarzoccoBluetoothClient parity with _bluetooth.py (line by line) | §5.2 JSON report with a function-by-function map of _bluetooth.py (every def and branch) → Swift (file:line) → test name. |
| BT-W4-02 | 4 | BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 | Verify: device-layer parity with _machine.py/_thing.py (fallback, BLE dashboard, overlay, expiry) | §5.2 JSON report with a method-by-method map of the BT paths of _machine.py/_thing.py → Swift → test. |
| BT-W4-03 | 4 | BT-W1-08, BT-W3-01, BT-W3-02, BT-W3-03, BT-W3-04, BT-W3-05, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 | Verify: Swift 6 concurrency and data races across client, UI and adapter (TSan + repeat runs) | §5.2 JSON report: isolation table per type, Task-lifetime audit, TSan output, repeat-run flakiness report; G-DEV-13 design check. |
| BT-W4-04 | 4 | BT-W1-08, BT-W2-03, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 | Verify: public/package API conformance with SPEC §6 and PLAN §3; source compatibility (§13) | §5.2 JSON report: a table of every SPEC §6 / PLAN §3 declaration → present/mismatch (with the symbol-graph or source line), extra non-private declarations, and a §13 compatibility diff against e1bc403. |
| BT-W4-05 | 4 | BT-W1-06, BT-W3-02, BT-W3-10 | Verify: secrecy of the BLE token (library, logs, errors, snapshots, CLI) | §5.2 JSON report: every place token bytes flow (sources → sinks) with a verdict. |
| BT-W4-06 | 4 | BT-W2-07, BT-W2-08, BT-W1-08, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 | Verify: docs accuracy, divergence register and DocC build | §5.2 JSON report: every doc claim checked against the code; D1–D22 present in UPSTREAM.md; DocC build log with no unresolved Bluetooth symbol links. |
| BT-W5-01 | 5 | BT-W4-01, BT-W4-02, BT-W4-03, BT-W4-04, BT-W4-05, BT-W4-06 | Final integration: all gates, docs, iOS, release build, coverage and ownership audits | Release-candidate report (§5.2 schema, plus `gates`, `coverage` and `hardwareHandoff` arrays); no repository change. |

On FAIL, the fix loop of §5.3 runs, using the fix owners in Appendix A. A verify package that is PASS
with only `minor` findings files them as follow-ups. They do not block the wave.

---

## 6. Hardware-in-the-loop checklist (gates the release, not the merge)

CI has no Bluetooth hardware, so these steps can only be run by a human, mostly with a machine and `angcli ble …`.
They **gate the v2.0.0 release (approval A5)**, not any merge, including the merge to `main` (A4). Run them on
macOS 14 (the floor), macOS 15 and current macOS, plus iOS 17+ where marked, on every available model (Linea Micra,
Linea Mini, Linea Mini R, GS3 AV, GS3 MP). Record raw values (redacted) in a findings note. When a result
contradicts a SPEC default (§14.2), file a SPEC amendment (A2) and a follow-up package. Do not edit code ad hoc.

| Id | Step | Verifies | Settles |
|---|---|---|---|
| H1 | `angcli ble scan`, then `angcli ble gatt --peripheral <id>` on every available model | service UUID hosting 0a0b…–0e0b…, characteristic property flags, notify vs indicate on 0e0b… | U1, U2 |
| H2 | `angcli ble listen --peripheral <id> --raw`: read the `[mtu n]` marker on a Mac; repeat on an iPhone in an app that links AngstromBluetooth (maintainer-supplied, SPEC §9.6; no package builds one) | negotiated ATT MTU; whether long writes are needed | U14 |
| H3 | On a fresh macOS user, or after `tccutil reset Bluetooth`, run `angcli ble scan` and watch the state while the TCC prompt is on screen | whether state reads .unknown or .unauthorized during the prompt; whether `poweredOnWait` (10 s) suffices | U17, §8.1 |
| H4 | Deny Bluetooth in System Settings, then turn Bluetooth off, running `angcli ble read machineMode` each time; turn the radio off during `ble listen` | the §8.1 error mapping; whether `[disconnected]` arrives on power-off | §8.1 |
| H5 | Build angcli without the embedded Info.plist (local, uncommitted change) and a Pronto build without the usage string; run a scan | crash vs silent deny when the usage string is missing | U16 |
| H6 | Rebuild angcli/Pronto ad-hoc, self-signed and Developer ID; check whether the Bluetooth grant persists | TCC grant persistence across signatures | U16 |
| H7 | Run `angcli ble scan` from Terminal, iTerm2, the VS Code terminal and over ssh | TCC attribution for a CLI | U16 |
| H8 | Connect with angcli while the official app or phone is connected to the machine, and the reverse | single-central behaviour and its error signature | U12 |
| H9 | Compare `ble scan` ids from angcli vs Pronto; repeat after reboot, Bluetooth reset and 'Forget device' | CBPeer.identifier scope | U18 |
| H10 | `angcli ble scan --all` (public `scanAll`, unfiltered) per model; note names vs cloud serials | advertised name format; MINI vs LINEA prefix per model | U3 |
| H11 | Only if the custom-executor adapter design is ever tried: run the assumeIsolated probe on macOS 14 | R-4 trap risk (not applicable to the shipped design) | — |
| H12 | `angcli ble listen --raw`: count the auth reads before 0x01 | whether 10 × 50 ms is enough | auth timing |
| H13 | `angcli ble listen --raw` right after subscribe: is the first notification a replay, and does it precede `[subscribed]`? | replay always sent; notify-before-ack routing | U15 |
| H14 | `angcli ble listen --raw` during a shot and at idle; compare notification lengths with REC line 23 (418 B) | whole notifications at Apple's MTU | U14 |
| H15 | If MTU < 93: `angcli ble cmd standby --enabled true --minutes 30 --mode PowerOn --confirm` | long-write support | U14 |
| H16 | After first use: any OS pairing alert, or a bonded entry in System Settings? | encryption/bonding requirements | U2 |
| H17 | `angcli ble token --peripheral <id>` in and out of pairing mode | token read behaviour and the ATT error code | U5, U4 (length only) |
| H18 | Sleep/wake the Mac for 5 min and toggle Bluetooth while `ble listen` runs | D14 recovery; reconnect behaviour | D14 |
| H19 | Pronto hidden for 30 min with BLE idle: is the idle disconnect late in the raw tap? | App Nap / timer coalescing | §8.3 |
| H20 | Reboot or update the machine while `ble listen` is connected | `[services invalidated]` path (D7c) | D7 |
| H21 | The maintainer-supplied iOS app (as H2) in background, with and without `UIBackgroundModes` → `bluetooth-central`. If no such app exists at A5, record H2-iOS and H21 as not run and list U14-on-iOS and §8.6 as unverified in the release notes | foreground-only v1 assumptions | §8.6 |
| H22 | `angcli ble read machineCapabilities` on **each** model | family strings (GS3 MP `GS3` vs `GS3MP`; Mini R `LINEAMINI2023`) | U13 |
| H23 | `angcli ble cmd temp coffee 93 --confirm`, then `93.5` | firmware accepts integral `93` (D6) and fractional values | U7 |
| H24 | `angcli ble cmd temp coffee 200 --confirm` (expected rejection) | failure status strings and casing | U8 |
| H25 | `angcli ble read isPlumbedIn` on the oldest available firmware | reply to an unknown read setting | U9 |
| H26 | `angcli ble read smartStandBy` with smart standby disabled | `"enabled":"false"` vs `false` (D5 relevance) | D5 |
| H27 | `angcli ble read all` repeatedly, watching latency | is the response ready right after the write ack; max response size | U6 |
| H28 | Notarise a Pronto (or angcli) build that links AngstromBluetooth and scans (hardened runtime, no entitlement); run it on a Mac with Bluetooth on (no espresso machine needed) | Gatekeeper accepts it and the TCC prompt appears | SPEC §8.3 |

### 6.1 Other release checks (maintainer, no hardware)

| Id | Step | Verifies |
|---|---|---|
| X1 | Run upstream's Bluetooth suites at 4c639ee: `uv run --frozen --extra dev pytest tests/test_bluetooth_client.py tests/test_bluetooth_dashboard.py tests/test_machine.py` | the 123 upstream cases pass (SPEC U21) |
| X2 | Run upstream's recorded-session test with prints of every update's brewing_start_time | the per-line golden of SPEC §9.3.4 (U22) |
| X3 | In `$UPSTREAM`, decode each BT-COERCE / BT-NTF-COERCE input (SPEC §9.3.2–§9.3.3) with the 4c639ee models, e.g. `uv run --frozen python -c "from pylamarzocco.models import BluetoothCommandStatus as S; print(S.from_dict({'id': 'a', 'message': None, 'status': 'success'}))"` (expect `message='None'`); notifications go through `BluetoothBrewingData.from_dict` and `BluetoothMachineTelemetry.from_dict` of `json.loads(payload)` | the Upstream column of the coercion vectors (SPEC U10, settled with mashumaro 3.17; re-run if `uv.lock` moves) |
| X4 | Build with the oldest Xcode whose Swift is 6.0 (the tools floor) | SPEC U20 |
| X5 | TestFlight/App Store upload of a build that links AngstromBluetooth | SPEC U19 (justifies the leaf product) |
| X6 | Ask the upstream author whether the payloads in tests/test_bluetooth_client.py and tests/conftest.py are real captures | SPEC U11 |

---

## 7. Coverage tables

### 7.1 SPEC §2 parity inventory → owning packages

Every row of SPEC §2.1–§2.7. "Implement" owns the behaviour. "Tests" owns the pinning test.

| § | Upstream | Angstrom | Implement | Tests |
|---|---|---|---|---|
| 2.1 | `__init__(ble_device, ble_token, ble_device_callback)` (BT:142-181) | `init(transport:peripheral:token:logHandler:)`; callback not ported (D3) | BT-W0-01, BT-W1-09 | BT-W3-01 (C51) |
| 2.1 | `is_connected` (183-186) | `isConnected` (authenticated, D11) | BT-W0-01 | BT-W3-01 (C16) |
| 2.1 | `register_connection_callback` (188-206) | `connectionEvents()` | BT-W1-09 | BT-W3-01 (C52, C53, C55) |
| 2.1 | `_set_connected` (208-214) | `setConnected(_:)` | BT-W1-09 | BT-W1-09, BT-W3-01 |
| 2.1 | `authentication_failed` (216-222) | `authenticationFailed` | BT-W0-01, BT-W1-09 | BT-W3-01 (C49) |
| 2.1 | `shot_counter_active` (224-231) | `shotCounterActive` | BT-W0-01 | BT-W3-03 |
| 2.1 | `_ensure_connected` (233-269) | `ensureConnected(refresh:)` | BT-W1-09 | BT-W1-09, BT-W3-01 (C09, C10) |
| 2.1 | `_reset_disconnect_timer` / `_auto_disconnect` (271-291) | `resetIdleTimer()` + idle task | BT-W1-09 | BT-W3-01 (C11, C12) |
| 2.1 | `_disconnect_internal` (293-311) | `disconnectInternal(fromIdleTimer:)` | BT-W1-09 | BT-W1-09 |
| 2.1 | `_drop_connection` (313-317) | `dropConnection` / `dropConnectionInBackground` | BT-W1-09 | BT-W3-01 (C14) |
| 2.1 | `disconnect()` (319-325) | `disconnect() async` | BT-W1-09 | BT-W3-01 (C17), BT-W3-03 (C40) |
| 2.1 | `start_shot_counter` (327-362) | `startShotCounter()` + `shotCounterEvents()` | BT-W2-02 | BT-W3-03 (C22, C36) |
| 2.1 | `stop_shot_counter` (364-371) | `stopShotCounter()` | BT-W2-02 | BT-W3-03 (C37, C38) |
| 2.1 | `_disable_shot_counter` (373-394) | `disableShotCounter()` | BT-W2-02 | BT-W3-03 |
| 2.1 | `_stop_notify_internal` (396-401) | `stopNotifyInternal()` | BT-W2-02 | BT-W3-03 |
| 2.1 | `_subscribe_shot_counter` (403-439) | `subscribeShotCounter()` | BT-W2-02 | BT-W3-03 (C20, C21) |
| 2.1 | `_handle_shot_counter_notification` (441-465) | `handleShotCounterNotification(_:)` | BT-W2-02 | BT-W3-04 (C24–C30) |
| 2.1 | `_on_bleak_disconnected` (467-473) | `handleLinkEvent(.disconnected, from:)` | BT-W1-09 | BT-W1-09, BT-W3-01 |
| 2.1 | `_handle_connection_lost` (475-486) | `handleConnectionLost()` | BT-W1-09 | BT-W3-05 (C32) |
| 2.1 | `_reconnect_shot_counter` (488-520) | `reconnectLoop()` | BT-W2-02 | BT-W3-05 (C32–C35) |
| 2.1 | `discover_devices` (522-537) | `static discoverMachines(transport:duration:)` (+ Angstrom-only unfiltered `scanAll`) | BT-W1-10 | BT-W1-10 (C50, `testScanAllIsUnfiltered`) |
| 2.1 | `read_token` (539-547) | `static readToken(transport:peripheral:)` | BT-W1-10 | BT-W1-10 (G-CODEC-1) |
| 2.1 | `address` (549-553) | `nonisolated let peripheral` | BT-W0-01 | BT-W3-01 (C51) |
| 2.1 | `get_machine_mode` (555-560) | `machineMode()` | BT-W2-01 | BT-W3-02 (C08) |
| 2.1 | `get_machine_capabilities` (562-568) | `machineCapabilities()` | BT-W2-01 | BT-W3-02 (C04) |
| 2.1 | `get_tank_status` (570-575) | `tankStatus()` | BT-W2-01 | BT-W3-02 (C07) |
| 2.1 | `get_plumbed_in` (577-582) | `isPlumbedIn()` | BT-W2-01 | BT-W3-02 (C43–C46) |
| 2.1 | `get_boilers` (584-588) | `boilers()` | BT-W2-01 | BT-W3-02 (C05) |
| 2.1 | `get_smart_standby_settings` (590-594) | `smartStandby()` | BT-W2-01 | BT-W3-02 (C06) |
| 2.1 | `set_power` (596-600) | `setPower(on:)` | BT-W2-01 | BT-W3-02 (C01) |
| 2.1 | `set_steam` (602-608) | `setSteam(on:)` | BT-W2-01 | BT-W3-02 |
| 2.1 | `set_smart_standby` (610-618) | `setSmartStandby(enabled:mode:minutes:)` | BT-W2-01 | BT-W3-02 (C03) |
| 2.1 | `set_temp` (620-626) | `setTemperature(boiler:celsius:)` | BT-W2-01 | BT-W3-02 (C02) |
| 2.1 | `_authenticate` (628-653) | `authenticate(_:)` | BT-W1-09 | BT-W3-01 (C18, C19, C49) |
| 2.1 | `__read_value_from_machine` (655-657) | `readSetting(_:)` | BT-W2-01 | BT-W3-02 |
| 2.1 | `_read_bluetooth_message` / `__write_bluetooth_message` (659-700) | `request(_:frame:)` + `BluetoothCodec` | BT-W2-01, BT-W1-02 | BT-W3-02 (C42), BT-W1-02 |
| 2.1 | `__send_command` (702-710) | `sendCommand(_:)` | BT-W2-01 | BT-W3-02 |
| 2.1 | `_resolve_characteristic` (712-747) | `resolve(_:on:)` (D7) | BT-W2-01 | BT-W3-01 (C15), BT-W3-03 (G-CONN-6) |
| 2.1 | `disconnect_on_exception` (114-136) | request wrapper `request(_:frame:)` | BT-W2-01 | BT-W3-01 (C14), BT-W3-03 (C48) |
| 2.1 | `_BrewingTracker` (77-111) | `BrewingTracker` | BT-W1-04 | BT-W1-04, BT-W3-04 |
| 2.1 | `_parse_bool` (62-64) | `BluetoothWireCoercion.parseBool(_:)` | BT-W0-01 | BT-W1-01 |
| 2.1 | `_safe_call` (67-74) | not ported (D4) | — | BT-W3-04 (C31 restated) |
| 2.1 | `_utcnow` (57-59) | `BluetoothTransport.now` | BT-W0-01, BT-W0-03 (test clock) | BT-W3-04 (C30) |
| 2.1 | logging (`_logger.*`) | optional `logHandler`, never the token | BT-W1-09 | BT-W1-09, BT-W4-05 |
| 2.2 | `READ_/WRITE_/GET_TOKEN_/AUTH_/SHOT_COUNTER_CHARACTERISTIC` (BT:40-44) | `BluetoothConstants.*Characteristic` | BT-W0-01 | BT-W1-01, BT-W2-09 |
| 2.2 | `BT_MODEL_PREFIXES` (BT:46) | `machineNamePrefixes` | BT-W0-01 | BT-W1-01, BT-W1-10 |
| 2.2 | `IDLE_TIMEOUT`, `AUTH_SUCCESS`, `AUTH_READ_ATTEMPTS`, `AUTH_READ_INTERVAL`, `MAX_AUTH_FAILURES`, `RECONNECT_INITIAL_DELAY`, `RECONNECT_MAX_DELAY` (BT:47-54) | `BluetoothTiming` / `BluetoothConstants.authSuccess` | BT-W0-01 | BT-W1-01, BT-W3-01, BT-W3-05 |
| 2.2 | `establish_connection(max_attempts=3)` (BT:252), `BLEAK_TIMEOUT = 20.0` (BRC:102) | `connectAttempts`, `connectTimeout` | BT-W0-01, BT-W1-09 | BT-W1-09 (G-CONN-1) |
| 2.3 | `BluetoothMachineCapabilities` (MBT:22-39) | struct + decoder | BT-W0-01, BT-W1-03 | BT-W1-03, BT-W3-02 |
| 2.3 | `BluetoothBoilerDetails` (MBT:42-49) | struct (Double, D9) + decoder | BT-W0-01, BT-W1-03 | BT-W1-03, BT-W3-02 |
| 2.3 | `BluetoothSmartStandbyDetails` (MBT:51-57) | struct + decoder | BT-W0-01, BT-W1-03 | BT-W1-03, BT-W3-02 |
| 2.3 | `BluetoothCommandStatus` (MBT:59-65) | struct + `isSuccess` + decoder | BT-W0-01, BT-W1-03 | BT-W1-01, BT-W1-03 |
| 2.3 | `_known_machine_mode` (MBT:68-70) | telemetry decoder drops `.other` | BT-W1-04 | BT-W1-04 |
| 2.3 | `_PartialNotification.is_empty/merge` (MBT:73-87) | `isEmpty` / `merging(_:)` | BT-W0-01 | BT-W1-01 |
| 2.3 | `BluetoothBrewingData` + `derive_state` (MBT:90-163) | struct + `deriveState(receivedAt:)` | BT-W0-01, BT-W1-04 | BT-W1-04, BT-W3-04 |
| 2.3 | `BluetoothShotCounterUpdate` (MBT:166-188) | struct | BT-W0-01 | BT-W1-01, BT-W3-04 |
| 2.3 | `BluetoothMachineTelemetry` (MBT:191-213) | struct (`BluetoothJSONValue` statistics) | BT-W0-01, BT-W1-04 | BT-W1-04, BT-W3-04 (C28) |
| 2.3 | `BluetoothReadSetting` (CONST:322-330) | enum | BT-W0-01 | BT-W1-01 |
| 2.3 | `BluetoothBrewingState` (CONST:333-339) | enum | BT-W0-01 | BT-W1-01 |
| 2.3 | `BoilerType` (CONST:307-311) | `BluetoothBoilerType` | BT-W0-01 | BT-W1-01 |
| 2.3 | `SmartStandByType` (CONST:260-264) | reuse `SmartStandbyAfter` | existing | BT-W1-03, BT-W3-02 |
| 2.3 | `MachineMode` / `MachineState` / `BoilerStatus` (CONST:11-31, 267-275) | reuse existing enums | existing | BT-W1-01 |
| 2.3 | `SteamTargetLevel` (CONST:141-146) | reuse `SteamLevel` | existing | BT-W1-01 |
| 2.3 | `STEAM_LEVEL_MAPPING` (MACH:58-62) | `SteamLevel.bluetoothTargetTemperature` | BT-W0-01 | BT-W1-01 |
| 2.3 | `_steam_level_from_temperature` (MACH:78-84) | `SteamLevel(bluetoothTargetTemperature:)` | BT-W0-01 | BT-W1-01 (D20–D25) |
| 2.3 | `BLE_MACHINE_STATE` (MACH:65-69) | `MachineState(bluetoothMode:)` | BT-W0-01 | BT-W1-01 |
| 2.3 | `BLE_BOILER_STATUS` (MACH:71-75) | `BoilerStatus(bluetoothMode:)` | BT-W0-01 | BT-W1-01 |
| 2.3 | `ModelName.from_string` BLE aliases (CONST:198-218) | `Model(bluetoothFamily:)` (D8) | BT-W0-01 | BT-W1-01 (O04–O07) |
| 2.3 | `ModelCode[family.name]` (MACH:344) | not needed (`Model` is name and code) | — | BT-W3-08 (D03) |
| 2.3 | `STEAM_LEVEL_MODELS` (CONST:182) | `Model.steamLevelModels` | BT-W0-01, BT-W1-11 | BT-W1-01, BT-W1-11 |
| 2.3 | `models_supported((GS3, GS3_AV, GS3_MP, STRADA_X))` (MACH:823) | `Model.steamTemperatureModels` | BT-W0-01, BT-W1-11 | BT-W1-11, BT-W3-07 |
| 2.4 | `BluetoothConnectionFailed` (EXC:20-21) | `.bluetoothConnectionFailed` + `.bluetoothUnavailable` (D10) | BT-W0-01, BT-W1-09 | BT-W1-01, BT-W1-09 |
| 2.4 | `BluetoothAuthenticationFailed` (EXC:46-47) | `.bluetoothAuthenticationFailed` + `isBluetoothConnectionFailure` | BT-W0-01 | BT-W1-01, BT-W3-01 |
| 2.4 | `BleakError` | `.bluetoothConnectionFailed(String)` | BT-W1-09 | BT-W1-09 (mapping table) |
| 2.4 | bare `TimeoutError` (request phase) | `.bluetoothTimedOut(String)` | BT-W1-09, BT-W2-01 | BT-W3-01 (D19) |
| 2.4 | `CloudOnlyFunctionality` (EXC:28-35) | `.cloudOnlyFunctionality` | BT-W0-01, BT-W1-11 | BT-W1-11 (T00) |
| 2.4 | `UnsupportedModel` (EXC:38-39) | existing `.unsupportedModel` | existing | BT-W3-07 |
| 2.4 | decode errors (`ValueError`, `JSONDecodeError`, …) | existing `.decoding(String)` | BT-W1-03, BT-W1-04 | BT-W1-03, BT-W3-02 (G-CODEC-5) |
| 2.5 | `LaMarzoccoThing.__init__(serial, cloud_client, bluetooth_client)` (THING:73-90) | `init(serialNumber:client:bluetooth:snapshot:)` | BT-W0-02 | BT-W3-06 (T01, T02) |
| 2.5 | `bluetooth_client_available` (THING:99-102) | `hasBluetoothClient` | BT-W0-02 | BT-W3-06 |
| 2.5 | `cloud_client_available` (THING:104-107) | `hasCloudClient` | BT-W0-02 | BT-W3-06 |
| 2.5 | `bluetooth_connected` (THING:109-114) | `isBluetoothConnected` | BT-W3-06 | BT-W3-06 (G-DEV-9) |
| 2.5 | `register_bluetooth_connection_callback` (THING:116-126) | `bluetoothConnectionEvents()` | BT-W3-06 | BT-W3-06 (M15) |
| 2.5 | `cloud_only` decorator (THING:27-38) | throwing `client` accessor | BT-W0-02, BT-W1-11 | BT-W1-11 (T00) |
| 2.5 | `models_supported` (THING:41-67) | existing `requireModel` | BT-W0-02 (access) | BT-W3-07 |
| 2.5 | `_dashboard_config_updated` hook (THING:181-182, MACH:316-323) | `setBaseDashboard`/`updateBaseDashboard` + `renderDashboard()` (D12) | BT-W0-02, BT-W1-11 | BT-W1-11, BT-W3-09 |
| 2.5 | `_widget(cls)` (THING:184-186) | existing `Dashboard` accessors | existing | — |
| 2.5 | `get_model_info_from_bluetooth` (MACH:325-348) | `refreshModelFromBluetooth()` | BT-W3-08 | BT-W3-08 (D03, M26, M27) |
| 2.5 | `get_dashboard_from_bluetooth` (MACH:350-485) | `refreshDashboardFromBluetooth()` + `applyingBluetoothState` | BT-W3-08, BT-W1-05 | BT-W3-08 (D01–D06, D15–D19, D26, M28), BT-W1-05 |
| 2.5 | `_update_machine_mode_widgets` (MACH:487-492) | existing `settingMachineMode(_:)` | existing | BT-W3-07 (M29) |
| 2.5 | `set_power` / `set_steam` / `set_steam_level` / `set_coffee_target_temperature` / `set_steam_target_temperature` / `set_smart_standby` (MACH:494-509, 764-841, 870-892) | six methods routed through `bluetoothFirst` | BT-W1-11, BT-W3-07 | BT-W3-07 (M01–M13, M29–M32, D07–D14) |
| 2.5 | `__bluetooth_command_with_cloud_fallback` (MACH:983-1049) | `bluetoothFirst(bluetooth:cloud:)` | BT-W3-07 | BT-W3-07 |
| 2.5 | `BLE_BREWING_STATE_TIMEOUT = 60` (MACH:88) | `bluetoothBrewingStateTimeout` | BT-W0-02 | BT-W3-09 (M19) |
| 2.5 | `ble_brewing_update` (MACH:132-135) | `bluetoothBrewingUpdate` | BT-W0-02, BT-W3-09 | BT-W3-09 |
| 2.5 | `bluetooth_telemetry` (MACH:137-143) | `bluetoothTelemetry` | BT-W0-02, BT-W3-09 | BT-W3-09 (M22) |
| 2.5 | `last_shot_time` (MACH:145-148) | `lastShotTime` | BT-W0-02, BT-W3-09 | BT-W3-09 |
| 2.5 | `bluetooth_shot_counter_active` (MACH:150-156) | `isShotCounterActive` | BT-W0-02, BT-W3-09 | BT-W3-09 (M25) |
| 2.5 | `connect_bluetooth_shot_counter` (MACH:158-191) | `startShotCounter()` + `bluetoothEvents()` | BT-W3-09 | BT-W3-09 (M14) |
| 2.5 | `disconnect_bluetooth_shot_counter` (MACH:193-207) | `stopShotCounter()` | BT-W3-09 | BT-W3-09 (M18) |
| 2.5 | `_on_shot_counter_update` / `_connection` / `_telemetry` (MACH:209-241) | `handleShotCounterEvent(_:)` | BT-W3-09 | BT-W3-09 (M16, M22, M23) |
| 2.5 | `_drop_ble_brewing_state` / `_clear_…` / `_apply_…` (MACH:243-246, 273-314) | `clearBluetoothBrewingState(notify:)` + `overlayingBluetoothBrewing(_:)` | BT-W3-09, BT-W1-05 | BT-W3-09, BT-W1-05 |
| 2.5 | `_notify_shot_counter_listeners` / `_notify_dashboard_listeners` (MACH:248-271) | `bluetoothEvents()` + `@Observable`; websocket-config synthesis not ported (D13) | BT-W3-09 | BT-W3-09 (M17, M24) |
| 2.5 | `LaMarzoccoGrinder` accepts `bluetooth_client`, never uses it | no grinder routing (parity) | BT-W1-11 | BT-W4-02 |
| 2.6 | `Thing.ble_auth_token` (GEN:128-130) | `bluetoothAuthToken(serial:)` (D2) | BT-W1-06 | BT-W1-06 (X01) |
| 2.6 | `_mask_bluetooth_token` (CLOUD:84-92) | library never logs bodies; `Redact.bluetoothFrame` + existing `Redact.bleAuthToken` | BT-W1-12, BT-W2-03 | BT-W2-03, BT-W4-05 |
| 2.6 | `Thing.shot_counter_supported` (GEN:131-136) | existing `Machine.shotCounterSupported` (doc reworded) | BT-W0-01 | BT-W1-01 (O01–O03), BT-W3-09 (M14) |
| 2.7 | `BleakClientWithServiceCache`, `use_services_cache`, `clear_cache()` | not ported; intent = `discover(…, refresh: true)` | BT-W2-01, BT-W2-02 | BT-W3-01 (C15), BT-W3-03 (C21) |
| 2.7 | `ble_device_callback` | not ported (D3) | — | BT-W3-01 (C51 restated) |
| 2.7 | `_safe_call` | not ported (D4) | — | BT-W3-04 (C31 restated) |
| 2.7 | `asyncio.Task(eager_start=True)` re-entrancy (TBC:1125-1180) | not applicable (streams) | — | BT-W3-03 (C37/C38), BT-W3-09 (C39) |
| 2.7 | legacy GATT layout (LEG) | not ported (§1.2) | — | BT-W2-11 (no d30a… assumption) |
| 2.7 | bleak `pair()` | not ported (§1.2) | — | BT-W2-11 |
| 2.7 | `ThingDashboardWebsocketConfig` synthesis for listeners | not ported (D13) | — | BT-W3-09 (M17, M24 restated) |

### 7.2 Upstream Bluetooth tests → owning package (each owned exactly once)

92 upstream test functions: 49 in `test_bluetooth_client.py`, 17 in `test_bluetooth_dashboard.py`, 20 in `test_machine.py`, 3 in `test_thing.py` (T00 added by R7), 2 in `test_models.py`, 1 in `test_cloud_client.py`. `test_grinder.py` has none. Line numbers are the `def` lines at `4c639ee`.

| Upstream test (`$UPSTREAM/…:line`) | Cases | Swift test(s) | Owner |
|---|---|---|---|
| `test_ble_set_power` (tests/test_bluetooth_client.py:295) | C01 | `BluetoothRequestTests.testSetPowerOnWritesMachineChangeMode` | BT-W3-02 |
| `test_ble_set_temperature` (tests/test_bluetooth_client.py:310) | C02 | `BluetoothRequestTests.testSetTemperatureSteamWritesSettingBoilerTarget` | BT-W3-02 |
| `test_ble_set_smart_standby` (tests/test_bluetooth_client.py:324) | C03 | `BluetoothRequestTests.testSetSmartStandbyWritesMinutesModeEnabled` | BT-W3-02 |
| `test_ble_get_machine_capability` (tests/test_bluetooth_client.py:338) | C04 | `BluetoothRequestTests.testGetMachineCapabilitiesDecodesFirstElement` | BT-W3-02 |
| `test_ble_get_boiler_details` (tests/test_bluetooth_client.py:361) | C05 | `BluetoothRequestTests.testGetBoilersDecodesList` | BT-W3-02 |
| `test_ble_get_smart_standby_details` (tests/test_bluetooth_client.py:388) | C06 | `BluetoothRequestTests.testGetSmartStandbyAcceptsStringBool` | BT-W3-02 |
| `test_ble_get_tank_status` (tests/test_bluetooth_client.py:406) | C07 | `BluetoothRequestTests.testGetTankStatusStringTrue` | BT-W3-02 |
| `test_get_machine_mode` (tests/test_bluetooth_client.py:420) | C08 | `BluetoothRequestTests.testGetMachineModeBrewing` | BT-W3-02 |
| `test_persistent_connection_auto_connect` (tests/test_bluetooth_client.py:434) | C09 | `BluetoothConnectionTests.testFirstCommandConnectsAndAuthenticates` | BT-W3-01 |
| `test_persistent_connection_reuse` (tests/test_bluetooth_client.py:454) | C10 | `BluetoothConnectionTests.testSequentialCommandsReuseConnection` | BT-W3-01 |
| `test_auto_disconnect_after_idle` (tests/test_bluetooth_client.py:475) | C11 | `BluetoothConnectionTests.testIdleTimeoutDisconnects` | BT-W3-01 |
| `test_timer_reset_on_new_command` (tests/test_bluetooth_client.py:493) | C12 (restated) | `BluetoothConnectionTests.testCommandRestartsIdleTimer` | BT-W3-01 |
| `test_concurrent_commands_thread_safe` (tests/test_bluetooth_client.py:516) | C13 | `BluetoothConnectionTests.testConcurrentCommandsConnectOnce` | BT-W3-01 |
| `test_exception_triggers_disconnect` (tests/test_bluetooth_client.py:544) | C14 | `BluetoothConnectionTests.testCommandErrorDropsIdleConnection` | BT-W3-01 |
| `test_characteristic_resolution_failure_clears_cache` (tests/test_bluetooth_client.py:565) | C15 | `BluetoothConnectionTests.testMissingCharacteristicRediscoversThenDrops` | BT-W3-01 |
| `test_is_connected_property` (tests/test_bluetooth_client.py:584) | C16 | `BluetoothConnectionTests.testIsConnectedLifecycle` | BT-W3-01 |
| `test_reconnect_after_disconnect` (tests/test_bluetooth_client.py:600) | C17 | `BluetoothConnectionTests.testCommandAfterManualDisconnectReconnects` | BT-W3-01 |
| `test_auth_read_back_failure` (tests/test_bluetooth_client.py:617) | C18 | `BluetoothAuthTests.testWrongTokenReadsTenTimesThenFails` | BT-W3-01 |
| `test_auth_read_back_retries_until_confirmed` (tests/test_bluetooth_client.py:636) | C19 | `BluetoothAuthTests.testAuthRetriesUntilConfirmed` | BT-W3-01 |
| `test_start_shot_counter_characteristic_missing` (tests/test_bluetooth_client.py:652) | C20 | `ShotCounterLifecycleTests.testMissingCharacteristicReturnsFalseAfterOneRediscovery` | BT-W3-03 |
| `test_start_shot_counter_rediscovers_services` (tests/test_bluetooth_client.py:677) | C21 | `ShotCounterLifecycleTests.testStaleServiceCacheRediscoversCharacteristic` | BT-W3-03 |
| `test_start_shot_counter` (tests/test_bluetooth_client.py:699) | C22 | `ShotCounterLifecycleTests.testStartSubscribesAndDisconnectUnsubscribes` | BT-W3-03 |
| `test_shot_counter_suppresses_auto_disconnect` (tests/test_bluetooth_client.py:719) | C23 | `ShotCounterLifecycleTests.testShotCounterSuppressesIdleDisconnect` | BT-W3-03 |
| `test_shot_counter_state_machine` (tests/test_bluetooth_client.py:784) | C24 [sequence], C25 [malformed] | `ShotCounterNotificationTests.testSequence`, `ShotCounterNotificationTests.testMalformedPayloadsAreDropped` | BT-W3-04 |
| `test_shot_counter_discards_replay` (tests/test_bluetooth_client.py:822) | C26 [during_subscribe], C27 [after_subscribe] | `ShotCounterNotificationTests.testReplayDuringSubscribeIsDropped`, `ShotCounterNotificationTests.testReplayAfterSubscribeIsDropped` | BT-W3-04 |
| `test_shot_counter_telemetry` (tests/test_bluetooth_client.py:848) | C28 | `ShotCounterNotificationTests.testTelemetryRoutingAndParsing` | BT-W3-04 |
| `test_shot_counter_recorded_sessions` (tests/test_bluetooth_client.py:912) | C29 | `ShotCounterRecordedSessionTests.testRecordedMorning20261005` | BT-W3-04 |
| `test_shot_counter_brewing_start_time` (tests/test_bluetooth_client.py:980) | C30 | `ShotCounterNotificationTests.testBrewingStartTimeIsEarliestEstimate` | BT-W3-04 |
| `test_shot_counter_callback_exception_is_caught` (tests/test_bluetooth_client.py:1009) | C31 (restated, D4) | `ShotCounterNotificationTests.testCancelledConsumerDoesNotAffectClient` | BT-W3-04 |
| `test_shot_counter_reconnects_after_disconnect` (tests/test_bluetooth_client.py:1022) | C32 | `ShotCounterReconnectTests.testReconnectsAndResetsTrackerAfterLinkLoss` | BT-W3-05 |
| `test_shot_counter_reconnect_retries_failed_connections` (tests/test_bluetooth_client.py:1053) | C33 (restated counts) | `ShotCounterReconnectTests.testReconnectRetriesThroughConnectErrors` | BT-W3-05 |
| `test_shot_counter_gives_up_after_auth_failures` (tests/test_bluetooth_client.py:1072) | C34 | `ShotCounterReconnectTests.testGivesUpAfterThreeAuthFailures` | BT-W3-05 |
| `test_shot_counter_no_reconnect_after_disconnect` (tests/test_bluetooth_client.py:1094) | C35 | `ShotCounterReconnectTests.testUserDisconnectDoesNotReconnect` | BT-W3-05 |
| `test_start_shot_counter_twice` (tests/test_bluetooth_client.py:1108) | C36 (restated, D4) | `ShotCounterLifecycleTests.testStartTwiceSubscribesOnce` | BT-W3-03 |
| `test_stop_shot_counter_reentrant` (tests/test_bluetooth_client.py:1126) | C37 [stop_shot_counter], C38 [disconnect] (restated, D4) | `ShotCounterLifecycleTests.testStopFromEventConsumerIsNoOp` | BT-W3-03 |
| `test_machine_stop_from_update_callback` (tests/test_bluetooth_client.py:1156) | C39 (restated, D4) | `ShotCounterOverlayTests.testStopFromEventConsumerDoesNotRecurse` | BT-W3-09 |
| `test_stop_shot_counter_notifies_connection_callback` (tests/test_bluetooth_client.py:1183) | C40 | `ShotCounterLifecycleTests.testDisconnectReportsUnsubscribed` | BT-W3-03 |
| `test_cancelled_connect_does_not_keep_unauthenticated_link` (tests/test_bluetooth_client.py:1197) | C41 | `BluetoothAuthTests.testCancellationDuringAuthDropsLink` | BT-W3-01 |
| `test_read_response_is_nul_terminated` (tests/test_bluetooth_client.py:1223) | C42 | `BluetoothRequestTests.testReadResponseCutAtFirstNul` | BT-W3-02 |
| `test_get_plumbed_in` (tests/test_bluetooth_client.py:1238) | C43–C46 (4 cases) | `BluetoothRequestTests.testGetPlumbedIn` | BT-W3-02 |
| `test_requests_are_atomic` (tests/test_bluetooth_client.py:1253) | C47 | `BluetoothConnectionTests.testRequestWriteReadPairsAreAtomic` | BT-W3-01 |
| `test_command_error_keeps_shot_counter_connection` (tests/test_bluetooth_client.py:1287) | C48 | `ShotCounterLifecycleTests.testCommandErrorKeepsShotCounterLink` | BT-W3-03 |
| `test_authentication_failed_flag` (tests/test_bluetooth_client.py:1305) | C49 | `BluetoothAuthTests.testAuthenticationFailedFlagSetAndCleared` | BT-W3-01 |
| `test_discover_devices_prefixes` (tests/test_bluetooth_client.py:1326) | C50 | `BluetoothDiscoveryTests.testNamePrefixFilter` | BT-W1-10 |
| `test_ble_device_callback` (tests/test_bluetooth_client.py:1345) | C51 (restated, D3) | `BluetoothConnectionTests.testConnectUsesStoredPeripheralID` | BT-W3-01 |
| `test_connection_callback_connect_and_idle_disconnect` (tests/test_bluetooth_client.py:1361) | C52 | `BluetoothConnectionTests.testConnectionEventsConnectAndIdle` | BT-W3-01 |
| `test_connection_callback_connection_lost` (tests/test_bluetooth_client.py:1382) | C53 | `BluetoothConnectionTests.testConnectionEventsDeduplicate` | BT-W3-01 |
| `test_connection_callback_not_called_on_failed_authentication` (tests/test_bluetooth_client.py:1405) | C54 | `BluetoothAuthTests.testUnauthenticatedLinkNeverReportedConnected` | BT-W3-01 |
| `test_connection_callback_unregister` (tests/test_bluetooth_client.py:1424) | C55 (restated, D4) | `BluetoothConnectionTests.testCancelledEventStreamStopsDelivery` | BT-W3-01 |
| `test_get_dashboard_from_bluetooth` (tests/test_bluetooth_dashboard.py:110) | D01 | `BluetoothDashboardRefreshTests.testRefreshMicraFromBluetooth` | BT-W3-08 |
| `test_get_dashboard_no_bluetooth` (tests/test_bluetooth_dashboard.py:183) | D02 | `BluetoothDashboardRefreshTests.testRefreshWithoutClientThrows` | BT-W3-08 |
| `test_get_model_info_from_bluetooth` (tests/test_bluetooth_dashboard.py:189) | D03 | `BluetoothDashboardRefreshTests.testModelInfoFromCapabilities` | BT-W3-08 |
| `test_get_dashboard_initializes_missing_widgets` (tests/test_bluetooth_dashboard.py:213) | D04 | `BluetoothDashboardRefreshTests.testRefreshCreatesMissingWidgetsMiniR` | BT-W3-08 |
| `test_get_dashboard_without_steam_level_support` (tests/test_bluetooth_dashboard.py:269) | D05 | `BluetoothDashboardRefreshTests.testRefreshGS3UsesSteamTemperature` | BT-W3-08 |
| `test_get_dashboard_mini_original_temperature_only` (tests/test_bluetooth_dashboard.py:334) | D06 | `BluetoothDashboardRefreshTests.testRefreshOriginalMiniUsesSteamTemperature` | BT-W3-08 |
| `test_set_power_updates_dashboard` (tests/test_bluetooth_dashboard.py:396) | D07 | `BluetoothCommandSideEffectTests.testSetPowerUpdatesModeOnly` | BT-W3-07 |
| `test_set_power_off_updates_dashboard` (tests/test_bluetooth_dashboard.py:414) | D08 | `BluetoothCommandSideEffectTests.testSetPowerOffUpdatesMode` | BT-W3-07 |
| `test_set_steam_updates_dashboard` (tests/test_bluetooth_dashboard.py:436) | D09 | `BluetoothCommandSideEffectTests.testSetSteamUpdatesEnabled` | BT-W3-07 |
| `test_set_coffee_temp_updates_dashboard` (tests/test_bluetooth_dashboard.py:452) | D10 | `BluetoothCommandSideEffectTests.testSetCoffeeTempUpdatesWidget` | BT-W3-07 |
| `test_set_steam_level_updates_dashboard` (tests/test_bluetooth_dashboard.py:470) | D11 | `BluetoothCommandSideEffectTests.testSetSteamLevelUpdatesWidget` | BT-W3-07 |
| `test_set_steam_temp_updates_dashboard` (tests/test_bluetooth_dashboard.py:488) | D12 | `BluetoothCommandSideEffectTests.testSetSteamTempUpdatesWidget` | BT-W3-07 |
| `test_failed_command_does_not_update_dashboard` (tests/test_bluetooth_dashboard.py:506) | D13 (restated, D18) | `BluetoothCommandSideEffectTests.testNonSuccessStatusWithoutCloudThrowsCommandFailed` | BT-W3-07 |
| `test_bluetooth_exception_does_not_update_dashboard` (tests/test_bluetooth_dashboard.py:533) | D14 (restated, D18) | `BluetoothCommandSideEffectTests.testBluetoothErrorWithoutCloudRethrows` | BT-W3-07 |
| `test_get_dashboard_from_bluetooth_statuses` (tests/test_bluetooth_dashboard.py:606) | D15–D19 (5 cases) | `BluetoothDashboardRefreshTests.testStatusDerivation` | BT-W3-08 |
| `test_get_dashboard_from_bluetooth_steam_level` (tests/test_bluetooth_dashboard.py:650) | D20–D25 (6 cases) | `BluetoothEnumsTests.testSteamLevelFromTarget` | BT-W1-01 |
| `test_get_dashboard_from_bluetooth_plumb_in_unsupported` (tests/test_bluetooth_dashboard.py:674) | D26 | `BluetoothDashboardRefreshTests.testPlumbInUnsupportedFallsBackToTank` | BT-W3-08 |
| `test_bluetooth_command_with_cloud_fallback` (tests/test_machine.py:206) | M01–M12 (6 commands × {bluetooth, cloud}) | `BluetoothFallbackTests.testCommandUsesBluetoothThenCloud` | BT-W3-07 |
| `test_failing_command` (tests/test_machine.py:486) | M13 (restated, D18) | `BluetoothFallbackTests.testBothTransportsFailThrowsCloudError` | BT-W3-07 |
| `test_connect_bluetooth_shot_counter` (tests/test_machine.py:745) | M14 | `ShotCounterOverlayTests.testStartIgnoresCloudSupportFlag` | BT-W3-09 |
| `test_register_bluetooth_connection_callback` (tests/test_machine.py:765) | M15 (restated, D4; moved R6) | `BluetoothDeviceStateTests.testBluetoothConnectionEventsForwardOrFinish` | BT-W3-06 |
| `test_shot_counter_overrides_machine_status` (tests/test_machine.py:784) | M16 | `ShotCounterOverlayTests.testOverrideLifecycle` | BT-W3-09 |
| `test_shot_counter_falls_back_to_websocket_callback` (tests/test_machine.py:835) | M17 (restated, D13) | `ShotCounterOverlayTests.testBrewingUpdateRendersObservableDashboard` | BT-W3-09 |
| `test_disconnect_bluetooth_shot_counter` (tests/test_machine.py:853) | M18 | `ShotCounterOverlayTests.testStopRestoresSilently` | BT-W3-09 |
| `test_shot_counter_state_expires` (tests/test_machine.py:882) | M19 | `ShotCounterOverlayTests.testStaleStateExpiresAfter60s` | BT-W3-09 |
| `test_bluetooth_refresh_after_shot_replaces_cloud_status` (tests/test_machine.py:917) | M20 | `ShotCounterOverlayTests.testBluetoothRefreshBecomesBaseline` | BT-W3-09 |
| `test_bluetooth_refresh_while_brewing_keeps_cloud_start_time` (tests/test_machine.py:940) | M21 | `ShotCounterOverlayTests.testBluetoothRefreshKeepsCloudStartTime` | BT-W3-09 |
| `test_bluetooth_telemetry` (tests/test_machine.py:961) | M22 | `ShotCounterOverlayTests.testTelemetryMergeAndModeApply` | BT-W3-09 |
| `test_bluetooth_machine_mode_during_shot` (tests/test_machine.py:995) | M23 | `ShotCounterOverlayTests.testModeDuringShotAppliedAfterShot` | BT-W3-09 |
| `test_bluetooth_machine_mode_falls_back_to_websocket_callback` (tests/test_machine.py:1014) | M24 (restated, D13) | `ShotCounterOverlayTests.testTemperatureTelemetryDoesNotChangeDashboard` | BT-W3-09 |
| `test_bluetooth_shot_counter_active` (tests/test_machine.py:1036) | M25 | `ShotCounterOverlayTests.testShotCounterActiveMirrorsClient` | BT-W3-09 |
| `test_get_model_info_from_bluetooth_errors` (tests/test_machine.py:1049) | M26 | `BluetoothDashboardRefreshTests.testModelInfoErrors` | BT-W3-08 |
| `test_get_model_info_from_bluetooth_unknown_model` (tests/test_machine.py:1063) | M27 (restated) | `BluetoothDashboardRefreshTests.testUnknownFamilyThrowsAndKeepsModel` | BT-W3-08 |
| `test_get_dashboard_from_bluetooth_error` (tests/test_machine.py:1079) | M28 | `BluetoothDashboardRefreshTests.testRefreshErrorPropagatesWithoutMutation` | BT-W3-08 |
| `test_set_power_updates_group_status` (tests/test_machine.py:1089) | M29 | `BluetoothCommandSideEffectTests.testSetPowerUpdatesGroupStatus` | BT-W3-07 |
| `test_set_smart_standby_auto_standby` (tests/test_machine.py:1137) | M30–M31 (2 cases) | `BluetoothFallbackTests.testSmartStandbyUsesCloudAutoStandbyWhenSupported` | BT-W3-07 |
| `test_bluetooth_failure_without_cloud` (tests/test_machine.py:1155) | M32 (restated, D18) | `BluetoothFallbackTests.testBluetoothFailureWithoutCloudRethrows` | BT-W3-07 |
| `test_cloud_only_without_cloud_client` (tests/test_thing.py:29) | T00 (added by plan, R7) | `MachineTransportRoutingTests.testCloudOnlyWithoutCloudClientThrows` | BT-W1-11 |
| `test_connection_properties_without_clients` (tests/test_thing.py:36) | T01 | `BluetoothDeviceStateTests.testPropertiesWithoutClients` | BT-W3-06 |
| `test_connection_properties_with_clients` (tests/test_thing.py:48) | T02 | `BluetoothDeviceStateTests.testPropertiesWithClients` | BT-W3-06 |
| `test_shot_counter_supported` (tests/test_models.py:395) | O01–O03 (true/false already covered by ModelsTests) | `BluetoothEnumsTests.testShotCounterSupportedNull` | BT-W1-01 |
| `test_model_name_from_bluetooth_family` (tests/test_models.py:416) | O04–O07 | `BluetoothEnumsTests.testFamilyMapping` | BT-W1-01 |
| `test_debug_log_masks_bluetooth_token` (tests/test_cloud_client.py:322) | X01 | `BluetoothTokenTests.testTokenDescriptionIsRedacted`, `BluetoothTokenTests.testBluetoothAuthTokenFromThings` | BT-W1-06 |

Angstrom-only tests (the G-* gaps of §3.5 and the divergences D1–D22) are listed under each package's **Tests** in §4.

### 7.3 SPEC file map → owning packages by wave

Every path that any package creates or modifies, in first-touch order. W*n*:c = creates, W*n*:m = modifies.

| Path | Packages (wave order) | Fix owner |
|---|---|---|
| `Sources/Angstrom/Bluetooth/BluetoothConstants.swift` | BT-W0-01:c, BT-W1-01:m | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothTransport.swift` | BT-W0-01:c, BT-W1-01:m | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothAuthToken.swift` | BT-W0-01:c, BT-W1-01:m | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothEnums.swift` | BT-W0-01:c, BT-W1-01:m | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothModels.swift` | BT-W0-01:c, BT-W1-01:m | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothWireCoercion.swift` | BT-W0-01:c, BT-W1-01:m | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothShotCounterModels.swift` | BT-W0-01:c, BT-W1-01:m | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothDiagnostics.swift` | BT-W0-01:c, BT-W1-01:m | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothCodec.swift` | BT-W0-01:c, BT-W1-02:m | BT-W1-02 |
| `Sources/Angstrom/Bluetooth/BluetoothResponseDecoder.swift` | BT-W0-01:c, BT-W1-03:m | BT-W1-03 |
| `Sources/Angstrom/Bluetooth/BrewingStateMachine.swift` | BT-W0-01:c, BT-W1-04:m | BT-W1-04 |
| `Sources/Angstrom/Bluetooth/Dashboard+Bluetooth.swift` | BT-W0-01:c, BT-W1-05:m | BT-W1-05 |
| `Sources/Angstrom/Bluetooth/BluetoothOpTable.swift` | BT-W0-01:c, BT-W1-07:m | BT-W1-07 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient.swift` | BT-W0-01:c, BT-W1-09:m | BT-W1-09 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Requests.swift` | BT-W0-01:c, BT-W2-01:m | BT-W2-01 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+ShotCounter.swift` | BT-W0-01:c, BT-W2-02:m | BT-W2-02 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Discovery.swift` | BT-W0-01:c, BT-W1-10:m | BT-W1-10 |
| `Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift` | BT-W0-01:c, BT-W1-06:m | BT-W1-06 |
| `Sources/AngstromBluetooth/BluetoothTransport+CoreBluetooth.swift` | BT-W0-01:c, BT-W1-08:m | BT-W1-08 |
| `Tests/AngstromTestSupport/AngstromTestSupport.swift` | BT-W0-01:c | BT-W0-01 |
| `Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt` | BT-W0-01:c | BT-W0-01 |
| `Package.swift` | BT-W0-01:m | BT-W0-01 |
| `Sources/Angstrom/Models.swift` | BT-W0-01:m, BT-W1-01:m | BT-W1-01 |
| `Sources/Angstrom/Commands.swift` | BT-W0-01:m | BT-W0-01 |
| `Sources/AngstromUI/MachineBluetoothEvent.swift` | BT-W0-02:c | BT-W0-02 |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothCommands.swift` | BT-W0-02:c, BT-W3-07:m | BT-W3-07 |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothDashboard.swift` | BT-W0-02:c, BT-W3-08:m | BT-W3-08 |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothConnection.swift` | BT-W0-02:c, BT-W3-06:m | BT-W3-06 |
| `Sources/AngstromUI/LaMarzoccoMachine+ShotCounter.swift` | BT-W0-02:c, BT-W3-09:m | BT-W3-09 |
| `Sources/AngstromUI/LaMarzoccoMachine.swift` | BT-W0-02:m, BT-W1-11:m | BT-W1-11 |
| `Tests/AngstromTestSupport/FakeBluetoothCentral.swift` | BT-W0-03:c | BT-W0-03 |
| `Tests/AngstromTestSupport/FakeBluetoothLink.swift` | BT-W0-03:c | BT-W0-03 |
| `Tests/AngstromTestSupport/ManualBluetoothSleeper.swift` | BT-W0-03:c | BT-W0-03 |
| `Tests/AngstromTestSupport/BluetoothTestClock.swift` | BT-W0-03:c | BT-W0-03 |
| `Tests/AngstromTestSupport/BluetoothTestVectors.swift` | BT-W0-03:c | BT-W0-03 |
| `Tests/AngstromTestSupport/ShotCounterRecording.swift` | BT-W0-03:c | BT-W0-03 |
| `Tests/AngstromTests/Bluetooth/FakeBluetoothTests.swift` | BT-W0-03:c | BT-W0-03 |
| `Tests/AngstromTests/Bluetooth/BluetoothEnumsTests.swift` | BT-W0-03:c, BT-W1-01:m | BT-W1-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothWireCoercionTests.swift` | BT-W0-03:c, BT-W1-01:m | BT-W1-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothModelsTests.swift` | BT-W0-03:c, BT-W1-01:m | BT-W1-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothCodecTests.swift` | BT-W0-03:c, BT-W1-02:m | BT-W1-02 |
| `Tests/AngstromTests/Bluetooth/BluetoothResponseDecoderTests.swift` | BT-W0-03:c, BT-W1-03:m | BT-W1-03 |
| `Tests/AngstromTests/Bluetooth/BrewingStateMachineTests.swift` | BT-W0-03:c, BT-W1-04:m | BT-W1-04 |
| `Tests/AngstromTests/Bluetooth/ShotCounterNotificationDecoderTests.swift` | BT-W0-03:c, BT-W1-04:m | BT-W1-04 |
| `Tests/AngstromTests/Bluetooth/DashboardBluetoothTests.swift` | BT-W0-03:c, BT-W1-05:m | BT-W1-05 |
| `Tests/AngstromTests/Bluetooth/BluetoothTokenTests.swift` | BT-W0-03:c, BT-W1-06:m | BT-W1-06 |
| `Tests/AngstromTests/Bluetooth/BluetoothOpTableTests.swift` | BT-W0-03:c, BT-W1-07:m | BT-W1-07 |
| `Tests/AngstromTests/Bluetooth/BluetoothClientCoreTests.swift` | BT-W0-03:c, BT-W1-09:m | BT-W1-09 |
| `Tests/AngstromTests/Bluetooth/BluetoothDiscoveryTests.swift` | BT-W0-03:c, BT-W1-10:m | BT-W1-10 |
| `Tests/AngstromTests/Bluetooth/BluetoothClientRequestsSmokeTests.swift` | BT-W0-03:c, BT-W2-01:m | BT-W2-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothClientShotCounterSmokeTests.swift` | BT-W0-03:c, BT-W2-02:m | BT-W2-02 |
| `Tests/AngstromTests/Bluetooth/BluetoothConnectionTests.swift` | BT-W0-03:c, BT-W3-01:m | BT-W3-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothAuthTests.swift` | BT-W0-03:c, BT-W3-01:m | BT-W3-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothRequestTests.swift` | BT-W0-03:c, BT-W3-02:m | BT-W3-02 |
| `Tests/AngstromTests/Bluetooth/BluetoothDiagnosticsTests.swift` | BT-W0-03:c, BT-W3-02:m | BT-W3-02 |
| `Tests/AngstromTests/Bluetooth/ShotCounterLifecycleTests.swift` | BT-W0-03:c, BT-W3-03:m | BT-W3-03 |
| `Tests/AngstromTests/Bluetooth/ShotCounterNotificationTests.swift` | BT-W0-03:c, BT-W3-04:m | BT-W3-04 |
| `Tests/AngstromTests/Bluetooth/ShotCounterRecordedSessionTests.swift` | BT-W0-03:c, BT-W3-04:m | BT-W3-04 |
| `Tests/AngstromTests/Bluetooth/ShotCounterReconnectTests.swift` | BT-W0-03:c, BT-W3-05:m | BT-W3-05 |
| `Tests/AngstromUITests/Bluetooth/BluetoothMachineHarness.swift` | BT-W0-04:c | BT-W0-04 |
| `Tests/AngstromUITests/Bluetooth/BluetoothMachineHarnessTests.swift` | BT-W0-04:c | BT-W0-04 |
| `Tests/AngstromUITests/Bluetooth/MachineTransportRoutingTests.swift` | BT-W0-04:c, BT-W1-11:m | BT-W1-11 |
| `Tests/AngstromUITests/Bluetooth/BluetoothDeviceStateTests.swift` | BT-W0-04:c, BT-W3-06:m | BT-W3-06 |
| `Tests/AngstromUITests/Bluetooth/BluetoothFallbackTests.swift` | BT-W0-04:c, BT-W3-07:m | BT-W3-07 |
| `Tests/AngstromUITests/Bluetooth/BluetoothCommandSideEffectTests.swift` | BT-W0-04:c, BT-W3-07:m | BT-W3-07 |
| `Tests/AngstromUITests/Bluetooth/BluetoothDashboardRefreshTests.swift` | BT-W0-04:c, BT-W3-08:m | BT-W3-08 |
| `Tests/AngstromUITests/Bluetooth/ShotCounterOverlayTests.swift` | BT-W0-04:c, BT-W3-09:m | BT-W3-09 |
| `Sources/AngstromBluetooth/CoreBluetoothCentral.swift` | BT-W1-08:c | BT-W1-08 |
| `Sources/AngstromBluetooth/CoreBluetoothLink.swift` | BT-W1-08:c | BT-W1-08 |
| `Sources/AngstromBluetooth/Documentation.docc/AngstromBluetooth.md` | BT-W1-08:c | BT-W1-08 |
| `cli/Support/Info.plist` | BT-W1-12:c | BT-W1-12 |
| `cli/Sources/angcli/Ble/Ble.swift` | BT-W1-12:c | BT-W1-12 |
| `cli/Sources/angcli/Ble/BleSession.swift` | BT-W1-12:c, BT-W2-03:m | BT-W2-03 |
| `cli/Sources/angcli/Ble/BleOutput.swift` | BT-W1-12:c, BT-W2-03:m | BT-W2-03 |
| `cli/Sources/angcli/Ble/BleScan.swift` | BT-W1-12:c, BT-W2-04:m | BT-W2-04 |
| `cli/Sources/angcli/Ble/BleGatt.swift` | BT-W1-12:c, BT-W2-04:m | BT-W2-04 |
| `cli/Sources/angcli/Ble/BleToken.swift` | BT-W1-12:c, BT-W2-04:m | BT-W2-04 |
| `cli/Sources/angcli/Ble/BleRead.swift` | BT-W1-12:c, BT-W2-05:m | BT-W2-05 |
| `cli/Sources/angcli/Ble/BleCmd.swift` | BT-W1-12:c, BT-W2-05:m | BT-W2-05 |
| `cli/Sources/angcli/Ble/BleListen.swift` | BT-W1-12:c, BT-W2-06:m | BT-W2-06 |
| `cli/Tests/angcliTests/BleSessionTests.swift` | BT-W1-12:c, BT-W2-03:m | BT-W2-03 |
| `cli/Tests/angcliTests/BleOutputTests.swift` | BT-W1-12:c, BT-W2-03:m | BT-W2-03 |
| `cli/Tests/angcliTests/BleDiscoveryCommandTests.swift` | BT-W1-12:c, BT-W2-04:m | BT-W2-04 |
| `cli/Tests/angcliTests/BleRequestCommandTests.swift` | BT-W1-12:c, BT-W2-05:m | BT-W2-05 |
| `cli/Tests/angcliTests/BleListenTests.swift` | BT-W1-12:c, BT-W2-06:m | BT-W2-06 |
| `cli/Package.swift` | BT-W1-12:m | BT-W1-12 |
| `cli/Sources/angcli/AngCLI.swift` | BT-W1-12:m | BT-W1-12 |
| `cli/Sources/angcli/Output.swift` | BT-W1-12:m | BT-W1-12 |
| `CLAUDE.md` | BT-W2-07:m | BT-W2-07 |
| `UPSTREAM.md` | BT-W2-07:m | BT-W2-07 |
| `.github/workflows/upstream-drift.yml` | BT-W2-07:m | BT-W2-07 |
| `.github/workflows/docs.yml` | BT-W2-07:m | BT-W2-07 |
| `Sources/Angstrom/Documentation.docc/Bluetooth.md` | BT-W2-08:c | BT-W2-08 |
| `README.md` | BT-W2-08:m | BT-W2-08 |
| `Sources/Angstrom/Documentation.docc/Angstrom.md` | BT-W2-08:m | BT-W2-08 |
| `Sources/Angstrom/Documentation.docc/GettingStarted.md` | BT-W2-08:m | BT-W2-08 |
| `Sources/AngstromUI/Documentation.docc/AngstromUI.md` | BT-W2-08:m | BT-W2-08 |
| `cli/SPEC.md` | BT-W2-08:m | BT-W2-08 |
| `cli/README.md` | BT-W2-08:m | BT-W2-08 |

**SPEC §7.1/§10.6/§11 rows → plan:**

| SPEC file-map row | Plan |
|---|---|
| `Package.swift` | BT-W0-01:m |
| `Sources/Angstrom/Models.swift` | BT-W0-01:m, BT-W1-01:m |
| `Sources/Angstrom/Commands.swift` | BT-W0-01:m |
| `Sources/Angstrom/Bluetooth/BluetoothConstants.swift` | BT-W0-01:c, BT-W1-01:m |
| `Sources/Angstrom/Bluetooth/BluetoothTransport.swift` | BT-W0-01:c, BT-W1-01:m |
| `Sources/Angstrom/Bluetooth/BluetoothAuthToken.swift` | BT-W0-01:c, BT-W1-01:m |
| `Sources/Angstrom/Bluetooth/BluetoothEnums.swift` | BT-W0-01:c, BT-W1-01:m |
| `Sources/Angstrom/Bluetooth/BluetoothWireCoercion.swift` | BT-W0-01:c, BT-W1-01:m |
| `Sources/Angstrom/Bluetooth/BluetoothModels.swift` | BT-W0-01:c, BT-W1-01:m |
| `Sources/Angstrom/Bluetooth/BluetoothShotCounterModels.swift` | BT-W0-01:c, BT-W1-01:m |
| `Sources/Angstrom/Bluetooth/BluetoothDiagnostics.swift` | BT-W0-01:c, BT-W1-01:m |
| `Sources/AngstromBluetooth/Placeholder.swift` | not created (R1): BT-W0-01 creates `BluetoothTransport+CoreBluetooth.swift` instead |
| `Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt` | BT-W0-01:c |
| `Tests/AngstromTestSupport/*.swift` | BT-W0-01, BT-W0-03 (see §3.4) |
| `Sources/Angstrom/Bluetooth/BluetoothCodec.swift` | BT-W0-01:c, BT-W1-02:m |
| `Sources/Angstrom/Bluetooth/BluetoothResponseDecoder.swift` | BT-W0-01:c, BT-W1-03:m |
| `Sources/Angstrom/Bluetooth/BrewingStateMachine.swift` | BT-W0-01:c, BT-W1-04:m |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient.swift` | BT-W0-01:c, BT-W1-09:m |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Requests.swift` | BT-W0-01:c, BT-W2-01:m |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+ShotCounter.swift` | BT-W0-01:c, BT-W2-02:m |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Discovery.swift` | BT-W0-01:c, BT-W1-10:m |
| `Sources/Angstrom/Bluetooth/BluetoothOpTable.swift` | BT-W0-01:c, BT-W1-07:m |
| `Sources/AngstromBluetooth/CoreBluetoothCentral.swift` | BT-W1-08:c |
| `Sources/AngstromBluetooth/CoreBluetoothLink.swift` | BT-W1-08:c |
| `Sources/AngstromBluetooth/BluetoothTransport+CoreBluetooth.swift` | BT-W0-01:c, BT-W1-08:m |
| `Sources/AngstromBluetooth/Documentation.docc/AngstromBluetooth.md` | BT-W1-08:c |
| `Sources/Angstrom/Bluetooth/Dashboard+Bluetooth.swift` | BT-W0-01:c, BT-W1-05:m |
| `Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift` | BT-W0-01:c, BT-W1-06:m |
| `Sources/AngstromUI/LaMarzoccoMachine.swift` | BT-W0-02:m, BT-W1-11:m |
| `Sources/AngstromUI/MachineBluetoothEvent.swift` | BT-W0-02:c |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothCommands.swift` | BT-W0-02:c, BT-W3-07:m |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothDashboard.swift` | BT-W0-02:c, BT-W3-08:m |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothConnection.swift` | BT-W0-02:c, BT-W3-06:m |
| `Sources/AngstromUI/LaMarzoccoMachine+ShotCounter.swift` | BT-W0-02:c, BT-W3-09:m |
| `Tests/AngstromTests/Bluetooth/*.swift` | BT-W0-03, BT-W1-01, BT-W1-02, BT-W1-03, BT-W1-04, BT-W1-05, BT-W1-06, BT-W1-07, BT-W1-09, BT-W1-10, BT-W2-01, BT-W2-02, BT-W3-01, BT-W3-02, BT-W3-03, BT-W3-04, BT-W3-05 (see §3.4) |
| `Tests/AngstromUITests/Bluetooth/*.swift` | BT-W0-04, BT-W1-11, BT-W3-06, BT-W3-07, BT-W3-08, BT-W3-09 (see §3.4) |
| `cli/Package.swift` | BT-W1-12:m |
| `cli/Support/Info.plist` | BT-W1-12:c |
| `cli/Sources/angcli/AngCLI.swift` | BT-W1-12:m |
| `cli/Sources/angcli/Output.swift` | BT-W1-12:m |
| `cli/Sources/angcli/Ble/Ble.swift` | BT-W1-12:c |
| `cli/Sources/angcli/Ble/BleSession.swift` | BT-W1-12:c, BT-W2-03:m |
| `cli/Sources/angcli/Ble/BleScan.swift` | BT-W1-12:c, BT-W2-04:m |
| `cli/Sources/angcli/Ble/BleGatt.swift` | BT-W1-12:c, BT-W2-04:m |
| `cli/Sources/angcli/Ble/BleToken.swift` | BT-W1-12:c, BT-W2-04:m |
| `cli/Sources/angcli/Ble/BleRead.swift` | BT-W1-12:c, BT-W2-05:m |
| `cli/Sources/angcli/Ble/BleCmd.swift` | BT-W1-12:c, BT-W2-05:m |
| `cli/Sources/angcli/Ble/BleListen.swift` | BT-W1-12:c, BT-W2-06:m |
| `cli/Sources/angcli/Ble/BleOutput.swift` | BT-W1-12:c, BT-W2-03:m |
| `cli/Tests/angcliTests/BleTests.swift` | split into five files (R8): BT-W2-03 (2), BT-W2-04, BT-W2-05, BT-W2-06; placeholders by BT-W1-12 |
| `cli/SPEC.md` | BT-W2-08:m |
| `cli/README.md` | BT-W2-08:m |
| `Sources/Angstrom/Documentation.docc/Angstrom.md` | BT-W2-08:m |
| `Sources/Angstrom/Documentation.docc/Bluetooth.md` | BT-W2-08:c |
| `Sources/Angstrom/Documentation.docc/GettingStarted.md` | BT-W2-08:m |
| `Sources/AngstromUI/Documentation.docc/AngstromUI.md` | BT-W2-08:m |
| `CLAUDE.md` | BT-W2-07:m |
| `README.md` | BT-W2-08:m |
| `UPSTREAM.md` | BT-W2-07:m |
| `.github/workflows/docs.yml` | BT-W2-07:m |
| `.github/workflows/upstream-drift.yml` | BT-W2-07:m |
| `.github/workflows/ci.yml` | no change (SPEC §11); BT-W2-07 acceptance and BT-W5-01 verify it is unchanged |

---

## 8. Orchestration sketch

### 8.1 Human approval points

| Id | When | What the human decides |
|---|---|---|
| A0 | Before Wave 0 | Approve SPEC, this plan and the owner-decision defaults Q1–Q19 (SPEC §14.1). Then commit the three docs to `bluetooth/integration`. |
| A1 | After the Wave 0 gate | Skim the Wave 0 diff (contracts, fakes, UI declarations, UI harness), about 1 h. Everything later builds on it, so a contract mistake found here is cheap. |
| A2 | On a `SPEC-DEFECT` report (§1.7) | Amend the SPEC, or reject the report. Dependants of the reporting package are paused meanwhile. |
| A3 | On escalation | A fix loop is exhausted (§5.3), a second ownership violation happens (§1.3), or a wave gate still fails after 2 triage rounds. |
| A4 | After BT-W5-01 is PASS | Merge `bluetooth/integration` → `main` as one PR. Cloud-only behaviour is unchanged, so merging does **not** wait for hardware. |
| A5 | After the hardware checklist and release checks (§6, §6.1) | Tag **v2.0.0**, update the `UPSTREAM.md` "Ported" date if needed, and let Pronto adopt `AngstromBluetooth`. **Hardware gates the release, not the merge.** |

**Owner delegation (2026-11-14).** The owner approved the SPEC, this plan and the Q1–Q19 defaults
(A0), and waived the remaining in-flight reviews: the orchestrator decides A1, A2 and A3 itself
and proceeds without waiting. It records every SPEC amendment in the SPEC status line and every
escalation decision in the commit that resolves it. A4 (merging to `main`) and A5 (the hardware
checklist and the release tag) remain the owner's.

### 8.2 Driver pseudocode

```python
m = json.load(open("docs/bluetooth/work-packages.json"))
validate_manifest(m)                       # same checks as the validator in §8.4
human_approve("A0")
git("switch -c bluetooth/integration e1bc403"); commit_docs()

CAP_AGENTS = 12                            # = widest wave; more gives nothing
BUILD_SLOTS = max(2, ncpu() // 4)          # enforced by the PATH wrappers of §1.8, not by this loop
ENV = {"UPSTREAM": ..., "PATH": SLOT_WRAPPER_DIR + ":" + os.environ["PATH"]}   # RESEARCH optional
TIMEOUT = {"S": 45, "M": 90, "L": 180}     # minutes per agent attempt
INTEG = "bluetooth/integration"

for wave in m["waves"]:
    pkgs = sorted((p for p in m["packages"] if p["wave"] == wave["id"]), key=lambda p: p["id"])
    if wave["mode"] in ("dag", "serial"):
        # dag: start every package whose dependencies have all merged; serial: one at a time
        pending, merged = list(pkgs), set()
        while pending:
            ready = [p for p in pending if all(d in merged or wave_of(d) < wave["id"] for d in p["dependsOn"])]
            batch = ready if wave["mode"] == "dag" else ready[:1]
            results = parallel_map(lambda p: run_package(p, base=git_head(INTEG)), batch, limit=CAP_AGENTS)
            for p in batch:                                # id order
                r = results[p["id"]]
                while not r.ok:                            # dependants wait; nothing merges unreviewed
                    human_approve("A3", p, r.findings)     # amend brief/SPEC (A2) or accept a re-run
                    r = run_package(p, base=git_head(INTEG))
                merge(p); merged.add(p["id"]); pending.remove(p)
    else:
        base = git_head(INTEG)
        results = parallel_map(lambda p: run_package(p, base), pkgs, limit=CAP_AGENTS)
        for p in pkgs:                                     # id order
            if results[p["id"]].ok and p["kind"] in ("implement", "docs"): merge(p)
        failed = [p for p in pkgs if p["kind"] in ("implement", "docs") and not results[p["id"]].ok]
        if failed:                                         # escalate at once; never let the gate find it
            human_approve("A3", failed)
            for p in failed:                               # one re-run, on the post-merge HEAD
                results[p["id"]] = r = run_package(p, base=git_head(INTEG))
                if not r.ok: stop_and_escalate("A3", p)    # the wave cannot pass without it
                merge(p)
        defects = blocked_by_reports(results) + verify_findings(results)   # §1.6, §5.3
        run_fix_jobs(group_by_fix_owner(defects))          # serial per file, ≤ 2 rounds each
    assert all_merged(p for p in pkgs if p["kind"] in ("implement", "docs"))   # before any gate run
    for attempt in range(3):
        if run_gate(wave["gate"], fresh_worktree(INTEG)): break
        culprit = bisect_merges(wave)                      # re-run the gate merge by merge
        run_fix_jobs([gate_failure(culprit)])
    else:
        human_approve("A3", wave)
    if wave["id"] == 0: human_approve("A1")

human_approve("A4"); human_runs_hardware_checklist(m["hardwareChecklist"], m["releaseChecks"]); human_approve("A5")


def run_package(p, base):
    if p["kind"] in ("verify", "integrate"):
        wt = disposable_worktree(base)                     # builds allowed; no commits (§1.8)
        out = agent(p["brief"], worktree=wt, env=ENV, timeout=TIMEOUT[p["size"]])
        require_clean(wt)                                  # `git status --porcelain` empty
        return parse_and_check_schema(out)                 # §5.2; FAIL → findings for fix jobs
    wt = new_worktree(p, base)                             # branch bt/<id>
    findings = []
    for round in range(3):                                 # implement + up to 2 fix rounds
        agent(p["brief"] + render(findings), worktree=wt, env=ENV, timeout=TIMEOUT[p["size"]])
        findings = (run_acceptance(p, wt) + check_ownership(p, wt, base)
                    + check_markers(p, wt))                # §1.4 items 1–3
        if findings: continue
        review_wt = disposable_worktree(branch=f"bt/{p['id'].lower()}")
        review = agent(package_review_prompt(p, base), worktree=review_wt, env=ENV)   # §5.1
        require_clean(review_wt)
        findings = [f for f in review["findings"] if f["severity"] != "minor"]
        if not findings: return Ok(review)
    return Fail(findings)
```

### 8.3 Suggested concurrency and expected shape

| Wave | Mode | Packages | Agents in flight | Notes |
|---|---|---|---|---|
| 0 | dag | 4 | ≤ 2 | BT-W0-01, then BT-W0-02 ∥ BT-W0-03, then BT-W0-04. Approval A1 follows it. |
| 1 | parallel | 12 | 12 | The widest implementation wave. BT-W1-09 is on the critical path. |
| 2 | parallel | 12 | 12 | 8 implementers plus 4 area reviewers of Wave 1. |
| 3 | parallel | 10 | 10 | Client parity suites and the AngstromUI layer. |
| 4 | parallel | 6 | 6 | Reviewers only. Their fix jobs follow. |
| 5 | serial | 1 | 1 | Final integration. |

### 8.4 Manifest validation

Before every run, the driver checks the manifest mechanically. The same checks ran when this plan
was written:

- JSON parses; ids are unique.
- Every `dependsOn` id exists, and points to the same or an earlier wave. The dependency graph is
  acyclic.
- In every **parallel** wave, no path appears in two packages' `owns` lists. In the **dag** wave, no
  path appears in two packages that have no dependency path between them (they may run concurrently).
- Every package has a non-empty `brief` and `acceptance`, and every `verify`/`integrate` package
  owns no files.

---

## 9. Risks and sequencing notes

### 9.1 Critical path

The waves are barriers, so the critical path is the dependency chain that holds the longest
package of each wave:

```
BT-W0-01 (L) → BT-W0-03 test support (L; BT-W0-02 (M) runs beside it) → BT-W0-04 UI harness (M)
  → BT-W1-09 client core (L)
  → BT-W2-02 client shot counter (L) → BT-W3-09 UI shot-counter overlay (L)
  → BT-W4-02 device-layer review (L) → BT-W5-01 integration (M)
```

BT-W3-01, BT-W3-04 and BT-W3-07 (all L) run alongside BT-W3-09 and are about as long. A slip in
any of them extends Wave 3. Fix rounds after Wave 4 are the most likely source of extra elapsed
time, so the Wave 2 reviewers exist to catch Wave 1 defects early.

### 9.2 Packages most likely to slip, and why

| Package | Risk | Mitigation |
|---|---|---|
| BT-W0-03 test support, BT-W0-04 UI harness | Every client and UI test depends on fake fidelity. A fake bug ripples through Waves 1–3 as false failures. The fake's default replay (`tick("3.34")`, `TBC:176`) is load-bearing for most shot-counter parity tests. | Self-tests in `FakeBluetoothTests` (including the default replay) and `BluetoothMachineHarnessTests`. Approval A1 includes the fakes. Fake defects use BLOCKED-BY like any other. |
| BT-W1-09 client core | Two FIFO gates on a re-entrant actor; cancellation cleanup; the error-mapping table; the idle task that must not cancel itself. | BT-W2-12 reviews it while Wave 2 runs, and BT-W4-03 runs TSan plus a 5× repeat. |
| BT-W2-02 client shot counter | Reconnect-loop races (D14 availability stream versus the backoff sleep); give-up bookkeeping; the replay flag armed before subscribe. | The smoke tests stay narrow. The parity suites BT-W3-03/04/05 are written independently. |
| BT-W1-08 adapter | It cannot run in CI. Swift 6 region-isolation errors appear only on a full `swift build`. iOS needs `xcodebuild`. | BT-W2-11 reviews concurrency. Hardware items H1–H28 exercise it before release. SPEC §5.4 states every adapter rule; the research sketch (compiled warning-free) is an optional head start only when `$RESEARCH` is provided. |
| BT-W3-04 recorded session | The per-line golden start times were traced by hand (SPEC U22). | Assertions 1–6 of SPEC §9.3.4 are authoritative. On a golden mismatch, the agent reports and does **not** edit the golden to match the code; a human decides (A3). Running upstream (U21/U22) settles it. |
| BT-W3-05 reconnect | C33's restated connect count (8) was flagged by the SPEC author for a second look. | The brief derives the count from SPEC §4.2 + §4.13. A mismatch is a SPEC-DEFECT report, not a silent change. |
| BT-W1-11 UI funnel | It touches about 33 assignment sites in a 774-line file, and all 177 + 15 existing tests must stay green. | The mechanical check counts exactly one `dashboard = ` assignment. BT-W2-10 reviews it. |
| BT-W1-12 / CLI | The `-sectcreate` path in `cli/Package.swift` might resolve relative to the wrong directory. | The fallback `"\(Context.packageDirectory)/Support/Info.plist"` is allowed (same semantics). |
| All | Swift 6.0 compatibility (SPEC U20): the local toolchain may be newer than the 6.0 tools floor. | Reviewers flag 6.1+ features (`Mutex`, `Task.immediate`, isolated conformances, `nonisolated(nonsending)`). CI's Xcode is the arbiter. |
| All | Gate G5 could flag warnings in `Sources/AngstromUI` that existed before this work. BT-W0-01 hits G5 first. | The `BASELINE-WARNING` rule of §1.5: BT-W0-01/02 report them, and the orchestrator excludes them from G5 (A3). |

### 9.3 What can be descoped without breaking a parity claim

Parity claims (SPEC §1.1) cover everything in the §2 inventory. These items are **Angstrom-only**
and can be cut without touching any of them. Each cut still needs approval A2, because some
frozen declarations would become dead code.

| Item | Owner(s) | Effect of cutting |
|---|---|---|
| D14: `.poweredOn` cuts the reconnect backoff short | BT-W2-02, BT-W3-05 | Back to pure upstream backoff. The SPEC stays valid; delete the D14 tests and the UPSTREAM.md row. |
| `gattTable` + `angcli ble gatt` | BT-W1-10, BT-W2-04 | H1 then needs a third-party GATT browser (for example LightBlue). |
| The decoded-event mirrors in `ble listen` | BT-W2-06 | Diagnostics only. `--raw` output is enough for the hardware checklist. (`ble scan --all` is **not** descopable: H10, which settles U3, needs it.) |
| The iOS `xcodebuild` acceptance step | BT-W1-08, BT-W2-11, BT-W5-01 | Only if the CI image lacks the iOS SDK. Then the iOS build is checked by hand before A5. |
| The DocC `Bluetooth.md` article's depth | BT-W2-08 | The README section suffices for v2.0.0. |
| The 5× repeat in BT-W4-03 | BT-W4-03 | Keep at least one TSan run. |

**Not descopable** without changing what v2.0.0 claims: anything in SPEC §2, the six BLE-first
commands and their fallback rules, the shot counter and its reconnect loop, the overlay with its
60 s expiry, byte-exact command frames, BLE-only `LaMarzoccoMachine` (Q3), and the CoreBluetooth
adapter. Without the adapter there is nothing to ship.

### 9.4 Sequencing notes

- **Wave 0 is deliberately front-loaded and dependency-ordered** (a dag: only BT-W0-02 and
  BT-W0-03 overlap). Every later package compiles against its stubs, and every test runs on its
  fakes. Approval A1 is the cheapest place to catch a contract error.
- **The CLI is off the critical path.** Its scaffolding lands in Wave 1, its commands in Wave 2.
  It only needs the frozen API to compile, and its tests never touch a client. The hardware
  checklist needs it, so it must be done before A5, not before A4.
- **Docs are written from the SPEC in Wave 2**, and BT-W4-06 checks them against the final code.
- **Wave 2 reviews Wave 1 while Wave 2 builds on it.** Fixes land on Wave 1 files, which no Wave 2
  package owns, so they never conflict.
- **No package waits on hardware.** Every UNVERIFIED item has an implemented default (SPEC §14.2).
  The hardware checklist (§6) only confirms or amends defaults before release.

---

## Appendix A. Fix-owner table

A finding against a path goes to the **last** implement/docs package (by wave) that owns it. Verify and
integrate packages own nothing. Paths outside this table (existing files that must not change) have no owner.
A finding there is a blocker, and a human (A3) decides.

| Path | Fix owner |
|---|---|
| `.github/workflows/docs.yml` | BT-W2-07 |
| `.github/workflows/upstream-drift.yml` | BT-W2-07 |
| `CLAUDE.md` | BT-W2-07 |
| `Package.swift` | BT-W0-01 |
| `README.md` | BT-W2-08 |
| `Sources/Angstrom/Bluetooth/BluetoothAuthToken.swift` | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothCodec.swift` | BT-W1-02 |
| `Sources/Angstrom/Bluetooth/BluetoothConstants.swift` | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothDiagnostics.swift` | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothEnums.swift` | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothModels.swift` | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothOpTable.swift` | BT-W1-07 |
| `Sources/Angstrom/Bluetooth/BluetoothResponseDecoder.swift` | BT-W1-03 |
| `Sources/Angstrom/Bluetooth/BluetoothShotCounterModels.swift` | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothTransport.swift` | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BluetoothWireCoercion.swift` | BT-W1-01 |
| `Sources/Angstrom/Bluetooth/BrewingStateMachine.swift` | BT-W1-04 |
| `Sources/Angstrom/Bluetooth/Dashboard+Bluetooth.swift` | BT-W1-05 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Discovery.swift` | BT-W1-10 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+Requests.swift` | BT-W2-01 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient+ShotCounter.swift` | BT-W2-02 |
| `Sources/Angstrom/Bluetooth/LaMarzoccoBluetoothClient.swift` | BT-W1-09 |
| `Sources/Angstrom/Commands.swift` | BT-W0-01 |
| `Sources/Angstrom/Documentation.docc/Angstrom.md` | BT-W2-08 |
| `Sources/Angstrom/Documentation.docc/Bluetooth.md` | BT-W2-08 |
| `Sources/Angstrom/Documentation.docc/GettingStarted.md` | BT-W2-08 |
| `Sources/Angstrom/LaMarzoccoCloudClient+BluetoothToken.swift` | BT-W1-06 |
| `Sources/Angstrom/Models.swift` | BT-W1-01 |
| `Sources/AngstromBluetooth/BluetoothTransport+CoreBluetooth.swift` | BT-W1-08 |
| `Sources/AngstromBluetooth/CoreBluetoothCentral.swift` | BT-W1-08 |
| `Sources/AngstromBluetooth/CoreBluetoothLink.swift` | BT-W1-08 |
| `Sources/AngstromBluetooth/Documentation.docc/AngstromBluetooth.md` | BT-W1-08 |
| `Sources/AngstromUI/Documentation.docc/AngstromUI.md` | BT-W2-08 |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothCommands.swift` | BT-W3-07 |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothConnection.swift` | BT-W3-06 |
| `Sources/AngstromUI/LaMarzoccoMachine+BluetoothDashboard.swift` | BT-W3-08 |
| `Sources/AngstromUI/LaMarzoccoMachine+ShotCounter.swift` | BT-W3-09 |
| `Sources/AngstromUI/LaMarzoccoMachine.swift` | BT-W1-11 |
| `Sources/AngstromUI/MachineBluetoothEvent.swift` | BT-W0-02 |
| `Tests/AngstromTestSupport/AngstromTestSupport.swift` | BT-W0-01 |
| `Tests/AngstromTestSupport/BluetoothTestClock.swift` | BT-W0-03 |
| `Tests/AngstromTestSupport/BluetoothTestVectors.swift` | BT-W0-03 |
| `Tests/AngstromTestSupport/FakeBluetoothCentral.swift` | BT-W0-03 |
| `Tests/AngstromTestSupport/FakeBluetoothLink.swift` | BT-W0-03 |
| `Tests/AngstromTestSupport/Fixtures/shot_counter_2026-10-05.txt` | BT-W0-01 |
| `Tests/AngstromTestSupport/ManualBluetoothSleeper.swift` | BT-W0-03 |
| `Tests/AngstromTestSupport/ShotCounterRecording.swift` | BT-W0-03 |
| `Tests/AngstromTests/Bluetooth/BluetoothAuthTests.swift` | BT-W3-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothClientCoreTests.swift` | BT-W1-09 |
| `Tests/AngstromTests/Bluetooth/BluetoothClientRequestsSmokeTests.swift` | BT-W2-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothClientShotCounterSmokeTests.swift` | BT-W2-02 |
| `Tests/AngstromTests/Bluetooth/BluetoothCodecTests.swift` | BT-W1-02 |
| `Tests/AngstromTests/Bluetooth/BluetoothConnectionTests.swift` | BT-W3-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothDiagnosticsTests.swift` | BT-W3-02 |
| `Tests/AngstromTests/Bluetooth/BluetoothDiscoveryTests.swift` | BT-W1-10 |
| `Tests/AngstromTests/Bluetooth/BluetoothEnumsTests.swift` | BT-W1-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothModelsTests.swift` | BT-W1-01 |
| `Tests/AngstromTests/Bluetooth/BluetoothOpTableTests.swift` | BT-W1-07 |
| `Tests/AngstromTests/Bluetooth/BluetoothRequestTests.swift` | BT-W3-02 |
| `Tests/AngstromTests/Bluetooth/BluetoothResponseDecoderTests.swift` | BT-W1-03 |
| `Tests/AngstromTests/Bluetooth/BluetoothTokenTests.swift` | BT-W1-06 |
| `Tests/AngstromTests/Bluetooth/BluetoothWireCoercionTests.swift` | BT-W1-01 |
| `Tests/AngstromTests/Bluetooth/BrewingStateMachineTests.swift` | BT-W1-04 |
| `Tests/AngstromTests/Bluetooth/DashboardBluetoothTests.swift` | BT-W1-05 |
| `Tests/AngstromTests/Bluetooth/FakeBluetoothTests.swift` | BT-W0-03 |
| `Tests/AngstromTests/Bluetooth/ShotCounterLifecycleTests.swift` | BT-W3-03 |
| `Tests/AngstromTests/Bluetooth/ShotCounterNotificationDecoderTests.swift` | BT-W1-04 |
| `Tests/AngstromTests/Bluetooth/ShotCounterNotificationTests.swift` | BT-W3-04 |
| `Tests/AngstromTests/Bluetooth/ShotCounterReconnectTests.swift` | BT-W3-05 |
| `Tests/AngstromTests/Bluetooth/ShotCounterRecordedSessionTests.swift` | BT-W3-04 |
| `Tests/AngstromUITests/Bluetooth/BluetoothCommandSideEffectTests.swift` | BT-W3-07 |
| `Tests/AngstromUITests/Bluetooth/BluetoothDashboardRefreshTests.swift` | BT-W3-08 |
| `Tests/AngstromUITests/Bluetooth/BluetoothDeviceStateTests.swift` | BT-W3-06 |
| `Tests/AngstromUITests/Bluetooth/BluetoothFallbackTests.swift` | BT-W3-07 |
| `Tests/AngstromUITests/Bluetooth/BluetoothMachineHarness.swift` | BT-W0-04 |
| `Tests/AngstromUITests/Bluetooth/BluetoothMachineHarnessTests.swift` | BT-W0-04 |
| `Tests/AngstromUITests/Bluetooth/MachineTransportRoutingTests.swift` | BT-W1-11 |
| `Tests/AngstromUITests/Bluetooth/ShotCounterOverlayTests.swift` | BT-W3-09 |
| `UPSTREAM.md` | BT-W2-07 |
| `cli/Package.swift` | BT-W1-12 |
| `cli/README.md` | BT-W2-08 |
| `cli/SPEC.md` | BT-W2-08 |
| `cli/Sources/angcli/AngCLI.swift` | BT-W1-12 |
| `cli/Sources/angcli/Ble/Ble.swift` | BT-W1-12 |
| `cli/Sources/angcli/Ble/BleCmd.swift` | BT-W2-05 |
| `cli/Sources/angcli/Ble/BleGatt.swift` | BT-W2-04 |
| `cli/Sources/angcli/Ble/BleListen.swift` | BT-W2-06 |
| `cli/Sources/angcli/Ble/BleOutput.swift` | BT-W2-03 |
| `cli/Sources/angcli/Ble/BleRead.swift` | BT-W2-05 |
| `cli/Sources/angcli/Ble/BleScan.swift` | BT-W2-04 |
| `cli/Sources/angcli/Ble/BleSession.swift` | BT-W2-03 |
| `cli/Sources/angcli/Ble/BleToken.swift` | BT-W2-04 |
| `cli/Sources/angcli/Output.swift` | BT-W1-12 |
| `cli/Support/Info.plist` | BT-W1-12 |
| `cli/Tests/angcliTests/BleDiscoveryCommandTests.swift` | BT-W2-04 |
| `cli/Tests/angcliTests/BleListenTests.swift` | BT-W2-06 |
| `cli/Tests/angcliTests/BleOutputTests.swift` | BT-W2-03 |
| `cli/Tests/angcliTests/BleRequestCommandTests.swift` | BT-W2-05 |
| `cli/Tests/angcliTests/BleSessionTests.swift` | BT-W2-03 |
