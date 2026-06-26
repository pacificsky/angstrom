import Foundation
import CryptoKit

/// A per-installation cryptographic identity required by the La Marzocco
/// customer-app cloud API. Generate one the first time, persist it (it's
/// `Codable`), and reuse it on subsequent launches.
///
/// This is a plain value type — it stores only the installation id and the
/// raw private-key scalar, deriving everything else on demand — so it is
/// `Sendable` and safe to hand to the client across concurrency domains.
///
/// Ported from `pylamarzocco` (util/_authentication.py) by Josef Zweck.
public struct InstallationKey: Sendable, Codable, Equatable {
    /// Random per-install UUID (lowercased), identifying this client to the API.
    public let installationId: String
    /// Raw 32-byte P-256 private-key scalar.
    public let privateKeyRaw: Data

    public init(installationId: String, privateKeyRaw: Data) {
        self.installationId = installationId
        self.privateKeyRaw = privateKeyRaw
    }

    /// Create a fresh identity. Persist the result and call
    /// ``LaMarzoccoCloudClient/register()`` once before signing in.
    public static func generate() -> InstallationKey {
        InstallationKey(
            installationId: UUID().uuidString.lowercased(),
            privateKeyRaw: P256.Signing.PrivateKey().rawRepresentation
        )
    }

    // MARK: - Derived material (internal)

    func privateKey() throws -> P256.Signing.PrivateKey {
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        } catch {
            throw LaMarzoccoError.invalidInstallationKey
        }
    }

    /// DER-encoded SubjectPublicKeyInfo of the public key.
    func publicKeyDER() throws -> Data { try privateKey().publicKey.derRepresentation }

    func publicKeyBase64() throws -> String { try publicKeyDER().base64EncodedString() }

    /// 32-byte secret: `sha256("{id}.{base64(pubDER)}.{base64(sha256(id))}")`.
    func secret() throws -> Data {
        let der = try publicKeyDER()
        let pubB64 = der.base64EncodedString()
        let instHashB64 = Data(SHA256.hash(data: Data(installationId.utf8))).base64EncodedString()
        let triple = "\(installationId).\(pubB64).\(instHashB64)"
        return Data(SHA256.hash(data: Data(triple.utf8)))
    }

    /// `"{id}.{base64(sha256(pubDER))}"`, used for the registration proof.
    func baseString() throws -> String {
        let der = try publicKeyDER()
        let hash = Data(SHA256.hash(data: der)).base64EncodedString()
        return "\(installationId).\(hash)"
    }

    /// ECDSA-sign `message` with the P-256 key (SHA-256), DER-encoded.
    func sign(_ message: Data) throws -> Data {
        try privateKey().signature(for: message).derRepresentation
    }
}
