import Foundation

/// Canonical signing bytes for discovery documents
/// (`Discovery-Static-Ed25519.md` §3), matching the moderation seat's
/// cross-language precedent (`onym-moderation` `authority/src/canonical.rs`):
///
/// 1. parse the document as UTF-8 JSON; the top level must be an object;
/// 2. remove the `signature` field **structurally and at the top level
///    only** — never by string surgery, because a planted copy of the
///    signature elsewhere in the document would make textual removal
///    forgeable;
/// 3. re-serialize compactly with all object keys, at every nesting
///    level, sorted by **UTF-8 byte order**, with §3's pinned string
///    escaping and without escaping `/`.
///
/// The serialization is implemented here rather than delegated to
/// `JSONSerialization`, because Foundation's `.sortedKeys` sorts
/// case-insensitively — it diverges from the profile's UTF-8 byte
/// order exactly on the §10 case-divergence vector — and Foundation's
/// string escaping is not the §3 pinned set. Both sub-vectors
/// (`canonical-case-*`, `canonical-escaping-*`) pin this serializer's
/// agreement with the Rust reference implementation byte for byte.
public enum DiscoveryCanonical {
    /// The bytes a discovery document's Ed25519 signature is made over.
    /// - Throws: `DiscoveryTrustError.providerManifestInvalid` when the
    ///   input is not JSON or its top level is not an object (the caller
    ///   remaps to the snapshot error when appropriate).
    public static func signingBytes(of raw: Data) throws -> Data {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: raw)
        } catch {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "document is not valid JSON")
        }
        guard var object = parsed as? [String: Any] else {
            throw DiscoveryTrustError.providerManifestInvalid(reason: "top level is not a JSON object")
        }
        object.removeValue(forKey: "signature")
        var out = ""
        try serialize(object, into: &out)
        return Data(out.utf8)
    }

    // MARK: - Canonical serialization (§3)

    private static func serialize(_ value: Any, into out: inout String) throws {
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
                try serialize(object[key]!, into: &out)
            }
            out.append("}")
        case let array as [Any]:
            out.append("[")
            var first = true
            for element in array {
                if !first { out.append(",") }
                first = false
                try serialize(element, into: &out)
            }
            out.append("]")
        case let string as String:
            appendEscaped(string, into: &out)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                out.append(number.boolValue ? "true" : "false")
            } else if CFNumberIsFloatType(number) {
                // §3: all numbers are non-negative integers; a float
                // has no canonical form here.
                throw DiscoveryTrustError.providerManifestInvalid(
                    reason: "non-integer number has no canonical form"
                )
            } else {
                out.append(number.stringValue)
            }
        case is NSNull:
            out.append("null")
        default:
            throw DiscoveryTrustError.providerManifestInvalid(
                reason: "unsupported JSON value"
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
