import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Resolves La Marzocco credentials from the environment or an interactive
/// prompt. Credentials are **never persisted** — they live only for the run.
enum Credentials {
    static func resolve() throws -> (username: String, password: String) {
        let environment = ProcessInfo.processInfo.environment

        let username: String
        if let value = environment["LAMARZOCCO_USERNAME"], !value.isEmpty {
            username = value
        } else {
            Stderr.prompt("La Marzocco email: ")
            username = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
        }

        let password: String
        if let value = environment["LAMARZOCCO_PASSWORD"], !value.isEmpty {
            password = value
        } else {
            password = readHiddenLine("Password: ")
        }

        guard !username.isEmpty, !password.isEmpty else {
            throw CLIError("""
                Username and password are required. Set LAMARZOCCO_USERNAME / \
                LAMARZOCCO_PASSWORD, or enter them when prompted.
                """)
        }
        return (username, password)
    }

    /// Read a line without echoing it (for the password). Uses `getpass`, which
    /// reads from the controlling terminal; falls back to a visible prompt when
    /// there is no TTY.
    private static func readHiddenLine(_ prompt: String) -> String {
        #if canImport(Darwin)
        if let raw = getpass(prompt) {
            return String(cString: raw)
        }
        #endif
        Stderr.prompt(prompt)
        return readLine(strippingNewline: true) ?? ""
    }
}
