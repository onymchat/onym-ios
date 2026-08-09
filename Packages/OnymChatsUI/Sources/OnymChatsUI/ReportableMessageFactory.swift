import CryptoKit
import Foundation
import OnymChatsCore
import OnymGroup
import OnymModeration

/// Decides whether a chat message is reportable and, if so, packages
/// it for disclosure. Eligibility: an incoming, text-only message with
/// a sender proof that actually verifies against the sender's stored
/// Ed25519 key. Verifying here (not just checking presence) keeps a
/// sender who ships a garbage proof from getting a Report menu entry
/// that can only dead-end at submit time.
enum ReportableMessageFactory {
    static func make(
        from message: ChatMessage,
        memberProfiles: [String: MemberProfile]
    ) -> ReportableMessage? {
        guard message.direction == .incoming,
              message.media.isEmpty,
              message.voiceAttachment == nil,
              !message.body.isEmpty,
              let proof = message.moderationAuthenticityProof,
              let signature = Data(base64Encoded: proof),
              let profile = memberProfiles[message.senderBlsPubkeyHex],
              let senderKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: profile.sendingPubkey
              ),
              let disclosedContent = try? ChatModerationProof.signedContent(
                messageID: message.id,
                groupID: message.groupID,
                sentAtMillis: ChatModerationProof.sentAtMillis(from: message.sentAt),
                body: message.body
              ),
              senderKey.isValidSignature(signature, for: Data(disclosedContent.utf8))
        else { return nil }
        let accused = "onym:key:" + profile.sendingPubkey
            .map { String(format: "%02x", $0) }
            .joined()
        return ReportableMessage(
            id: message.id.uuidString.lowercased(),
            accused: accused,
            disclosedContent: disclosedContent,
            authenticityProof: proof,
            displayBody: message.body
        )
    }
}
