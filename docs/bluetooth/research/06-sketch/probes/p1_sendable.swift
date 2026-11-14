import CoreBluetooth
actor A { func take(_ p: CBPeripheral) {} ; func takeC(_ c: CBCharacteristic) {}; func takeU(_ u: CBUUID) {} ; func takeM(_ m: CBCentralManager) {} }
func f(p: CBPeripheral, c: CBCharacteristic, u: CBUUID, m: CBCentralManager, a: A) async {
  await a.take(p)
  await a.takeC(c)
  await a.takeU(u)
  await a.takeM(m)
}
func g(p: CBPeripheral) { Task.detached { _ = p.identifier } }
