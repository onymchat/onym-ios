import XCTest
@testable import OnymIOS

/// Covers the pure event-building path of the broadcast adapter. The
/// connection / publish / subscribe paths require a real or fake
/// WebSocket server and are deferred to integration tests.
final class NostrMessageTransportTests: XCTestCase {
    private var signer: OnymNostrSigner!

    override func setUp() {
        super.setUp()
        signer = try! OnymNostrSigner(secretKey: Data(repeating: 0xCD, count: 32))
    }

    func test_buildPublishEvent_usesKind44114() throws {
        let event = try NostrMessageTransport.buildPublishEvent(
            payload: Data("hello".utf8),
            topic: TransportTopic(rawValue: "topic-a"),
            signer: signer
        )
        XCTAssertEqual(event.kind, 44114)
    }

    func test_buildPublishEvent_emitsTopicTag() throws {
        let event = try NostrMessageTransport.buildPublishEvent(
            payload: Data(),
            topic: TransportTopic(rawValue: "topic-a"),
            signer: signer
        )
        let tTags = event.tags.filter { $0.first == "t" }
        XCTAssertEqual(tTags, [["t", "topic-a"]],
                       "publish must emit exactly one [t, topic] tag")
    }

    func test_buildPublishEvent_appendsMsTag() throws {
        let event = try NostrMessageTransport.buildPublishEvent(
            payload: Data(),
            topic: TransportTopic(rawValue: "x"),
            signer: signer
        )
        XCTAssertNotNil(event.tags.first { $0.first == "ms" })
    }

    func test_buildPublishEvent_payloadRoundtripsViaBase64() throws {
        let payload = Data((0..<256).map { UInt8($0) })
        let event = try NostrMessageTransport.buildPublishEvent(
            payload: payload,
            topic: TransportTopic(rawValue: "x"),
            signer: signer
        )
        let decoded = Data(base64Encoded: event.content)
        XCTAssertEqual(decoded, payload)
    }

    func test_buildPublishEvent_emptyPayloadProducesEmptyBase64() throws {
        let event = try NostrMessageTransport.buildPublishEvent(
            payload: Data(),
            topic: TransportTopic(rawValue: "x"),
            signer: signer
        )
        XCTAssertEqual(event.content, "")
    }

    func test_buildPublishEvent_eventIDIsValid() throws {
        let event = try NostrMessageTransport.buildPublishEvent(
            payload: Data("hello".utf8),
            topic: TransportTopic(rawValue: "topic-a"),
            signer: signer
        )
        XCTAssertTrue(event.verifyEventID())
    }

    func test_buildPublishEvent_distinctEphemeralSignersProduceDifferentPubkeys() throws {
        let signerA = try OnymNostrSigner.ephemeral()
        let signerB = try OnymNostrSigner.ephemeral()
        let topic = TransportTopic(rawValue: "x")
        let eventA = try NostrMessageTransport.buildPublishEvent(payload: Data(), topic: topic, signer: signerA)
        let eventB = try NostrMessageTransport.buildPublishEvent(payload: Data(), topic: topic, signer: signerB)
        XCTAssertNotEqual(eventA.pubkey, eventB.pubkey,
                          "ephemeral signing is the metadata-hiding property — pubkeys must differ")
    }
}
