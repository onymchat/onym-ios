import Foundation
import CryptoKit

/// Why a service manifest failed review. `reason` strings are
/// diagnostic, not part of any contract.
public enum ServiceManifestError: Error, Equatable, Sendable {
    /// Not JSON, top level not an object, or the common spine
    /// (componentId / seat / operator) is missing or malformed.
    case manifestInvalid(reason: String)
    /// Missing, unparseable, or non-verifying embedded signature.
    case signatureInvalid(reason: String)
    /// `validUntil` is in the past.
    case expired(validUntil: Date)
    /// Fetched bytes hash differently than the digest the caller
    /// pinned (e.g. a catalog entry's `manifest.digest`).
    case digestMismatch(expected: String, actual: String)
}

/// A seat operator's manifest — courier, notary, authority, or any
/// future seat — parsed down to the **common spine** every seat
/// shares: `componentId`, `seat`, `operator`, optional `offers`,
/// optional `validUntil`, and the embedded `signature`.
///
/// Destination seats own their schemas, so parsing is deliberately
/// tolerant: unknown fields are preserved untouched inside `rawBytes`
/// and simply not surfaced here. Seat adapters that need
/// seat-specific fields (endpoints, relay URLs, policies) decode them
/// from `rawBytes` with their own types.
///
/// The exact bytes as served are retained alongside the decode —
/// signature verification and hash pinning are always over
/// `rawBytes`, never over a re-encode.
public struct SignedServiceManifest: Sendable, Equatable {
    /// `onym:component:<[a-z0-9-]{1,64}>`.
    public let componentId: String
    /// The seat this operator fills (e.g. "courier", "notary",
    /// "authority"). Non-empty; otherwise unconstrained — new seats
    /// must not require a foundation change.
    public let seat: String
    /// The operator key as published: `onym:key:<64-lowercase-hex>`.
    public let operatorKey: String
    /// The 64-lowercase-hex Ed25519 public key from `operatorKey`.
    public let operatorPublicKeyHex: String
    /// Offers decoded lossily from the manifest's `offers` array —
    /// malformed entries are skipped, absent array is empty.
    public let offers: [ServiceOffer]
    /// Manifest expiry, when the operator published one.
    public let validUntil: Date?
    /// The exact bytes as served. What gets verified, hashed, and
    /// pinned is always this, never a re-encode.
    public let rawBytes: Data
    /// `sha256:<64-lowercase-hex>` over `rawBytes`, matching the
    /// digest format catalog entries pin.
    public let manifestHash: String
    /// The embedded top-level `signature` (base64), if present.
    /// Verification lives in `ServiceManifestReviewer`.
    let signatureBase64: String?

    /// Parse the common spine out of exact manifest bytes. Performs
    /// **no** signature or expiry checks — use
    /// `ServiceManifestReviewer.review(raw:expectedDigest:now:)` to
    /// obtain a manifest fit for consent.
    public init(raw: Data) throws {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: raw)
        } catch {
            throw ServiceManifestError.manifestInvalid(reason: "document is not valid JSON")
        }
        guard let object = parsed as? [String: Any] else {
            throw ServiceManifestError.manifestInvalid(reason: "top level is not a JSON object")
        }
        guard let componentId = object["componentId"] as? String,
              ServiceManifestFormat.isComponentId(componentId)
        else {
            throw ServiceManifestError.manifestInvalid(reason: "missing or malformed componentId")
        }
        guard let seat = object["seat"] as? String, !seat.isEmpty else {
            throw ServiceManifestError.manifestInvalid(reason: "missing or empty seat")
        }
        guard let operatorKey = object["operator"] as? String,
              let operatorHex = ServiceManifestFormat.operatorKeyHex(operatorKey)
        else {
            throw ServiceManifestError.manifestInvalid(reason: "missing or malformed operator key")
        }
        var validUntil: Date?
        if let validUntilRaw = object["validUntil"] {
            guard let text = validUntilRaw as? String,
                  let date = ServiceManifestFormat.date(fromRFC3339: text)
            else {
                throw ServiceManifestError.manifestInvalid(reason: "validUntil is not an RFC 3339 timestamp")
            }
            validUntil = date
        }

        self.componentId = componentId
        self.seat = seat
        self.operatorKey = operatorKey
        self.operatorPublicKeyHex = operatorHex
        self.offers = ServiceOffer.decodeLossy(object["offers"])
        self.validUntil = validUntil
        self.rawBytes = raw
        self.manifestHash = ServiceManifestFormat.sha256Digest(of: raw)
        self.signatureBase64 = object["signature"] as? String
    }
}

/// Canonical signing bytes for service manifests, matching the
/// cross-language precedent set by the moderation seat
/// (`ModerationCanonicalEncoder`, `authority/src/canonical.rs`):
///
/// 1. parse the document as UTF-8 JSON; the top level must be an
///    object;
/// 2. remove the `signature` field **structurally** — never by string
///    surgery, because a planted copy of the signature elsewhere in
///    the document would make textual removal forgeable;
/// 3. re-serialize compactly with all object keys, at every nesting
///    level, sorted (`.sortedKeys`), without escaping `/`
///    (`.withoutEscapingSlashes` — reference implementations sign the
///    unescaped form, and base64 signatures and URLs are full of
///    slashes).
///
/// Local to OnymFoundation on purpose: seat packages depend on this
/// package and must not gain an OnymModeration (or OnymDiscovery)
/// dependency to verify a manifest.
public enum ServiceManifestCanonical {
    /// The bytes a manifest's embedded Ed25519 signature is made over.
    public static func signingBytes(of raw: Data) throws -> Data {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: raw)
        } catch {
            throw ServiceManifestError.manifestInvalid(reason: "document is not valid JSON")
        }
        guard var object = parsed as? [String: Any] else {
            throw ServiceManifestError.manifestInvalid(reason: "top level is not a JSON object")
        }
        object.removeValue(forKey: "signature")
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

/// Identifier / digest syntax shared by every seat manifest.
enum ServiceManifestFormat {
    /// `onym:key:<64-lowercase-hex>` → the hex, or nil.
    static func operatorKeyHex(_ value: String) -> String? {
        guard value.hasPrefix("onym:key:") else { return nil }
        let hex = String(value.dropFirst("onym:key:".count))
        guard hex.count == 64, isLowercaseHex(hex) else { return nil }
        return hex
    }

    /// `onym:component:<[a-z0-9-]{1,64}>`.
    static func isComponentId(_ value: String) -> Bool {
        guard value.hasPrefix("onym:component:") else { return false }
        let id = value.dropFirst("onym:component:".count)
        guard (1...64).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    /// `sha256:` + 64 lowercase hex.
    static func isDigest(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let hex = String(value.dropFirst("sha256:".count))
        return hex.count == 64 && isLowercaseHex(hex)
    }

    static func isLowercaseHex(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }

    /// `sha256:<hex>` over exact bytes.
    static func sha256Digest(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase-hex string → bytes, or nil on odd length / non-hex.
    static func data(fromLowercaseHex hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2), isLowercaseHex(hex) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// RFC 3339, seconds or fractional-seconds precision.
    static func date(fromRFC3339 value: String) -> Date? {
        let wholeSeconds = ISO8601DateFormatter()
        if let date = wholeSeconds.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    /// Base64 accepting padded or unpadded input.
    static func decodeBase64AcceptingUnpadded(_ value: String) -> Data? {
        if let data = Data(base64Encoded: value) { return data }
        let remainder = value.count % 4
        guard remainder > 0 else { return nil }
        return Data(base64Encoded: value + String(repeating: "=", count: 4 - remainder))
    }
}
