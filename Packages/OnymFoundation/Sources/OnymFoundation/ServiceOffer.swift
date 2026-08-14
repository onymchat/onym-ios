import Foundation

/// One entry of a service manifest's `offers` array — the commercial
/// terms a seat operator publishes alongside its technical manifest.
///
/// Only the spine every seat shares is decoded (`offerId`, `model`,
/// optional `period`); everything under `service` is seat-specific
/// and kept opaque for the seat adapter (or a future StoreKit layer)
/// to interpret.
public struct ServiceOffer: Sendable, Equatable {
    /// Operator-scoped offer identifier.
    public let offerId: String
    /// Pricing model. "free", "subscription", and "consumable" are the
    /// models this app understands today; unknown values are preserved
    /// verbatim so a manifest can introduce one without breaking the
    /// decode — they simply gate as not-free.
    public let model: String
    /// Billing period for recurring models (e.g. "monthly"), when
    /// published.
    public let period: String?
    /// The offer's seat-specific `service` object, **re-encoded** as
    /// compact JSON — never hash or verify anything against this.
    /// `JSONSerialization` re-serialization controls neither key-sort
    /// semantics nor number form, so these bytes are not the bytes the
    /// operator published or signed; anything byte-sensitive must go
    /// back to the manifest's exact `rawBytes`. Opaque at this layer:
    /// a value-level carrier for whoever understands the seat's schema.
    public let serviceData: Data?

    /// Free offers are the only ones the stub entitlement layer can
    /// grant; StoreKit slots in behind `EntitlementProviding` later.
    public var isFree: Bool { model == "free" }

    public init(offerId: String, model: String, period: String? = nil, serviceData: Data? = nil) {
        self.offerId = offerId
        self.model = model
        self.period = period
        self.serviceData = serviceData
    }

    /// Lossy decode of a manifest's `offers` value: a malformed entry
    /// (not an object, missing `offerId`/`model`) is skipped rather
    /// than failing the whole manifest — offers are presentation
    /// metadata, not trust material.
    static func decodeLossy(_ value: Any?) -> [ServiceOffer] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { element in
            guard let object = element as? [String: Any],
                  let offerId = object["offerId"] as? String, !offerId.isEmpty,
                  let model = object["model"] as? String, !model.isEmpty
            else { return nil }
            var serviceData: Data?
            if let service = object["service"] as? [String: Any] {
                serviceData = try? JSONSerialization.data(
                    withJSONObject: service,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            }
            return ServiceOffer(
                offerId: offerId,
                model: model,
                period: object["period"] as? String,
                serviceData: serviceData
            )
        }
    }
}
