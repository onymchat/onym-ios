import Foundation

/// Soft/enforce switches for moderation signature checks, mirroring
/// `ContractsTrust` in OnymFoundation. Under enforcement an
/// unverifiable object is rejected outright. (UI-test builds are
/// unaffected: their fixture fetchers and stub backend don't route
/// through these checks.)
public enum ModerationTrust {
    /// Reject authority manifests whose `signature` doesn't verify
    /// against the directory-pinned operator key.
    ///
    /// **Still `false` for one deployment reason only**: the client
    /// verifies the detached signature served at `<manifest-url>.sig`,
    /// and the deployed authority answers 404 there (verified
    /// 2026-08-09 against authority.onym.app). Flipping this on before
    /// that asset exists would hard-fail every consent. Publish the
    /// `.sig` (operator signature over the exact manifest bytes), then
    /// flip.
    public static let enforceManifestSignatures = false

    /// Reject verdicts whose `signature` doesn't verify against the
    /// consented manifest's operator key. ON: the deployed authority
    /// signs verdicts with the directory-pinned operator key, and the
    /// gate check runs every served ban verdict through
    /// `VerdictValidator` before display. Honesty note: while
    /// `enforceManifestSignatures` is off, the operator key used here
    /// comes from a manifest that was itself accepted unverified at
    /// consent time — this switch cannot be stronger than that one.
    /// Publishing the `.sig` closes the chain.
    public static let enforceVerdictSignatures = true
}
