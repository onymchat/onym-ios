import Foundation

/// Soft/enforce switches for moderation signature checks, mirroring
/// `ContractsTrust` in OnymFoundation. Under enforcement an
/// unverifiable object is rejected outright. (UI-test builds are
/// unaffected: their fixture fetchers and stub backend don't route
/// through these checks.)
public enum ModerationTrust {
    /// Reject authority manifests whose `signature` doesn't verify
    /// against the directory-pinned operator key. ON: every deploy
    /// signs the exact materialized manifest bytes inside the
    /// authority image and publishes the detached signature at
    /// `<manifest-url>.sig` (onym-infra#5), moved into place so the
    /// published signature either matches the published manifest or
    /// is absent — and the deploy's verify step proves the served
    /// pair before finishing. The wire contract (base64 of the
    /// 64-byte raw signature + trailing LF; `SignedAsset` trims
    /// before decoding) is pinned in onym-infra's README.
    ///
    /// Under enforcement a missing or stale signature rejects the
    /// manifest and blocks consent outright — this flip must ship
    /// only after the signed deploy is live (curl the `.sig` first).
    public static let enforceManifestSignatures = true

    /// Reject verdicts whose `signature` doesn't verify against the
    /// consented manifest's operator key. ON: the deployed authority
    /// signs verdicts with the directory-pinned operator key, and the
    /// gate check runs every served ban verdict through
    /// `VerdictValidator` before display.
    ///
    /// Precise trust bound while `enforceManifestSignatures` is off:
    /// the verdict-signing key itself IS directory-pinned regardless —
    /// the fetcher requires the manifest's declared operator to equal
    /// the directory key byte-for-byte — so a substituted manifest
    /// cannot swap the key verdicts verify against. What the missing
    /// `.sig` leaves unverified is the REST of the manifest: the ban
    /// terms and windows `VerdictValidator` derives its dates from.
    /// Publishing the `.sig` (onym-infra#4) closes that.
    public static let enforceVerdictSignatures = true
}
