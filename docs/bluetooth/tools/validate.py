"""Mechanical validation of work-packages.json + PLAN.md (argv[1] = dir holding both, default docs/bluetooth; repo root derived from this file)."""
import json, os, re, sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))  # repo root
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs/bluetooth")
errors = []
m = json.load(open(os.path.join(D, "work-packages.json")))                     # parses
plan = open(os.path.join(D, "PLAN.md")).read()
for k in ("meta", "waves", "packages", "hardwareChecklist", "releaseChecks"):
    if k not in m: errors.append(f"missing top-level key {k}")
waves = {w["id"]: w for w in m["waves"]}
for w in m["waves"]:
    if w.get("mode") not in ("serial", "parallel", "dag"): errors.append(f"wave {w['id']} bad mode")
    if not w.get("gate"): errors.append(f"wave {w['id']} has no gate")
pk = {}
for p in m["packages"]:
    if p["id"] in pk: errors.append(f"duplicate id {p['id']}")                    # unique ids
    pk[p["id"]] = p
    for key in ("id", "title", "wave", "kind", "size", "dependsOn", "owns", "specRefs", "upstreamRefs", "tests", "acceptance", "brief"):
        if key not in p: errors.append(f"{p['id']} missing {key}")
    if p["wave"] not in waves: errors.append(f"{p['id']} unknown wave")
    if not p.get("brief", "").strip(): errors.append(f"{p['id']} empty brief")
    if not p.get("acceptance") or not all(a.strip() for a in p["acceptance"]): errors.append(f"{p['id']} empty acceptance")
    if p["kind"] in ("verify", "integrate") and (p["owns"]["create"] or p["owns"]["modify"]): errors.append(f"{p['id']} owns files")
    if not p["id"].startswith(f"BT-W{p['wave']}-"): errors.append(f"{p['id']} id/wave mismatch")
    for a in p["acceptance"]:
        if a not in p["brief"]: errors.append(f"{p['id']} acceptance not in brief: {a[:50]}")
for p in m["packages"]:                                                         # deps exist, same-or-earlier wave
    for d in p["dependsOn"]:
        if d not in pk: errors.append(f"{p['id']} depends on unknown {d}")
        elif pk[d]["wave"] > p["wave"]: errors.append(f"{p['id']} depends on later-wave {d}")
        elif pk[d]["wave"] == p["wave"] and waves[p["wave"]]["mode"] == "parallel": errors.append(f"{p['id']} depends on same parallel wave {d}")
state = {}
def visit(n, stack):                                                            # acyclic
    if state.get(n) == 1: errors.append("cycle: " + " -> ".join(stack + [n])); return
    if state.get(n) == 2: return
    state[n] = 1
    for d in pk[n]["dependsOn"]:
        if d in pk: visit(d, stack + [n])
    state[n] = 2
for n in pk: visit(n, [])
def reach(a):
    out, todo = set(), list(pk[a]["dependsOn"])
    while todo:
        x = todo.pop()
        if x not in out: out.add(x); todo += pk[x]["dependsOn"]
    return out
R = {n: reach(n) for n in pk}
for wid, w in waves.items():                                                    # no path owned twice where concurrent
    ps = [q for q in m["packages"] if q["wave"] == wid]
    for i, a in enumerate(ps):
        pa = a["owns"]["create"] + a["owns"]["modify"]
        if len(pa) != len(set(pa)): errors.append(f"{a['id']} lists a path twice")
        for b in ps[i + 1:]:
            common = set(pa) & set(b["owns"]["create"] + b["owns"]["modify"])
            if not common: continue
            concurrent = w["mode"] == "parallel" or (w["mode"] == "dag" and a["id"] not in R[b["id"]] and b["id"] not in R[a["id"]])
            if concurrent: errors.append(f"wave {wid} ({w['mode']}): {sorted(common)} owned by {a['id']} and {b['id']}")
