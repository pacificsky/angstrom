import ArgumentParser

/// `angcli ble <subcommand>`: talk to a nearby machine over Bluetooth (SPEC §10.1).
struct Ble: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ble",
        abstract: "Talk to a nearby La Marzocco machine over Bluetooth (debugging).",
        subcommands: [BleScan.self, BleGatt.self, BleToken.self, BleRead.self, BleCmd.self, BleListen.self])
}
