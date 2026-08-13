import Foundation
import CryptoKit
@testable import OnymFoundation

/// Builds self-signed sample manifests the way an operator's
/// publishing pipeline would: canonical bytes (structural `signature`
/// removal, sorted keys, unescaped slashes), Ed25519-sign, embed.
enum ManifestFactory {
    static let now = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!

    /// A base manifest object for a notary seat, including fields this
    /// layer does not understand (`endpoints`, `profiles`) — the spine
    /// parser must tolerate them.
    static func sampleObject(operatorKeyHex: String) -> [String: Any] {
        [
            "componentId": "onym:component:sample-notary",
            "seat": "notary",
            "operator": "onym:key:\(operatorKeyHex)",
            "name": "Sample Notary",
            "endpoints": ["submit": "https://notary.example/submit"],
            "profiles": ["onym-notary-v1"],
            "validUntil": "2027-01-01T00:00:00Z",
            "offers": [
                [
                    "offerId": "free-tier",
                    "model": "free",
                    "service": ["quota": 100],
                ],
                [
                    "offerId": "pro-monthly",
                    "model": "subscription",
                    "period": "monthly",
                ],
            ],
        ]
    }

    static func operatorKeyHex(_ key: Curve25519.Signing.PrivateKey) -> String {
        key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// Serialize, sign the canonical form, and re-serialize with the
    /// signature embedded. The final serialization is *not* canonical
    /// (no sorted keys guarantee needed) — verification re-canonicalizes.
    static func signedBytes(
        object: [String: Any],
        key: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        var object = object
        object.removeValue(forKey: "signature")
        let unsigned = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let signingBytes = try ServiceManifestCanonical.signingBytes(of: unsigned)
        let signature = try key.signature(for: signingBytes)
        object["signature"] = signature.base64EncodedString()
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        )
    }

    /// A complete valid signed sample manifest plus its key.
    static func signedSample(
        mutate: (inout [String: Any]) -> Void = { _ in }
    ) throws -> (raw: Data, key: Curve25519.Signing.PrivateKey) {
        let key = Curve25519.Signing.PrivateKey()
        var object = sampleObject(operatorKeyHex: operatorKeyHex(key))
        mutate(&object)
        return (try signedBytes(object: object, key: key), key)
    }

    /// Mint a reviewed token from freshly signed sample bytes.
    static func reviewedSample(
        mutate: (inout [String: Any]) -> Void = { _ in }
    ) throws -> ReviewedServiceManifest {
        let (raw, _) = try signedSample(mutate: mutate)
        return try ServiceManifestReviewer().review(raw: raw, now: now)
    }
}
