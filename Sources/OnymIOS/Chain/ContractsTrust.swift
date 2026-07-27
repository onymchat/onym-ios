import Foundation
import CryptoKit
import os.log

/// Trust configuration for the runtime-fetched, trust-critical JSON
/// assets — the Soroban `contracts-manifest.json` (whose `id` becomes
/// the governance authority via `ContractsRepository`) and the curated
/// relay / server lists that are auto-installed as defaults on a cold
/// install.
///
/// Each of those assets is downloaded over a plain GET (H-3). This type
/// adds client-side **Ed25519 detached-signature** verification: the
/// asset is signed offline with a private key that never touches the
/// app, and the app ships only the matching *public* key. A MITM /
/// compromised-CDN / trusted-proxy attacker who swaps the JSON can no
/// longer forge a matching signature.
///
/// ## Enforcement is GATED OFF by default
///
/// `enforceSignatures` defaults to `false` (soft mode) because **no
/// signed assets are published yet** — flipping it on before the
/// release-signing pipeline is live would brick prepopulation on every
/// install. In soft mode a missing/invalid signature is logged as a
/// warning and the asset is used anyway (preserving today's behaviour).
/// In enforce mode an unverified asset is rejected.
///
/// Turning enforcement on requires, in order:
///   1. The offline release-signing pipeline that produces `<asset>.sig`
///      files and attaches them to each GitHub release (tracked
///      separately — see PR / issue #183).
///   2. Replacing the placeholder public key in
///      `Resources/contracts-trust-pubkey.json` with the real
///      offline-signing public key.
///   3. Flipping `enforceSignatures` to `true`.
enum ContractsTrust {
    /// MASTER SWITCH. **Leave `false`** until the release-signing
    /// pipeline is live and real `.sig` assets ship (see the type doc).
    /// `true` makes the fetchers reject any asset without a valid
    /// detached signature made by `bundledPublicKey`.
    static let enforceSignatures = false

    /// The offline-signing public key bundled with the app, or `nil`
    /// when the placeholder has not yet been replaced (empty
    /// `publicKeyBase64`). A `nil` key fails **closed**: under
    /// `enforceSignatures == true` every asset is rejected, so the flag
    /// can never be flipped on without also shipping a real key.
    static let bundledPublicKey: Curve25519.Signing.PublicKey? = loadBundledPublicKey()

    private struct PublicKeyDocument: Decodable {
        let publicKeyBase64: String
    }

    private static func loadBundledPublicKey() -> Curve25519.Signing.PublicKey? {
        guard let url = Bundle.main.url(
            forResource: "contracts-trust-pubkey",
            withExtension: "json"
        ) else { return nil }
        guard
            let data = try? Data(contentsOf: url),
            let doc = try? JSONDecoder().decode(PublicKeyDocument.self, from: data),
            !doc.publicKeyBase64.isEmpty,
            let raw = Data(base64Encoded: doc.publicKeyBase64),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return nil }
        return key
    }
}

/// Reusable Ed25519 detached-signature verifier. Wraps a single
/// CryptoKit `Curve25519.Signing.PublicKey`; `isValid` returns `false`
/// (never throws) for a missing key, a malformed signature, or a genuine
/// mismatch so callers can apply their own soft/enforce policy.
struct Ed25519DetachedSignatureVerifier: Sendable {
    let publicKey: Curve25519.Signing.PublicKey?

    /// The app-wide verifier keyed on the bundled public key.
    static let bundled = Ed25519DetachedSignatureVerifier(publicKey: ContractsTrust.bundledPublicKey)

    /// Verify a detached `signature` over the exact `data` bytes.
    /// Returns `false` if no public key is configured.
    func isValid(signature: Data, for data: Data) -> Bool {
        guard let publicKey else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }
}

enum SignedAssetVerificationError: Error, Sendable {
    /// No detached signature could be fetched (network failure / non-2xx
    /// on the `<asset>.sig` URL). Only thrown under enforcement.
    case signatureUnavailable
    /// A signature was fetched but did not verify against the bundled
    /// public key (tampering, wrong key, or no key configured). Only
    /// thrown under enforcement.
    case signatureInvalid
}

/// Shared verification step wired into every trust-critical fetcher.
/// Fetches the detached signature that lives alongside the asset at
/// `<asset-url>.sig`, verifies it against the bundled public key, and
/// applies the soft/enforce policy from `ContractsTrust`.
enum SignedAsset {
    private static let log = Logger(subsystem: "app.onym.ios", category: "ContractsTrust")

    /// - Parameters:
    ///   - assetData: the exact bytes that were fetched and will be used.
    ///   - assetURL: the asset's URL; the signature is fetched from
    ///     `<assetURL>.sig`.
    ///   - session: the same `URLSession` the asset was fetched with
    ///     (so tests can stub the `.sig` request too).
    ///   - label: human-readable asset name for log lines.
    ///   - verifier: the Ed25519 verifier (defaults to the bundled key).
    ///   - enforce: policy switch (defaults to `ContractsTrust.enforceSignatures`).
    /// - Throws: `SignedAssetVerificationError` **only** when `enforce`
    ///   is `true` and the signature is missing or invalid. In soft mode
    ///   this never throws — it logs a warning and returns.
    static func verify(
        assetData: Data,
        assetURL: URL,
        session: URLSession,
        label: String,
        verifier: Ed25519DetachedSignatureVerifier = .bundled,
        enforce: Bool = ContractsTrust.enforceSignatures
    ) async throws {
        let signature: Data?
        do {
            signature = try await fetchSignature(for: assetURL, session: session)
        } catch {
            signature = nil
        }

        guard let signature else {
            if enforce {
                log.error("\(label, privacy: .public): no detached signature available; rejecting (enforcement ON)")
                throw SignedAssetVerificationError.signatureUnavailable
            }
            log.warning("\(label, privacy: .public): no detached signature available; accepting anyway (enforcement OFF, H-3 soft mode)")
            return
        }

        if verifier.isValid(signature: signature, for: assetData) {
            return
        }

        if enforce {
            log.error("\(label, privacy: .public): detached signature did NOT verify; rejecting (enforcement ON)")
            throw SignedAssetVerificationError.signatureInvalid
        }
        log.warning("\(label, privacy: .public): detached signature did NOT verify; accepting anyway (enforcement OFF, H-3 soft mode)")
    }

    /// Fetch and decode the raw signature bytes from `<assetURL>.sig`.
    /// Accepts either a 64-byte raw Ed25519 signature or its base64
    /// text encoding. Throws on network failure / non-2xx so the caller
    /// treats the signature as unavailable.
    private static func fetchSignature(for assetURL: URL, session: URLSession) async throws -> Data {
        let sigURL = URL(string: assetURL.absoluteString + ".sig") ?? assetURL.appendingPathExtension("sig")
        let (data, response) = try await session.data(from: sigURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw SignedAssetVerificationError.signatureUnavailable
        }
        return decodeSignature(data)
    }

    /// A raw 64-byte Ed25519 signature is used as-is; otherwise the body
    /// is treated as base64 (trimmed) and decoded. Falls back to the raw
    /// bytes so a malformed body simply fails verification rather than
    /// crashing.
    static func decodeSignature(_ data: Data) -> Data {
        if data.count == 64 { return data }
        if let text = String(data: data, encoding: .utf8),
           let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return decoded
        }
        return data
    }
}
