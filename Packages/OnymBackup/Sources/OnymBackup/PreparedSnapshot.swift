import Foundation

/// The plaintext archive of one run, before it is sealed for anybody.
///
/// It exists as its own type because composing it is the expensive half
/// of a backup — it reads the whole history and fetches every blob —
/// while sealing is cheap. A person keeping their history with more than
/// one operator reads their history once and seals it once per operator.
///
/// It is also the one artefact in the working directory that is readable
/// without the recovery phrase, so it is destroyed as soon as the last
/// seal exists — before any upload starts, not after.
public struct BackupPlaintextArchive: Sendable {
    public let url: URL
    public let createdAt: Date

    init(url: URL, createdAt: Date) {
        self.url = url
        self.createdAt = createdAt
    }

    /// Not throwing, and safe to call twice: this runs on the failure
    /// path as well, where a second error would replace a real one.
    public func destroy() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Sealed bytes addressed to nobody yet.
///
/// Every operator gets its own seal, minted with its own fresh salt from
/// the same plaintext, so two operators hold two unrelated ciphertexts
/// under two unrelated references. Sending one set of bytes to both would
/// give colluding operators a digest that links their two holders —
/// undoing by convenience exactly what per-operator key derivation
/// (`BackupKeys.signingInfo`) and the profile's prohibition on convergent
/// keying (`UI-Backup.md` §8.2) exist to prevent.
///
/// What is deliberately absent is everything an operator was told: the
/// terms this device pinned with it, the position the snapshot takes in
/// *its* chain, and the operation id it reconciles on. Those are stamped
/// per operator by `BackupRepository.place(prepared:)`, because none of
/// them is a property of the bytes.
public struct PreparedSnapshot: Sendable, Equatable {
    public let snapshotReference: SnapshotReference
    public let sealedBytesURL: URL
    public let sealedAt: Date

    public init(snapshotReference: SnapshotReference, sealedBytesURL: URL, sealedAt: Date) {
        self.snapshotReference = snapshotReference
        self.sealedBytesURL = sealedBytesURL
        self.sealedAt = sealedAt
    }

    /// Address these bytes to one operator.
    public func addressed(
        operationId: String,
        acceptedTermsId: String,
        supersedes: SnapshotReference?
    ) -> SealedSnapshot {
        SealedSnapshot(
            operationId: operationId,
            snapshotReference: snapshotReference,
            sealedBytesURL: sealedBytesURL,
            sealedAt: sealedAt,
            acceptedTermsId: acceptedTermsId,
            supersedes: supersedes
        )
    }

    /// Drop bytes no operator will receive.
    ///
    /// A seal minted for an operator that then refused its own
    /// preconditions is ciphertext nobody will claim — not a disclosure,
    /// but a file the person never sees and would otherwise keep.
    public func discard() {
        try? FileManager.default.removeItem(at: sealedBytesURL)
    }
}
