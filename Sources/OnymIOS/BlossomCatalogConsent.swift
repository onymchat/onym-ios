import Foundation
import OnymDiscovery
import OnymFoundation
import OnymTransportBlossom

/// Apply step of the blossom catalog picker's consent flow, extracted
/// from the `OnymIOSApp` composition root so the one piece with real
/// behavior — endpoint extraction + ORDERING — is unit-testable.
///
/// A consented pick becomes the ACTIVE (first) server: uploads and
/// downloads only ever target `currentEndpoints().first`, and the
/// first launch seeds Onym Official at the head, so a plain append
/// would leave the user's pick configured but inert. Making it active
/// is the evident intent of picking a blob-storage module (onboarding
/// step 4, or the Settings catalog row).
enum BlossomCatalogConsent {
    /// Throws `ModuleApplyError.noUsableEndpoint` when the manifest has
    /// no https endpoint — the consent flow surfaces it instead of
    /// showing "Service added" over a no-op.
    @MainActor
    static func apply(
        manifest: SignedServiceManifest,
        to repository: BlossomServersRepository
    ) async throws {
        let fields = SeatManifestFields(rawBytes: manifest.rawBytes)
        let url = try ModuleConsentAcceptance.requiredEndpointURL(
            in: fields.endpointURIs,
            scheme: "https"
        )
        // Not a published default — no "Default" badge; `addEndpoint`
        // marks the configuration user-interacted so a refresh never
        // auto-populates over the choice. `makeActive` puts the pick
        // at the head (the upload/download target); the seeded default
        // stays in the list right behind it.
        await repository.addEndpoint(
            BlossomServerEndpoint(
                name: displayName(fields, componentId: manifest.componentId),
                url: url,
                isDefault: false
            ),
            makeActive: true
        )
    }

    /// Manifest `name` when published and non-empty, else the component
    /// id minus its prefix — same rule as the seat adapters.
    @MainActor
    private static func displayName(_ fields: SeatManifestFields, componentId: String) -> String {
        if let name = fields.name, !name.isEmpty { return name }
        return ModuleConsentFlow.shortComponentId(componentId)
    }
}
