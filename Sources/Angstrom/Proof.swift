import Foundation
import CryptoKit

/// La Marzocco's bespoke request-proof + signed-header scheme.
/// Ported from `pylamarzocco` (util/_authentication.py) and verified
/// byte-for-byte against the Python reference (see `ProofTests`).
enum Proof {
    /// The "Y5.e" proof: mutate a copy of the 32-byte secret byte-by-byte over
    /// the input string, then return `base64(sha256(work))`.
    static func requestProof(baseString: String, secret: Data) -> String {
        precondition(secret.count == 32, "secret must be 32 bytes")
        var work = [UInt8](secret)
        for byteVal in Array(baseString.utf8) {
            let idx = Int(byteVal) % 32
            let shiftIdx = (idx + 1) % 32
            let shiftAmount = Int(work[shiftIdx] & 7) // 0...7
            let xor = Int(byteVal) ^ Int(work[idx])   // 0...255
            // XOR then rotate-left within a byte (xor >> 8 == 0 when shiftAmount == 0).
            let rotated = ((xor << shiftAmount) | (xor >> (8 - shiftAmount))) & 0xFF
            work[idx] = UInt8(rotated)
        }
        return Data(SHA256.hash(data: Data(work))).base64EncodedString()
    }

    /// Headers carried on the signin/refresh and all authenticated requests.
    static func requestHeaders(for key: InstallationKey) throws -> [String: String] {
        let nonce = UUID().uuidString.lowercased()
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000)) // ms
        let proofInput = "\(key.installationId).\(nonce).\(timestamp)"
        let proof = requestProof(baseString: proofInput, secret: try key.secret())
        let signatureData = "\(proofInput).\(proof)"
        let signature = try key.sign(Data(signatureData.utf8))
        return [
            "X-App-Installation-Id": key.installationId,
            "X-Timestamp": timestamp,
            "X-Nonce": nonce,
            "X-Request-Signature": signature.base64EncodedString(),
        ]
    }
}
