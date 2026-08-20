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
///
/// Every method reports a `BackupSinkOutcome` and every one of them
/// takes the store at its word about whether the write happened. The
/// counting used to be `await store.insertOrUpdate(…)` followed by an
/// unconditional `written += 1`, throwing away a `Bool` that meant
/// exactly the thing being counted. So the summary reported *calls
/// made*, and "1 chats, 3 messages" read identically whether three
/// messages were on the device or none were — which is precisely how a
/// restore that wrote nothing survived QA looking like a success.
///
/// Taking a store at its word requires the word to be unambiguous.
/// Groups and invitations both used to answer `false` for a row that
/// was persisted and for one that was not, so this file read `list()`
/// before writing and inferred which `false` it had from whether the
/// key was already present. That worked, and it is gone: all three
/// stores now report their own outcome. The inference is not kept
/// alongside as a cross-check — two mechanisms answering one question
/// leaves the next reader unable to tell which one is authoritative,
/// and the pre-read was always the weaker of the two, reconstructing
/// from the outside what the store knew from the inside.
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

    @discardableResult
    func restore(groups: [BackupGroupRecord]) async throws -> BackupSinkOutcome {
        var landed = 0
        var unreadable = 0
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
                unreadable += 1
                continue
            }
            let outcome = await groupStore.insertOrUpdate(
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
            // `.inserted` or `.updated` — either way the group is on
            // this device now, which is the only thing the summary
            // claims. `.failed` is the store saying it could not encode
            // the row and persisted nothing, and saying so is the whole
            // point: a chat the person can see in the summary and not in
            // their chat list is worse than one the summary never
            // promised.
            if outcome == .failed {
                unreadable += 1
            } else {
                landed += 1
            }
        }
        return BackupSinkOutcome(landed: landed, unreadable: unreadable)
    }

    @discardableResult
    func restore(messages: [BackupMessageRecord]) async throws -> BackupSinkOutcome {
        var landed = 0
        var unreadable = 0
        for record in messages {
            guard
                let id = UUID(uuidString: record.id),
                let ownerID = IdentityID(record.ownerIdentityID),
                let direction = MessageDirection(rawValue: record.directionRaw),
                let status = MessageStatus(rawValue: record.statusRaw),
                let groupType = SEPGroupType(rawValue: record.groupTypeRaw)
            else {
                unreadable += 1
                continue
            }
            // `.inserted` and `.updated` both mean the row is on the
            // device; `.failed` means the encrypt or the save gave way
            // and nothing is. `MessageStore` has answered this way since
            // it was written, which is why the message path never grew
            // the pre-read the other two have now shed.
            let outcome = await messageStore.insertOrUpdate(
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
            if outcome == .failed {
                unreadable += 1
            } else {
                landed += 1
            }
        }
        return BackupSinkOutcome(landed: landed, unreadable: unreadable)
    }

    @discardableResult
    func restore(invitations: [BackupInvitationRecord]) async throws -> BackupSinkOutcome {
        var landed = 0
        var unreadable = 0
        for record in invitations {
            guard
                let ownerID = IdentityID(record.ownerIdentityID),
                let status = IncomingInvitationStatus(rawValue: record.statusRaw)
            else {
                unreadable += 1
                continue
            }
            let outcome = await invitationStore.save(
                IncomingInvitationRecord(
                    id: record.id,
                    ownerIdentityID: ownerID,
                    payload: record.payload,
                    receivedAt: record.receivedAt,
                    status: status
                )
            )
            // `.duplicate` is the ordinary case on any second restore
            // — an invitation the device already holds — and counting it
            // as landed is what keeps it from being reported as one this
            // build could not parse. Only `.failed` wrote nothing.
            if outcome == .failed {
                unreadable += 1
            } else {
                landed += 1
            }
        }
        return BackupSinkOutcome(landed: landed, unreadable: unreadable)
    }

    @discardableResult
    func restore(consents: [BackupConsentRecord]) async throws -> BackupSinkOutcome {
        let restored = consents.compactMap {
            try? Self.decoder.decode(PinnedConsentRecord.self, from: $0.raw)
        }
        // A consent that would not decode is the one genuinely alarming
        // case, and it is the only one counted as unreadable. Everything
        // below this line is about consents that decoded perfectly well
        // and are simply already here.
        let unreadable = consents.count - restored.count
        guard !restored.isEmpty else {
            return BackupSinkOutcome(landed: 0, unreadable: unreadable)
        }
        // Merged, not replaced: a device may already have consented to
        // something since the snapshot was taken, and a restore that
        // overwrote it would silently revoke a choice the person made
        // more recently than the backup.
        //
        // A *failed* load must therefore abort rather than read as "no
        // existing consents". Treating a corrupt or transient read as an
        // empty store and then saving would replace every live consent
        // with the restored, inactive ones — the exact revocation this
        // merge exists to prevent, executed by the code meant to prevent
        // it. Losing the restored consents is recoverable; the person is
        // re-asked. Losing the live ones is not.
        let existing = try consentStore.load()
        let known = Set(existing.map { "\($0.componentId)|\($0.manifestHash)" })
        let additions = restored.filter { !known.contains("\($0.componentId)|\($0.manifestHash)") }
        // Nothing to add is not nothing restored. Every consent in this
        // archive is on the device, which is what the summary counts;
        // reporting zero here is what made a normal restore announce
        // that four consents "could not be read by this version of
        // Onym", for four consents the person had granted themselves —
        // one of which had to be the operator the snapshot came from.
        guard !additions.isEmpty else {
            return BackupSinkOutcome(landed: restored.count, unreadable: unreadable)
        }
        try consentStore.save(existing + additions.map {
            // Restored consents land inactive. Re-activating one would
            // silently re-select an operator the person has not seen
            // since; the consent surface asks.
            var record = $0
            record.isActive = false
            return record
        })
        return BackupSinkOutcome(landed: restored.count, unreadable: unreadable)
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
