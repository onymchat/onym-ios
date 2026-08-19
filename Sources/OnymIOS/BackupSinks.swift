import Foundation
import OnymBackup
import OnymChain
import OnymChatsCore
import OnymFoundation
import OnymGroup
import OnymIdentity
import OnymPersistence

/// Writes a restored snapshot back into local state.
///
/// Everything goes through the app's stores, never into their database
/// files. That is what makes a snapshot restorable at all: the rows
/// arrive as domain values and each store re-encrypts them under *this*
/// device's at-rest key, which is the key the previous device could not
/// have shared even if it wanted to.
///
/// Writes are `insertOrUpdate`, so restoring twice — or restoring onto a
/// device that has since received some of the same messages — converges
/// instead of duplicating.
struct AppBackupSink: BackupSinkProviding {
    let groupStore: any GroupStore
    let messageStore: any MessageStore
    let invitationStore: any InvitationStore
    let consentStore: any PinnedConsentStore
    /// Where restored attachment ciphertext is written so the media
    /// loaders find it without a round trip to the blob store.
    let blobDirectory: URL

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func restore(groups: [BackupGroupRecord]) async throws {
        for record in groups {
            // A record we cannot reconstruct is skipped rather than
            // fatal, and the reason is asymmetric: the whole archive was
            // already verified and decoded before any of this ran, so a
            // failure here means one row's *shape* is from a schema this
            // build does not know. Refusing the entire restore over one
            // unknown group would cost the person everything else.
            guard
                let ownerID = IdentityID(record.ownerIdentityID),
                let tier = SEPTier(rawValue: record.tierRaw),
                let groupType = SEPGroupType(rawValue: record.groupTypeRaw),
                let members = try? Self.decoder.decode([GovernanceMember].self, from: record.membersJSON),
                let profiles = try? Self.decoder.decode(
                    [String: MemberProfile].self, from: record.memberProfilesJSON)
            else {
                continue
            }
            await groupStore.insertOrUpdate(
                ChatGroup(
                    id: record.id,
                    ownerIdentityID: ownerID,
                    name: record.name,
                    groupSecret: record.groupSecret,
                    createdAt: record.createdAt,
                    members: members,
                    memberProfiles: profiles,
                    epoch: record.epoch,
                    salt: record.salt,
                    commitment: record.commitment,
                    tier: tier,
                    groupType: groupType,
                    adminPubkeyHex: record.adminPubkeyHex,
                    adminEd25519PubkeyHex: record.adminEd25519PubkeyHex,
                    isPublishedOnChain: record.isPublishedOnChain,
                    avatarJPEG: record.avatarJPEG,
                    lastReadAt: record.lastReadAt,
                    invitationMessage: record.invitationMessage
                )
            )
        }
    }

    func restore(messages: [BackupMessageRecord]) async throws {
        for record in messages {
            guard
                let id = UUID(uuidString: record.id),
                let ownerID = IdentityID(record.ownerIdentityID),
                let direction = MessageDirection(rawValue: record.directionRaw),
                let status = MessageStatus(rawValue: record.statusRaw),
                let groupType = SEPGroupType(rawValue: record.groupTypeRaw)
            else {
                continue
            }
            await messageStore.insertOrUpdate(
                ChatMessage(
                    id: id,
                    groupID: record.groupID,
                    ownerIdentityID: ownerID,
                    senderBlsPubkeyHex: record.senderBlsPubkeyHex,
                    body: record.body,
                    sentAt: record.sentAt,
                    direction: direction,
                    status: status,
                    replyToMessageID: record.replyToMessageID.flatMap(UUID.init(uuidString:)),
                    groupType: groupType,
                    failureReason: record.failureReasonRaw.flatMap(SendFailureReason.init(rawValue:)),
                    moderationAuthenticityProof: record.moderationAuthenticityProof,
                    imageAttachment: Self.decode(ChatImageAttachment.self, record.imageAttachmentJSON),
                    videoAttachment: Self.decode(ChatVideoAttachment.self, record.videoAttachmentJSON),
                    albumAttachments: Self.decode([ChatMediaAttachment].self, record.albumAttachmentsJSON),
                    voiceAttachment: Self.decode(ChatVoiceAttachment.self, record.voiceAttachmentJSON),
                    systemEvent: Self.decode(ChatSystemEvent.self, record.systemEventJSON)
                )
            )
        }
    }

    func restore(invitations: [BackupInvitationRecord]) async throws {
        for record in invitations {
            guard
                let ownerID = IdentityID(record.ownerIdentityID),
                let status = IncomingInvitationStatus(rawValue: record.statusRaw)
            else {
                continue
            }
            await invitationStore.save(
                IncomingInvitationRecord(
                    id: record.id,
                    ownerIdentityID: ownerID,
                    payload: record.payload,
                    receivedAt: record.receivedAt,
                    status: status
                )
            )
        }
    }

    func restore(consents: [BackupConsentRecord]) async throws {
        let restored = consents.compactMap {
            try? Self.decoder.decode(PinnedConsentRecord.self, from: $0.raw)
        }
        guard !restored.isEmpty else { return }
        // Merged, not replaced: a device may already have consented to
        // something since the snapshot was taken, and a restore that
        // overwrote it would silently revoke a choice the person made
        // more recently than the backup.
        let existing = (try? consentStore.load()) ?? []
        let known = Set(existing.map { "\($0.componentId)|\($0.manifestHash)" })
        let additions = restored.filter { !known.contains("\($0.componentId)|\($0.manifestHash)") }
        guard !additions.isEmpty else { return }
        try consentStore.save(existing + additions.map {
            // Restored consents land inactive. Re-activating one would
            // silently re-select an operator the person has not seen
            // since; the consent surface asks.
            var record = $0
            record.isActive = false
            return record
        })
    }

    func restore(blob: BackupBlobRecord) async throws {
        try FileManager.default.createDirectory(
            at: blobDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        // Ciphertext, addressed by its own digest — the same shape the
        // blob store serves, so the media loaders treat a restored blob
        // exactly like a downloaded one.
        try blob.ciphertext.write(
            to: blobDirectory.appending(path: blob.sha256),
            options: [.atomic, .completeFileProtection]
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: Data?) -> T? {
        guard let json else { return nil }
        return try? decoder.decode(type, from: json)
    }
}
