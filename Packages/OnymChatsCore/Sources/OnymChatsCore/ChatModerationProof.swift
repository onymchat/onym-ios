import CryptoKit
import Foundation

/// Canonical preimage of the moderation authenticity proof — the exact
/// string the sender signs and a reporter later discloses to an
/// Authority as `EvidenceItem.disclosedContent`.
///
/// The proof must bind the body to its message identity. A signature
/// over the bare body would be transferable: anyone holding a
/// (body, signature) pair — including a third party who was never a
/// recipient — could file it as evidence for any message, in any group,
/// at any time, and the Authority couldn't tell. Folding `messageID`,
/// `groupID`, and `sentAtMillis` into the signed bytes pins the proof
/// to one concrete send.
///
/// The preimage is a JSON object with **UTF-8 byte-ordered keys**
/// (`JSONEncoder.OutputFormatting.sortedKeys`), matching the canonical
/// form every other moderation signing payload uses. The Authority
/// never reconstructs these bytes — it verifies the signature over
/// `disclosedContent` verbatim and parses the context fields out of it —
/// so the only implementations that must agree byte-for-byte are the
/// signing sender and the verifying recipient, both of which are this
/// function.
///
/// The group is bound through `group_binding` — a SHA-256 over the
/// group's 32-byte shared secret (`ChatGroup.groupSecret`, sealed into
/// invitations and never on-chain), the group id, and the message id —
/// rather than the raw group id. Members recompute it from their
/// stored group, so the binding is just as tight, but the disclosed
/// content carries no identifier an outsider can resolve: group ids
/// are public on-chain lookup keys, so a keyless hash could be broken
/// by trial-hashing one candidate per group. The secret input closes
/// that — an Authority cannot correlate independent reports to one
/// group or join them against chain data — and the message id in the
/// preimage keeps two reports from the same group unlinkable to each
/// other as well.
public enum ChatModerationProof {
    /// Version discriminator inside the preimage so a future shape
    /// change can't be confused with this one.
    public static let version = 1

    public static func signedContent(
        messageID: UUID,
        groupID: String,
        groupSecret: Data,
        sentAtMillis: Int64,
        body: String
    ) throws -> String {
        struct Preimage: Encodable {
            let body: String
            let groupBinding: String
            let messageID: String
            let proofVersion: Int
            let sentAtMillis: Int64

            enum CodingKeys: String, CodingKey {
                case body
                case groupBinding = "group_binding"
                case messageID = "message_id"
                case proofVersion = "proof_version"
                case sentAtMillis = "sent_at_millis"
            }
        }
        let messageIDString = messageID.uuidString.lowercased()
        var hasher = SHA256()
        hasher.update(data: Data("onym-moderation-proof-v1|".utf8))
        hasher.update(data: groupSecret)
        hasher.update(data: Data("|\(groupID)|\(messageIDString)".utf8))
        let binding = hasher.finalize()
            .map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Preimage(
            body: body,
            groupBinding: binding,
            messageID: messageIDString,
            proofVersion: version,
            sentAtMillis: sentAtMillis
        ))
        return String(decoding: data, as: UTF8.self)
    }

    /// Millisecond timestamp recovered from a stored `sentAt` date.
    /// The receiver derives `sentAt` as `Date(millis / 1000)`; rounding
    /// the reverse conversion recovers the wire value exactly (Double
    /// carries sub-microsecond precision at epoch-seconds magnitude).
    public static func sentAtMillis(from sentAt: Date) -> Int64 {
        Int64((sentAt.timeIntervalSince1970 * 1000).rounded())
    }
}
