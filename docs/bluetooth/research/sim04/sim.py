"""Standalone re-implementation of upstream _BrewingTracker + telemetry split
(clients/_bluetooth.py:77-111,441-465; models/_bluetooth.py:73-213) used only to
derive golden per-notification outputs for the recorded fixture."""
import json, sys, itertools
from datetime import datetime, date, timedelta, timezone

BREW = {"BrewingStartedGroup1DoseIndex":"started_dose_index","BrewingUpdateGroup1Ev":"ev",
"BrewingUpdateGroup1Backflush":"backflush","BrewingUpdateGroup1Time":"brewing_time",
"FlushStoppedGroup1Time":"flush_stopped_time","FlushStoppedGroup1DoseIndex":"flush_stopped_dose_index",
"BrewingStoppedGroup1Time":"brewing_stopped_time","BrewingStoppedGroup1DoseIndex":"brewing_stopped_dose_index",
"BrewingStoppedGroup1StopType":"brewing_stopped_stop_type","BrewingStoppedGroup1StopReason":"brewing_stopped_stop_reason"}
TEL = {"CoffeeBoiler1UpdateTemperature":"coffee","SteamBoilerUpdateTemperature":"steam","MachineMode":"mode","Sleep":"sleep","MachineStatistics":"stats"}
MODES = {"BrewingMode","EcoMode","StandBy"}

def derive(d, at):
    if any(d.get(k) is not None for k in ("brewing_stopped_time","brewing_stopped_dose_index","brewing_stopped_stop_type","brewing_stopped_stop_reason")) or d.get("ev") is False:
        s="BrewingStopped"
    elif d.get("flush_stopped_time") is not None or d.get("flush_stopped_dose_index") is not None:
        s="Flushed"
    elif d.get("backflush") is True:
        s="Backflushing"
    elif d.get("started_dose_index") is not None or (d.get("ev") is True and d.get("brewing_time") is not None):
        s="Brewing"
    else:
        return None
    timer = (d.get("brewing_time") or 0.0) if s=="Brewing" else None
    u = dict(state=s, timer=timer, final=d.get("brewing_stopped_time"), dose=d.get("started_dose_index"),
             reason=d.get("brewing_stopped_stop_reason"), at=at, start=None)
    if s=="Brewing" and timer is not None:
        u["start"] = at - timedelta(seconds=timer)
    return u

class Tracker:
    def __init__(s): s.d={}; s.start=None
    def process(s, msg, at):
        if msg.get("started_dose_index") is not None: s.d={}; s.start=None
        s.d = {**s.d, **{k:v for k,v in msg.items() if v is not None}}
        u = derive(s.d, at)
        if u is None: return None
        if u["state"] in ("Flushed","BrewingStopped"): s.d={}; s.start=None
        elif u["start"] is not None:
            if s.start is None or u["start"] < s.start: s.start=u["start"]
            u["start"]=s.start
        return u

def load(path, day):
    sessions=[]
    for line in open(path).read().splitlines():
        if line.startswith("#"): continue
        t,p=line.split(" ",1)
        at=datetime.combine(day, datetime.strptime(t,"%H:%M:%S.%f").time(), timezone.utc)
        if p.endswith("# replay"):
            sessions.append([(at,p[:-len("# replay")].strip()),[]])
        else:
            sessions[-1][1].append((at,p))
    return sessions

sessions = load(sys.argv[1], date(2026,10,5))
updates=[]; tel=[]
for si,(replay,notes) in enumerate(sessions, start=1):
    tr=Tracker()
    print(f"--- session {si}: replay dropped at {replay[0]:%H:%M:%S.%f}: {replay[1]}")
    for at,p in notes:
        payload=json.loads(p.encode().strip(b"\x00"))
        b={BREW[k]:v for k,v in payload.items() if k in BREW}
        t={}
        for k,v in payload.items():
            if k in TEL:
                if k=="MachineMode": v = v if v in MODES else None
                if k=="MachineStatistics": v = json.loads(v)
                if v is not None: t[TEL[k]]=v
        out=[]
        if b:
            u=tr.process(b,at)
            if u:
                updates.append(u)
                out.append(f"SHOT state={u['state']} timer={u['timer']} final={u['final']} dose={u['dose']} reason={u['reason']} start={u['start'].strftime('%H:%M:%S.%f') if u['start'] else None}")
        if t:
            tel.append(t)
            tt={k:(('{tot_doses:%s,...}'%v['tot_doses']) if k=='stats' else v) for k,v in t.items()}
            out.append(f"TELEMETRY {tt}")
        print(f"{at:%H:%M:%S.%f}"[:-3], "|", "; ".join(out) if out else "(no callback)")
print("groupby:", [(s,len(list(g))) for s,g in itertools.groupby(u['state'] for u in updates)])
print("starts:", [f"{u['at']:%H:%M:%S.%f}"[:-3] for u in updates if u['timer']==0.0])
merged={}
for t in tel: merged.update(t)
print("merged:", {k:(v if k!='stats' else v['tot_doses']) for k,v in merged.items()})
print("modes:", [t['mode'] for t in tel if 'mode' in t])
