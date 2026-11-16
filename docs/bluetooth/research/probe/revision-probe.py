import sys, json
sys.path.insert(0, sys.argv[1])
from pylamarzocco.models._bluetooth import *
from pylamarzocco.clients._bluetooth import _BrewingTracker
from datetime import datetime, timezone
def t(label, f):
    try: print(label, "->", repr(f()))
    except Exception as e: print(label, "!!", type(e).__name__, e)
t("ssb minutes 1e300", lambda: BluetoothSmartStandbyDetails.from_dict(json.loads('{"mode":"PowerOn","minutes":1e300,"enabled":true}')).minutes > 2**63)
t("ssb minutes 12345678901234567890", lambda: BluetoothSmartStandbyDetails.from_dict(json.loads('{"mode":"PowerOn","minutes":12345678901234567890,"enabled":true}')))
t("cap family 5", lambda: BluetoothMachineCapabilities.from_dict({"family":5,"groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":False,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":[],"schedulingType":"x"}))
t("tel inf str", lambda: BluetoothMachineTelemetry.from_dict(json.loads('{"CoffeeBoiler1UpdateTemperature":"inf"}')))
t("tel NaN literal", lambda: BluetoothMachineTelemetry.from_dict(json.loads('{"CoffeeBoiler1UpdateTemperature":NaN}')))
t("stats null str + temp", lambda: BluetoothMachineTelemetry.from_dict(json.loads('{"MachineStatistics":"null","CoffeeBoiler1UpdateTemperature":90}')))
t("stats '5'", lambda: BluetoothMachineTelemetry.from_dict(json.loads('{"MachineStatistics":"5"}')))
t("stats true", lambda: BluetoothMachineTelemetry.from_dict(json.loads('{"MachineStatistics":true}')))
t("stats bad str", lambda: BluetoothMachineTelemetry.from_dict(json.loads('{"MachineStatistics":"{bad"}')))
tr = _BrewingTracker(); now = datetime(2026,1,1,tzinfo=timezone.utc)
t("trk started", lambda: tr.process(BluetoothBrewingData.from_dict({"BrewingStartedGroup1DoseIndex":"DoseA"}), now).state)
t("trk nan", lambda: tr.process(BluetoothBrewingData.from_dict({"BrewingUpdateGroup1Time":"nan","BrewingUpdateGroup1Ev":True}), now))
t("trk data after nan", lambda: tr._data)
tr2 = _BrewingTracker()
t("trk2 started", lambda: tr2.process(BluetoothBrewingData.from_dict({"BrewingStartedGroup1DoseIndex":"DoseA"}), now).state)
t("trk2 ev []", lambda: tr2.process(BluetoothBrewingData.from_dict({"BrewingUpdateGroup1Ev":[]}), now).state)
t("dose list derive", lambda: BluetoothBrewingData.from_dict({"BrewingStartedGroup1DoseIndex":["a"]}).derive_state(now))
