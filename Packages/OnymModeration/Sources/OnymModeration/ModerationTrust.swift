import Foundation

/// Soft/enforce switches for moderation signature checks, mirroring
/// `ContractsTrust` in OnymFoundation: **no real authority publishes
/// signed manifests or verdicts yet**, so enforcement defaults off and
/// a missing/invalid signature is logged and accepted. Flipping either
/// switch on requires real authorities with published operator keys —
/// under enforcement an unverifiable object is rejected outright.
public enum ModerationTrust {
    /// Reject authority manifests whose `signature` doesn't verify
    /// against the directory-pinned operator key. **Leave `false`**
    /// until real authorities publish signed manifests.
    public static let enforceManifestSignatures = false

    /// Reject verdicts whose `signature` doesn't verify against the
    /// consented manifest's operator key. **Leave `false`** until real
    /// authorities issue signed verdicts (the stub backend's fixture
    /// verdicts carry sentinel signatures).
    public static let enforceVerdictSignatures = false
}
