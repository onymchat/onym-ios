import XCTest
import OnymTransport
@testable import OnymMesh

final class MeshInboxTransportTests: XCTestCase {
    private struct NoSource: MeshFrameSource {
        func frames() -> AsyncStream<Data> { AsyncStream { _ in } }
    }

    private let inbox = TransportInboxID(rawValue: "aabbccddeeff0011")
    private let pairKey = Data(repeating: 0x42, count: 32)
    private let now = Date(timeIntervalSince1970: 1_794_398_400) // 2026-11-11T12:00:00Z

    private func makeTransport(contacts: [MeshContact]? = nil) -> MeshInboxTransport {
        let list = contacts ?? [MeshContact(inbox: inbox, pairKey: pairKey)]
        let now = self.now
        return MeshInboxTransport(source: NoSource(), contacts: { list }, now: { now })
    }

    private func frames(for envelope: Data, epoch: UInt32, key: Data? = nil, id: UInt64 = 1) -> [Data] {
        let tag = MeshTag.derive(pairKey: key ?? pairKey, epoch: epoch)
        return MeshFrame.fragment(envelope: envelope, tag: tag, epoch: epoch, envelopeID: id, maxFrameSize: 40)!.map(\.bytes)
    }

    /// Collect what the inbox subscription yields after feeding `input`.
    private func received(_ transport: MeshInboxTransport, feeding input: [Data]) async -> [InboundInbox] {
        let stream = transport.subscribe(inbox: inbox)
        try? await Task.sleep(nanoseconds: 50_000_000) // let the subscription register
        for bytes in input { await transport.receive(bytes) }
        await transport.unsubscribe(inbox: inbox)
        var out: [InboundInbox] = []
        for await message in stream { out.append(message) }
        return out
    }

    func testDeliversMatchingEnvelopeMarkedBluetooth() async {
        let envelope = Data(repeating: 7, count: 100)
        let epoch = MeshEpoch.number(at: now)
        let out = await received(makeTransport(), feeding: frames(for: envelope, epoch: epoch))
        XCTAssertEqual(out.map(\.payload), [envelope])
        XCTAssertEqual(out.first?.delivery, .bluetooth, "so the dispatcher sends no receipt")
        XCTAssertEqual(out.first?.inbox, inbox)
        XCTAssertEqual(out.first?.messageID, "ble:0000000000000001")
    }

    func testDropsFramesForSomeoneElse() async {
        let epoch = MeshEpoch.number(at: now)
        let stranger = Data(repeating: 0x99, count: 32)
        let out = await received(makeTransport(), feeding: frames(for: Data([1, 2, 3]), epoch: epoch, key: stranger))
        XCTAssertTrue(out.isEmpty)
    }

    func testAcceptsTheRetentionWindowAndOneEpochAhead() async {
        let current = MeshEpoch.number(at: now)
        let dayOld = MeshEpoch.number(at: now.addingTimeInterval(-MeshInboxTransport.retention))
        let input = frames(for: Data([1]), epoch: dayOld, id: 1)
            + frames(for: Data([2]), epoch: current + 1, id: 2)
        let out = await received(makeTransport(), feeding: input)
        XCTAssertEqual(out.map(\.payload), [Data([1]), Data([2])])
    }

    func testRejectsEpochsOutsideTheWindow() async {
        let current = MeshEpoch.number(at: now)
        let tooOld = MeshEpoch.number(at: now.addingTimeInterval(-MeshInboxTransport.retention)) - 1
        let input = frames(for: Data([1]), epoch: tooOld, id: 1)
            + frames(for: Data([2]), epoch: current + 2, id: 2)
        let out = await received(makeTransport(), feeding: input)
        XCTAssertTrue(out.isEmpty)
    }

    /// The legacy-advertising shape iPhones receive: same tag, same
    /// delivery, a 9-byte header and the epoch's low byte only.
    func testDeliversCompactFrames() async {
        let envelope = Data(repeating: 9, count: 70)
        let epoch = MeshEpoch.number(at: now)
        let tag = MeshTag.derive(pairKey: pairKey, epoch: epoch)
        let input = MeshCompactFrame.fragment(envelope: envelope, tag: tag, epoch: epoch, envelopeID: 0x0102)!.map(\.bytes)
        let out = await received(makeTransport(), feeding: input.reversed())
        XCTAssertEqual(out.map(\.payload), [envelope])
        XCTAssertEqual(out.first?.delivery, .bluetooth)
    }

    func testCompactEpochOutsideTheWindowDoesNotResolve() {
        // 98 epochs of window; a low byte matching none of them is noise.
        XCTAssertNil(MeshCompactFrame.resolveEpoch(low: 0x10, oldest: 0x1_0020, current: 0x1_0070))
        XCTAssertEqual(MeshCompactFrame.resolveEpoch(low: 0x71, oldest: 0x1_0020, current: 0x1_0070), 0x1_0071, "one ahead")
        XCTAssertEqual(MeshCompactFrame.resolveEpoch(low: 0x20, oldest: 0x1_0020, current: 0x1_0070), 0x1_0020, "oldest")
    }

    func testNeverSends() async {
        do {
            _ = try await makeTransport().send(Data([1]), to: inbox)
            XCTFail("the mesh transport is receive-only")
        } catch {}
    }

    func testIgnoresGarbage() async {
        let out = await received(makeTransport(), feeding: [Data(), Data([1, 2, 3]), Data(repeating: 0xFF, count: 64)])
        XCTAssertTrue(out.isEmpty)
    }
}
