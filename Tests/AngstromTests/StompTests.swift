import XCTest
@testable import Angstrom

/// The STOMP frame codec — exactness is load-bearing for the live connection.
final class StompTests: XCTestCase {

    func testEncodeConnectFrame() {
        let frame = Stomp.encode(.connect, headers: [
            ("host", "lion.lamarzocco.io"),
            ("accept-version", "1.2,1.1,1.0"),
            ("heart-beat", "0,0"),
            ("Authorization", "Bearer abc"),
        ])
        XCTAssertEqual(
            frame,
            "CONNECT\nhost:lion.lamarzocco.io\naccept-version:1.2,1.1,1.0\nheart-beat:0,0\nAuthorization:Bearer abc\n\n\u{00}"
        )
    }

    func testEncodeWithBody() {
        let frame = Stomp.encode(.message, headers: [("destination", "/x")], body: "{\"a\":1}")
        XCTAssertEqual(frame, "MESSAGE\ndestination:/x\n\n{\"a\":1}\u{00}")
    }

    func testDecodeConnected() {
        let frame = Stomp.decode("CONNECTED\nversion:1.2\nheart-beat:0,0\n\n\u{00}")
        XCTAssertEqual(frame?.command, "CONNECTED")
        XCTAssertEqual(frame?.headers["version"], "1.2")
        XCTAssertNil(frame?.body)
    }

    func testDecodeMessageWithBodyAndNUL() {
        let frame = Stomp.decode("MESSAGE\nsubscription:s1\ndestination:/ws/sn/SN1/dashboard\n\n{\"connected\":true}\u{00}")
        XCTAssertEqual(frame?.command, "MESSAGE")
        XCTAssertEqual(frame?.headers["destination"], "/ws/sn/SN1/dashboard")
        XCTAssertEqual(frame?.body, "{\"connected\":true}")
    }

    func testDecodeHeaderValueWithColon() {
        // Only the first colon splits key/value (timestamps etc. contain colons).
        let frame = Stomp.decode("MESSAGE\nat:12:30:00\n\nbody\u{00}")
        XCTAssertEqual(frame?.headers["at"], "12:30:00")
    }

    func testEncodeDecodeRoundTrip() {
        let encoded = Stomp.encode(.subscribe, headers: [
            ("destination", "/ws/sn/SN1/dashboard"), ("ack", "auto"), ("id", "abc"), ("content-length", "0"),
        ])
        let frame = Stomp.decode(encoded)
        XCTAssertEqual(frame?.command, "SUBSCRIBE")
        XCTAssertEqual(frame?.headers["destination"], "/ws/sn/SN1/dashboard")
        XCTAssertEqual(frame?.headers["content-length"], "0")
        XCTAssertNil(frame?.body)
    }
}
