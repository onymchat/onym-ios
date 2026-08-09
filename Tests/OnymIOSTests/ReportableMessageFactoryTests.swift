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

    func test_incomingSignedTextMessage_isReportable() throws {
        let message = try signedMessage(body: "prohibited content")

        let reportable = try XCTUnwrap(
            ReportableMessageFactory.make(from: message, memberProfiles: profiles())
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
        XCTAssertNil(ReportableMessageFactory.make(from: message, memberProfiles: profiles()))
    }

    func test_messageWithoutProof_isNotReportable() throws {
        let message = try signedMessage(proofOverride: .some(nil))
        XCTAssertNil(ReportableMessageFactory.make(from: message, memberProfiles: profiles()))
    }

    func test_messageWithGarbageProof_isNotReportable() throws {
        // Present but unverifiable — mere presence must not surface the
        // menu entry (it could only fail later, at submit).
        let message = try signedMessage(
            proofOverride: .some(Data(repeating: 7, count: 64).base64EncodedString())
        )
        XCTAssertNil(ReportableMessageFactory.make(from: message, memberProfiles: profiles()))
    }

    func test_proofOverBareBody_isNotReportable() throws {
        // Legacy / non-canonical proof: a signature over the bare body
        // is transferable and must not be exportable as evidence.
        let body = "prohibited content"
        let bareProof = try senderKey.signature(for: Data(body.utf8)).base64EncodedString()
        let message = try signedMessage(body: body, proofOverride: .some(bareProof))
        XCTAssertNil(ReportableMessageFactory.make(from: message, memberProfiles: profiles()))
    }

    func test_emptyBody_isNotReportable() throws {
        let message = try signedMessage(body: "")
        XCTAssertNil(ReportableMessageFactory.make(from: message, memberProfiles: profiles()))
    }

    func test_unknownSender_isNotReportable() throws {
        let message = try signedMessage()
        XCTAssertNil(ReportableMessageFactory.make(from: message, memberProfiles: [:]))
    }

    func test_mediaMessage_isNotReportable() throws {
        let image = ChatImageAttachment(
            sha256: String(repeating: "cd", count: 32),
            mimeType: "image/jpeg",
            byteSize: 1234,
            width: 10,
            height: 10,
            encKey: Data(repeating: 7, count: 32),
            blurhash: "LEHV6nWB2yk8",
            server: "https://blossom.onym.app"
        )
        let message = try signedMessage(imageAttachment: image)
        XCTAssertNil(ReportableMessageFactory.make(from: message, memberProfiles: profiles()))
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
        XCTAssertNil(ReportableMessageFactory.make(from: message, memberProfiles: profiles()))
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
