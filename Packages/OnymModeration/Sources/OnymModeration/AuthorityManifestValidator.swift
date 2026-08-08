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
    ///     appellate §5.2 constraint 2 requires — it must be a
    ///     `onym:component:` reference naming someone *other than* the
    ///     issuer, since the rule exists so no permanent sanction
    ///     depends on its issuer staying alive; or
    ///   - `newHolderAppeal` is absent. Device marks survive resale, so
    ///     §5.7 makes the new-holder path mandatory and the ban UX is
    ///     required to display it — a manifest without one cannot
    ///     deliver the remedy the user is consenting to.
    public func validateForConsent(_ signed: SignedManifest, now: Date) throws {
        let manifest = signed.manifest
        guard manifest.validUntil > now else {
            throw ModerationError.manifestInvalid("manifest validUntil \(manifest.validUntil) has passed")
        }
        guard supportedProfileIds.contains(manifest.moderationProfileId) else {
            throw ModerationError.unsupportedProfile(manifest.moderationProfileId)
        }
        guard let newHolderAppeal = manifest.newHolderAppeal, !newHolderAppeal.isEmpty else {
            throw ModerationError.manifestInvalid(
                "manifest declares no newHolderAppeal path (mandatory — device marks outlive the device's owner)"
            )
        }
        let permanentClasses = manifest.violationClasses
            .filter { $0.banTerm == .permanent }
            .map(\.classId)
        if !permanentClasses.isEmpty {
            try Self.requireExternalAppellate(of: manifest, forClasses: permanentClasses)
        }
    }

    /// §5.2 constraint 2 in full: the appellate must be a component
    /// reference, and a component *other than the issuer*. Accepting any
    /// non-`"self"` string let a manifest name its own `componentId`
    /// (or a non-component value) and still declare permanent bans.
    private static func requireExternalAppellate(
        of manifest: AuthorityManifest,
        forClasses permanentClasses: [String]
    ) throws {
        let classes = permanentClasses.joined(separator: ", ")
        guard let appellate = manifest.appellate, !appellate.isEmpty, appellate != "self" else {
            throw ModerationError.manifestInvalid(
                "permanent ban term (\(classes)) requires an external appellate"
            )
        }
        guard appellate.hasPrefix(Self.componentReferencePrefix) else {
            throw ModerationError.manifestInvalid(
                "permanent ban term (\(classes)) requires the appellate to be a \(Self.componentReferencePrefix) reference"
            )
        }
        guard appellate != manifest.componentId else {
            throw ModerationError.manifestInvalid(
                "permanent ban term (\(classes)) names the issuer as its own appellate"
            )
        }
    }

    static let componentReferencePrefix = "onym:component:"
}
