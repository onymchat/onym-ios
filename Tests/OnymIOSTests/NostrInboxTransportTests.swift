import XCTest
@testable import OnymIOS

/// Covers the pure event-building and filter-shape paths of the inbox
/// adapter. Connection-bearing paths await an integration test layer.
final class NostrInboxTransportTests: XCTestCase {
    private var signer: OnymNostrSigner!

    override func setUp() {
        super.setUp()
        signer = try! OnymNostrSigner(secretKey: Data(repeating: 0xEF, count: 32))
    }

    // MARK: - buildSendEvent

    func test_buildSendEvent_usesKind34113() throws {
        let event = try NostrInboxTransport.buildSendEvent(
            payload: Data(),
            inbox: TransportInboxID(rawValue: "abc123"),
            signer: signer
        )
        XCTAssertEqual(event.kind, 34113)
    }

    func test_buildSendEvent_emitsExpectedTagSet() throws {
        let event = try NostrInboxTransport.buildSendEvent(
            payload: Data(),
            inbox: TransportInboxID(rawValue: "abc123"),
            signer: signer
        )
        // Strip the appended ms tag — its value is non-deterministic.
        let userTags = event.tags.filter { $0.first != "ms" }
        XCTAssertEqual(userTags, [
            ["d", "sep-inbox:abc123"],
            ["t", "abc123"],
            ["sep_inbox", "abc123"],
            ["sep_version", "1"],
        ])
    }

    func test_buildSendEvent_dTagPrefixIsLoadBearing() throws {
        // A relay using the parameterised-replaceable `d` tag for routing
        // would key on the literal string — drift on the prefix would
        // silently break delivery.
        let event = try NostrInboxTransport.buildSendEvent(
            payload: Data(),
            inbox: TransportInboxID(rawValue: "id-1"),
            signer: signer
        )
        let dTag = event.tags.first { $0.first == "d" }
        XCTAssertEqual(dTag?[1], "sep-inbox:id-1")
    }

    func test_buildSendEvent_payloadRoundtripsViaBase64() throws {
        let payload = Data("invitation-blob".utf8)
        let event = try NostrInboxTransport.buildSendEvent(
            payload: payload,
            inbox: TransportInboxID(rawValue: "x"),
            signer: signer
        )
        XCTAssertEqual(Data(base64Encoded: event.content), payload)
    }

    func test_buildSendEvent_eventIDIsValid() throws {
        let event = try NostrInboxTransport.buildSendEvent(
            payload: Data("x".utf8),
            inbox: TransportInboxID(rawValue: "x"),
            signer: signer
        )
        XCTAssertTrue(event.verifyEventID())
    }

    // MARK: - subscriptionFilters

    func test_subscriptionFilters_returnsThreeShapes() {
        let filters = NostrInboxTransport.subscriptionFilters(inbox: "id-1")
        XCTAssertEqual(filters.count, 3,
                       "primary #d + secondary #t + legacy kind = 3 filters")
    }

    func test_subscriptionFilters_primaryUsesDTagWithPrefix() {
        let filters = NostrInboxTransport.subscriptionFilters(inbox: "id-1")
        let kinds = filters[0]["kinds"] as? [Int]
        let dValues = filters[0]["#d"] as? [String]
        XCTAssertEqual(kinds, [34113])
        XCTAssertEqual(dValues, ["sep-inbox:id-1"])
    }

    func test_subscriptionFilters_secondaryUsesTTagOnPrimaryKind() {
        let filters = NostrInboxTransport.subscriptionFilters(inbox: "id-1")
        let kinds = filters[1]["kinds"] as? [Int]
        let tValues = filters[1]["#t"] as? [String]
        XCTAssertEqual(kinds, [34113])
        XCTAssertEqual(tValues, ["id-1"])
    }

    func test_subscriptionFilters_legacyUsesTTagOnLegacyKind() {
        let filters = NostrInboxTransport.subscriptionFilters(inbox: "id-1")
        let kinds = filters[2]["kinds"] as? [Int]
        let tValues = filters[2]["#t"] as? [String]
        XCTAssertEqual(kinds, [24113])
        XCTAssertEqual(tValues, ["id-1"])
    }
}
