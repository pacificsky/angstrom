import CoreBluetooth
import Dispatch
actor QueueActor {
  let queue = DispatchSerialQueue(label: "x")
  nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
  var n = 0
  func bump() { n += 1 }
}
final class D: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
  let owner: QueueActor
  init(owner: QueueActor) { self.owner = owner }
  func centralManagerDidUpdateState(_ central: CBCentralManager) { owner.assumeIsolated { $0.bump() } }
}
actor DelegateActor: NSObject, CBCentralManagerDelegate {
  nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}
@globalActor actor BluetoothActor: GlobalActor {
  static let shared = BluetoothActor()
  static let queue = DispatchSerialQueue(label: "bt")
  nonisolated var unownedExecutor: UnownedSerialExecutor { Self.queue.asUnownedSerialExecutor() }
}
@BluetoothActor final class Del3: NSObject, @BluetoothActor CBCentralManagerDelegate {
  var n = 0
  func centralManagerDidUpdateState(_ central: CBCentralManager) { n += 1 }
}
@BluetoothActor func makeManager(d: Del3) -> CBCentralManager { CBCentralManager(delegate: d, queue: BluetoothActor.queue) }
