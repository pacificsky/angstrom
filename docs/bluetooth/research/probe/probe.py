import json, sys
import types
import os; sys.path.insert(0, os.environ['SITE_PACKAGES'])  # a venv with mashumaro 3.17 installed
pkg = types.ModuleType('pylamarzocco'); pkg.__path__ = [sys.argv[1] + '/pylamarzocco']; sys.modules['pylamarzocco'] = pkg
from pylamarzocco.models import BluetoothSmartStandbyDetails, BluetoothBoilerDetails, BluetoothCommandStatus, BluetoothMachineCapabilities
from pylamarzocco.const import MachineMode, ModelName
def t(label, f):
    try: print(label, "->", repr(f()))
    except Exception as e: print(label, "-> EXC", type(e).__name__, e)
t("ssb enabled 'true'", lambda: BluetoothSmartStandbyDetails.from_dict({"mode":"PowerOn","minutes":42,"enabled":"true"}))
t("ssb enabled 'false'", lambda: BluetoothSmartStandbyDetails.from_dict({"mode":"PowerOn","minutes":42,"enabled":"false"}))
t("ssb enabled false", lambda: BluetoothSmartStandbyDetails.from_dict({"mode":"LastBrewing","minutes":"42","enabled":False}))
t("boiler float target", lambda: BluetoothBoilerDetails.from_dict({"id":"CoffeeBoiler1","isEnabled":True,"target":93.5,"current":65.9}))
t("boiler str isEnabled 'false'", lambda: BluetoothBoilerDetails.from_dict({"id":"CoffeeBoiler1","isEnabled":"false","target":93,"current":65}))
t("boiler unknown id", lambda: BluetoothBoilerDetails.from_dict({"id":"CoffeeBoiler2","isEnabled":True,"target":93,"current":65}))
t("cmd status missing message", lambda: BluetoothCommandStatus.from_json('{"id":"x","status":"success"}'))
t("cmd status extra key", lambda: BluetoothCommandStatus.from_json('{"id":"x","message":"m","status":"success","extra":1}'))
t("cmd status numeric id", lambda: BluetoothCommandStatus.from_json('{"id":5,"message":"m","status":"success"}'))
t("caps unknown mode", lambda: BluetoothMachineCapabilities.from_dict({"family":"MICRA","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":False,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":["BrewingMode","Foo"],"schedulingType":"x"}))
t("caps EcoMode", lambda: BluetoothMachineCapabilities.from_dict({"family":"lineamini2023","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":False,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":["BrewingMode","EcoMode","StandBy"],"schedulingType":"x"}))
t("caps unknown family", lambda: BluetoothMachineCapabilities.from_dict({"family":"STRADA","groupsNumber":1,"coffeeBoilersNumber":1,"hasCupWarmer":False,"steamBoilersNumber":1,"teaDosesNumber":0,"machineModes":[],"schedulingType":"x"}))
t("MachineMode('Off')", lambda: MachineMode("Off"))
for name in ["GS3","LINEA","Linea Mini","linea micra","MINI","GS3 AV","LINEAMINI2023"]:
    t(f"ModelName.from_string({name!r})", lambda: ModelName.from_string(name))
print("json float 93.0:", json.dumps({"value":93.0},separators=(",",":")), "int:", json.dumps({"value":126},separators=(",",":")), "bool:", json.dumps({"state":True},separators=(",",":")))
print("json non-ascii:", json.dumps({"n":"é"},separators=(",",":")))
print("json.loads(''):", end=" ");
try: json.loads("")
except Exception as e: print(type(e).__mro__[:3])
