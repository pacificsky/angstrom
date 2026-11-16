import Foundation

/// La Marzocco BLE protocol constants, verbatim from pylamarzocco v2.5.6 (`_bluetooth.py:40-54`).
package enum BluetoothConstants {
    /// `READ_CHARACTERISTIC`: read-setting requests are written here and answered here.
    package static let readCharacteristic = GATTUUID("0a0b7847-e12b-09a8-b04b-8e0922a9abab")
    /// `WRITE_CHARACTERISTIC`: command frames are written here and their status read back.
    package static let writeCharacteristic = GATTUUID("0b0b7847-e12b-09a8-b04b-8e0922a9abab")
    /// `GET_TOKEN_CHARACTERISTIC`: readable only while the machine is in pairing mode.
    package static let tokenCharacteristic = GATTUUID("0c0b7847-e12b-09a8-b04b-8e0922a9abab")
    /// `AUTH_CHARACTERISTIC`: the token is written here; `0x01` is read back on success.
    package static let authCharacteristic = GATTUUID("0d0b7847-e12b-09a8-b04b-8e0922a9abab")
    /// `SHOT_COUNTER_CHARACTERISTIC`: notifies brewing state and telemetry.
    package static let shotCounterCharacteristic = GATTUUID("0e0b7847-e12b-09a8-b04b-8e0922a9abab")
    /// The four characteristics discovered on every authenticated connection.
    package static let sessionCharacteristics: Set<GATTUUID> =
        [readCharacteristic, writeCharacteristic, authCharacteristic, shotCounterCharacteristic]
    /// `BT_MODEL_PREFIXES` — case-sensitive name prefixes kept by discovery.
    package static let machineNamePrefixes: [String] = ["MICRA", "MINI", "LINEA", "GS3"]
    /// `AUTH_SUCCESS = b"\x01"`.
    package static let authSuccess = Data([0x01])
}

/// Every timing constant of the BLE client. Defaults are upstream values or bleak defaults (§2.2).
package struct BluetoothTiming: Sendable, Equatable {
    /// `IDLE_TIMEOUT = 30`.
    package var idleTimeout: Duration = .seconds(30)
    /// `AUTH_READ_ATTEMPTS = 10`.
    package var authReadAttempts: Int = 10
    /// `AUTH_READ_INTERVAL = 0.05`.
    package var authReadInterval: Duration = .milliseconds(50)
    /// `MAX_AUTH_FAILURES = 3`.
    package var maxAuthFailures: Int = 3
    /// `RECONNECT_INITIAL_DELAY = 1`.
    package var reconnectInitialDelay: Duration = .seconds(1)
    /// `RECONNECT_MAX_DELAY = 60`.
    package var reconnectMaxDelay: Duration = .seconds(60)
    /// `establish_connection` default `max_attempts`.
    package var connectAttempts: Int = 3
    /// bleak's default connect timeout.
    package var connectTimeout: Duration = .seconds(20)
    /// `establish_connection` backoff after a timed-out attempt.
    package var connectBackoffAfterTimeout: Duration = .milliseconds(250)
    /// `establish_connection` backoff after any other failed attempt.
    package var connectBackoff: Duration = .milliseconds(100)
    /// Bound on every GATT read/write/subscribe/discovery (D19).
    package var operationTimeout: Duration = .seconds(20)
    /// How long a connect waits for Bluetooth to become `.poweredOn` (D19).
    package var poweredOnWait: Duration = .seconds(10)
    /// Connect timeout of the pairing-mode token read.
    package var tokenReadConnectTimeout: Duration = .seconds(10)
    /// Default discovery scan length.
    package var scanDuration: Duration = .seconds(5)
    package init() {}
}
