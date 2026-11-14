import CoreBluetooth
@MainActor final class MainCentral: NSObject, CBCentralManagerDelegate {
  var manager: CBCentralManager?
  var state: CBManagerState = .unknown
  func start() { manager = CBCentralManager(delegate: self, queue: nil) } // nil = main queue (CBCentralManager.h:118-119)
  nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let s = central.state
    MainActor.assumeIsolated { self.state = s }
  }
}
@MainActor final class MainCentral2: NSObject, @MainActor CBCentralManagerDelegate {
  var n = 0
  func centralManagerDidUpdateState(_ central: CBCentralManager) { n += 1 }
}
