import Foundation

/// A user's consent to one service manifest, plus everything needed to
/// honor it offline: the consented manifest snapshot (exact bytes —
/// re-verifiable, still renderable if the operator disappears).
/// Mirrors `MandateRecord` in OnymModeration minus the seat-specific
/// signing/countersigning — this is the generic shape every
/// non-moderation seat (courier, notary, blob host, …) shares.
public struct PinnedConsentRecord: Codable, Sendable, Equatable {
    /// `onym:component:<id>` of the consented service.
    public let componentId: String
    /// The seat that service fills, from its manifest.
    public let seatType: String
    /// `sha256:<hex>` over `manifestBytes`.
    public let manifestHash: String
    /// The exact manifest bytes `manifestHash` was computed over.
    /// Never re-fetched, never re-encoded.
    public let manifestBytes: Data
    /// Where the manifest came from at consent time (a discovery
    /// source's label, "Manual", …). Display provenance only.
    public let sourceLabel: String?
    /// The offer the user selected, when the consent flow chose one.
    public let offerId: String?
    public let acceptedAt: Date
    /// Exactly one record is active per componentId. Re-consenting
    /// deactivates the old record without touching anything else —
    /// history is kept, consent artifacts are immutable.
    public var isActive: Bool

    /// The only way to build a record is from a token the reviewer
    /// minted — the no-refetch invariant holds at the type level: the
    /// bytes pinned here are the bytes that were verified and shown.
    public init(
        reviewed: ReviewedServiceManifest,
        sourceLabel: String? = nil,
        offerId: String? = nil,
        acceptedAt: Date,
        isActive: Bool = true
    ) {
        let manifest = reviewed.signedManifest
        self.componentId = manifest.componentId
        self.seatType = manifest.seat
        self.manifestHash = manifest.manifestHash
        self.manifestBytes = manifest.rawBytes
        self.sourceLabel = sourceLabel
        self.offerId = offerId
        self.acceptedAt = acceptedAt
        self.isActive = isActive
    }

    /// The consented manifest, decoded from the stored snapshot. A
    /// manifest that was accepted at consent time keeps decoding from
    /// the pinned bytes; `nil` only for a corrupted store.
    public func consentedManifest() -> SignedServiceManifest? {
        try? SignedServiceManifest(raw: manifestBytes)
    }

    /// The pinned manifest's `validUntil`, derived from the stored
    /// bytes; `nil` when the operator published no expiry (or the
    /// snapshot no longer decodes).
    public var validUntil: Date? {
        consentedManifest()?.validUntil
    }

    /// Whether the pinned manifest's `validUntil` has passed. **Pin
    /// freshness is deliberately not enforced anywhere**: expiry is
    /// checked once at review time, and an expired pin stays the
    /// active consent record — consent to an operator does not lapse
    /// just because the operator's published manifest aged out. This
    /// exists so callers *can* ask (to badge a stale pin, prompt a
    /// re-fetch, or gate a paid flow); a manifest with no `validUntil`
    /// never expires.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let validUntil else { return false }
        return validUntil < now
    }
}
