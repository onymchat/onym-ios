import Foundation

/// The archive's wire schema.
///
/// These are **not** the app's domain models, and that separation is
/// load-bearing: an archive written today must still decode years later
/// on a device running a client whose `ChatGroup` has been renamed,
/// split, or re-typed twice over. Conforming the domain models to
/// `Codable` would tie the on-disk schema to whatever refactor lands
/// next; an explicit mirror makes a schema change a deliberate act with
/// a version bump attached.
///
/// Everything here is plaintext *inside the seal*. It carries group
/// secrets and per-blob content keys, because that is what makes a
/// restore a restore rather than a transcript — the rule is that none of
/// it is ever legible to an operator, not that it is absent
/// (`UI-Backup.md` §14.1).

/// One chat group.
public struct BackupGroupRecord: Sendable, Equatable, Codable {
    public let id: String
    public let ownerIdentityID: String
    public let name: String
    public let groupSecret: Data
    public let createdAt: Date
    public let membersJSON: Data
    public let memberProfilesJSON: Data
    public let epoch: UInt64
    public let salt: Data
    public let commitment: Data?
    public let tierRaw: Int
    public let groupTypeRaw: String
    public let adminPubkeyHex: String?
    public let adminEd25519PubkeyHex: String?
    public let isPublishedOnChain: Bool
    public let avatarJPEG: Data?
    public let lastReadAt: Date?
    public let invitationMessage: String?

    public init(
        id: String,
        ownerIdentityID: String,
        name: String,
        groupSecret: Data,
        createdAt: Date,
        membersJSON: Data,
        memberProfilesJSON: Data,
        epoch: UInt64,
        salt: Data,
        commitment: Data?,
        tierRaw: Int,
        groupTypeRaw: String,
        adminPubkeyHex: String?,
        adminEd25519PubkeyHex: String?,
        isPublishedOnChain: Bool,
        avatarJPEG: Data?,
        lastReadAt: Date?,
        invitationMessage: String?
    ) {
        self.id = id
        self.ownerIdentityID = ownerIdentityID
        self.name = name
        self.groupSecret = groupSecret
        self.createdAt = createdAt
        self.membersJSON = membersJSON
        self.memberProfilesJSON = memberProfilesJSON
        self.epoch = epoch
        self.salt = salt
        self.commitment = commitment
        self.tierRaw = tierRaw
        self.groupTypeRaw = groupTypeRaw
        self.adminPubkeyHex = adminPubkeyHex
        self.adminEd25519PubkeyHex = adminEd25519PubkeyHex
        self.isPublishedOnChain = isPublishedOnChain
        self.avatarJPEG = avatarJPEG
        self.lastReadAt = lastReadAt
        self.invitationMessage = invitationMessage
    }
}

/// One chat message.
///
/// Attachment descriptors ride as re-encoded JSON rather than typed
/// fields: their shapes belong to the chat layer and change with it, and
/// this schema should not have to move every time a new media kind
/// lands. Each descriptor carries its own content key, which is why a
/// snapshot restores media rather than just referring to it.
public struct BackupMessageRecord: Sendable, Equatable, Codable {
    public let id: String
    public let groupID: String
    public let ownerIdentityID: String
    public let senderBlsPubkeyHex: String
    public let body: String
    public let sentAt: Date
    public let directionRaw: String
    public let statusRaw: String
    public let groupTypeRaw: String
    public let replyToMessageID: String?
    public let failureReasonRaw: String?
    public let moderationAuthenticityProof: String?
    public let imageAttachmentJSON: Data?
    public let videoAttachmentJSON: Data?
    public let albumAttachmentsJSON: Data?
    public let voiceAttachmentJSON: Data?
    public let systemEventJSON: Data?

    public init(
        id: String,
        groupID: String,
        ownerIdentityID: String,
        senderBlsPubkeyHex: String,
        body: String,
        sentAt: Date,
        directionRaw: String,
        statusRaw: String,
        groupTypeRaw: String,
        replyToMessageID: String?,
        failureReasonRaw: String?,
        moderationAuthenticityProof: String?,
        imageAttachmentJSON: Data?,
        videoAttachmentJSON: Data?,
        albumAttachmentsJSON: Data?,
        voiceAttachmentJSON: Data?,
        systemEventJSON: Data?
    ) {
        self.id = id
        self.groupID = groupID
        self.ownerIdentityID = ownerIdentityID
        self.senderBlsPubkeyHex = senderBlsPubkeyHex
        self.body = body
        self.sentAt = sentAt
        self.directionRaw = directionRaw
        self.statusRaw = statusRaw
        self.groupTypeRaw = groupTypeRaw
        self.replyToMessageID = replyToMessageID
        self.failureReasonRaw = failureReasonRaw
        self.moderationAuthenticityProof = moderationAuthenticityProof
        self.imageAttachmentJSON = imageAttachmentJSON
        self.videoAttachmentJSON = videoAttachmentJSON
        self.albumAttachmentsJSON = albumAttachmentsJSON
        self.voiceAttachmentJSON = voiceAttachmentJSON
        self.systemEventJSON = systemEventJSON
    }
}

/// A received invitation, still sealed to the recipient's inbox key.
public struct BackupInvitationRecord: Sendable, Equatable, Codable {
    public let id: String
    public let ownerIdentityID: String
    public let payload: Data
    public let receivedAt: Date
    public let statusRaw: String

    public init(id: String, ownerIdentityID: String, payload: Data, receivedAt: Date, statusRaw: String) {
        self.id = id
        self.ownerIdentityID = ownerIdentityID
        self.payload = payload
        self.receivedAt = receivedAt
        self.statusRaw = statusRaw
    }
}

/// A pinned service consent.
///
/// Included because a device restored without them is stranded: it has
/// history but no record of which operators the person chose, and the
/// first action would re-ask consents already given.
public struct BackupConsentRecord: Sendable, Equatable, Codable {
    public let componentId: String
    public let raw: Data

    public init(componentId: String, raw: Data) {
        self.componentId = componentId
        self.raw = raw
    }
}

/// One attachment blob, exactly as the blob store holds it.
///
/// **Ciphertext, never plaintext.** The device's media caches hold
/// decrypted bytes under filenames that are public content addresses;
/// copying those into a snapshot would put plaintext media in an
/// operator's hands keyed by an identifier anyone can look up. The bytes
/// here are what Blossom serves, and they are verified against the
/// descriptor's address before they go in.
public struct BackupBlobRecord: Sendable, Equatable, Codable {
    /// Lowercase hex SHA-256 of these exact bytes — the content address
    /// the attachment descriptor points at.
    public let sha256: String
    public let ciphertext: Data

    public init(sha256: String, ciphertext: Data) {
        self.sha256 = sha256
        self.ciphertext = ciphertext
    }
}
