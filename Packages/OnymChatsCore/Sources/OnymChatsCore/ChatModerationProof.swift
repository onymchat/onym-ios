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
/// A message carrying media signs a v2 preimage, which adds a `media`
/// array committing to each attached blob's exact bytes. Without it an
/// attachment is unreportable in principle, not merely unimplemented:
/// nothing else in the system is a sender commitment to those bytes.
/// The transport envelope is not one — `SealedEnvelope` signs only the
/// ephemeral key it carries, so it authenticates who sent an envelope
/// but produces nothing a third party could later verify against the
/// content. Media sent before v2 therefore cannot be authenticated,
/// ever, and recipients simply cannot report it.
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

    /// Version emitted when the message carries media. A v2 preimage is
    /// a v1 preimage plus a `media` array committing to the exact bytes
    /// of every blob the message references.
    ///
    /// The version — not the mere presence of the field — is what a
    /// verifier dispatches on. A `media` array riding along in a v1
    /// preimage must be refused rather than honoured, or the
    /// discriminator would buy nothing.
    public static let mediaVersion = 2

    /// The sender's commitment to one attached blob's exact bytes.
    ///
    /// Two hashes, because they answer different questions.
    /// `plaintextSha256` is over the bytes a recipient actually decrypts
    /// and sees, so it is what an Authority re-derives from disclosed
    /// evidence without ever needing the attachment key.
    /// `blobSha256` is the ciphertext digest that already addresses the
    /// blob on the blob server, so the commitment stays tied to the
    /// stored object a recipient really fetched.
    ///
    /// Note that "plaintext" means the encoded bytes that travelled —
    /// `ChatImageEncoder`'s downscaled, re-encoded JPEG — not the
    /// original camera file. The evidence is what was received, which is
    /// the only thing a recipient can honestly disclose.
    ///
    /// `width`/`height` are omitted where they have no meaning (voice),
    /// which drops the keys from the preimage entirely rather than
    /// encoding a placeholder.
    public struct MediaCommitment: Encodable, Sendable, Equatable {
        public let blobSha256: String
        public let height: Int?
        public let mimeType: String
        public let plaintextByteLength: Int
        public let plaintextSha256: String
        public let width: Int?

        public init(
            blobSha256: String,
            mimeType: String,
            plaintextSha256: String,
            plaintextByteLength: Int,
            width: Int? = nil,
            height: Int? = nil
        ) {
            self.blobSha256 = blobSha256
            self.height = height
            self.mimeType = mimeType
            self.plaintextByteLength = plaintextByteLength
            self.plaintextSha256 = plaintextSha256
            self.width = width
        }

        enum CodingKeys: String, CodingKey {
            case blobSha256 = "blob_sha256"
            case height
            case mimeType = "mime_type"
            case plaintextByteLength = "plaintext_byte_length"
            case plaintextSha256 = "plaintext_sha256"
            case width
        }
    }

    /// Text-message preimage — unchanged v1 bytes.
    ///
    /// Kept as its own entry point so every existing text call site and
    /// its pinned bytes stay exactly as they were: a message with no
    /// media must still produce a v1 preimage, byte for byte.
    public static func signedContent(
        messageID: UUID,
        groupID: String,
        groupSecret: Data,
        sentAtMillis: Int64,
        body: String
    ) throws -> String {
        try signedContent(
            messageID: messageID,
            groupID: groupID,
            groupSecret: groupSecret,
            sentAtMillis: sentAtMillis,
            body: body,
            media: []
        )
    }

    /// Preimage for a message that may carry media.
    ///
    /// Empty `media` yields the v1 shape; a non-empty one yields v2.
    /// Media order is the message's own order and is part of the signed
    /// bytes, so an album cannot be reordered after the fact.
    public static func signedContent(
        messageID: UUID,
        groupID: String,
        groupSecret: Data,
        sentAtMillis: Int64,
        body: String,
        media: [MediaCommitment]
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
        /// v2 adds exactly one key. `media` sorts between
        /// `group_binding` and `message_id` by UTF-8 byte order, which
        /// `MediaPreimageKeyOrderTests` pins.
        struct MediaPreimage: Encodable {
            let body: String
            let groupBinding: String
            let media: [MediaCommitment]
            let messageID: String
            let proofVersion: Int
            let sentAtMillis: Int64

            enum CodingKeys: String, CodingKey {
                case body
                case groupBinding = "group_binding"
                case media
                case messageID = "message_id"
                case proofVersion = "proof_version"
                case sentAtMillis = "sent_at_millis"
            }
        }
        let messageIDString = messageID.uuidString.lowercased()
        let binding = groupBinding(
            groupID: groupID,
            groupSecret: groupSecret,
            messageIDString: messageIDString
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        if media.isEmpty {
            data = try encoder.encode(Preimage(
                body: body,
                groupBinding: binding,
                messageID: messageIDString,
                proofVersion: version,
                sentAtMillis: sentAtMillis
            ))
        } else {
            data = try encoder.encode(MediaPreimage(
                body: body,
                groupBinding: binding,
                media: media,
                messageID: messageIDString,
                proofVersion: mediaVersion,
                sentAtMillis: sentAtMillis
            ))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The keyed group binding shared by every preimage version. The
    /// domain string stays `v1`: it separates this hash from other uses
    /// of the group secret, and it is not the preimage's own version.
    private static func groupBinding(
        groupID: String,
        groupSecret: Data,
        messageIDString: String
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("onym-moderation-proof-v1|".utf8))
        hasher.update(data: groupSecret)
        hasher.update(data: Data("|\(groupID)|\(messageIDString)".utf8))
        return hasher.finalize()
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Millisecond timestamp recovered from a stored `sentAt` date.
    /// The receiver derives `sentAt` as `Date(millis / 1000)`; rounding
    /// the reverse conversion recovers the wire value exactly (Double
    /// carries sub-microsecond precision at epoch-seconds magnitude).
    public static func sentAtMillis(from sentAt: Date) -> Int64 {
        Int64((sentAt.timeIntervalSince1970 * 1000).rounded())
    }
}
