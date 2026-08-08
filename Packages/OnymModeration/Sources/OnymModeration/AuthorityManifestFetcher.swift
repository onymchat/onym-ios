import Foundation
import CryptoKit
import os.log
import OnymFoundation

/// Fetches an authority's manifest as **exact bytes**, hashes them
/// (that hash is what the mandate pins), decodes, requires the declared
/// `operator` to be the directory-pinned key, and verifies the
/// authority's detached signature over those exact bytes.
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
        let pinnedKey = try Self.directoryPinnedOperatorKey(for: manifest, listing: listing)
        try await verifySignature(rawBytes: data, pinnedKey: pinnedKey, listing: listing)
        return SignedManifest(manifest: manifest, rawBytes: data)
    }

    /// The manifest's declared `operator` must be the directory-pinned
    /// key, byte for byte — otherwise a manifest could name its own
    /// verdict-signing key and the directory pin would guard nothing.
    /// Both sides go through the single `AuthorityKey` parser, which also
    /// validates the `onym:key:` form.
    static func directoryPinnedOperatorKey(
        for manifest: AuthorityManifest,
        listing: AuthorityListing
    ) throws -> Curve25519.Signing.PublicKey {
        let declared: Data
        do {
            declared = try AuthorityKey.rawBytes(fromReference: manifest.operatorKey)
        } catch {
            throw ModerationError.manifestInvalid("operator is not a valid \(AuthorityKey.referencePrefix) reference")
        }
        let pinnedKey: Curve25519.Signing.PublicKey
        do {
            pinnedKey = try AuthorityKey.publicKey(fromBase64: listing.operatorPublicKeyBase64)
        } catch {
            throw ModerationError.manifestInvalid("directory listing carries no usable operator key")
        }
        guard declared == pinnedKey.rawRepresentation else {
            throw ModerationError.manifestInvalid("operator does not match the directory-pinned key")
        }
        return pinnedKey
    }

    /// The authority signs the manifest's **exact bytes** with a
    /// detached signature published alongside it at `<manifest-url>.sig`
    /// — the same posture as `SignedAsset` elsewhere in the app. No
    /// embedded signature, so nothing has to be excised from (or
    /// re-encoded out of) the signed bytes. Soft mode accepts and logs
    /// until real authorities sign (see `ModerationTrust`).
    private func verifySignature(
        rawBytes: Data,
        pinnedKey: Curve25519.Signing.PublicKey,
        listing: AuthorityListing
    ) async throws {
        do {
            try await SignedAsset.verify(
                assetData: rawBytes,
                assetURL: listing.manifestURL,
                session: session,
                label: "manifest \(listing.componentId)",
                verifier: Ed25519DetachedSignatureVerifier(publicKey: pinnedKey),
                enforce: enforceSignature
            )
        } catch {
            // `SignedAsset.verify` throws only under enforcement; soft
            // mode logs there and returns.
            Self.log.error("\(listing.componentId, privacy: .public): manifest signature did NOT verify; rejecting (enforcement ON)")
            throw ModerationError.manifestInvalid("manifest signature did not verify: \(error)")
        }
    }
}
