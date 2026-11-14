import Foundation

extension BluetoothBrewingData {
    /// MBT:125-163 (§4.11).
    public func deriveState(receivedAt: Date) -> BluetoothShotCounterUpdate? {
        fatalError("unimplemented: BT-W1-04")
    }
}

/// `_BrewingTracker` (BT:77-111, §4.11).
package struct BrewingTracker: Sendable {
    /// The merged brewing data of the current shot (`D` in §4.11).
    private var data = BluetoothBrewingData()
    /// The earliest brewing start seen for the current shot (`S` in §4.11).
    private var start: Date?

    package init() {}

    package mutating func process(_ message: BluetoothBrewingData, receivedAt: Date) -> BluetoothShotCounterUpdate? {
        fatalError("unimplemented: BT-W1-04")
    }
}

/// §3.8 framing + field rules. nil = drop the notification.
package enum ShotCounterNotificationDecoder {
    package static func decode(_ data: Data) -> DecodedShotCounterNotification? {
        fatalError("unimplemented: BT-W1-04")
    }
}
