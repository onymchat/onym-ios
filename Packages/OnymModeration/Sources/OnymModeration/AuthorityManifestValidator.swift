import Foundation

/// The manifest's **consent-time validity conditions** (Moderation.md
/// §5.2), in one place. `AuthorityManifestFetcher` establishes
/// authenticity (directory-pinned operator key, detached signature);
/// this establishes that the terms are ones this client may consent to
/// at all.
///
/// These are validity conditions, not UI concerns: `ModerationRepository`
/// runs them before enrollment and mandate signing, so an invalid
/// manifest can never end up pinned by a signed mandate — and keeping
/// them here stops the rules from scattering across the consent path.
public struct AuthorityManifestValidator: Sendable {
    /// Moderation profiles this client implements. The spec fixes this
    /// string — Moderation.md §5.1 declares the profile's `profileId`
    /// and §5.2 carries it as the manifest's `moderationProfileId` — so
    /// a conforming manifest names exactly this. It lives in one place;
    /// a manifest declaring anything else is refused rather than
    /// half-honored.
    public static let defaultSupportedProfileIds: Set<String> = [
        "onym:moderation-profile:consent-bound-v1",
    ]

    private let supportedProfileIds: Set<String>

    public init(supportedProfileIds: Set<String> = AuthorityManifestValidator.defaultSupportedProfileIds) {
        self.supportedProfileIds = supportedProfileIds
    }

    /// - Throws: `ModerationError` when this manifest may not be
    ///   consented to now:
    ///   - `validUntil` has passed — it bounds *new* mandates and cases,
    ///     so an already-signed mandate keeps honoring its pinned terms;
    ///   - `moderationProfileId` is a profile this client doesn't
    ///     implement;
    ///   - a class declares a `permanent` ban term without the external
    ///     appellate §5.2 constraint 2 requires (`nil`, empty, or
    ///     `"self"` is not an external appellate).
    public func validateForConsent(_ signed: SignedManifest, now: Date) throws {
        let manifest = signed.manifest
        guard manifest.validUntil > now else {
            throw ModerationError.manifestInvalid("manifest validUntil \(manifest.validUntil) has passed")
        }
        guard supportedProfileIds.contains(manifest.moderationProfileId) else {
            throw ModerationError.unsupportedProfile(manifest.moderationProfileId)
        }
        let permanentClasses = manifest.violationClasses
            .filter { $0.banTerm == .permanent }
            .map(\.classId)
        if !permanentClasses.isEmpty {
            guard let appellate = manifest.appellate, !appellate.isEmpty, appellate != "self" else {
                throw ModerationError.manifestInvalid(
                    "permanent ban term (\(permanentClasses.joined(separator: ", "))) requires an external appellate"
                )
            }
        }
    }
}
