import CryptoKit
import Foundation

/// Turns a downloaded snapshot back into local state.
///
/// Three gates, in this order, and none of them may move:
///
/// 1. **Verify the whole reference.** Bytes that do not compose their
///    digest never reach a decoder.
/// 2. **Decode the entire archive.** Every record is parsed and its
///    per-entry digest checked before anything is written.
/// 3. **Only then write.**
///
/// The cost of that ordering is holding a decoded archive in memory; the
/// alternative is a half-restored device, which `UI-Backup.md` §7.11
/// forbids and which is worse in every way a person would notice — a
/// chat list with some groups and none of their messages looks like data
/// loss, because it is.
public actor BackupRestorer {
    private let sink: any BackupSinkProviding

    public init(sink: any BackupSinkProviding) {
        self.sink = sink
    }

    public func restore(
        sealedURL: URL,
        reference: SnapshotReference,
        keyMaterial: BackupKeyMaterial,
        workingDirectory: URL
    ) async throws -> BackupRestoreSummary {
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let plaintextURL = workingDirectory.appending(path: "restore-\(reference.digestHex)")
        defer { try? FileManager.default.removeItem(at: plaintextURL) }

        // Gate 1 and the decryption it guards.
        try BackupOpener.open(
            sealedURL: sealedURL,
            to: plaintextURL,
            reference: reference,
            archiveRoot: keyMaterial.archiveRoot
        )

        // Gate 2: read and validate everything first.
        let reader = try BackupArchiveReader(url: plaintextURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var groups: [BackupGroupRecord] = []
        var messages: [BackupMessageRecord] = []
        var invitations: [BackupInvitationRecord] = []
        var consents: [BackupConsentRecord] = []
        var blobs: [BackupBlobRecord] = []

        try reader.forEachRecord { kind, bytes in
            // A record that will not decode is `incompleteSnapshot`, not
            // a record to skip. Skipping would produce a restore that
            // reports success while silently dropping a person's groups.
            switch kind {
            case .groups:
                groups = try Self.decode([BackupGroupRecord].self, from: bytes, using: decoder)
            case .messages:
                messages = try Self.decode([BackupMessageRecord].self, from: bytes, using: decoder)
            case .invitations:
                invitations = try Self.decode([BackupInvitationRecord].self, from: bytes, using: decoder)
            case .consents:
                consents = try Self.decode([BackupConsentRecord].self, from: bytes, using: decoder)
            case .blobCiphertext:
                blobs = try Self.decode([BackupBlobRecord].self, from: bytes, using: decoder)
            }
        }

        // Every blob is re-checked against the address it claims. The
        // archive was authenticated, so this is not about tampering — it
        // catches a snapshot written by a buggy composer before its
        // contents become this device's media.
        for blob in blobs {
            let actual = SHA256.hash(data: blob.ciphertext).map { String(format: "%02x", $0) }.joined()
            guard actual == blob.sha256 else { throw BackupError.incompleteSnapshot }
        }

        // Gate 3: write. Groups before messages, because a message whose
        // group does not exist yet is an orphan in every surface that
        // renders it.
        // Counts come from the sink, not from the archive. A row the
        // sink could not reconstruct is skipped, and reporting the
        // archive's totals would claim to have restored things that are
        // not there — the same overstatement this seat refuses
        // everywhere else.
        // From here on a failure is *not* "nothing happened": the
        // earlier writes have landed. Reported as `restoreInterrupted`
        // so the screen can say so, rather than inheriting the
        // pre-write promise.
        let wroteGroups: BackupSinkOutcome
        let wroteMessages: BackupSinkOutcome
        let wroteInvitations: BackupSinkOutcome
        let wroteConsents: BackupSinkOutcome
        do {
            wroteGroups = try await sink.restore(groups: groups)
            wroteMessages = try await sink.restore(messages: messages)
            wroteInvitations = try await sink.restore(invitations: invitations)
            wroteConsents = try await sink.restore(consents: consents)
            for blob in blobs {
                try await sink.restore(blob: blob)
            }
        } catch {
            throw BackupError.localFailure(reason: .restoreInterrupted)
        }

        // What could not be read is what the sink *said* could not be
        // read, not what is left over after subtracting what it wrote.
        //
        // The subtraction was `held - written`, and it was wrong for
        // every row that was already on the device. A restore's writes
        // are `insertOrUpdate` precisely so that restoring twice, or
        // onto a phone that has since received some of the same
        // messages, converges rather than duplicating — and a sink that
        // reported only *new* rows made every one of those convergences
        // look like a parse failure. The consent list made it
        // unmissable: you cannot reach an operator's snapshot without
        // having consented to that operator, so the consents in the
        // archive are always already held, and the screen said all of
        // them "could not be read by this version of Onym".
        //
        // Only the sink knows which of the two happened, so only the
        // sink may say. Arithmetic here cannot recover the distinction.
        var skipped: [String: Int] = [:]
        for (name, outcome) in [
            ("groups", wroteGroups),
            ("messages", wroteMessages),
            ("invitations", wroteInvitations),
            ("consents", wroteConsents),
        ] where outcome.unreadable > 0 {
            skipped[name] = outcome.unreadable
        }

        // Only a snapshot that meant to carry blobs can be missing any.
        // A descriptors-only archive carries none by design and its
        // attachments still resolve from the blob store, so reporting
        // every one of them as unresolved would be alarming and false.
        let unresolved: [String]
        if reader.header.mediaPolicy == .includeCiphertext {
            let carried = Set(blobs.map(\.sha256))
            let referenced = Set(messages.flatMap(Self.contentAddresses(in:)))
            unresolved = referenced.subtracting(carried).sorted()
        } else {
            unresolved = []
        }

        return BackupRestoreSummary(
            groups: wroteGroups.landed,
            messages: wroteMessages.landed,
            invitations: wroteInvitations.landed,
            consents: wroteConsents.landed,
            blobs: blobs.count,
            skipped: skipped,
            unresolvedBlobs: unresolved
        )
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from bytes: Data,
        using decoder: JSONDecoder
    ) throws -> T {
        guard let value = try? decoder.decode(type, from: bytes) else {
            throw BackupError.incompleteSnapshot
        }
        return value
    }

    private static func contentAddresses(in message: BackupMessageRecord) -> [String] {
        [
            message.imageAttachmentJSON,
            message.videoAttachmentJSON,
            message.albumAttachmentsJSON,
            message.voiceAttachmentJSON,
        ]
        .compactMap { $0 }
        .flatMap(BackupComposer.contentAddresses(inAttachmentJSON:))
    }
}
