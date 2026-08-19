import CryptoKit
import Foundation

/// Small syntax helpers for the shapes this seat shares with the rest of
/// the system: `sha256:<64 lowercase hex>` digests and RFC 3339 UTC
/// timestamps.
///
/// `OnymFoundation` has the same helpers behind `ServiceManifestFormat`,
/// but they are internal to that module. Rather than widen a shared
/// package's API for one consumer, this seat carries its own copy — the
/// same posture the profile takes for canonical bytes, where the point is
/// that two sides agree on *bytes*, not that they share code.
enum BackupFormat {
    static let digestPrefix = "sha256:"

    static func isLowercaseHex(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isNumber || ("a"..."f").contains($0) }
    }

    /// `sha256:<64 lowercase hex>` over `data`, matching
    /// `ServiceManifestFormat.sha256Digest` so one digest syntax covers
    /// manifests, terms, and snapshots.
    static func sha256Digest(of data: Data) -> String {
        digestPrefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True for a well-formed digest string. Deliberately strict: an
    /// operator-supplied digest that merely *looks* plausible must not
    /// reach a comparison.
    static func isDigest(_ value: String) -> Bool {
        guard value.hasPrefix(digestPrefix) else { return false }
        let hex = String(value.dropFirst(digestPrefix.count))
        return hex.count == 64 && isLowercaseHex(hex)
    }

    static func data(fromLowercaseHex hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2), isLowercaseHex(hex) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// RFC 3339 with no fractional seconds — the same pinned form the
    /// moderation seat signs over, so a timestamp inside signed bytes
    /// cannot drift between encoder configurations.
    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func date(fromRFC3339 value: String) -> Date? {
        timestampFormatter.date(from: value)
    }

    static func string(fromDate date: Date) -> String {
        timestampFormatter.string(from: date)
    }
}
