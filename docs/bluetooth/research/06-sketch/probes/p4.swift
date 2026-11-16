import CoreBluetooth
final class NS {}   // swift non-Sendable
actor A { var keep: [AnyObject] = []; func take(_ p: CBPeripheral) { keep.append(p) }; func takeN(_ n: NS) { keep.append(n) }; func get() -> CBPeripheral? { keep.first as? CBPeripheral } ; func getN() -> NS? { keep.first as? NS } }
func f(p: CBPeripheral, n: NS, a: A) async {
  await a.take(p)     // line 5
  await a.takeN(n)    // line 6
  _ = p.identifier
  _ = n
}
func g(a: A) async { let p = await a.get(); _ = p?.name; let n = await a.getN(); _ = n }
