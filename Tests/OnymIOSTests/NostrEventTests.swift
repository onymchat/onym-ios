import XCTest
@testable import OnymIOS

/// Tests for the NIP-01 wire format and the integrity check that
/// `NostrRelayConnection` runs on every inbound event. These are the
/// only invariants that protect us from relay-side tampering, so the
/// coverage is deliberately blunt: build → mutate one byte → verify
/// fails.
final class NostrEventTests: XCTestCase {
    private var signer: OnymNostrSigner!

    override func setUp() {
        super.setUp()
        // Deterministic 32-byte secret so generated event ids are stable
        // across runs — makes failures easier to debug than a random key.
        let secret = Data(repeating: 0xAB, count: 32)
        signer = try! OnymNostrSigner(secretKey: secret)
    }

    // MARK: - build

    func test_build_producesValidEventID() throws {
        let event = try NostrEvent.build(
            kind: 44114,
            tags: [["t", "topic-x"]],
            content: "hello",
            signer: signer
        )
        XCTAssertTrue(event.verifyEventID(), "freshly built event must verify")
    }

    func test_build_appendsMillisecondTag() throws {
        let event = try NostrEvent.build(
            kind: 44114,
            tags: [["t", "topic-x"]],
            content: "hello",
            signer: signer
        )
        let msTag = event.tags.first { $0.first == "ms" }
        XCTAssertNotNil(msTag, "build() must append [\"ms\", ...]")
        XCTAssertEqual(msTag?.count, 2)
        let ms = Int64(msTag?[1] ?? "")
        XCTAssertNotNil(ms)
        // Within 5s of "now" — sanity, not exact equality.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThan(abs((ms ?? 0) - nowMs), 5_000)
    }

    func test_build_signatureIs64Bytes() throws {
        let event = try NostrEvent.build(
            kind: 44114,
            tags: [],
            content: "x",
            signer: signer
        )
        XCTAssertEqual(event.sig.count, 128, "BIP340 sig is 64 bytes = 128 hex chars")
    }

    func test_build_pubkeyMatchesSigner() throws {
        let event = try NostrEvent.build(
            kind: 44114,
            tags: [],
            content: "x",
            signer: signer
        )
        let expectedPubkeyHex = try signer.publicKey().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(event.pubkey, expectedPubkeyHex)
    }

    func test_build_preservesCallerProvidedTags() throws {
        let userTags: [[String]] = [["t", "topic-x"], ["sep_version", "1"]]
        let event = try NostrEvent.build(
            kind: 34113,
            tags: userTags,
            content: "x",
            signer: signer
        )
        // Caller tags appear first, then the appended ms tag.
        XCTAssertEqual(Array(event.tags.prefix(userTags.count)), userTags)
    }

    // MARK: - verifyEventID tampering

    func test_verifyEventID_rejectsTamperedContent() throws {
        let event = try NostrEvent.build(kind: 44114, tags: [], content: "hello", signer: signer)
        let tampered = NostrEvent(
            id: event.id, pubkey: event.pubkey, createdAt: event.createdAt,
            kind: event.kind, tags: event.tags,
            content: "goodbye", sig: event.sig
        )
        XCTAssertFalse(tampered.verifyEventID())
    }

    func test_verifyEventID_rejectsTamperedTags() throws {
        let event = try NostrEvent.build(kind: 44114, tags: [["t", "a"]], content: "x", signer: signer)
        let tampered = NostrEvent(
            id: event.id, pubkey: event.pubkey, createdAt: event.createdAt,
            kind: event.kind,
            tags: [["t", "b"]] + event.tags.dropFirst(),
            content: event.content, sig: event.sig
        )
        XCTAssertFalse(tampered.verifyEventID())
    }

    func test_verifyEventID_rejectsTamperedKind() throws {
        let event = try NostrEvent.build(kind: 44114, tags: [], content: "x", signer: signer)
        let tampered = NostrEvent(
            id: event.id, pubkey: event.pubkey, createdAt: event.createdAt,
            kind: 1, tags: event.tags,
            content: event.content, sig: event.sig
        )
        XCTAssertFalse(tampered.verifyEventID())
    }

    // MARK: - displayMilliseconds

    func test_displayMilliseconds_readsMsTag() {
        let event = NostrEvent(
            id: "00", pubkey: "00", createdAt: 1_700_000_000,
            kind: 44114, tags: [["ms", "1700000000123"]],
            content: "", sig: ""
        )
        XCTAssertEqual(event.displayMilliseconds, 1_700_000_000_123)
    }

    func test_displayMilliseconds_fallsBackToCreatedAt() {
        let event = NostrEvent(
            id: "00", pubkey: "00", createdAt: 1_700_000_000,
            kind: 44114, tags: [],
            content: "", sig: ""
        )
        XCTAssertEqual(event.displayMilliseconds, 1_700_000_000_000)
    }

    func test_displayMilliseconds_ignoresMalformedMsTag() {
        let event = NostrEvent(
            id: "00", pubkey: "00", createdAt: 1_700_000_000,
            kind: 44114, tags: [["ms", "not-a-number"]],
            content: "", sig: ""
        )
        XCTAssertEqual(event.displayMilliseconds, 1_700_000_000_000)
    }

    func test_displayMilliseconds_ignoresNegativeMs() {
        let event = NostrEvent(
            id: "00", pubkey: "00", createdAt: 1_700_000_000,
            kind: 44114, tags: [["ms", "-1"]],
            content: "", sig: ""
        )
        XCTAssertEqual(event.displayMilliseconds, 1_700_000_000_000)
    }

    // MARK: - Codable

    func test_codable_usesCreatedAtFieldName() throws {
        let event = NostrEvent(
            id: "deadbeef", pubkey: "abc", createdAt: 42,
            kind: 1, tags: [["t", "x"]], content: "hi", sig: "sig"
        )
        let json = try JSONEncoder().encode(event)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertNotNil(dict?["created_at"], "wire field is `created_at`, not `createdAt`")
        XCTAssertNil(dict?["createdAt"])
    }

    func test_codable_roundtrip() throws {
        let original = NostrEvent(
            id: "deadbeef", pubkey: "abc", createdAt: 42,
            kind: 1, tags: [["t", "x"], ["ms", "42000"]], content: "hi", sig: "sig"
        )
        let json = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NostrEvent.self, from: json)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.tags, original.tags)
        XCTAssertEqual(decoded.content, original.content)
    }
}
