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
reports it as `minor`, with `"summary": "UNVERIFIED: …"`. In `cli/`, an `internal` declaration in an
owned file that exists so `@testable` tests can reach a decision (for example the mapping from an
event to an exit) is not a finding, even where a brief says "tests are parsing only".

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

