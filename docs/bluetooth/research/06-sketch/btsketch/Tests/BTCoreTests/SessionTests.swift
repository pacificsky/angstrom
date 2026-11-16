import Foundation
import Testing
@testable import BTCore

private let machine = BluetoothPeripheralID(rawValue: "00000000-0000-0000-0000-000000000001")

private func makeSession(_ central: FakeCentral, _ sleeper: RecordingSleeper = RecordingSleeper(),
                         token: String = "token") -> BluetoothMachineSession {
    BluetoothMachineSession(transport: BluetoothTransport(central: central, sleeper: sleeper),
                            peripheral: machine, token: token)
}

@Test func authSucceedsAfterPolling() async throws {
    let central = FakeCentral()
    let sleeper = RecordingSleeper()
    central.makeLink = { FakeLink.laMarzocco(token: "token", confirmOnRead: 3) }
    let session = makeSession(central, sleeper)
    _ = try await session.ensureConnected()
    let ops = central.links[0].recordedOps
    #expect(ops.first == .discover(refresh: false))
    #expect(ops[1] == .write(LMChar.auth, Data("token".utf8)))   // token, no NUL (:636-640)
    #expect(ops.filter { $0 == .read(LMChar.auth) }.count == 3)
    #expect(sleeper.count(.authPoll) == 2)                         // no sleep before the first read
}

@Test func authFailsAfterTenReadsAndDropsLink() async throws {
    let central = FakeCentral()
    central.makeLink = { FakeLink.laMarzocco(token: "right") }
    let session = makeSession(central, token: "wrong")
    await #expect(throws: BluetoothSessionError.authenticationFailed) { _ = try await session.ensureConnected() }
    let ops = central.links[0].recordedOps
    #expect(ops.filter { $0 == .read(LMChar.auth) }.count == 10)   // AUTH_READ_ATTEMPTS
    #expect(ops.last == .disconnect)
    #expect(await session.authenticationFailed)
    #expect(await !session.isConnected)
}

@Test func commandFramingIsJSONPlusNUL() async throws {
    let central = FakeCentral()
    let session = makeSession(central)
    let status = try await session.sendCommand(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#)
    #expect(status == #"{"id":"test-id","message":"Success","status":"success"}"#) // cut at NUL
    let ops = central.links[0].recordedOps
    #expect(ops.suffix(2) == [
        .write(LMChar.write, Data(#"{"name":"MachineChangeMode","parameter":{"mode":"BrewingMode"}}"#.utf8) + [0x00]),
        .read(LMChar.write),
    ])
}

@Test func requestsAreSerialized() async throws {
    let central = FakeCentral()
    let gate = Gate()
    let link = FakeLink.laMarzocco(token: "token")
    central.enqueueConnect(.success(link))
    let session = makeSession(central)
    _ = try await session.ensureConnected()
    link.beforeOp = { op in if op == .write(LMChar.write, Data("A".utf8) + [0]) { await gate.wait() } }
    async let a = session.sendCommand("A")
    try await Task.sleep(for: .milliseconds(50))         // let A reach the gate
    async let b = session.sendCommand("B")
    try await Task.sleep(for: .milliseconds(50))
    #expect(!link.recordedOps.contains(.write(LMChar.write, Data("B".utf8) + [0])))
    await gate.release()
    _ = try await (a, b)
    let tail = Array(link.recordedOps.suffix(4))
    #expect(tail == [.write(LMChar.write, Data("A".utf8) + [0]), .read(LMChar.write),
                     .write(LMChar.write, Data("B".utf8) + [0]), .read(LMChar.write)])
}

@Test func reconnectsAfterLinkDrop() async throws {
    let central = FakeCentral()
    let session = makeSession(central)
    _ = try await session.sendCommand("A")
    central.links[0].drop(.disconnected(code: 7))         // CBErrorPeripheralDisconnected = 7
    try await Task.sleep(for: .milliseconds(50))         // watcher observes .disconnected
    #expect(await !session.isConnected)
    _ = try await session.sendCommand("B")
    #expect(central.connectCount == 2)
}

@Test func connectRetriesThreeTimesThenFails() async throws {
    let central = FakeCentral()
    let sleeper = RecordingSleeper()
    for _ in 0..<3 { central.enqueueConnect(.failure(.timedOut("connect"))) }
    let session = makeSession(central, sleeper)
    await #expect(throws: BluetoothSessionError.self) { _ = try await session.ensureConnected() }
    #expect(central.connectCount == 3)
    #expect(sleeper.count(.connectBackoff) == 2)
}

@Test func unavailableFailsFastWithoutConnecting() async throws {
    let central = FakeCentral()
    central.setAvailability(.unauthorized(.denied))
    let session = makeSession(central)
    await #expect(throws: BluetoothSessionError.unavailable(.unauthorized(.denied))) {
        _ = try await session.ensureConnected()
    }
    #expect(central.connectCount == 0)
}

@Test func firstNotificationAfterSubscribeIsDropped() async throws {
    let central = FakeCentral()
    let link = FakeLink.laMarzocco(token: "token")
    link.replayOnSubscribe = [Data(#"{"stale":true}"#.utf8)]
    central.enqueueConnect(.success(link))
    let session = makeSession(central)
    let stream = await session.shotCounterNotifications()
    #expect(try await session.startShotCounter())
    link.notify(LMChar.shotCounter, Data(#"{"fresh":true}"#.utf8), at: Date(timeIntervalSince1970: 42))
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.value == Data(#"{"fresh":true}"#.utf8))
    #expect(first?.receivedAt == Date(timeIntervalSince1970: 42))
}

@Test func staleLinkEventsAreIgnored() async throws {
    let central = FakeCentral()
    let session = makeSession(central)
    _ = try await session.sendCommand("A")
    let old = central.links[0]
    await session.disconnect()                           // detaches before disconnecting
    _ = try await session.sendCommand("B")              // new link
    old.drop(nil)                                        // late event from the old link
    try await Task.sleep(for: .milliseconds(50))
    #expect(await session.isConnected)
}
