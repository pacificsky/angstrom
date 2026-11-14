# Bluetooth port — planning documents

Planning material for bringing Angstrom to full Bluetooth parity with `pylamarzocco`
v2.5.6 (`4c639ee`), targeting Angstrom **v2.0.0**. Nothing here is built by SwiftPM.

| Path | What it is |
|---|---|
| [`SPEC.md`](SPEC.md) | The frozen specification: scope, parity inventory, wire protocol, behaviour, architecture, Swift API contracts, testing strategy, divergences, open questions. Hand-edited. |
| [`PLAN.md`](PLAN.md) | The implementation plan for parallel agents: execution model, waves, work packages, verification, hardware checklist, coverage tables. **Generated — do not edit by hand.** |
| [`work-packages.json`](work-packages.json) | Machine-readable manifest of the same plan (waves, packages, file ownership, briefs, acceptance commands). **Generated — do not edit by hand.** |
| [`tools/`](tools) | The generator and validator for `PLAN.md` and `work-packages.json`. |
| [`research/`](research) | The six research notes the spec was written from, plus the probe scripts and CoreBluetooth sketches they cite. Provenance only: the spec is self-sufficient, and where a note and the spec disagree, the spec wins. |

## Changing the plan

`PLAN.md` and `work-packages.json` are generated from one source so they cannot drift apart.
Edit `tools/packages.py` (the work packages) or the `tools/frag_*.md` fragments (the prose
sections), then regenerate and validate from the repo root:

```sh
python3 docs/bluetooth/tools/gen.py        # rewrites PLAN.md and work-packages.json
python3 docs/bluetooth/tools/validate.py   # manifest checks + PLAN.md/manifest consistency
```

The validator checks that the manifest parses, ids are unique, dependencies exist and are
acyclic, no file is owned by two packages that can run concurrently, every package has a
brief and acceptance commands, every upstream Bluetooth test is owned exactly once, and
`PLAN.md` agrees with the manifest.

## Path placeholders in the research notes

The notes were written against local checkouts; machine-specific paths were replaced with:

- `$UPSTREAM` — a `pylamarzocco` clone at `4c639ee`
- `$REPO` — the Angstrom repo root
- `$PRONTO` — a checkout of the Pronto app
- `$VENV` — a throwaway Python venv with upstream's dependencies installed
- `$SCRATCH` — a temporary working directory that no longer exists
