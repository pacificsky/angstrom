import Foundation

/// Verbatim upstream test constants (§9.3).
package enum BluetoothTestVectors {
    /// `COMMAND_SUCCESS` (`tests/test_bluetooth_client.py:47`).
    package static let commandSuccess = Data(#"{"id":"test-id","message":"Success","status":"success"}"#.utf8)
    /// `STARTED` (`tests/test_bluetooth_client.py:48`).
    package static let started = Data(#"{"BrewingStartedGroup1DoseIndex":"DoseA"}"#.utf8)

    /// `_tick` (`tests/test_bluetooth_client.py:51-59`): a timer notification of a running shot,
    /// rendered with `json.dumps` default separators (`", "` and `": "`, WITH spaces) and the keys in
    /// upstream's insertion order. `time` is inserted verbatim, so `"3.34"` renders as Python's
    /// `repr(3.34)` did.
    package static func tick(_ time: String, backflush: Bool = false) -> Data {
        Data(("{\"BrewingUpdateGroup1Time\": \(time), \"BrewingUpdateGroup1Ev\": true, "
            + "\"BrewingUpdateGroup1Backflush\": \(backflush ? "true" : "false")}").utf8)
    }
}
