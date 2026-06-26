import XCTest
import Foundation
import CryptoKit
@testable import Angstrom

final class InstallationKeyTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let key = InstallationKey.generate()
        let data = try JSONEncoder().encode(key)
        let restored = try JSONDecoder().decode(InstallationKey.self, from: data)
        XCTAssertEqual(key, restored)
    }

    func testDerivationIsDeterministic() throws {
        let key = InstallationKey.generate()
        let same = InstallationKey(installationId: key.installationId, privateKeyRaw: key.privateKeyRaw)
        XCTAssertEqual(try key.secret(), try same.secret())
        XCTAssertEqual(try key.baseString(), try same.baseString())
        XCTAssertEqual(try key.secret().count, 32)
    }

    func testSignatureVerifiesAgainstPublicKey() throws {
        let key = InstallationKey.generate()
        let message = Data("hello.world".utf8)
        let signatureDER = try key.sign(message)

        let publicKey = try P256.Signing.PublicKey(derRepresentation: key.publicKeyDER())
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: message))
    }

    func testInvalidRawKeyThrows() {
        let bad = InstallationKey(installationId: "x", privateKeyRaw: Data([0, 1, 2]))
        XCTAssertThrowsError(try bad.secret()) { error in
            XCTAssertEqual(error as? LaMarzoccoError, .invalidInstallationKey)
        }
    }
}
