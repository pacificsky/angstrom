import ArgumentParser
import Angstrom

@main
struct AngCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "angcli",
        abstract: "Debug the La Marzocco cloud API through Angstrom — hold the websocket open and print raw + decoded frames.",
        discussion: """
            Credentials come from LAMARZOCCO_USERNAME / LAMARZOCCO_PASSWORD or an \
            interactive prompt and are never persisted. The per-install key is \
            stored at ~/.config/angstrom/installation.json (mode 0600); tokens and \
            signed proof headers are never written or printed.

            This talks to the real La Marzocco cloud with real credentials — mind \
            rate limits and ToS.
            """,
        version: "1.0.0",
        subcommands: [Listen.self, Dump.self, Machines.self],
        defaultSubcommand: Listen.self
    )
}

/// Which views of the websocket traffic to print. Defaults to both.
struct OutputMode {
    let includesRaw: Bool
    let includesDecoded: Bool

    init(raw: Bool, decoded: Bool, both: Bool) {
        // Default (no flags), an explicit --both, or the contradictory
        // --raw --decoded combination all mean "show everything".
        if both || (raw && decoded) || (!raw && !decoded) {
            includesRaw = true
            includesDecoded = true
        } else {
            includesRaw = raw
            includesDecoded = decoded
        }
    }
}

// `RawEndpoint` (in Angstrom) is a String-backed, CaseIterable enum, so a default
// `ExpressibleByArgument` conformance lets `dump <endpoint>` parse + auto-list it.
// Declared here so the library never picks up an ArgumentParser dependency.
extension RawEndpoint: @retroactive ExpressibleByArgument {}
