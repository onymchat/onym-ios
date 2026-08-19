import CryptoKit
import Foundation

/// What one record inside an archive holds.
///
/// A small closed vocabulary rather than free-form filenames: the reader
/// has to know what it is decoding before it decodes it, and a snapshot
/// written by a newer client must be refused rather than half-read.
public enum BackupArchiveEntryKind: UInt8, Sendable, Equatable, CaseIterable {
    case groups = 0x01
    case messages = 0x02
    case invitations = 0x03
    case consents = 0x04
    /// Attachment ciphertext, exactly as Blossom holds it. Never
    /// plaintext media: the local media caches store decrypted bytes
    /// keyed by a public content address, and copying those into a
    /// snapshot would be the worst thing in it.
    case blobCiphertext = 0x05
}

/// One record's place in the archive.
public struct BackupArchiveEntry: Sendable, Equatable, Codable {
    public let kind: UInt8
    public let length: Int
    /// `sha256:<hex>` of this record's bytes. Redundant against the
    /// AEAD, deliberately: it lets the reader reject a record before
    /// handing it to a decoder, and it survives into the header where a
    /// restore can report *which* record failed rather than only that
    /// something did.
    public let sha256: String

    public var entryKind: BackupArchiveEntryKind? { BackupArchiveEntryKind(rawValue: kind) }
}

/// The archive header, carried in the clear inside the seal.
public struct BackupArchiveHeader: Sendable, Equatable, Codable {
    public let archiveVersion: Int
    public let createdAt: Date
    public let identityCount: Int
    /// The archive's true length before padding. The padding is inside
    /// the seal, so this is the only place the real size is recorded.
    public let contentByteSize: Int
    public let entries: [BackupArchiveEntry]
}

/// The container format of `UI-Backup-Object-HTTP.md` §5.4's plaintext
/// side: `"ONYMBAK1"`, a length-prefixed JSON header, then length-
/// prefixed records.
///
/// Records are explicit wire structs written by the composer, not the
/// app's domain models. Keeping them apart is what stops a rename in
/// `ChatGroup` from silently changing the schema of every archive ever
/// written.
public enum BackupArchive {
    static let magic = Data("ONYMBAK1".utf8)
    public static let archiveVersion = 1
}

/// Streams records into an archive file.
///
/// The header names every entry and its digest, so it can only be
/// written once the entries are known. Rather than buffer an archive
/// that may be hundreds of megabytes, records go to a scratch file first
/// and are copied in behind the finished header — one extra pass over
/// the bytes, and no requirement to hold them.
public final class BackupArchiveWriter {
    private let scratchURL: URL
    private let handle: FileHandle
    private var entries: [BackupArchiveEntry] = []
    private var identityCount = 0
    private var finished = false

    public init(scratchURL: URL) throws {
        self.scratchURL = scratchURL
        FileManager.default.createFile(
            atPath: scratchURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        self.handle = try FileHandle(forWritingTo: scratchURL)
    }

    public func setIdentityCount(_ count: Int) {
        identityCount = count
    }

    /// Append one record. `bytes` is whatever the composer serialized
    /// for that kind; this layer does not interpret it.
    public func append(kind: BackupArchiveEntryKind, bytes: Data) throws {
        var framed = Data([kind.rawValue])
        framed.append(BackupSealer.bigEndian(UInt32(bytes.count)))
        framed.append(bytes)
        try handle.write(contentsOf: framed)
        entries.append(
            BackupArchiveEntry(
                kind: kind.rawValue,
                length: bytes.count,
                sha256: BackupFormat.sha256Digest(of: bytes)
            )
        )
    }

    /// Write the finished archive to `url` and return its plaintext
    /// length. The scratch file is removed either way.
    /// The scratch file holds *plaintext* archive records, so it must
    /// not outlive the writer. `finish` removes it on the happy path;
    /// this catches the abandoned one — a composer that threw partway,
    /// or a cancelled snapshot.
    deinit {
        try? FileManager.default.removeItem(at: scratchURL)
    }

    @discardableResult
    public func finish(writingTo url: URL, createdAt: Date = Date()) throws -> Int {
        guard !finished else { throw BackupError.localFailure(reason: .archiveWriterFinished) }
        finished = true
        try handle.close()
        defer { try? FileManager.default.removeItem(at: scratchURL) }

        let recordBytes = try BackupSealer.fileSize(of: scratchURL)
        let header = BackupArchiveHeader(
            archiveVersion: BackupArchive.archiveVersion,
            createdAt: createdAt,
            identityCount: identityCount,
            contentByteSize: recordBytes,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let headerJSON = try encoder.encode(header)

        FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }

        try output.write(contentsOf: BackupArchive.magic)
        try output.write(contentsOf: BackupSealer.bigEndian(UInt32(headerJSON.count)))
        try output.write(contentsOf: headerJSON)

        let input = try FileHandle(forReadingFrom: scratchURL)
        defer { try? input.close() }
        while let block = try input.read(upToCount: 1 << 20), !block.isEmpty {
            try output.write(contentsOf: block)
        }
        return BackupArchive.magic.count + 4 + headerJSON.count + recordBytes
    }
}

/// Reads an archive back, verifying as it goes.
public struct BackupArchiveReader {
    public let header: BackupArchiveHeader
    private let url: URL
    private let recordsOffset: Int

    /// Open and read the header only.
    ///
    /// A newer `archiveVersion` is refused outright. Restoring a subset
    /// of a schema we do not fully understand is how a "successful"
    /// restore silently loses a column.
    public init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard
            let magic = try handle.read(upToCount: BackupArchive.magic.count),
            magic == BackupArchive.magic,
            let lengthBytes = try handle.read(upToCount: 4), lengthBytes.count == 4
        else {
            throw BackupError.localFailure(reason: .archiveUnreadable)
        }
        let headerLength = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard
            let headerJSON = try handle.read(upToCount: headerLength),
            headerJSON.count == headerLength
        else {
            throw BackupError.localFailure(reason: .archiveUnreadable)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(BackupArchiveHeader.self, from: headerJSON) else {
            throw BackupError.localFailure(reason: .archiveUnreadable)
        }
        guard header.archiveVersion <= BackupArchive.archiveVersion else {
            throw BackupError.unsupportedProfile
        }
        self.header = header
        self.recordsOffset = BackupArchive.magic.count + 4 + headerLength
    }

    /// Walk every record in order, handing each to `body`.
    ///
    /// Each record's digest is checked against the header before it is
    /// delivered. A record that fails is `incompleteSnapshot` and the
    /// walk stops — the caller must not write a partial restore.
    public func forEachRecord(
        _ body: (BackupArchiveEntryKind, Data) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(recordsOffset))

        for entry in header.entries {
            guard
                let framing = try handle.read(upToCount: 5), framing.count == 5,
                let kind = BackupArchiveEntryKind(rawValue: framing[framing.startIndex]),
                // The header is what a restore reports from, so it is
                // authoritative. Neither the per-entry digest nor the
                // AEAD covers the framing byte, so header and framing
                // can disagree about what a record *is* while both
                // verify — and a record decoded as the wrong kind is a
                // worse outcome than a refusal.
                framing[framing.startIndex] == entry.kind
            else {
                throw BackupError.incompleteSnapshot
            }
            let length = Int(framing.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard length == entry.length, let bytes = try handle.read(upToCount: length),
                  bytes.count == length
            else {
                throw BackupError.incompleteSnapshot
            }
            guard BackupFormat.sha256Digest(of: bytes) == entry.sha256 else {
                throw BackupError.incompleteSnapshot
            }
            try body(kind, bytes)
        }
    }
}
