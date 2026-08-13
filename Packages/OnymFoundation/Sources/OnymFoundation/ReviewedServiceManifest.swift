import Foundation
import CryptoKit

/// A service manifest that passed review — the unit of consent,
/// mintable only by `ServiceManifestReviewer.review(raw:expectedDigest:now:)`.
///
/// `SignedServiceManifest` is a plain value with a public initializer,
/// so taking one at consent time would move authenticity (embedded
/// operator signature over the exact bytes, digest pin, expiry) out of
/// the reviewer and onto whoever calls it — and a hand-built value can
/// pair `rawBytes` of one manifest with the decoded fields of another,
/// pinning a hash whose contents differ from what the user was shown.
/// Wrapping it in a type with **no public initializer** keeps the
/// check where the invariant lives: the only bytes that can reach a
/// pinned consent record are bytes the reviewer verified. Same
/// discipline as `ReviewedManifest` in OnymModeration — what was
/// reviewed is exactly what gets pinned.
public struct ReviewedServiceManifest: Sendable, Equatable {
    /// The reviewed manifest, for the consent surface to display.
    public let signedManifest: SignedServiceManifest

    init(_ signedManifest: SignedServiceManifest) {
        self.signedManifest = signedManifest
    }
}

/// Verifies a service manifest's exact published bytes and mints the
/// `ReviewedServiceManifest` token consent APIs require.
///
/// **Hard-enforced** — unlike `ContractsTrust`'s soft mode for the
/// legacy lists, there is no accept-anyway path: a manifest that fails
/// any check is rejected. The signature is the manifest's own embedded
/// `signature`, verified against its own `operator` key over the
/// canonical bytes (`ServiceManifestCanonical`); binding that key to
/// an identity the user trusts (catalog digest pin, out-of-band
/// fingerprint check) is the caller's protocol.
public struct ServiceManifestReviewer: Sendable {
    public init() {}

    /// Review exact manifest bytes.
    ///
    /// - Parameters:
    ///   - raw: the bytes as served. These exact bytes end up in the
    ///     token — never a re-fetch, never a re-encode.
    ///   - expectedDigest: `sha256:<hex>` pin when the bytes were
    ///     reached through a catalog entry (or a user-confirmed hash).
    ///     `nil` on the direct paste-URL path, where trust is the
    ///     signature self-check plus the user's explicit review.
    ///   - now: injected clock for the `validUntil` check.
    /// - Throws: `ServiceManifestError`.
    public func review(
        raw: Data,
        expectedDigest: String? = nil,
        now: Date = Date()
    ) throws -> ReviewedServiceManifest {
        if let expectedDigest {
            let actual = ServiceManifestFormat.sha256Digest(of: raw)
            guard ServiceManifestFormat.isDigest(expectedDigest), expectedDigest == actual else {
                throw ServiceManifestError.digestMismatch(expected: expectedDigest, actual: actual)
            }
        }

        let manifest = try SignedServiceManifest(raw: raw)

        guard let signatureBase64 = manifest.signatureBase64 else {
            throw ServiceManifestError.signatureInvalid(reason: "manifest carries no signature")
        }
        guard let signature = ServiceManifestFormat.decodeBase64AcceptingUnpadded(signatureBase64) else {
            throw ServiceManifestError.signatureInvalid(reason: "signature is not valid base64")
        }
        guard let keyData = ServiceManifestFormat.data(fromLowercaseHex: manifest.operatorPublicKeyHex),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else {
            throw ServiceManifestError.signatureInvalid(reason: "operator key is not a valid Ed25519 public key")
        }
        let signingBytes = try ServiceManifestCanonical.signingBytes(of: raw)
        let verifier = Ed25519DetachedSignatureVerifier(publicKey: publicKey)
        guard verifier.isValid(signature: signature, for: signingBytes) else {
            throw ServiceManifestError.signatureInvalid(reason: "signature does not verify against the operator key")
        }

        if let validUntil = manifest.validUntil, validUntil < now {
            throw ServiceManifestError.expired(validUntil: validUntil)
        }

        return ReviewedServiceManifest(manifest)
    }
}
