import CryptoKit
import Foundation
import OnymChatsCore
import OnymGroup
import OnymModeration

/// Decides whether a chat message is reportable and, if so, packages
/// it for disclosure. Eligibility: an incoming message with a sender
/// proof that actually verifies against the sender's stored Ed25519
/// key. Verifying here (not just checking presence) keeps a sender who
/// ships a garbage proof from getting a Report menu entry that can only
/// dead-end at submit time.
///
/// A single received photo is reportable on the same terms. What makes
/// that possible is the version 2 proof preimage, which commits to the
/// attachment's plaintext digest — so the check below is the same one
/// in a second place: recompute the digest of the bytes actually held
/// and require the sender to have signed *that*. A photo whose bytes
/// do not match its commitment is not evidence of anything, and a
/// Report entry that led there would dead-end at the Authority.
///
/// Video, album and voice messages are signed at send time but no
/// Authority accepts them as evidence yet, so they stay unreportable.
enum ReportableMessageFactory {
    /// Whether a Report entry should appear in the message's menu.
    ///
    /// Split from `make` because a photo's verification needs the
    /// decrypted bytes, which come from an actor, and a context menu
    /// cannot await. Text is fully verified here exactly as before —
    /// it costs nothing extra. A photo is checked as far as it can be
    /// without its bytes; the byte-level check still happens, in `make`,
    /// before anything is disclosed.
    ///
    /// The asymmetry is deliberate and safe in one direction only: this
    /// may offer Report for a photo that later fails verification, and
    /// the flow shows nothing rather than filing. It must never refuse
    /// something `make` would have accepted.
    static func isReportable(
        from message: ChatMessage,
        memberProfiles: [String: MemberProfile],
        groupSecret: Data
    ) -> Bool {
        guard message.direction == .incoming,
              message.voiceAttachment == nil,
              message.videoAttachment == nil,
              message.albumAttachments == nil,
              message.moderationAuthenticityProof != nil,
              memberProfiles[message.senderBlsPubkeyHex] != nil
        else { return false }

        if message.imageAttachment != nil {
            return message.media.count <= 1
        }
        return make(
            from: message,
            memberProfiles: memberProfiles,
            groupSecret: groupSecret
        ) != nil
    }

    static func make(
        from message: ChatMessage,
        memberProfiles: [String: MemberProfile],
        groupSecret: Data,
        attachmentBytes: Data? = nil
    ) -> ReportableMessage? {
        guard message.direction == .incoming,
              message.voiceAttachment == nil,
              message.videoAttachment == nil,
              message.albumAttachments == nil,
              let proof = message.moderationAuthenticityProof,
              let signature = Data(base64Encoded: proof),
              let profile = memberProfiles[message.senderBlsPubkeyHex],
              let senderKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: profile.sendingPubkey
              )
        else { return nil }

        let accused = "onym:key:" + profile.sendingPubkey
            .map { String(format: "%02x", $0) }
            .joined()
        let sentAtMillis = ChatModerationProof.sentAtMillis(from: message.sentAt)

        // Photo: the decrypted bytes must be in hand, and must be the
        // ones the sender committed to.
        if let attachment = message.imageAttachment {
            guard let bytes = attachmentBytes,
                  message.media.count <= 1,
                  let commitment = try? commitment(for: attachment, bytes: bytes),
                  let disclosedContent = try? ChatModerationProof.signedContent(
                    messageID: message.id,
                    groupID: message.groupID,
                    groupSecret: groupSecret,
                    sentAtMillis: sentAtMillis,
                    body: message.body,
                    media: [commitment]
                  ),
                  senderKey.isValidSignature(signature, for: Data(disclosedContent.utf8))
            else { return nil }

            return ReportableMessage(
                id: message.id.uuidString.lowercased(),
                accused: accused,
                disclosedContent: disclosedContent,
                authenticityProof: proof,
                displayBody: message.body,
                images: [ReportableMessage.Image(
                    sha256: commitment.plaintextSha256,
                    bytes: bytes,
                    width: attachment.width,
                    height: attachment.height
                )]
            )
        }

        // Text: unchanged.
        guard message.media.isEmpty,
              !message.body.isEmpty,
              let disclosedContent = try? ChatModerationProof.signedContent(
                messageID: message.id,
                groupID: message.groupID,
                groupSecret: groupSecret,
                sentAtMillis: sentAtMillis,
                body: message.body
              ),
              senderKey.isValidSignature(signature, for: Data(disclosedContent.utf8))
        else { return nil }

        return ReportableMessage(
            id: message.id.uuidString.lowercased(),
            accused: accused,
            disclosedContent: disclosedContent,
            authenticityProof: proof,
            displayBody: message.body
        )
    }

    /// Rebuild the sender's media commitment from the attachment
    /// descriptor and the bytes this device decrypted.
    ///
    /// The digest is computed here rather than taken from anywhere: it
    /// is the whole point. If these bytes hash to something the sender
    /// did not sign, the signature check above fails and no Report
    /// entry appears.
    private static func commitment(
        for attachment: ChatImageAttachment,
        bytes: Data
    ) throws -> ChatModerationProof.MediaCommitment {
        ChatModerationProof.MediaCommitment(
            blobSha256: attachment.sha256,
            mimeType: attachment.mimeType,
            plaintextSha256: ChatImageCrypto.sha256Hex(bytes),
            plaintextByteLength: bytes.count,
            width: attachment.width,
            height: attachment.height
        )
    }
}
