import CryptoKit
import XCTest
@testable import OnymChatsUI
import OnymChatsCore
import OnymGroup
import OnymIdentity

/// Eligibility rules for the Report context-menu entry —
/// `ReportableMessageFactory.make` decides which messages can be
/// disclosed. Only an incoming, text-only message whose sender proof
/// actually verifies against the sender's stored Ed25519 key is
/// reportable; everything else must return nil so the menu never
/// offers a report that can only dead-end at submit.
final class ReportableMessageFactoryTests: XCTestCase {

    private let senderKey = Curve25519.Signing.PrivateKey()
    private let senderHex = String(repeating: "11", count: 48)
    private let groupID = String(repeating: "aa", count: 32)
    private let groupSecret = Data(repeating: 0x55, count: 32)

    func test_incomingSignedTextMessage_isReportable() throws {
        let message = try signedMessage(body: "prohibited content")

        let reportable = try XCTUnwrap(
            ReportableMessageFactory.make(
            from: message, memberProfiles: profiles(), groupSecret: groupSecret
        )
        )

        XCTAssertEqual(reportable.id, message.id.uuidString.lowercased())
        XCTAssertEqual(
            reportable.accused,
            "onym:key:" + senderKey.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(reportable.displayBody, "prohibited content")
        XCTAssertEqual(reportable.disclosedContent, try ChatModerationProof.signedContent(
            messageID: message.id,
            groupID: groupID,
            groupSecret: groupSecret,
            sentAtMillis: ChatModerationProof.sentAtMillis(from: message.sentAt),
            body: message.body
        ))
        // The exported pair must verify exactly the way the repository
        // and the Authority will check it.
        let signature = try XCTUnwrap(Data(base64Encoded: reportable.authenticityProof))
        XCTAssertTrue(senderKey.publicKey.isValidSignature(
            signature, for: Data(reportable.disclosedContent.utf8)
        ))
    }

    func test_outgoingMessage_isNotReportable() throws {
        let message = try signedMessage(direction: .outgoing)
        XCTAssertNil(ReportableMessageFactory.make(
            from: message, memberProfiles: profiles(), groupSecret: groupSecret
        ))
    }

    func test_messageWithoutProof_isNotReportable() throws {
        let message = try signedMessage(proofOverride: .some(nil))
        XCTAssertNil(ReportableMessageFactory.make(
            from: message, memberProfiles: profiles(), groupSecret: groupSecret
        ))
    }

    func test_messageWithGarbageProof_isNotReportable() throws {
        // Present but unverifiable — mere presence must not surface the
        // menu entry (it could only fail later, at submit).
        let message = try signedMessage(
            proofOverride: .some(Data(repeating: 7, count: 64).base64EncodedString())
        )
        XCTAssertNil(ReportableMessageFactory.make(
            from: message, memberProfiles: profiles(), groupSecret: groupSecret
        ))
    }

    func test_proofOverBareBody_isNotReportable() throws {
        // Legacy / non-canonical proof: a signature over the bare body
        // is transferable and must not be exportable as evidence.
        let body = "prohibited content"
        let bareProof = try senderKey.signature(for: Data(body.utf8)).base64EncodedString()
        let message = try signedMessage(body: body, proofOverride: .some(bareProof))
        XCTAssertNil(ReportableMessageFactory.make(
            from: message, memberProfiles: profiles(), groupSecret: groupSecret
        ))
    }

    func test_wrongGroupSecret_isNotReportable() throws {
        // The group binding is keyed by the group's shared secret; a
        // preimage rebuilt with a different secret must not verify.
        let message = try signedMessage()
        XCTAssertNil(ReportableMessageFactory.make(
            from: message,
            memberProfiles: profiles(),
            groupSecret: Data(repeating: 0x66, count: 32)
        ))
    }

    func test_emptyBody_isNotReportable() throws {
        let message = try signedMessage(body: "")
        XCTAssertNil(ReportableMessageFactory.make(
            from: message, memberProfiles: profiles(), groupSecret: groupSecret
        ))
    }

    func test_unknownSender_isNotReportable() throws {
        let message = try signedMessage()
        XCTAssertNil(ReportableMessageFactory.make(
            from: message, memberProfiles: [:], groupSecret: groupSecret
        ))
    }

    // MARK: - Photos

    /// The happy path: a received photo whose bytes hash to the digest
    /// its sender signed.
    func test_receivedPhoto_isReportable() throws {
        let bytes = Data("the exact jpeg bytes that travelled".utf8)
        let (message, attachment) = try signedPhotoMessage(bytes: bytes)

        let reportable = try XCTUnwrap(ReportableMessageFactory.make(
            from: message,
            memberProfiles: profiles(),
            groupSecret: groupSecret,
            attachmentBytes: bytes
        ))

        XCTAssertEqual(reportable.images.count, 1)
        XCTAssertEqual(reportable.images[0].bytes, bytes)
        XCTAssertEqual(reportable.images[0].sha256, ChatImageCrypto.sha256Hex(bytes))
        XCTAssertEqual(reportable.images[0].width, attachment.width)
        // And the disclosed content is the v2 preimage the sender
        // signed, verifying exactly as the Authority will check it.
        let signature = try XCTUnwrap(Data(base64Encoded: reportable.authenticityProof))
        XCTAssertTrue(senderKey.publicKey.isValidSignature(
            signature, for: Data(reportable.disclosedContent.utf8)
        ))
        XCTAssertTrue(reportable.disclosedContent.contains("\"proof_version\":2"))
    }

    /// One flipped byte and this is a different picture, which the
    /// sender never signed. Catching it here keeps the menu from
    /// offering a report that could only fail at the Authority.
    func test_photoWhoseBytesDoNotMatchTheCommitment_isNotReportable() throws {
        let (message, _) = try signedPhotoMessage(bytes: Data("original".utf8))

        XCTAssertNil(ReportableMessageFactory.make(
            from: message,
            memberProfiles: profiles(),
            groupSecret: groupSecret,
            attachmentBytes: Data("tampered".utf8)
        ))
    }

    /// Without the decrypted bytes there is nothing to verify against,
    /// so there is nothing to disclose.
    func test_photoWithoutItsBytes_isNotReportable() throws {
        let (message, _) = try signedPhotoMessage(bytes: Data("the bytes".utf8))

        XCTAssertNil(ReportableMessageFactory.make(
            from: message, memberProfiles: profiles(), groupSecret: groupSecret
        ))
    }

    /// A photo sent before proof v2 carries a v1 signature that commits
    /// to the caption alone. It cannot be authenticated, ever.
    func test_photoSignedBeforeMediaCommitmentsExisted_isNotReportable() throws {
        let bytes = Data("the bytes".utf8)
        let image = attachment(for: bytes)
        // `signedMessage` signs a v1 preimage — exactly what a client
        // shipped before this feature produced.
        let message = try signedMessage(body: "caption", imageAttachment: image)

        XCTAssertNil(ReportableMessageFactory.make(
            from: message,
            memberProfiles: profiles(),
            groupSecret: groupSecret,
            attachmentBytes: bytes
        ))
    }

    /// The menu predicate may be optimistic about photos — it cannot
    /// await the bytes — but it must never be optimistic about a kind
    /// of message the disclosure path would refuse outright.
    func test_eligibilityNeverOffersWhatDisclosureWouldRefuse() throws {
        let voice = ChatVoiceAttachment(
            sha256: String(repeating: "cd", count: 32),
            mimeType: "audio/mp4",
            byteSize: 1234,
            durationSeconds: 2,
            encKey: Data(repeating: 7, count: 32),
            waveform: [1, 2, 3],
            server: "https://blossom.onym.app"
        )
        for message in [
            try signedMessage(direction: .outgoing),
            try signedMessage(proofOverride: .some(nil)),
            try signedMessage(voiceAttachment: voice),
        ] {
            XCTAssertFalse(ReportableMessageFactory.isReportable(
                from: message, memberProfiles: profiles(), groupSecret: groupSecret
            ))
        }
        // And a photo, which it cannot fully check, is offered.
        let (photo, _) = try signedPhotoMessage(bytes: Data("bytes".utf8))
        XCTAssertTrue(ReportableMessageFactory.isReportable(
            from: photo, memberProfiles: profiles(), groupSecret: groupSecret
        ))
    }

    func test_voiceMessage_isNotReportable() throws {
        let voice = ChatVoiceAttachment(
            sha256: String(repeating: "cd", count: 32),
            mimeType: "audio/mp4",
            byteSize: 1234,
            durationSeconds: 2,
            encKey: Data(repeating: 7, count: 32),
            waveform: [10, 200],
            server: "https://blossom.onym.app"
        )
        let message = try signedMessage(body: "caption", voiceAttachment: voice)
        XCTAssertNil(ReportableMessageFactory.make(
            from: message, memberProfiles: profiles(), groupSecret: groupSecret
        ))
    }

    // MARK: - Helpers

    private func profiles() -> [String: MemberProfile] {
        [senderHex: MemberProfile(
            alias: "Sender",
            inboxPublicKey: Data(repeating: 1, count: 32),
            sendingPubkey: senderKey.publicKey.rawRepresentation
        )]
    }

    /// An incoming message whose proof is a valid canonical-preimage
    /// signature by `senderKey`, unless overridden. `proofOverride`
    /// distinguishes "leave the valid proof" (nil) from "force this
    /// value, including no proof at all" (.some).
    /// The attachment descriptor a sender would build for `bytes`.
    private func attachment(for bytes: Data) -> ChatImageAttachment {
        ChatImageAttachment(
            sha256: String(repeating: "cd", count: 32),
            mimeType: "image/jpeg",
            byteSize: bytes.count + 28,
            width: 10,
            height: 10,
            encKey: Data(repeating: 7, count: 32),
            blurhash: "LEHV6nWB2yk8",
            server: "https://blossom.onym.app"
        )
    }

    /// An incoming photo message whose proof is a v2 preimage
    /// committing to `bytes` — what a post-proof-v2 sender produces.
    private func signedPhotoMessage(
        bytes: Data,
        body: String = ""
    ) throws -> (ChatMessage, ChatImageAttachment) {
        let image = attachment(for: bytes)
        let id = UUID()
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let preimage = try ChatModerationProof.signedContent(
            messageID: id,
            groupID: groupID,
            groupSecret: groupSecret,
            sentAtMillis: ChatModerationProof.sentAtMillis(from: sentAt),
            body: body,
            media: [ChatModerationProof.MediaCommitment(
                blobSha256: image.sha256,
                mimeType: image.mimeType,
                plaintextSha256: ChatImageCrypto.sha256Hex(bytes),
                plaintextByteLength: bytes.count,
                width: image.width,
                height: image.height
            )]
        )
        let message = ChatMessage(
            id: id,
            groupID: groupID,
            ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: senderHex,
            body: body,
            sentAt: sentAt,
            direction: .incoming,
            status: .received,
            replyToMessageID: nil,
            groupType: .tyranny,
            moderationAuthenticityProof: try senderKey
                .signature(for: Data(preimage.utf8)).base64EncodedString(),
            imageAttachment: image
        )
        return (message, image)
    }

    private func signedMessage(
        body: String = "prohibited content",
        direction: MessageDirection = .incoming,
        proofOverride: String?? = nil,
        imageAttachment: ChatImageAttachment? = nil,
        voiceAttachment: ChatVoiceAttachment? = nil
    ) throws -> ChatMessage {
        let id = UUID()
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let proof: String?
        if let proofOverride {
            proof = proofOverride
        } else {
            let preimage = try ChatModerationProof.signedContent(
                messageID: id,
                groupID: groupID,
                groupSecret: groupSecret,
                sentAtMillis: ChatModerationProof.sentAtMillis(from: sentAt),
                body: body
            )
            proof = try senderKey.signature(for: Data(preimage.utf8)).base64EncodedString()
        }
        return ChatMessage(
            id: id,
            groupID: groupID,
            ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: senderHex,
            body: body,
            sentAt: sentAt,
            direction: direction,
            status: direction == .incoming ? .received : .sent,
            replyToMessageID: nil,
            groupType: .tyranny,
            moderationAuthenticityProof: proof,
            imageAttachment: imageAttachment,
            voiceAttachment: voiceAttachment
        )
    }
}
