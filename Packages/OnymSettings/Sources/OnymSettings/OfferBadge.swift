import SwiftUI
import OnymDesign
import OnymFoundation

/// Small capsule summarizing one offer's pricing model — "FREE" in
/// green, the model name ("SUBSCRIPTION", …) in gray for paid tiers.
/// Used on catalog rows and the consent surface's offers list.
struct OfferBadge: View {
    let offer: ServiceOffer

    var body: some View {
        Chip(
            text: Self.modelDisplayName(offer.model).uppercased(),
            fg: offer.isFree ? OnymTokens.green : OnymTile.gray,
            bg: (offer.isFree ? OnymTokens.green : OnymTile.gray).opacity(0.15)
        )
    }

    /// Localized display name for a wire pricing-model token. Known
    /// models get a real localization; an unknown future token falls
    /// back to the capitalized wire value — displayed, never dropped.
    static func modelDisplayName(_ model: String) -> String {
        switch model {
        case "free": return String(localized: "Free")
        case "subscription": return String(localized: "Subscription")
        case "consumable": return String(localized: "Consumable")
        default: return model.capitalized
        }
    }
}

/// Detail screen for one offer out of a service manifest: identifier,
/// pricing model, billing period, and the seat-specific `service`
/// object rendered opaquely. Free offers are selectable from the
/// consent surface; paid offers render disabled until purchasing
/// exists (`EntitlementProviding` gates them — the free-tier stub
/// grants only free models).
struct OfferDetailView: View {
    let offer: ServiceOffer
    let isEntitled: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LargeTitle(verbatim: offer.offerId)

                SectionLabel("OFFER")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("Offer ID", offer.offerId)
                        detailRow("Model", OfferBadge.modelDisplayName(offer.model))
                        if let period = offer.period {
                            detailRow("Period", period)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }

                if let service = serviceSummary {
                    SectionLabel("SERVICE TERMS")
                    Card {
                        Text(verbatim: service)
                            .font(OnymType.mono(size: 12))
                            .foregroundStyle(OnymTokens.text2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    Footnote("Published by the operator as part of the signed manifest. This app doesn't interpret it — it's shown exactly as offered.")
                }

                if !isEntitled {
                    Footnote("Purchasing is not yet available in this app. Paid offers become selectable once in-app purchases land.")
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Offer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(OnymType.font(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(verbatim: value)
                .font(OnymType.mono(size: 13))
                .foregroundStyle(OnymTokens.text2)
        }
    }

    /// Pretty-printed `service` object, when the offer carries one.
    private var serviceSummary: String? {
        guard let data = offer.serviceData,
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }
}
