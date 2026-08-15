import Foundation
import OnymFoundation

/// Why a generic module consent could not be recorded.
public enum ModuleConsentError: Error, Equatable, Sendable {
    /// The moderation seat's consent is a *signed mandate*
    /// (OnymModeration's flow) — it must never be reduced to this
    /// generic local pin.
    case moderationSeatExcluded
}

/// Why a recorded consent could not be *applied* to the seat's legacy
/// configuration. Thrown by the seat-specific apply closures so the
/// flow can tell the user the truth: the consent pin exists, but the
/// service was not added.
public enum ModuleApplyError: Error, Equatable, Sendable {
    /// The consented manifest lists no endpoint with the scheme the
    /// seat requires (e.g. no https endpoint for a notary, no wss
    /// endpoint for a message relay).
    case noUsableEndpoint
}

/// The accept path of the generalized module consent flow, as a pure
/// helper so its ordering is unit-testable without any UI: pin the
/// reviewed manifest, then record the selection provenance that
/// references it.
public enum ModuleConsentAcceptance {
    /// The one seat type this generic consent must refuse.
    public static let excludedSeatType = "moderation"

    /// Record consent to a reviewed manifest picked from a discovery
    /// catalog.
    ///
    /// Ordering is deliberate: the consent pin is written **first**,
    /// the `ModuleSelection` second — the selection references the
    /// consented hash, so an interruption between the two leaves a
    /// consent without a selection (harmless history) rather than a
    /// selection whose consent was never pinned. Applying the derived
    /// endpoint to the seat's legacy configuration is the caller's
    /// final step, after both records exist.
    @discardableResult
    public static func accept(
        reviewed: ReviewedServiceManifest,
        source: SourceAttribution,
        offerId: String?,
        consentStore: any PinnedConsentStore,
        selectionStore: any SeatSelectionStore,
        acceptedAt: Date = Date()
    ) throws -> (record: PinnedConsentRecord, selection: ModuleSelection) {
        let manifest = reviewed.signedManifest
        guard manifest.seat != excludedSeatType else {
            throw ModuleConsentError.moderationSeatExcluded
        }
        let record = try consentStore.accept(
            reviewed,
            sourceLabel: source.sourceLabel,
            offerId: offerId,
            acceptedAt: acceptedAt
        )
        let selection = ModuleSelection(
            seatType: manifest.seat,
            componentId: manifest.componentId,
            providerId: source.providerId,
            manifestHash: manifest.manifestHash,
            offerId: offerId,
            selectedAt: acceptedAt
        )
        selectionStore.record(selection)
        return (record, selection)
    }

    /// The endpoint a seat's apply step writes into its legacy
    /// configuration: the first of `endpointURIs` (published order)
    /// whose URL scheme matches `scheme`, case-insensitively.
    ///
    /// Throws `ModuleApplyError.noUsableEndpoint` instead of returning
    /// nil so a manifest without a usable endpoint surfaces as an
    /// error the consent flow must show — never as a silent no-op
    /// behind a "Service added" screen.
    public static func requiredEndpointURL(
        in endpointURIs: [String],
        scheme: String
    ) throws -> URL {
        guard let url = endpointURIs
            .compactMap(URL.init(string:))
            .first(where: { $0.scheme?.lowercased() == scheme.lowercased() })
        else { throw ModuleApplyError.noUsableEndpoint }
        return url
    }
}
