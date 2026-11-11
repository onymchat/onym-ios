import XCTest
@testable import OnymMesh

final class MeshFrameTests: XCTestCase {
    private let tag = MeshTag(bytes: Data([1, 2, 3]))!

    private func frame(_ index: UInt8, of count: UInt8, id: UInt64 = 7, chunk: Data = Data([0xAA])) -> MeshFrame {
        MeshFrame(epoch: 100, tag: tag, envelopeID: id, index: index, count: count, chunk: chunk)
    }

    // MARK: - Codec

    func testRoundTrip() {
        let f = frame(2, of: 5, id: 0xDEADBEEF_CAFEF00D, chunk: Data("chunk".utf8))
        XCTAssertEqual(MeshFrame(bytes: f.bytes), f)
    }

    /// Bytes off the radio are untrusted: anything malformed is dropped.
    func testRejectsMalformed() {
        let good = frame(0, of: 1).bytes
        XCTAssertNil(MeshFrame(bytes: Data(good.prefix(MeshFrame.headerSize))), "no chunk")
        var wrongVersion = good; wrongVersion[0] = 2
        XCTAssertNil(MeshFrame(bytes: wrongVersion))
        var zeroCount = good; zeroCount[17] = 0
        XCTAssertNil(MeshFrame(bytes: zeroCount))
        var indexPastCount = good; indexPastCount[16] = 1
        XCTAssertNil(MeshFrame(bytes: indexPastCount))
        XCTAssertNil(MeshFrame(bytes: Data()))
    }

    func testFragmentLimits() {
        XCTAssertNil(MeshFrame.fragment(envelope: Data(), tag: tag, epoch: 1, envelopeID: 1, maxFrameSize: 100))
        XCTAssertNil(MeshFrame.fragment(envelope: Data([1]), tag: tag, epoch: 1, envelopeID: 1, maxFrameSize: MeshFrame.headerSize))
        XCTAssertNil(
            MeshFrame.fragment(envelope: Data(count: MeshFrame.maxEnvelopeSize + 1), tag: tag, epoch: 1, envelopeID: 1, maxFrameSize: 245),
            "over the mesh's size cap"
        )
        XCTAssertNil(
            MeshFrame.fragment(envelope: Data(count: 256), tag: tag, epoch: 1, envelopeID: 1, maxFrameSize: MeshFrame.headerSize + 1),
            "more than 255 fragments"
        )
    }

    // MARK: - Reassembly

    func testReassemblesOutOfOrderAndIgnoresRepeats() throws {
        let envelope = Data((0..<1000).map { UInt8($0 % 251) })
        let frames = try XCTUnwrap(MeshFrame.fragment(envelope: envelope, tag: tag, epoch: 1, envelopeID: 9, maxFrameSize: 120))
        var r = MeshReassembler()
        var out: [Data] = []
        // A looping broadcaster: every fragment twice, shuffled.
        for f in (frames + frames).shuffled() {
            if let e = r.add(f, at: Date()) { out.append(e) }
        }
        XCTAssertEqual(out, [envelope], "delivered once, intact")
    }

    func testDeliveredEnvelopeIsNotDeliveredAgainNextLap() {
        var r = MeshReassembler()
        let now = Date()
        XCTAssertNotNil(r.add(frame(0, of: 1), at: now))
        XCTAssertNil(r.add(frame(0, of: 1), at: now.addingTimeInterval(60)))
        XCTAssertNotNil(r.add(frame(0, of: 1), at: now.addingTimeInterval(r.deliveredMemory + 1)), "forgotten after the memory window")
    }

    func testFragmentDisagreeingAboutCountIsIgnored() {
        var r = MeshReassembler()
        let now = Date()
        XCTAssertNil(r.add(frame(0, of: 2), at: now))
        XCTAssertNil(r.add(frame(1, of: 3), at: now), "inconsistent shape")
        XCTAssertNotNil(r.add(frame(1, of: 2), at: now))
    }

    func testIncompleteEnvelopeTimesOut() {
        var r = MeshReassembler()
        let now = Date()
        XCTAssertNil(r.add(frame(0, of: 2), at: now))
        XCTAssertNil(r.add(frame(1, of: 2), at: now.addingTimeInterval(r.timeout + 1)), "first half expired")
    }

    func testPendingIsBounded() {
        var r = MeshReassembler()
        r.maxPending = 2
        let now = Date()
        XCTAssertNil(r.add(frame(0, of: 2, id: 1), at: now))
        XCTAssertNil(r.add(frame(0, of: 2, id: 2), at: now.addingTimeInterval(1)))
        XCTAssertNil(r.add(frame(0, of: 2, id: 3), at: now.addingTimeInterval(2)), "evicts id 1")
        XCTAssertNil(r.add(frame(1, of: 2, id: 1), at: now.addingTimeInterval(3)), "id 1 restarted, not completed")
        XCTAssertNotNil(r.add(frame(1, of: 2, id: 3), at: now.addingTimeInterval(4)))
    }
}
