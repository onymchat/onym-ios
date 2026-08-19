import CryptoKit
import Foundation

/// Opens what `BackupSealer` produced, after the reference has been
/// verified in full.
///
/// Order matters and is not negotiable: **verify the whole digest, then
/// decrypt.** A snapshot whose bytes do not compose its reference is
/// `incompleteSnapshot` and never becomes a partial restore
/// (`UI-Backup.md` §7.11). Streaming decryption of an unverified file
/// would hand plausible-looking plaintext to the caller for the prefix
/// that happened to survive.
public enum BackupOpener {
    /// SHA-256 over the exact file, compared against `reference`.
    ///
    /// Both the size and the digest are checked, and the size first —
    /// a truncated file is the cheap case and there is no reason to hash
    /// a gigabyte to discover it.
    public static func verify(sealedURL: URL, matches reference: SnapshotReference) throws {
        let size = try BackupSealer.fileSize(of: sealedURL)
        guard size == reference.sealedByteSize else { throw BackupError.incompleteSnapshot }

        let handle = try FileHandle(forReadingFrom: sealedURL)
        defer { try? handle.close() }
        var digest = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            digest.update(data: block)
        }
        let computed = BackupFormat.digestPrefix
            + digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard computed == reference.digest else { throw BackupError.incompleteSnapshot }
    }

    /// Verify, then decrypt to `plaintextURL`.
    ///
    /// The padding written at seal time is stripped by the archive
    /// reader, not here: this layer restores exactly the padded byte
    /// stream that was sealed, and the archive's own header carries its
    /// true length. Keeping the two concerns apart means a change to the
    /// padding ladder cannot silently alter what a snapshot decrypts to.
    public static func open(
        sealedURL: URL,
        to plaintextURL: URL,
        reference: SnapshotReference,
        archiveRoot: SymmetricKey
    ) throws {
        try verify(sealedURL: sealedURL, matches: reference)

        let input = try FileHandle(forReadingFrom: sealedURL)
        defer { try? input.close() }

        guard
            let header = try input.read(upToCount: BackupSealer.headerBytes),
            header.count == BackupSealer.headerBytes,
            header.prefix(BackupSealer.magic.count) == BackupSealer.magic
        else {
            throw BackupError.localFailure(reason: .archiveUnreadable)
        }
        var cursor = BackupSealer.magic.count
        let suite = header[header.startIndex + cursor]
        cursor += 2  // suite + reserved
        guard suite == BackupSealer.suiteAESGCM else {
            // A sealed file from a future suite is not something to
            // guess at: its key derivation and framing are both unknown.
            throw BackupError.unsupportedProfile
        }
        let chunkPlainBytes = Int(readUInt32(header, at: cursor)); cursor += 4
        let chunkCount = Int(readUInt32(header, at: cursor)); cursor += 4
        let salt = header.suffix(BackupSealer.saltBytes)
        guard chunkPlainBytes > 0, chunkCount >= 0 else {
            throw BackupError.localFailure(reason: .archiveUnreadable)
        }

        let key = BackupKeys.snapshotKey(archiveRoot: archiveRoot, snapshotSalt: Data(salt))

        FileManager.default.createFile(atPath: plaintextURL.path, contents: nil)
        try (plaintextURL as NSURL).setResourceValue(
            URLFileProtection.complete,
            forKey: .fileProtectionKey
        )
        let output = try FileHandle(forWritingTo: plaintextURL)
        defer { try? output.close() }

        for index in 0..<chunkCount {
            let expected = chunkPlainBytes + BackupSealer.chunkOverhead
            guard
                let combined = try input.read(upToCount: expected),
                combined.count > BackupSealer.chunkOverhead
            else {
                throw BackupError.incompleteSnapshot
            }
            let box = try AES.GCM.SealedBox(combined: combined)
            // AES-GCM authenticates before it returns plaintext, so a
            // flipped bit anywhere in a chunk throws here rather than
            // producing garbage the archive reader would then try to
            // parse.
            let plain = try AES.GCM.open(box, using: key)
            guard Data(box.nonce) == Data(try BackupSealer.nonce(for: index)) else {
                // Chunks are ordered by their nonce counter. A file whose
                // chunks were reordered still authenticates chunk by
                // chunk, so the ordering has to be checked explicitly.
                throw BackupError.incompleteSnapshot
            }
            try output.write(contentsOf: plain)
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
