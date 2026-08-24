import SwiftUI
import OnymDesign
import OnymDiscovery
import OnymFoundation
import OnymModerationUI

/// The generalized consent surface for a catalog-listed service
/// (transport / notary / blob storage): who listed it and under what
/// relationship, the operator key fingerprint, the offers, the linked
/// terms when the operator published any, and the exact manifest hash
/// the acceptance pins. One explicit accept button.
///
/// Public since the onboarding wiring: the first-launch transport /
/// blob / notary steps present the same consent sheet the Settings
/// pickers do, so catalog picks consent identically in both places.
public struct ModuleConsentView: View {
    @State private var flow: ModuleConsentFlow
    @Environment(\.dismiss) private var dismiss

    public init(flow: ModuleConsentFlow) {
        _flow = State(initialValue: flow)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch flow.step {
                    case .loading:
                        loading
                    case .reviewing, .applying:
                        review
                    case .done:
                        done
                    case .failed:
                        failed
                    }
                }
                .padding(.bottom, 32)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle("Review Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(flow.step == .done ? "Done" : "Cancel") { dismiss() }
                        .accessibilityIdentifier("settings.module_consent.dismiss")
                }
            }
            .task { flow.start() }
        }
    }

    // MARK: - Loading

    @ViewBuilder
    private var loading: some View {
        if let error = flow.errorMessage {
            Card {
                VStack(spacing: 10) {
                    Text(verbatim: error)
                        .font(OnymType.font(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                    Button("Retry") { flow.tappedRetry() }
                        .accessibilityIdentifier("settings.module_consent.retry")
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            }
            .padding(.top, 24)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Fetching and verifying the service's manifest…")
                    .font(OnymType.font(size: 14))
                    .foregroundStyle(OnymTokens.text2)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 120)
        }
    }

    // MARK: - Failed (terminal)

    /// Terminal failure: this entry can never be consented through
    /// this surface (moderation seat, no manifest URL, or a
    /// digest-pinned manifest failing an entry cross-check). No Retry
    /// — retrying could never succeed, so offering the button would be
    /// a lie. Cancel in the toolbar remains the way out.
    private var failed: some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: "xmark.octagon")
                    .font(OnymType.font(size: 28))
                    .foregroundStyle(OnymTokens.text3)
                Text(verbatim: flow.errorMessage ?? String(localized: "This entry can't be added."))
                    .font(OnymType.font(size: 14))
                    .foregroundStyle(OnymTokens.text2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .padding(.top, 24)
        .accessibilityIdentifier("settings.module_consent.failed")
    }

    // MARK: - Review

    @ViewBuilder
    private var review: some View {
        if let reviewed = flow.reviewed {
            let manifest = reviewed.signedManifest

            LargeTitle(verbatim: flow.displayName)

            attributionBanner

            // §4.2 disclosed warning/review status, repeated ON the
            // consent surface — the disclosure must be strongest at
            // the accept step, not only on the picker row.
            if let status = flow.entry.entry.status {
                statusBanner(status)
            }

            SectionLabel("SERVICE")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    termRow("Seat", manifest.seat)
                    termRow("Component", manifest.componentId)
                    termRow("Operator key fingerprint", flow.operatorKeyFingerprint ?? "—")
                    if let validUntil = manifest.validUntil {
                        termRow("Valid until", validUntil.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }

            if !manifest.offers.isEmpty {
                offersSection(manifest)
            }

            if let termsURL = flow.termsURL {
                SectionLabel("TERMS")
                Card {
                    NavigationLink {
                        MarkdownDocumentView(title: String(localized: "Terms"), url: termsURL)
                    } label: {
                        Row(
                            title: "Linked terms",
                            subtitle: termsURL.absoluteString,
                            subtitleMono: true,
                            last: true
                        ) {
                            IconTile(symbol: "doc.text", bg: OnymTile.gray)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.module_consent.terms")
                }
            }

            SectionLabel("WHAT YOU'RE ACCEPTING")
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Manifest hash")
                        .font(OnymType.font(size: 13, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                    Text(verbatim: manifest.manifestHash)
                        .font(OnymType.mono(size: 11))
                        .foregroundStyle(OnymTokens.text2)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Footnote("Your acceptance pins this hash of these exact bytes and adds the service's endpoint to your configuration. Nothing is signed and nothing leaves this device — you can remove the endpoint at any time.")

            if let error = flow.errorMessage {
                Footnote(verbatim: error)
            }

            VStack(spacing: 10) {
                PrimaryButton(action: { flow.tappedAccept() }) {
                    if flow.step == .applying {
                        ProgressView().tint(OnymTokens.onAccent)
                    } else {
                        Text("Accept and Add")
                    }
                }
                .disabled(flow.step == .applying || !flow.canAccept)
                .accessibilityIdentifier("settings.module_consent.accept")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if !flow.canAccept, !manifest.offers.isEmpty {
                // Paid-only manifest (no entitled offer to select):
                // Accept stays disabled, and the screen says why
                // instead of leaving a dead button.
                Footnote("None of this service's offers can be selected yet — purchasing is not yet available in this app, so this service can't be added.")
            }
        }
    }

    /// The §4.2 status disclosure on the accept surface: the chip, an
    /// explanation, and the provider's published details link when the
    /// status carries a `uri`.
    private func statusBanner(_ status: EntryStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Chip(
                    text: (status.state == "warning"
                        ? String(localized: "WARNING")
                        : String(localized: "UNDER REVIEW")).uppercased(),
                    fg: OnymTile.amber,
                    bg: OnymTile.amber.opacity(0.15)
                )
                Text(status.state == "warning"
                     ? "The listing provider has attached a warning to this service."
                     : "The listing provider has this service under review.")
                    .font(OnymType.font(size: 13))
                    .foregroundStyle(OnymTokens.text)
            }
            if let uri = status.uri, let url = URL(string: uri) {
                Link(destination: url) {
                    Text(verbatim: uri)
                        .font(OnymType.mono(size: 12))
                        .foregroundStyle(OnymAccent.blue.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityIdentifier("settings.module_consent.status.uri")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OnymTile.amber.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: OnymRadius.inset, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityIdentifier("settings.module_consent.status")
    }

    /// Who listed this entry, and their declared relationship to it —
    /// text, not color, so the disclosure survives every rendering.
    private var attributionBanner: some View {
        Text(verbatim: attributionText)
            .font(OnymType.font(size: 13))
            .foregroundStyle(OnymTokens.text2)
            .lineSpacing(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: OnymRadius.inset, style: .continuous))
            .padding(.horizontal, 16)
            .accessibilityIdentifier("settings.module_consent.attribution")
    }

    private var attributionText: String {
        let source = flow.entry.source
        var text = String(localized: "Listed by \(source.sourceLabel) — \(Self.disclosureText(source.relationship))")
        if source.placement.lowercased() != "organic" {
            text += String(localized: " · placement: \(Self.disclosureText(source.placement))")
        }
        return text
    }

    /// Wire values like `common-owner` read as "common owner". Unknown
    /// future values pass through verbatim (minus hyphens) — the
    /// disclosure must never be dropped for being unrecognized.
    static func disclosureText(_ wireValue: String) -> String {
        wireValue.replacingOccurrences(of: "-", with: " ")
    }

    // MARK: - Offers

    @ViewBuilder
    private func offersSection(_ manifest: SignedServiceManifest) -> some View {
        SectionLabel("OFFERS")
        Card {
            ForEach(Array(manifest.offers.enumerated()), id: \.element.offerId) { idx, offer in
                offerRow(
                    offer,
                    isEntitled: flow.entitledOfferIds.contains(offer.offerId),
                    last: idx == manifest.offers.count - 1
                )
            }
        }
        if manifest.offers.contains(where: { !flow.entitledOfferIds.contains($0.offerId) }) {
            Footnote("Paid offers can't be selected yet — purchasing is not yet available in this app.")
        }
    }

    private func offerRow(_ offer: ServiceOffer, isEntitled: Bool, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    guard isEntitled else { return }
                    flow.selectedOfferId = offer.offerId
                } label: {
                    Image(systemName: flow.selectedOfferId == offer.offerId
                          ? "checkmark.circle.fill" : "circle")
                        .font(OnymType.font(size: 20))
                        .foregroundStyle(isEntitled
                                         ? (flow.selectedOfferId == offer.offerId
                                            ? OnymTokens.green : OnymTokens.text3)
                                         : OnymTokens.text3.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!isEntitled)
                .accessibilityIdentifier("settings.module_consent.offer.select.\(offer.offerId)")

                NavigationLink {
                    OfferDetailView(offer: offer, isEntitled: isEntitled)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: offer.offerId)
                                .font(OnymType.mono(size: 14, weight: .semibold))
                                .foregroundStyle(isEntitled ? OnymTokens.text : OnymTokens.text3)
                            if let period = offer.period {
                                Text(verbatim: period)
                                    .font(OnymType.font(size: 12))
                                    .foregroundStyle(OnymTokens.text3)
                            }
                        }
                        Spacer(minLength: 4)
                        OfferBadge(offer: offer)
                        Image(systemName: "chevron.right")
                            .font(OnymType.font(size: 12, weight: .semibold))
                            .foregroundStyle(OnymTokens.text3)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.module_consent.offer.\(offer.offerId)")

            if !last { SettingsRowDivider(inset: 48) }
        }
    }

    private func termRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(OnymType.font(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(verbatim: value)
                .font(OnymType.mono(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .textSelection(.enabled)
        }
    }

    // MARK: - Done

    private var done: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(OnymType.font(size: 44))
                .foregroundStyle(OnymTokens.green)
            Text("Service added")
                .font(OnymType.font(size: 17, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text("Its endpoint is now in your configured list.")
                .font(OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .accessibilityIdentifier("settings.module_consent.done")
    }
}
