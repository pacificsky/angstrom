import Foundation
import Angstrom

/// A persistable snapshot of a machine's last-known cloud state, so a UI can
/// render stale data on launch before the network refresh completes.
///
/// Encode with ``encoded()`` (which uses La Marzocco's millisecond-epoch date
/// strategy so timestamps survive the round-trip) and store the bytes; rebuild
/// with ``init(data:)`` and pass to ``LaMarzoccoMachine``'s initializer.
///
/// Note: a widget this version couldn't decode is preserved by `code`/`index`
/// but loses its raw payload — only recognized widgets round-trip in full.
public struct MachineSnapshot: Codable, Sendable, Hashable {
    public let serialNumber: String
    public let dashboard: Dashboard?
    public let settings: MachineSettings?
    public let schedule: MachineSchedule?

    public init(
        serialNumber: String,
        dashboard: Dashboard? = nil,
        settings: MachineSettings? = nil,
        schedule: MachineSchedule? = nil
    ) {
        self.serialNumber = serialNumber
        self.dashboard = dashboard
        self.settings = settings
        self.schedule = schedule
    }

    /// Serialize for persistence (millisecond-epoch dates).
    public func encoded() throws -> Data {
        try JSONEncoder.laMarzocco().encode(self)
    }

    /// Rebuild from bytes produced by ``encoded()``.
    public init(data: Data) throws {
        self = try JSONDecoder.laMarzocco().decode(MachineSnapshot.self, from: data)
    }
}
