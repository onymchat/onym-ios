import Foundation

/// Narrow seam over `IdentityRepository.currentIdentities()` used by
/// inbox-side interactors that need to look up an identity's
/// view-facing summary (BLS + inbox public keys, display alias)
/// without taking a dependency on the whole repository. Mirrors the
/// `InvitationEnvelopeDecrypting` pattern: tests substitute a canned
/// list, production conforms `IdentityRepository` directly.
protocol IdentitiesProviding: Sendable {
    func currentIdentities() async -> [IdentitySummary]
}
