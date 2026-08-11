import XCTest
import OnymChatsCore

/// The exact bytes a sender signs as a moderation authenticity proof.
///
/// These are golden-byte tests on purpose. The preimage is verified by
/// an Authority written in another language (Rust, today), and the
/// Authority never reconstructs it — it verifies a signature over the
/// disclosed string verbatim and parses fields out. So drift here does
/// not surface as a parse error on either side; it surfaces as "every
/// report signature for media is invalid", silently, in production.
///
/// Two properties are load-bearing and neither is obvious from reading
/// the encoder call:
///
///  - Keys sort by **UTF-8 byte order** (`JSONEncoder`'s `.sortedKeys`,
///    not `JSONSerialization`'s case-insensitive option of the same
///    name), so `media` lands between `group_binding` and `message_id`.
///  - Forward slashes are **escaped** (`image\/jpeg`), because the
///    preimage encoder deliberately does not set
///    `.withoutEscapingSlashes`. Adding that option would be a silent
///    breaking change: a v1 body containing "/" would stop reproducing
///    the bytes its sender already signed, retroactively invalidating
///    the proof on every such message already delivered.
final class ChatModerationProofTests: XCTestCase {
    private let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let groupID = "group-1"
    private let groupSecret = Data(repeating: 0x07, count: 32)
    private let sentAtMillis: Int64 = 1_785_580_800_123

    /// SHA-256 over `"onym-moderation-proof-v1|" ‖ secret ‖ "|<group>|<message>"`
    /// for the fixture above, computed independently of this code.
    private let binding = "18413f675da1f5410fa8e199b799c2bf3700575ddac201c9a8d2dfdf8327ce6a"

    private let blobSha = String(repeating: "0f", count: 32)
    private let plaintextSha = String(repeating: "1a", count: 32)

    private func imageCommitment() -> ChatModerationProof.MediaCommitment {
        ChatModerationProof.MediaCommitment(
            blobSha256: blobSha,
            mimeType: "image/jpeg",
            plaintextSha256: plaintextSha,
            plaintextByteLength: 421_337,
            width: 1200,
            height: 1600
        )
    }

    private func content(
        body: String = "hello",
        media: [ChatModerationProof.MediaCommitment]
    ) throws -> String {
        try ChatModerationProof.signedContent(
            messageID: messageID,
            groupID: groupID,
            groupSecret: groupSecret,
            sentAtMillis: sentAtMillis,
            body: body,
            media: media
        )
    }

    /// A message with no media must still produce v1 bytes, exactly.
    /// Every text proof already signed by a shipped client depends on
    /// this, so it is the one assertion that must never be "updated to
    /// match" a new implementation.
    func test_textMessage_producesTheExactV1Preimage() throws {
        let expected = #"{"body":"hello","group_binding":"\#(binding)","message_id":"00000000-0000-0000-0000-000000000001","proof_version":1,"sent_at_millis":1785580800123}"#
        XCTAssertEqual(try content(media: []), expected)
    }

    /// The convenience entry point text sends use must be identical to
    /// passing no media, or the two call paths would drift apart.
    func test_theTextEntryPoint_matchesAnEmptyMediaList() throws {
        let viaTextPath = try ChatModerationProof.signedContent(
            messageID: messageID,
            groupID: groupID,
            groupSecret: groupSecret,
            sentAtMillis: sentAtMillis,
            body: "hello"
        )
        XCTAssertEqual(viaTextPath, try content(media: []))
    }

    /// The full v2 shape: `media` sorted into place, entry keys in byte
    /// order, and the escaped slash in the MIME type.
    func test_mediaMessage_producesTheExactV2Preimage() throws {
        let expected = #"{"body":"hello","group_binding":"\#(binding)","media":[{"blob_sha256":"\#(blobSha)","height":1600,"mime_type":"image\/jpeg","plaintext_byte_length":421337,"plaintext_sha256":"\#(plaintextSha)","width":1200}],"message_id":"00000000-0000-0000-0000-000000000001","proof_version":2,"sent_at_millis":1785580800123}"#
        XCTAssertEqual(try content(media: [imageCommitment()]), expected)
    }

