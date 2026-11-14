import CoreBluetooth
import Dispatch

actor QueueBackedCentral {
    let queue = DispatchSerialQueue(label: "angstrom.bluetooth.b")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    var count = 0
    func bump() { count += 1 }
}

// Delegate must be an NSObject; it forwards into the actor.
final class Proxy: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    let owner: QueueBackedCentral
    init(owner: QueueBackedCentral) { self.owner = owner }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Synchronous entry into the actor from a raw GCD callback on its queue:
        owner.assumeIsolated { $0.bump() }   // runtime check: needs SerialExecutor.checkIsolated (macOS 15+/iOS 18+)
    }
}

actor DelegateActor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}
