import Foundation
import CryptoKit
import os.log
import OnymFoundation

/// Fetches an authority's manifest as **exact bytes**, hashes them
/// (that hash is what the mandate pins), decodes, and verifies the
/// manifest's own signature against the directory-pinned operator key.
public protocol AuthorityManifestFetcher: Sendable {
    func fetch(_ listing: AuthorityListing) async throws -> SignedManifest
}

public struct URLSessionAuthorityManifestFetcher: AuthorityManifestFetcher {
    private static let log = Logger(subsystem: "app.onym.ios", category: "ModerationManifest")

    let session: URLSession
    let decoder: JSONDecoder
    let enforceSignature: Bool

    public init(
        session: URLSession = .shared,
        decoder: JSONDecoder? = nil,
        enforceSignature: Bool = ModerationTrust.enforceManifestSignatures
    ) {
        self.session = session
        if let decoder {
            self.decoder = decoder
        } else {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            self.decoder = d
        }
        self.enforceSignature = enforceSignature
    }

    public func fetch(_ listing: AuthorityListing) async throws -> SignedManifest {
        let (data, response) = try await session.data(from: listing.manifestURL)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            throw ModerationError.manifestInvalid("status \(statusCode)")
        }
        let manifest: AuthorityManifest
        do {
            manifest = try decoder.decode(AuthorityManifest.self, from: data)
        } catch {
            throw ModerationError.manifestInvalid("malformed manifest: \(error)")
        }
        guard manifest.componentId == listing.componentId else {
            throw ModerationError.manifestInvalid("componentId does not match the directory listing")
        }
        try verifySignature(of: manifest, rawBytes: data, listing: listing)
        return SignedManifest(manifest: manifest, rawBytes: data)
    }

    /// The manifest's `signature` field covers the manifest content;
    /// with no canonical JSON in the draft spec we verify over the
    /// fetched bytes with the signature field's value excised — the
    /// same exact-bytes posture as `SignedAsset`, adapted for an
    /// embedded (not detached) signature. PROVISIONAL like every
    /// signing form here; soft mode accepts and logs until real
    /// authorities sign (see `ModerationTrust`).
    private func verifySignature(
        of manifest: AuthorityManifest,
        rawBytes: Data,
        listing: AuthorityListing
    ) throws {
        let verified: Bool
        if
            let keyRaw = Data(base64Encoded: listing.operatorPublicKeyBase64),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyRaw),
            let signature = Data(base64Encoded: manifest.signature),
            let signedBytes = Self.bytesExcludingSignature(from: rawBytes, signature: manifest.signature)
        {
            verified = Ed25519DetachedSignatureVerifier(publicKey: key)
                .isValid(signature: signature, for: signedBytes)
        } else {
            verified = false
        }
        guard !verified else { return }
        if enforceSignature {
            Self.log.error("\(listing.componentId, privacy: .public): manifest signature did NOT verify; rejecting (enforcement ON)")
            throw ModerationError.manifestInvalid("manifest signature did not verify")
        }
        Self.log.warning("\(listing.componentId, privacy: .public): manifest signature did NOT verify; accepting anyway (enforcement OFF)")
    }

    /// Excise the signature value from the raw JSON text so the signed
    /// content is byte-stable regardless of where the signature field
    /// sits. Returns nil when the raw bytes aren't UTF-8 or don't
    /// contain the signature value.
    static func bytesExcludingSignature(from rawBytes: Data, signature: String) -> Data? {
        guard let text = String(data: rawBytes, encoding: .utf8), text.contains(signature) else {
            return nil
        }
        return Data(text.replacingOccurrences(of: signature, with: "").utf8)
    }
}
