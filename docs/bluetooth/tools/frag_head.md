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
@@G5@@
# G5' — the same for the angcli Bluetooth files:
@@G5CLI@@
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
   `try XCTSkipIf(true, "BLOCKED-BY <owner-id>: <one line>")` (not a bare `throw XCTSkip(…)`: the
   code after it draws an unreachable-code warning, which fails G5);
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
