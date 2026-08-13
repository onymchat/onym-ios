import Foundation

/// Canonical signing bytes for discovery documents
/// (`Discovery-Static-Ed25519.md` §3), matching the moderation seat's
/// cross-language precedent (`onym-moderation` `authority/src/canonical.rs`):
///
/// 1. parse the document as UTF-8 JSON; the top level must be an object;
/// 2. remove the `signature` field **structurally** — never by string
///    surgery, because a planted copy of the signature elsewhere in the
///    document would make textual removal forgeable;
/// 3. re-serialize compactly with all object keys, at every nesting
///    level, sorted by UTF-8 byte order, without escaping `/`.
///
/// Unlike `ModerationCanonicalEncoder` (which canonicalizes values we
/// *encode*), this canonicalizes bytes we *received*, so it must go
/// through `JSONSerialization`, not `JSONEncoder`. Two caveats carried
/// over from that encoder's documentation:
///
/// - **Case-sensitivity.** `JSONSerialization`'s `.sortedKeys` sorts
///   case-insensitively, while serde_json (and the profile) sort by
///   UTF-8 byte order. The two disagree only when sibling keys differ
///   by letter case at the deciding character; the profile's schema has
///   no such pair, and the cross-language `canonical-input.json` →
///   `canonical-bytes.bin` fixture test pins the agreement.
/// - **Slashes.** `.withoutEscapingSlashes` is load-bearing: every
///   snapshot URL and base64 signature contains `/`, and the reference
///   implementation signs the unescaped form.
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
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}
