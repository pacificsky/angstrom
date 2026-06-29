import Foundation
import Angstrom

/// A user-facing error whose message is printed as-is (no Swift type noise).
struct CLIError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}

/// A connected client plus the machines on the account.
struct Session {
    let client: LaMarzoccoCloudClient
    let machines: [Machine]
}

/// Shared startup: load (or generate) the installation key, resolve credentials,
/// authenticate, persist the (possibly newly-registered) installation, and
/// return the account's machines.
enum Bootstrap {
    static func connect() async throws -> Session {
        let stored = InstallationStore.load()
        if stored == nil {
            Stderr.log("No saved installation — generating a new key and registering this client.")
        }
        let installationKey = stored?.installationKey ?? .generate()
        let registered = stored?.isRegistered ?? false

        let credentials = try Credentials.resolve()
        let client = LaMarzoccoCloudClient(
            username: credentials.username,
            password: credentials.password,
            installationKey: installationKey,
            registered: registered,
            logHandler: { Stderr.log("· \($0)") }
        )

        Stderr.log("Authenticating as \(credentials.username)…")
        let machines: [Machine]
        do {
            machines = try await client.connect()
        } catch {
            throw CLIError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }

        // Persist the key + registration flag (register() may have flipped it).
        // The key is read without `await` (it's `nonisolated`); the flag isn't.
        do {
            try InstallationStore.save(StoredInstallation(
                installationKey: client.installationKey,
                isRegistered: await client.isRegistered))
        } catch {
            Stderr.log("Warning: could not persist installation to \(InstallationStore.fileURL.path): \(error.localizedDescription)")
        }

        return Session(client: client, machines: machines)
    }
}

/// Picks the machine to operate on: an explicit `--serial`, the only machine, or
/// an interactive choice when several exist (defaulting to the first).
enum MachineSelector {
    static func choose(_ machines: [Machine], serial: String?) throws -> Machine {
        if let serial {
            guard let match = machines.first(where: { $0.serialNumber == serial }) else {
                let available = machines.map(\.serialNumber).joined(separator: ", ")
                throw CLIError("No machine with serial '\(serial)'. Available: \(available).")
            }
            return match
        }
        if machines.count == 1 { return machines[0] }

        Stderr.log("Multiple machines on this account:")
        for (index, machine) in machines.enumerated() {
            Stderr.log("  [\(index)] \(machine.serialNumber)  \(machine.modelName)  \(machine.type.rawValue)")
        }
        Stderr.prompt("Select a machine [0]: ")
        let entry = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
        let index = entry.isEmpty ? 0 : (Int(entry) ?? -1)
        guard machines.indices.contains(index) else {
            throw CLIError("Invalid selection '\(entry)'.")
        }
        return machines[index]
    }
}
