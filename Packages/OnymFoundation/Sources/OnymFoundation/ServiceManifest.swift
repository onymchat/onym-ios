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
    /// The caller's `expectedDigest` is not `sha256:<64-hex>` at all —
    /// garbage in the pin, not swapped bytes. Distinct from
    /// `digestMismatch` so the two failures stay diagnosable.
    case digestPinMalformed(value: String)
    /// The manifest's `operator` key differs from the key the caller
    /// bound the review to (`expectedOperatorKey`). The signature may
    /// still be internally valid — this is an identity mismatch, not a
    /// byte swap.
    case operatorKeyMismatch(expected: String, actual: String)
    /// A number at `path` is not an integer. Signed v1 manifests are
    /// integer-only (spec §3): canonical signing bytes must re-serialize
    /// byte-stably, and floats have no pinned decimal form. Distinct
    /// from `manifestInvalid` and names the offending field so an
    /// operator can find `pricePerGB: 0.5` and republish it as a string
    /// or scaled integer.
    case nonIntegerNumber(path: String)
    /// A JSON value at `path` is of a type the canonical form does not
    /// define (should be unreachable for values `JSONSerialization`
    /// produces; kept distinct so it never masquerades as a manifest
    /// syntax problem).
    case unsupportedValueType(path: String)
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
///
/// **Numbers are integers-only in v1 signed manifests** (spec §3):
/// the canonical signing bytes must re-serialize byte-stably, and a
/// float has no pinned decimal form, so a manifest containing one
/// anywhere fails review with `nonIntegerNumber(path:)`. Price-like
/// values belong in strings (`"0.5"`) or scaled integers
/// (`priceMilliCentsPerGB`).
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

/// Canonical signing bytes for service manifests
/// (`Discovery-Static-Ed25519.md` §3), matching the moderation seat's
/// cross-language precedent (`onym-moderation` `authority/src/canonical.rs`):
///
/// 1. parse the document as UTF-8 JSON; the top level must be an
///    object;
/// 2. remove the `signature` field **structurally and at the top level
///    only** — never by string surgery, because a planted copy of the
///    signature elsewhere in the document would make textual removal
///    forgeable;
/// 3. re-serialize compactly with all object keys, at every nesting
///    level, sorted by **UTF-8 byte order**, with §3's pinned string
///    escaping and without escaping `/`.
///
/// The serialization is implemented here rather than delegated to
/// `JSONSerialization`, whose `.sortedKeys` sorts *case-insensitively
/// and numerically* — `seatID`/`seatable` and `relay2`/`relay10` both
/// come out in the wrong order — and whose number re-serialization is
/// uncontrolled; `ModerationCanonicalEncoder` and `Report.signingBytes`
/// document the same prohibition. The normative definition of these
/// bytes is `Discovery-Static-Ed25519.md` §3 in `onym-system`; the
/// reference implementation is the Rust canonicalizer in the
/// `onym-discovery` repo, whose emitted bytes are pinned here as the
/// `foundation-vectors` fixture pair — change either implementation
/// and that fixture fails on whichever side drifted.
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
        var out = ""
        try serialize(object, at: "", into: &out)
        return Data(out.utf8)
    }

    // MARK: - Canonical serialization (§3)

    /// `path` is the dotted/indexed location of `value` for error
    /// reporting ("" at the top level, `offers[0].service.pricePerGB`
    /// deeper down) — diagnostics only, never part of the bytes.
    private static func serialize(_ value: Any, at path: String, into out: inout String) throws {
        switch value {
        case let object as [String: Any]:
            out.append("{")
            // UTF-8 byte order, not Swift's Unicode-aware ordering and
            // not Foundation's case-insensitive `.sortedKeys`.
            let keys = object.keys.sorted {
                Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
            }
            var first = true
            for key in keys {
                if !first { out.append(",") }
                first = false
                appendEscaped(key, into: &out)
                out.append(":")
                let childPath = path.isEmpty ? key : path + "." + key
                try serialize(object[key]!, at: childPath, into: &out)
            }
            out.append("}")
        case let array as [Any]:
            out.append("[")
            var first = true
            for (index, element) in array.enumerated() {
                if !first { out.append(",") }
                first = false
                try serialize(element, at: "\(path)[\(index)]", into: &out)
            }
            out.append("]")
        case let string as String:
            appendEscaped(string, into: &out)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                out.append(number.boolValue ? "true" : "false")
            } else if CFNumberIsFloatType(number) {
                // Spec §3: numbers in signed manifests are integers;
                // a float has no canonical decimal form, so its
                // signing bytes could not round-trip byte-stably.
                throw ServiceManifestError.nonIntegerNumber(
                    path: path.isEmpty ? "(top level)" : path
                )
            } else {
                out.append(number.stringValue)
            }
        case is NSNull:
            out.append("null")
        default:
            throw ServiceManifestError.unsupportedValueType(
                path: path.isEmpty ? "(top level)" : path
            )
        }
    }

    /// §3 pinned escaping: exactly `"` `\` and U+0000–U+001F are
    /// escaped — two-character forms where defined, lowercase `\u00xx`
    /// otherwise — and nothing else: no `/`, no non-ASCII, no U+007F.
    private static func appendEscaped(_ string: String, into out: inout String) {
        out.append("\"")
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x08: out.append("\\b")
            case 0x0C: out.append("\\f")
            case 0x0A: out.append("\\n")
            case 0x0D: out.append("\\r")
            case 0x09: out.append("\\t")
            case 0x00...0x1F: out.append(String(format: "\\u%04x", scalar.value))
            default: out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
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

    /// Cached formatters — `ISO8601DateFormatter` is expensive to
    /// build and documented thread-safe, and `date(fromRFC3339:)` sits
    /// on the parse path of every manifest.
    private static let wholeSecondsFormatter = ISO8601DateFormatter()
    private static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// RFC 3339, seconds or fractional-seconds precision.
    static func date(fromRFC3339 value: String) -> Date? {
        if let date = wholeSecondsFormatter.date(from: value) { return date }
        return fractionalSecondsFormatter.date(from: value)
    }

    /// Base64 accepting padded or unpadded input.
    static func decodeBase64AcceptingUnpadded(_ value: String) -> Data? {
        if let data = Data(base64Encoded: value) { return data }
        let remainder = value.count % 4
        guard remainder > 0 else { return nil }
        return Data(base64Encoded: value + String(repeating: "=", count: 4 - remainder))
    }
}
