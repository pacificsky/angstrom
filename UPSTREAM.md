# Upstream porting watermark

Angstrom is an independent Swift port of the **cloud** protocol and authentication
from [`pylamarzocco`](https://github.com/zweckj/pylamarzocco) by Josef Zweck.
The Python source is the reference of record — see [CLAUDE.md](CLAUDE.md). This
file records exactly how far that port has been carried, so we can tell what is
already ported from what still needs picking up.

## Ported through

<!-- The two markers below are parsed by .github/workflows/upstream-drift.yml.
     Keep the format `key: value` on a single line; update both in the same PR
     that lands the port. -->

<!-- upstream-version: v2.3.0 -->
<!-- upstream-sha: a267213 -->

| | |
|---|---|
| **Upstream** | https://github.com/zweckj/pylamarzocco |
| **Version** | `v2.3.0` |
| **Commit** | [`a267213`](https://github.com/zweckj/pylamarzocco/commit/a267213) |
| **Ported** | 2026-06-26 |
| **Scope** | Cloud protocol, auth/proof, models, websocket, commands, statistics. Bluetooth is excluded by design and is **not** tracked here. |

As of this watermark the full cloud surface of `v2.3.0` is ported — there is no
known cloud gap below this line. (Bluetooth-only changes upstream are out of
scope and never advance this watermark.)

## Syncing to a newer upstream

When `pylamarzocco` publishes changes past the watermark above (the drift-check
workflow opens a tracking issue when it does), follow this runbook:

```bash
# 1. Get upstream locally (clone once, or `git fetch` an existing checkout).
git clone https://github.com/zweckj/pylamarzocco /tmp/pylamarzocco   # first time
git -C /tmp/pylamarzocco fetch --tags origin                          # thereafter

# 2. See what landed since the watermark.
git -C /tmp/pylamarzocco log --oneline a267213..v2.4.0                # replace with target tag
git -C /tmp/pylamarzocco diff a267213..v2.4.0 -- pylamarzocco/        # the review surface

# 3. Triage each change:
#    - cloud / auth / proof / models / websocket / commands / stats  -> port to Swift
#    - Bluetooth-only                                                 -> skip (out of scope)
```

Then, **in the same PR that lands the port**:

1. Port the relevant changes, matching the Python wire-shape/decoding exactly.
2. Bump **both** `upstream-version` and `upstream-sha` markers above, and the
   table (Version / Commit / Ported / Scope notes), to the new target.
3. `swift build && swift test` must pass.
4. Close the drift tracking issue (or let the next bump's PR reference it).

> Verify the SHA matches the tag: `a267213` should be the commit that
> `v2.3.0` points to (`git -C /tmp/pylamarzocco rev-parse v2.3.0`). Always record
> the **tagged release** commit, not an arbitrary `main` SHA, so the watermark
> corresponds to a real upstream version.
