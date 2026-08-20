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

    /// The blob store's answer for one content address.
    ///
    /// The two failure modes must be told apart. A blob the store no
    /// longer holds is `.gone`: blob retention is its own contract,
    /// shorter than a backup's by design, and a snapshot should record
    /// what it could get rather than abort. A blob the store could not
    /// be *asked* about — a dropped connection, a 5xx — is an error, and
    /// folding it into `.gone` would quietly produce a media-thin
    /// snapshot on a flaky network and call it complete.
    func blobCiphertext(sha256: String) async throws -> BackupBlobAvailability
}

/// Writes go through the app's stores rather than into the database
/// files, so the restoring device re-encrypts everything under *its*
/// at-rest key. That is the whole reason a snapshot is a logical export:
/// the bytes that arrive are not the bytes that get stored.
/// What a blob store had to say.
public enum BackupBlobAvailability: Sendable, Equatable {
    case available(Data)
    /// The store answered, and does not hold it.
    case gone
}

/// What one kind of row did on its way into local state.
///
/// Two numbers rather than one, because a single count cannot tell the
/// difference between the two reasons a row is not *new* on this device,
/// and the screen says something very different about each:
///
/// - `landed` — the row is on the device now. Freshly inserted, updated
///   in place, or already present and left alone: all three mean the
///   history is here, which is the only question the summary asks.
/// - `unreadable` — the row was handed over and did not land. A shape
///   from a schema this build does not know, an id that will not parse,
///   a store that refused the write. Worth saying out loud, because part
///   of someone's history did not arrive.
///
/// The previous shape returned `landed` alone and let `BackupRestorer`
/// subtract it from what the archive held. That subtraction is where the
/// two meanings collapsed: a consent already present on the device — and
/// every restore has at least one, since consenting to an operator is
/// how you reach its snapshot at all — came out the far side as "could
/// not be read by this version of Onym". Nothing was wrong; the
/// arithmetic simply had no way to say so. So the sink says so instead.
public struct BackupSinkOutcome: Sendable, Equatable {
    /// Rows that are on the device now, however they got there.
    public let landed: Int
    /// Rows handed over that this build could not put anywhere.
    public let unreadable: Int

    public init(landed: Int, unreadable: Int) {
        self.landed = landed
        self.unreadable = unreadable
    }

    public static let none = BackupSinkOutcome(landed: 0, unreadable: 0)
}

/// Where a restored snapshot's contents go.
///
/// Every method reports **what actually landed**, not how many rows it
/// was handed. An implementation that cannot reconstruct a row — an enum
/// case from a newer schema, an unparseable id — skips it, and a summary
/// built from the archive's counts would then report restoring things
/// that are not there. The count has to come from the writer, and so
/// does the reason a row is missing from it.
public protocol BackupSinkProviding: Sendable {
    @discardableResult func restore(groups: [BackupGroupRecord]) async throws -> BackupSinkOutcome
    @discardableResult func restore(messages: [BackupMessageRecord]) async throws -> BackupSinkOutcome
    @discardableResult func restore(invitations: [BackupInvitationRecord]) async throws -> BackupSinkOutcome
    @discardableResult func restore(consents: [BackupConsentRecord]) async throws -> BackupSinkOutcome
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
    /// Rows the archive held that the sink could not reconstruct, by
    /// kind. Non-empty means this build does not understand part of the
    /// snapshot — worth telling someone about rather than absorbing.
    public let skipped: [String: Int]
    /// Content addresses this snapshot *meant* to carry and did not.
    ///
    /// Empty for a descriptors-only snapshot, which carries no blobs by
    /// design and whose attachments still resolve from the blob store —
    /// reporting all of them as unresolved would be alarming and wrong.
    public let unresolvedBlobs: [String]

    public init(
        groups: Int,
        messages: Int,
        invitations: Int,
        consents: Int,
        blobs: Int,
        skipped: [String: Int] = [:],
        unresolvedBlobs: [String]
    ) {
        self.skipped = skipped
        self.groups = groups
        self.messages = messages
        self.invitations = invitations
        self.consents = consents
        self.blobs = blobs
        self.unresolvedBlobs = unresolvedBlobs
    }
}