    /// `media` must sort between `group_binding` and `message_id`.
    /// Case-insensitive sorting would also place it there, so this is
    /// not the test that catches a `JSONSerialization` swap — it pins
    /// the position a verifier's field scan depends on.
    func test_mediaKeySortsBetweenGroupBindingAndMessageID() throws {
        let text = try content(media: [imageCommitment()])
        let group = try XCTUnwrap(text.range(of: "\"group_binding\""))
        let media = try XCTUnwrap(text.range(of: "\"media\""))
        let message = try XCTUnwrap(text.range(of: "\"message_id\""))
        XCTAssertTrue(group.lowerBound < media.lowerBound)
        XCTAssertTrue(media.lowerBound < message.lowerBound)
    }

    /// Audio has no pixel dimensions, so those keys are absent rather
    /// than carrying a zero a verifier might read as a real value.
    func test_mediaWithoutDimensions_omitsWidthAndHeight() throws {
        let voice = ChatModerationProof.MediaCommitment(
            blobSha256: blobSha,
            mimeType: "audio/mp4",
            plaintextSha256: plaintextSha,
            plaintextByteLength: 9
        )
        let expected = #"{"body":"","group_binding":"\#(binding)","media":[{"blob_sha256":"\#(blobSha)","mime_type":"audio\/mp4","plaintext_byte_length":9,"plaintext_sha256":"\#(plaintextSha)"}],"message_id":"00000000-0000-0000-0000-000000000001","proof_version":2,"sent_at_millis":1785580800123}"#
        XCTAssertEqual(try content(body: "", media: [voice]), expected)
    }

    /// Album order is inside the signed bytes, so a reporter cannot
    /// present item 2 as item 1 and a sender cannot later claim a
    /// different arrangement.
    func test_mediaOrderIsSigned() throws {
        let second = ChatModerationProof.MediaCommitment(
            blobSha256: String(repeating: "ee", count: 32),
            mimeType: "image/jpeg",
            plaintextSha256: String(repeating: "dd", count: 32),
            plaintextByteLength: 10,
            width: 4,
            height: 5
        )
        let forward = try content(media: [imageCommitment(), second])
        let reversed = try content(media: [second, imageCommitment()])
        XCTAssertNotEqual(forward, reversed)
    }

    /// Each committed field must actually change the bytes. A field
    /// that silently fell out of the preimage would leave the Authority
    /// checking a value nobody signed.
    func test_everyCommittedFieldChangesTheSignedBytes() throws {
        let base = try content(media: [imageCommitment()])
        let variants: [ChatModerationProof.MediaCommitment] = [
            .init(blobSha256: String(repeating: "cc", count: 32), mimeType: "image/jpeg",
                  plaintextSha256: plaintextSha, plaintextByteLength: 421_337,
                  width: 1200, height: 1600),
            .init(blobSha256: blobSha, mimeType: "image/png",
                  plaintextSha256: plaintextSha, plaintextByteLength: 421_337,
                  width: 1200, height: 1600),
            .init(blobSha256: blobSha, mimeType: "image/jpeg",
                  plaintextSha256: String(repeating: "cc", count: 32), plaintextByteLength: 421_337,
                  width: 1200, height: 1600),
            .init(blobSha256: blobSha, mimeType: "image/jpeg",
                  plaintextSha256: plaintextSha, plaintextByteLength: 421_338,
                  width: 1200, height: 1600),
            .init(blobSha256: blobSha, mimeType: "image/jpeg",
                  plaintextSha256: plaintextSha, plaintextByteLength: 421_337,
                  width: 1201, height: 1600),
            .init(blobSha256: blobSha, mimeType: "image/jpeg",
                  plaintextSha256: plaintextSha, plaintextByteLength: 421_337,
                  width: 1200, height: 1601),
        ]
        for variant in variants {
            XCTAssertNotEqual(try content(media: [variant]), base)
        }
    }

    /// The version discriminator, not the presence of the field, is
    /// what a verifier dispatches on — so it must actually move.
    func test_versionDiscriminatorDistinguishesTheTwoShapes() throws {
        XCTAssertTrue(try content(media: []).contains("\"proof_version\":1"))
        XCTAssertTrue(try content(media: [imageCommitment()]).contains("\"proof_version\":2"))
    }
}
