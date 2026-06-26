import XCTest
import Foundation
@testable import Angstrom

/// Vectors generated from the `pylamarzocco` reference implementation
/// (`generate_request_proof`) with `secret = bytes(range(32))`. These guard the
/// Swift port against drift.
final class ProofTests: XCTestCase {
    private let secret = Data((0..<32).map { UInt8($0) })

    func testRequestProofMatchesPythonReference() {
        let vectors: [(input: String, expected: String)] = [
            ("test.installation.123", "MbXXde+IuE4L0yCipe+LPk2/V96vSgPaRgwZYtW46/E="),
            ("abc", "e4sqH8QhuxVNsnZ4VWquYj8NTS/72YdV2jGoD/il5cI="),
            ("a3f9.7c2e1b.1700000000", "ETa94uRWsxOfeCFZtJidogCB3D1Jhbt0WwiI5/bFfTc="),
            ("", "Yw3NKWbEM2aRElRIu7JbT/QSpJxzLbLIq8G4WBvXEN0="),
        ]
        for vector in vectors {
            XCTAssertEqual(
                Proof.requestProof(baseString: vector.input, secret: secret),
                vector.expected,
                "proof mismatch for input \"\(vector.input)\""
            )
        }
    }
}
