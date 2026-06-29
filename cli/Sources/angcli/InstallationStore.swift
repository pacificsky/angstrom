import Foundation
import Angstrom

/// What the CLI persists between runs. Per the Angstrom contract, the caller
/// owns the ``InstallationKey`` and the `isRegistered` flag; tokens are never
/// persisted (they live only in the client's memory).
struct StoredInstallation: Codable {
    var installationKey: InstallationKey
    var isRegistered: Bool
}

/// File-backed store at `~/.config/angstrom/installation.json` (mode `0600`).
///
/// The installation key embeds a P-256 private-key scalar — treat the file as a
/// secret. Keychain storage is a possible hardening follow-up.
enum InstallationStore {
    static var directoryURL: URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("angstrom", isDirectory: true)
    }

    static var fileURL: URL { directoryURL.appendingPathComponent("installation.json") }

    /// Load the saved installation, or `nil` on first run / unreadable file.
    static func load() -> StoredInstallation? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredInstallation.self, from: data)
    }

    /// Persist the installation, creating the directory (`0700`) and forcing the
    /// file mode to `0600`.
    static func save(_ value: StoredInstallation) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
        // `.atomic` writes via a temp file with default perms, so clamp after.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
