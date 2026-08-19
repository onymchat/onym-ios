import CryptoKit
import Foundation
import OnymFoundation

/// Seals a plaintext archive into the container of
/// `UI-Backup-Object-HTTP.md` §5.4, streaming so a multi-hundred-megabyte
/// snapshot never sits in memory whole.
///
/// The output is what the `SnapshotReference` digest covers, byte for
/// byte: magic, header, salt, and AEAD chunks. Nothing outside this file
/// may re-serialize it, because a reference that disagrees with the bytes
/// is the one failure the whole seat is arranged to prevent.
public enum BackupSealer {
    static let magic = Data("ONYMSEAL1".utf8)
    static let suiteAESGCM: UInt8 = 0x01
    /// Plaintext bytes per AEAD chunk. A sealing-layer concern only: it
    /// bounds memory on the device and has nothing to do with the
    /// transfer chunking an operator grants (§9.3).
    public static let chunkPlainBytes = 1 << 20  // 1 MiB
    static let headerBytes = 9 + 1 + 1 + 4 + 4 + 32
    static let saltBytes = 32
    /// AES-GCM combined form adds a 12-byte nonce and a 16-byte tag.
    static let chunkOverhead = 12 + 16

    /// Seal `plaintextURL` to `sealedURL`, returning the reference over
    /// the exact bytes written.
    ///
    /// The snapshot salt is drawn fresh from the CSPRNG. It is what
    /// makes keying non-convergent: two holders sealing identical
    /// archives get unrelated ciphertext and unrelated digests, so an
    /// operator cannot confirm that someone possesses a known file
    /// (§5.3).
    ///
    /// There is deliberately no way to supply one. Reusing a salt under
    /// the same archive root reproduces the same snapshot key, and the
    /// nonces are counters — so two different plaintexts would be sealed
    /// under an identical (key, nonce) pair, which collapses AES-GCM's
    /// confidentiality *and* its integrity. The only caller that ever
    /// wanted to pin a salt was a fixture, and a fixture can reach the
    /// internal overload.
    @discardableResult
    public static func seal(
        plaintextURL: URL,
        to sealedURL: URL,
        archiveRoot: SymmetricKey
    ) throws -> SnapshotReference {
        try seal(plaintextURL: plaintextURL, to: sealedURL, archiveRoot: archiveRoot, snapshotSalt: nil)
    }

    @discardableResult
    static func seal(
        plaintextURL: URL,
        to sealedURL: URL,
        archiveRoot: SymmetricKey,
        snapshotSalt: Data?
    ) throws -> SnapshotReference {
        let salt = try snapshotSalt ?? SecureRandom.data(saltBytes)
        guard salt.count == saltBytes else { throw BackupError.localFailure(reason: .archiveUnreadable) }

        let plainSize = try fileSize(of: plaintextURL)
        let paddedSize = BackupPadding.paddedLength(for: plainSize)
        var remainingPadding = paddedSize - plainSize
        let chunkCount = paddedSize == 0 ? 0 : (paddedSize + chunkPlainBytes - 1) / chunkPlainBytes

        let key = BackupKeys.snapshotKey(archiveRoot: archiveRoot, snapshotSalt: salt)

        FileManager.default.createFile(atPath: sealedURL.path, contents: nil)
        try (sealedURL as NSURL).setResourceValue(
            URLFileProtection.complete,
            forKey: .fileProtectionKey
        )
        let input = try FileHandle(forReadingFrom: plaintextURL)
        let output = try FileHandle(forWritingTo: sealedURL)
        defer {
            try? input.close()
            try? output.close()
        }

        var digest = SHA256()
        var written = 0

        func emit(_ data: Data) throws {
            try output.write(contentsOf: data)
            digest.update(data: data)
            written += data.count
        }

        var header = Data()
        header.append(magic)
        header.append(suiteAESGCM)
        header.append(0x00)  // reserved
        header.append(bigEndian(UInt32(chunkPlainBytes)))
        header.append(bigEndian(UInt32(chunkCount)))
        header.append(salt)
        try emit(header)

        for index in 0..<chunkCount {
            var plain = try input.read(upToCount: chunkPlainBytes) ?? Data()
            // The archive runs out before the padded length does; the
            // rest of the stream is zeros. Padding is inside the seal, so
            // an operator sees only the bucket.
            if plain.count < chunkPlainBytes, remainingPadding > 0 {
                let take = min(remainingPadding, chunkPlainBytes - plain.count)
                plain.append(Data(repeating: 0, count: take))
                remainingPadding -= take
            }
            guard !plain.isEmpty else { break }
            let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce(for: index))
            guard let combined = sealed.combined else {
                throw BackupError.localFailure(reason: .archiveUnreadable)
            }
            try emit(combined)
        }

        return try SnapshotReference(
            digest: BackupFormat.digestPrefix + digest.finalize().map { String(format: "%02x", $0) }.joined(),
            sealedByteSize: written
        )
    }

    /// Counter nonce: 4 zero bytes then the chunk index, big-endian.
    ///
    /// Unique by construction under a per-snapshot key, which is the
    /// property AES-GCM actually needs. A random nonce would also be
    /// sound and would cost a birthday argument for nothing.
    static func nonce(for index: Int) throws -> AES.GCM.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        bytes.append(bigEndian(UInt64(index)))
        return try AES.GCM.Nonce(data: bytes)
    }

    static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func bigEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func fileSize(of url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw BackupError.localFailure(reason: .archiveUnreadable)
        }
        return size
    }
}