created_by = {}
for p in sorted(m["packages"], key=lambda q: (q["wave"], q["id"])):
    for path in p["owns"]["create"]:
        if path in created_by: errors.append(f"{path} created twice")
        if os.path.exists(os.path.join(ROOT, path)): errors.append(f"{p['id']} creates existing {path}")
        created_by[path] = p["id"]
for p in m["packages"]:
    for path in p["owns"]["modify"]:
        if os.path.exists(os.path.join(ROOT, path)): continue
        c = created_by.get(path)
        if c is None: errors.append(f"{p['id']} modifies missing {path}")
        elif c != p["id"] and c not in R[p["id"]]: errors.append(f"{p['id']} modifies {path} created by {c} without depending on it")
ids_plan = set(re.findall(r"\bBT-W\d-\d\d\b", plan))                            # PLAN mentions every id, no extras
for pid in pk:
    if pid not in ids_plan: errors.append(f"PLAN.md never mentions {pid}")
for pid in sorted(ids_plan - set(pk)): errors.append(f"PLAN.md mentions {pid}, absent from manifest")
dep_rows = dict(re.findall(r"^\| (BT-W\d-\d\d) \| ([^|]+) \|$", plan, re.M))
for pid, p in pk.items():
    if f"#### {pid} — {p['title']}" not in plan: errors.append(f"PLAN.md lacks heading for {pid}"); continue
    deps = [] if dep_rows.get(pid, "").strip() == "—" else [x.strip() for x in dep_rows.get(pid, "").split(",")]
    if sorted(deps) != sorted(p["dependsOn"]): errors.append(f"PLAN.md deps for {pid} differ")
    sec = plan.split(f"#### {pid} — ", 1)[1].split("\n#### ", 1)[0]
    for path in p["owns"]["create"] + p["owns"]["modify"]:
        if f"`{path}`" not in sec: errors.append(f"PLAN.md {pid} lacks owned path {path}")
    if f"| {p['wave']} | {p['kind']} | {p['size']} |" not in sec: errors.append(f"PLAN.md {pid} wave/kind/size differs")
    for a in p["acceptance"]:
        if "  " + a not in sec: errors.append(f"PLAN.md {pid} lacks acceptance {a[:50]}")
    for t in p["tests"]:
        if t not in sec: errors.append(f"PLAN.md {pid} lacks test {t[:50]}")
rows = re.findall(r"^\| `(test_[a-z0-9_]+)` \(tests/[a-z_]+\.py:(\d+)\) \| [^|]+ \| [^|]+ \| (BT-W\d-\d\d) \|$", plan, re.M)
fns = [r[0] for r in rows]
if {f for f in fns if fns.count(f) > 1}: errors.append("upstream test owned twice")
for _, _, o in rows:
    if o not in pk: errors.append(f"§7.2 owner {o} unknown")
names = {}                                                                      # Class.method unique across packages
for p in m["packages"]:
    for t in p["tests"]:
        for cm in re.findall(r"\b([A-Z][A-Za-z]+Tests\.test[A-Za-z0-9_]+)", t):
            names.setdefault(cm, set()).add(p["id"])
for cm, owners in names.items():
    if len(owners) > 1: errors.append(f"test {cm} listed by {sorted(owners)}")
meth = {}
for cm in names: meth.setdefault(cm.split(".")[1], set()).add(cm.split(".")[0])
for mth, cls in meth.items():
    if len(cls) > 1: errors.append(f"method name {mth} used in classes {sorted(cls)}")
print(f"packages={len(pk)} waves={len(waves)} upstream-test rows={len(rows)} hardware={len(m['hardwareChecklist'])} releaseChecks={len(m['releaseChecks'])}")
for wid, w in waves.items():
    print(f"  wave {wid} {w['mode']:8s} {sum(1 for p in m['packages'] if p['wave'] == wid):2d} packages")
if errors:
    print("ERRORS:"); [print(" -", e) for e in errors]; sys.exit(1)
print("OK: manifest valid; PLAN.md consistent")
