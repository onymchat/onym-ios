import Foundation
import OnymBackup
import OnymChain
import OnymChatsCore
import OnymFoundation
import OnymGroup
import OnymIdentity
import OnymPersistence
import OnymTransportBlossom

/// Reads local state for a snapshot, through the app's own store
/// protocols.
///
/// It lives in the composition root because it is the only place that
/// knows both the domain models and the archive schema — `OnymBackup`
/// deliberately knows nothing about `ChatGroup`, so a rename there can
/// never silently change what an archive means.
///
/// What it can reach is the point. There is no `IdentityRepository`
/// here, no keychain, no `StorageEncryption`: the eligibility rule of
/// `UI-Backup.md` §16.1 holds because this type has no way to obtain
/// seed material, not because someone remembered not to ask for it.
struct AppBackupSource: BackupSourceProviding {
    let groupStore: any GroupStore
    let messageStore: any MessageStore
    let invitationStore: any InvitationStore
    let consentStore: any PinnedConsentStore
    /// Only ever asked for *ciphertext*, and only under
    /// `.includeCiphertext`. The device's own media caches are never
    /// read: they hold decrypted bytes under filenames that are public
    /// content addresses.
    let blobClient: (any BlossomClient)?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func identityCount() async -> Int {
        Set(await groupStore.list().map(\.ownerIdentityID)).count
    }

    func groups() async throws -> [BackupGroupRecord] {
        try await groupStore.list().map { group in
            BackupGroupRecord(
                id: group.id,
                ownerIdentityID: group.ownerIdentityID.description,
                name: group.name,
                groupSecret: group.groupSecret,
                createdAt: group.createdAt,
                membersJSON: try Self.encoder.encode(group.members),
                memberProfilesJSON: try Self.encoder.encode(group.memberProfiles),
                epoch: group.epoch,
                salt: group.salt,
                commitment: group.commitment,
                tierRaw: group.tier.rawValue,
                groupTypeRaw: group.groupType.rawValue,
                adminPubkeyHex: group.adminPubkeyHex,
                adminEd25519PubkeyHex: group.adminEd25519PubkeyHex,
                isPublishedOnChain: group.isPublishedOnChain,
                avatarJPEG: group.avatarJPEG,
                lastReadAt: group.lastReadAt,
                invitationMessage: group.invitationMessage
            )
        }
    }

    func messages(groupID: String, ownerIdentityID: String) async throws -> [BackupMessageRecord] {
        try await messageStore.list(groupID: groupID, ownerIDString: ownerIdentityID).map { message in
            BackupMessageRecord(
                id: message.id.uuidString,
                groupID: message.groupID,
                ownerIdentityID: message.ownerIdentityID.description,
                senderBlsPubkeyHex: message.senderBlsPubkeyHex,
                body: message.body,
                sentAt: message.sentAt,
                directionRaw: message.direction.rawValue,
                statusRaw: message.status.rawValue,
                groupTypeRaw: message.groupType.rawValue,
                replyToMessageID: message.replyToMessageID?.uuidString,
                failureReasonRaw: message.failureReason?.rawValue,
                moderationAuthenticityProof: message.moderationAuthenticityProof,
                imageAttachmentJSON: try message.imageAttachment.map(Self.encoder.encode),
                videoAttachmentJSON: try message.videoAttachment.map(Self.encoder.encode),
                albumAttachmentsJSON: try message.albumAttachments.map(Self.encoder.encode),
                voiceAttachmentJSON: try message.voiceAttachment.map(Self.encoder.encode),
                systemEventJSON: try message.systemEvent.map(Self.encoder.encode)
            )
        }
    }

    func invitations() async throws -> [BackupInvitationRecord] {
        await invitationStore.list().map { record in
            BackupInvitationRecord(
                id: record.id,
                ownerIdentityID: record.ownerIdentityID.description,
                payload: record.payload,
                receivedAt: record.receivedAt,
                statusRaw: record.status.rawValue
            )
        }
    }

    func consents() async throws -> [BackupConsentRecord] {
        // A corrupt consent store is not a reason to abandon a snapshot
        // of someone's messages. The restore re-asks for consent, which
        // is a nuisance; losing the history would not be.
        let records = (try? consentStore.load()) ?? []
        return try records.map {
            BackupConsentRecord(componentId: $0.componentId, raw: try Self.encoder.encode($0))
        }
    }

    func blobCiphertext(sha256: String) async throws -> BackupBlobAvailability {
        guard let blobClient else { return .gone }
        do {
            return .available(try await blobClient.download(sha256: sha256))
        } catch BlossomError.badStatus(404), BlossomError.badStatus(410) {
            // The store answered and does not hold it. Expected: blob
            // retention is its own contract, shorter than a backup's.
            return .gone
        }
        // Everything else — a dropped connection, a 5xx, a malformed
        // response — propagates. Folding it into "gone" would turn a
        // flaky network into a snapshot that is quietly missing half its
        // media and reports itself complete; failing means the snapshot
        // is retried, which is cheap and correct.
    }
}
