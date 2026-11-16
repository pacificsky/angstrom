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
