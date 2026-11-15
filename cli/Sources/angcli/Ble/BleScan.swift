import ArgumentParser
import Angstrom

/// `angcli ble scan [--duration <s>=5] [--all]` (SPEC §10.1).
///
/// Without `--all` it lists the La Marzocco machines nearby (`discoverMachines`, name-prefix
/// filtered). With `--all` it lists every peripheral seen (`scanAll`, unfiltered, SPEC §4.14; H10)
/// and prints the count to stderr. stdout gets one `{"id","name","rssi"}` line per peripheral.
struct BleScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan for nearby La Marzocco machines and print one JSON line per peripheral."
    )

    @Option(name: .long, help: "Scan duration in seconds.")
    var duration: Double = 5

    @Flag(name: .long, help: "List every peripheral seen, not only La Marzocco machines (names may be null).")
    var all = false

    /// Longest accepted `--duration` (one day). The bound keeps `Duration.seconds(_:)` (which
    /// traps when the value overflows its attosecond range) and the scan's `Task.sleep` (which
    /// converts to 64-bit nanoseconds) from crashing on huge input; out-of-range values fail
    /// validation instead.
    static let maximumDuration: Double = 86_400

    func validate() throws {
        guard duration.isFinite, duration > 0, duration <= Self.maximumDuration else {
            throw ValidationError("--duration must be a positive number of seconds, at most \(Int(Self.maximumDuration)).")
        }
    }

    func run() async throws {
        let transport = BleSession.makeTransport()
        let scanDuration = Duration.seconds(duration)
        let found: [DiscoveredPeripheral]
        do {
            if all {
                found = try await LaMarzoccoBluetoothClient.scanAll(transport: transport, duration: scanDuration)
            } else {
                found = try await LaMarzoccoBluetoothClient.discoverMachines(transport: transport, duration: scanDuration)
            }
        } catch {
            throw BleSession.cliError(error)
        }
        if all {
            Stderr.log("\(found.count) peripheral(s) found")
        }
        for peripheral in found {
            if let line = BleOutput.peripheralLine(peripheral) {
                Stdout.line(line)
            } else {
                Stderr.log("Could not encode peripheral \(peripheral.id.rawValue)")
            }
        }
    }
}
