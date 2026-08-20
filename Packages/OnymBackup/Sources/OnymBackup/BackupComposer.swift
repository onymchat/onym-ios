import CryptoKit
import Foundation
import OnymFoundation

/// Builds one sealed snapshot from local state.
///
/// The order is fixed and the reason is the whole seat: read through the
/// source, write an archive, pad it, seal it under a seed-derived key,
/// and address it by a digest over the sealed bytes. Nothing before the
/// seal ever leaves the device, and nothing after it is legible to
/// anyone who does not hold the recovery phrase.
///
/// Whole-snapshot only. The profile names verifiable incrementals as
/// unsolved design work and this does not pretend otherwise: a large
/// history re-uploads in full, which is a real cost the consent surface
/// has to state rather than let someone discover on their data plan.
public actor BackupComposer {
    private let source: any BackupSourceProviding
    private let mediaPolicy: BackupMediaPolicy
    /// Where sealed snapshots and scratch files live.
    ///
    /// Immutable and `Sendable`, so callers outside the actor can read
    /// it without a hop — the repository needs it to clean up bytes for
    /// an operation the composer knows nothing about.
    public let workingDirectory: URL

    public init(
        source: any BackupSourceProviding,
        mediaPolicy: BackupMediaPolicy,
        workingDirectory: URL
    ) {
        self.source = source
        self.mediaPolicy = mediaPolicy
        self.workingDirectory = workingDirectory
    }

    /// Compose, seal, and return the snapshot ready for the adapter.
    ///
    /// `acceptedTermsId` is pinned into the result, not looked up later:
    /// what the person consented to is a property of this snapshot, and
    /// re-reading current terms at upload time would silently re-point
    /// it at terms nobody agreed to.
    public func compose(
        keyMaterial: BackupKeyMaterial,
        acceptedTermsId: String,
        supersedes: SnapshotReference? = nil,
        now: Date = Date()
    ) async throws -> SealedSnapshot {
        // Minted before a byte is written, not between the seal and the
        // return. The refactor had it second, where a failure would
        // throw *after* `seal` had produced a full-size file — one that
        // no state record mentions, so nothing claims it and nothing
        // ever deletes it.
        let operationId = try Self.newIdentifier()
        let archive = try await composeArchive(now: now)
        // Before the upload, not after: the plaintext is the one
        // artefact here that is readable without the recovery phrase.
        defer { archive.destroy() }
        let prepared = try seal(archive, archiveRoot: keyMaterial.archiveRoot)
        return prepared.addressed(
            operationId: operationId,
            acceptedTermsId: acceptedTermsId,
            supersedes: supersedes
        )
    }

    /// Read the whole history into one plaintext archive.
    ///
    /// The expensive half, and the half that is the same for every
    /// operator: someone keeping their history with two operators reads
    /// it once and seals it twice. The caller owns the result and must
    /// `destroy()` it — including on the failure path, and before the
    /// first upload rather than after the last.
    public func composeArchive(now: Date = Date()) async throws -> BackupPlaintextArchive {
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let runId = try Self.newIdentifier()
        let plaintextURL = workingDirectory.appending(path: "archive-\(runId)")
        let scratchURL = workingDirectory.appending(path: "scratch-\(runId)")
        defer { try? FileManager.default.removeItem(at: scratchURL) }

        let writer = try BackupArchiveWriter(scratchURL: scratchURL)
        writer.setIdentityCount(await source.identityCount())
        writer.setMediaPolicy(mediaPolicy)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let groups = try await source.groups()
            try writer.append(kind: .groups, bytes: try encoder.encode(groups))

            var messages: [BackupMessageRecord] = []
            for group in groups {
                messages += try await source.messages(
                    groupID: group.id,
                    ownerIdentityID: group.ownerIdentityID
                )
            }
            try writer.append(kind: .messages, bytes: try encoder.encode(messages))

            try writer.append(kind: .invitations, bytes: try encoder.encode(try await source.invitations()))
            try writer.append(kind: .consents, bytes: try encoder.encode(try await source.consents()))

            if mediaPolicy == .includeCiphertext {
                let blobs = try await collectBlobs(from: messages)
                if !blobs.isEmpty {
                    try writer.append(kind: .blobCiphertext, bytes: try encoder.encode(blobs))
                }
            }

            try writer.finish(writingTo: plaintextURL, createdAt: now)
        } catch {
            // A half-written plaintext archive is readable without the
            // seed. It does not survive the throw.
            try? FileManager.default.removeItem(at: plaintextURL)
            throw error
        }
        return BackupPlaintextArchive(url: plaintextURL, createdAt: now)
    }

    /// Seal one archive for one operator.
    ///
    /// Called once per operator, and each call mints a fresh snapshot
    /// salt — so the same history sealed for two operators produces two
    /// unrelated ciphertexts under two unrelated references. Handing both
    /// operators the same bytes would be cheaper and would hand a pair of
    /// colluding operators the link between their two holders.
    ///
    /// `archiveRoot` is derived from the seed alone and is therefore the
    /// same at every operator: the snapshot must be openable by whoever
    /// holds the recovery phrase, not by whoever stored it.
    public func seal(
        _ archive: BackupPlaintextArchive,
        archiveRoot: SymmetricKey
    ) throws -> PreparedSnapshot {
        let sealedURL = workingDirectory.appending(path: "pending-\(try Self.newIdentifier())")
        let reference: SnapshotReference
        do {
            reference = try BackupSealer.seal(
                plaintextURL: archive.url,
                to: sealedURL,
                archiveRoot: archiveRoot
            )
        } catch {
            // A half-written seal is ciphertext, so it is not a
            // disclosure — but it is a file nobody will ever claim, and
            // repeated failures would accumulate them under a directory
            // the person never sees.
            try? FileManager.default.removeItem(at: sealedURL)
            throw error
        }
        return PreparedSnapshot(
            snapshotReference: reference,
            sealedBytesURL: sealedURL,
            sealedAt: archive.createdAt
        )
    }

    /// Delete working files nobody will claim.
    ///
    /// Written because a comment in `BackupRepository` claimed the
    /// working directory "is swept on the next run" and nothing ever
    /// swept it. The claim mattered: a run that ends `unknown` keeps its
    /// sealed bytes deliberately — the upload may have landed — but
    /// reconciliation resolves that by asking the operator, never by
    /// re-reading the file, so nothing ever deleted it. Every unresolved
    /// run left a full-size snapshot on the device, permanently, once
    /// per operator.
    ///
    /// `claimed` is the filenames that must survive: the sealed bytes of
    /// snapshots awaiting a purchase, which are the one case where the
    /// file itself is still needed. Everything else here is scratch.
    ///
    /// Age-guarded because a manual per-operator run can be sealing into
    /// this directory right now, and a sweep is not worth a race with
    /// it.
    /// Two ages, because two kinds of file are at stake.
    ///
    /// `plaintextAge` covers everything readable without the recovery
    /// phrase: the archive a compose writes, the scratch it builds it
    /// in, and `restore-<digest>`, which is the *whole history in the
    /// clear* and is cleaned today only by an in-process `defer` — a
    /// force-quit or a jetsam during a several-hundred-megabyte restore
    /// skips it. Keeping that for a day to avoid racing a concurrent
    /// compose is the wrong trade; an hour is long enough that no live
    /// run is touching it.
    ///
    /// `ciphertextAge` covers sealed bytes, where the cost of being
    /// early is a re-upload and the cost of being wrong is deleting
    /// something a purchase is waiting on.
    public func sweepWorkingDirectory(
        claiming claimed: Set<String>,
        plaintextAge: TimeInterval = 60 * 60,
        ciphertextAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) {
        // `sealed-` is the restore path's download: ciphertext, so space
        // only, and it leaks by the same route as `restore-`.
        let plaintextPrefixes = ["archive-", "scratch-", "restore-"]
        let ciphertextPrefixes = ["pending-", "sealed-"]
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: workingDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else {
            return
        }
        for url in entries {
            let name = url.lastPathComponent
            guard !claimed.contains(name) else { continue }
            let age: TimeInterval
            if plaintextPrefixes.contains(where: name.hasPrefix) {
                age = plaintextAge
            } else if ciphertextPrefixes.contains(where: name.hasPrefix) {
                age = ciphertextAge
            } else {
                continue
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func newIdentifier() throws -> String {
        try SecureRandom.data(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Fetch the ciphertext behind every attachment the messages
    /// reference.
    ///
    /// Two rules, both non-negotiable. The bytes come from the blob
    /// store, never from the device's media caches — those hold
    /// *decrypted* media under filenames that are public content
    /// addresses, and putting them in a snapshot would hand an operator
    /// plaintext keyed by an identifier anyone can look up. And every
    /// blob is verified against the address it claims before it is
    /// included, because a snapshot is the last place to discover that a
    /// blob store served something else.
    private func collectBlobs(from messages: [BackupMessageRecord]) async throws -> [BackupBlobRecord] {
        var addresses: Set<String> = []
        for message in messages {
            for json in [
                message.imageAttachmentJSON,
                message.videoAttachmentJSON,
                message.albumAttachmentsJSON,
                message.voiceAttachmentJSON,
            ].compactMap({ $0 }) {
                addresses.formUnion(BackupComposer.contentAddresses(inAttachmentJSON: json))
            }
        }

        var blobs: [BackupBlobRecord] = []
        for address in addresses.sorted() {
            // `.gone` is expected and skipped: blob retention is its
            // own contract, shorter than a backup's by design. A
            // transport failure is *not* folded in here — the source
            // throws for that, so a flaky network fails the snapshot and
            // it is retried, rather than silently producing one with
            // half the media in it.
            guard case .available(let ciphertext) = try await source.blobCiphertext(sha256: address) else {
                continue
            }
            let actual = SHA256.hash(data: ciphertext).map { String(format: "%02x", $0) }.joined()
            guard actual == address else { continue }
            blobs.append(BackupBlobRecord(sha256: address, ciphertext: ciphertext))
        }
        return blobs
    }

    /// Pull `sha256` values out of an attachment descriptor without
    /// decoding it into a typed shape.
    ///
    /// Deliberately structural rather than typed: the descriptor schemas
    /// belong to the chat layer and gain fields with every new media
    /// kind, and this package should not need a release to keep finding
    /// their addresses.
    static func contentAddresses(inAttachmentJSON json: Data) -> [String] {
        guard let any = try? JSONSerialization.jsonObject(with: json) else { return [] }
        var found: [String] = []
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if key == "sha256", let hex = child as? String, BackupFormat.isLowercaseHex(hex),
                       hex.count == 64 {
                        found.append(hex)
                    } else {
                        walk(child)
                    }
                }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(any)
        return found
    }
}
