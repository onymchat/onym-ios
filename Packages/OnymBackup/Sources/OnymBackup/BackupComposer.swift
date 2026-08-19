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
    private let workingDirectory: URL

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
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let operationId = try SecureRandom.data(16).map { String(format: "%02x", $0) }.joined()
        let plaintextURL = workingDirectory.appending(path: "archive-\(operationId)")
        let scratchURL = workingDirectory.appending(path: "scratch-\(operationId)")

        // The plaintext archive is the one artefact on disk that is
        // readable without the seed, so it is removed the moment the
        // seal exists — including on the throwing path.
        defer {
            try? FileManager.default.removeItem(at: plaintextURL)
            try? FileManager.default.removeItem(at: scratchURL)
        }

        let writer = try BackupArchiveWriter(scratchURL: scratchURL)
        writer.setIdentityCount(await source.identityCount())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

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

        let sealedURL = workingDirectory.appending(path: "pending-\(operationId)")
        let reference = try BackupSealer.seal(
            plaintextURL: plaintextURL,
            to: sealedURL,
            archiveRoot: keyMaterial.archiveRoot
        )
        return SealedSnapshot(
            operationId: operationId,
            snapshotReference: reference,
            sealedBytesURL: sealedURL,
            sealedAt: now,
            acceptedTermsId: acceptedTermsId,
            supersedes: supersedes
        )
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
            // A blob the store no longer serves is not a failure: blob
            // retention is its own contract, shorter than a backup's by
            // design. The descriptor still travels, and the restore says
            // what it could not resolve.
            guard let ciphertext = try await source.blobCiphertext(sha256: address) else { continue }
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
