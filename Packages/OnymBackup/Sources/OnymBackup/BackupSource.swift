import Foundation

/// What may go into a snapshot, and what the person chose about media.
public enum BackupMediaPolicy: String, Sendable, Equatable, Codable, CaseIterable {
    /// Attachments ride as descriptors only; media re-resolves from the
    /// blob store on restore. Cheap and honest — and the honesty costs
    /// something the consent surface must say out loud: media whose blob
    /// retention has lapsed is gone, and no snapshot will bring it back.
    case descriptorsOnly
    /// Attachment ciphertext travels in the archive. Larger snapshots,
    /// and media that survives the blob operator.
    case includeCiphertext
}

/// Where a snapshot's contents come from.
///
/// The composer talks to this and to nothing else. That is the
/// structural half of the eligibility rule: `BackupComposer` holds no
/// reference to identity, to the keychain, or to any store that could
/// hand it seed material, so "seed material is never eligible"
/// (`UI-Backup.md` §16.1) is a property of the type graph rather than a
/// discipline someone has to keep remembering.
///
/// Implementations read through the app's own store protocols. They must
/// never read the SwiftData files directly: local rows are encrypted
/// under a device-bound key, so a file-level copy is unopenable on the
/// device that would need it.
public protocol BackupSourceProviding: Sendable {
    /// How many identities this snapshot covers. Recorded in the archive
    /// header for the restore surface, not used for anything else.
    func identityCount() async -> Int

    func groups() async throws -> [BackupGroupRecord]

    /// Messages for one group, scoped to the identity that owns it —
    /// the same scoping the chat list uses, so a group two local
    /// identities are both in yields each one's own rows.
    func messages(groupID: String, ownerIdentityID: String) async throws -> [BackupMessageRecord]

    func invitations() async throws -> [BackupInvitationRecord]

    func consents() async throws -> [BackupConsentRecord]

    /// The blob store's bytes for one content address, or `nil` if it no
    /// longer serves them.
    ///
    /// A missing blob is not a failure: retention at the blob operator
    /// is its own contract and shorter than a backup's by design. The
    /// snapshot records what it could get and the restore reports what
    /// it could not.
    func blobCiphertext(sha256: String) async throws -> Data?
}

/// Where a restored snapshot's contents go.
///
/// Writes go through the app's stores rather than into the database
/// files, so the restoring device re-encrypts everything under *its*
/// at-rest key. That is the whole reason a snapshot is a logical export:
/// the bytes that arrive are not the bytes that get stored.
public protocol BackupSinkProviding: Sendable {
    func restore(groups: [BackupGroupRecord]) async throws
    func restore(messages: [BackupMessageRecord]) async throws
    func restore(invitations: [BackupInvitationRecord]) async throws
    func restore(consents: [BackupConsentRecord]) async throws
    /// Hand back one attachment blob. The implementation is responsible
    /// for putting it somewhere the media loaders will find it.
    func restore(blob: BackupBlobRecord) async throws
}

/// What a restore actually did.
public struct BackupRestoreSummary: Sendable, Equatable {
    public let groups: Int
    public let messages: Int
    public let invitations: Int
    public let consents: Int
    public let blobs: Int
    /// Content addresses the snapshot referenced but did not carry, and
    /// which the blob store no longer serves. Surfaced rather than
    /// swallowed: the person's media is partly gone, and a restore that
    /// reported plain success would be lying about it.
    public let unresolvedBlobs: [String]

    public init(
        groups: Int,
        messages: Int,
        invitations: Int,
        consents: Int,
        blobs: Int,
        unresolvedBlobs: [String]
    ) {
        self.groups = groups
        self.messages = messages
        self.invitations = invitations
        self.consents = consents
        self.blobs = blobs
        self.unresolvedBlobs = unresolvedBlobs
    }
}
