import Foundation

/// The identity of one snapshot: a digest over the exact sealed byte
/// sequence, plus that sequence's length.
///
/// It covers the sealed bytes and nothing else — not the local state
/// before sealing, not the decoded archive, not a locator, not any
/// mutable operator metadata. That is what lets the same reference survive
/// export from one operator and upload to another with no re-sealing
/// (`UI-Backup-Object-HTTP.md` §12).
///
/// `sealedByteSize` is a padding bucket, not a measurement of a person's
/// history: the archive is padded before sealing (§7 of the profile), so
/// two very different histories land on the same size.
public struct SnapshotReference: Sendable, Equatable, Hashable, Codable {
    public let referenceVersion: Int
    public let algorithm: String
    /// `sha256:<64 lowercase hex>`.
    public let digest: String
    public let sealedByteSize: Int

    public init(digest: String, sealedByteSize: Int) throws {
        guard BackupFormat.isDigest(digest) else { throw BackupError.invalidReference }
        guard sealedByteSize > 0 else { throw BackupError.invalidReference }
        self.referenceVersion = 1
        self.algorithm = BackupProfile.digestSuite
        self.digest = digest
        self.sealedByteSize = sealedByteSize
    }

    /// Decoding is where operator-supplied references arrive, so it
    /// validates rather than trusting the wire. An unparseable or
    /// wrong-suite reference is `invalidReference`, never a value we go on
    /// to compare against real bytes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .referenceVersion)
        let algorithm = try container.decode(String.self, forKey: .algorithm)
        let digest = try container.decode(String.self, forKey: .digest)
        let sealedByteSize = try container.decode(Int.self, forKey: .sealedByteSize)
        guard
            version == 1,
            algorithm == BackupProfile.digestSuite,
            BackupFormat.isDigest(digest),
            sealedByteSize > 0
        else {
            throw BackupError.invalidReference
        }
        self.referenceVersion = version
        self.algorithm = algorithm
        self.digest = digest
        self.sealedByteSize = sealedByteSize
    }

    /// The hex body without the `sha256:` prefix — for path components and
    /// filenames, where the colon is unwelcome.
    public var digestHex: String {
        String(digest.dropFirst(BackupFormat.digestPrefix.count))
    }

    /// First and last four hex characters, for display. Never used for
    /// comparison: a truncated digest is a label, not an identity.
    public var shortDigest: String {
        let hex = digestHex
        return "\(hex.prefix(4))…\(hex.suffix(4))"
    }
}
