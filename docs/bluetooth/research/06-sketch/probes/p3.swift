import CoreBluetooth
func needsSendable<T: Sendable>(_ t: T.Type) {}
func check() {
  needsSendable(CBPeripheral.self)
  needsSendable(CBCentralManager.self)
  needsSendable(CBCharacteristic.self)
  needsSendable(CBUUID.self)
  needsSendable(CBManagerState.self)
  needsSendable(CBManagerAuthorization.self)
  needsSendable(CBError.self)
  needsSendable(CBError.Code.self)
}
final class Holder: @unchecked Sendable { var p: CBPeripheral? }
actor B { var p: CBPeripheral?; func set(_ x: CBPeripheral) { p = x }; func get() -> CBPeripheral? { p } }
func h(b: B) async { let p = await b.get(); _ = p?.identifier }
