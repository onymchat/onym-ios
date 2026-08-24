import SwiftUI
import OnymDesign
import OnymModeration

/// The consent surface (Moderation.md §8 interface obligation 1):
/// full-screen, every violation class with all five terms, the
/// appellate and new-holder paths, the manifest hash being pinned,
/// and one explicit agree button. Nothing collapsed by default,
/// nothing buried in unrelated terms.
public struct ModerationConsentView: View {
    @State private var flow: ModerationConsentFlow
    @Environment(\.dismiss) private var dismiss

    public init(flow: ModerationConsentFlow) {
        _flow = State(initialValue: flow)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                ModerationConsentContent(flow: flow)
                    .padding(.bottom, 32)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Switching is a normal, abandonable settings task, and
                // the `.done` step has no other way out — `onConsented`
                // belongs to the app factory and can't dismiss us.
                // Onboarding and re-consent deliberately have no escape:
                // consent is the gate.
                if flow.isDismissable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(dismissLabel) { dismiss() }
                            .accessibilityIdentifier("moderation.consent.dismiss")
                    }
                }
            }
            .task { flow.start() }
            .onDisappear { flow.stop() }
        }
        .interactiveDismissDisabled(!flow.isDismissable)
    }

    private var navigationTitle: LocalizedStringKey {
        switch flow.mode {
        case .onboarding: return "Moderation"
        case .switching: return "Switch Authority"
        case .reconsent(.termsChanged): return "Terms Updated"
        case .reconsent(.authorityDelisted): return "Authority Unavailable"
        }
    }

    /// "Cancel" while the task can still be abandoned; "Done" once the
    /// mandate exists, whichever terms it ended up binding.
    private var dismissLabel: LocalizedStringKey {
        switch flow.state.step {
        case .done: return "Done"
        default: return "Cancel"
        }
    }

}

/// The consent surface's step bodies (directory pick → manifest review
/// → sign → done), extracted from `ModerationConsentView` so the
/// first-launch onboarding moderation step can embed the exact same
/// surface — same copy, same accessibility identifiers, same flow —
/// inside its own scaffold instead of a second implementation.
/// `ModerationConsentView` remains the standalone presentation
/// (NavigationStack + dismissal rules) over this content.
///
/// The embedder owns the flow's lifecycle: call `flow.start()` /
/// `flow.stop()` around this view's appearance the way
/// `ModerationConsentView` does.
public struct ModerationConsentContent: View {
    private let flow: ModerationConsentFlow

    public init(flow: ModerationConsentFlow) {
        self.flow = flow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch flow.state.step {
            case .loadingDirectory:
                loading
            case .pickingAuthority:
                picker
            case .reviewingManifest, .signing:
                review
            case .done:
                done
            }
        }
    }

    // MARK: - Steps

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading moderation authorities…")
                .font(OnymType.font(size: 14))
                .foregroundStyle(OnymTokens.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    @ViewBuilder
    private var picker: some View {
        SettingsLargeTitle(pickerTitle)
        Text(pickerBlurb)
            .font(OnymType.font(size: 14))
            .foregroundStyle(OnymTokens.text2)
            .lineSpacing(3)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

        supersededHashes

        switch flow.state.fetchStatus {
        case .failed(let message):
            SettingsCard {
                VStack(spacing: 10) {
                    Text(message)
                        .font(OnymType.font(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                    Button("Retry") { flow.tappedRetry() }
                        .accessibilityIdentifier("moderation.consent.retry")
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            }
        case .fetching, .idle:
            SettingsCard {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(16)
            }
        case .success where flow.state.authorities.isEmpty:
            SettingsCard {
                Text("No authorities are published yet.")
                    .font(OnymType.font(size: 14))
                    .foregroundStyle(OnymTokens.text3)
                    .frame(maxWidth: .infinity)
                    .padding(16)
            }
        case .success:
            SettingsCard {
                ForEach(Array(flow.state.authorities.enumerated()), id: \.element.componentId) { idx, listing in
                    Button { flow.selectedAuthority(listing) } label: {
                        SettingsRow(
                            titleText: listing.name,
                            subtitle: rowSubtitle(for: listing),
                            // The re-consent marker is prepended to the
                            // component id, which already fills the
                            // single default line on its own.
                            subtitleLineLimit: 2,
                            last: idx == flow.state.authorities.count - 1
                        ) {
                            SettingsIconTile(symbol: "checkmark.shield", bg: SettingsTile.indigo)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("moderation.consent.authority.\(listing.componentId)")
                }
            }
        }

        if let error = flow.state.errorMessage {
            SettingsFootnote(verbatim: error)
        }
    }

    /// The two documents the "terms have changed" claim is about. Only
    /// on the re-consent surface, and only once both are known — on
    /// every other path there is no prior hash to contrast.
    @ViewBuilder
    private var supersededHashes: some View {
        if case .reconsent(.termsChanged) = flow.mode,
           let pinned = flow.state.pinnedManifestHash,
           let published = flow.state.publishedManifestHash {
            SettingsSectionLabel("WHAT CHANGED")
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    hashRow("Terms you signed", pinned)
                    hashRow("Published now", published)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func hashRow(_ label: LocalizedStringKey, _ hash: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(OnymType.font(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(hash)
                .font(OnymType.mono(size: 11))
                .foregroundStyle(OnymTokens.text2)
                .textSelection(.enabled)
        }
    }

    private var pickerTitle: LocalizedStringKey {
        switch flow.mode {
        case .onboarding, .switching:
            return "Choose a moderation authority"
        case .reconsent(.termsChanged):
            return "These terms have changed"
        case .reconsent(.authorityDelisted):
            return "Your authority is no longer listed"
        }
    }

    /// The re-consent copy has one job beyond explaining itself: not to
    /// frighten. Nothing the user signed has been altered and no case
    /// has been re-termed — the mandate they hold is still honoured on
    /// its own terms. What has run out is its currency, and only fresh
    /// consent renews that.
    private var pickerBlurb: LocalizedStringKey {
        switch flow.mode {
        case .onboarding, .switching:
            return "Onym requires a moderation authority to handle reports of prohibited content. You choose who that is. Its entire power over you is written in the terms you'll review next — nothing can be added to them later without your fresh consent."
        case .reconsent(.termsChanged):
            return "Your authority now publishes terms that differ from the ones you signed. The mandate you hold is untouched — anything already under way is still judged by the terms you agreed to, and no one can edit them. Onym won't keep running on consent that no longer matches what's published, so read the new terms and sign them, or move to another authority."
        case .reconsent(.authorityDelisted):
            return "The authority your mandate names is no longer a designated authority here. It remains bound by the mandate you signed — what has changed is that Onym no longer routes anything through it, so reports and cases can't reach it from this app. Choose an authority below to review its terms and sign a fresh mandate."
        }
    }

    /// Runtime data, so never a localization key — the marker is
    /// localized and the component id appended verbatim.
    private func rowSubtitle(for listing: AuthorityListing) -> String {
        guard case .reconsent = flow.mode,
              listing.componentId == flow.state.currentAuthorityId
        else { return listing.componentId }
        return String(localized: "Your current authority") + " · " + listing.componentId
    }

    @ViewBuilder
    private var review: some View {
        if let reviewing = flow.state.reviewingManifest?.signedManifest {
            SettingsLargeTitle(verbatim: flow.state.selectedListing?.name ?? String(localized: "Terms"))

            Text("These are the exact terms you're consenting to. A case can only ever reach you under a violation class listed here, with these windows and this appeal path.")
                .font(OnymType.font(size: 14))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(3)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            ForEach(reviewing.manifest.violationClasses, id: \.classId) { violationClass in
                classCard(violationClass)
            }

            proceduralCard(reviewing)

            SettingsSectionLabel("WHAT YOU'RE SIGNING")
            SettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Manifest hash")
                        .font(OnymType.font(size: 13, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                    Text(reviewing.manifestHash)
                        .font(OnymType.mono(size: 11))
                        .foregroundStyle(OnymTokens.text2)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            SettingsFootnote("Your consent binds to this hash of these exact terms. The authority cannot edit them under your mandate — changed terms bind only new consents.")

            if let error = flow.state.errorMessage {
                SettingsFootnote(verbatim: error)
            }

            VStack(spacing: 10) {
                SettingsPrimaryButton(action: { flow.tappedAgree() }) {
                    if flow.state.step == .signing {
                        ProgressView().tint(OnymTokens.onAccent)
                    } else {
                        Text("I agree and sign")
                    }
                }
                .disabled(flow.state.step == .signing)
                .accessibilityIdentifier("moderation.consent.agree")

                Button("Back") { flow.tappedBack() }
                    .font(OnymType.font(size: 14))
                    .foregroundStyle(OnymTokens.text2)
                    .disabled(flow.state.step == .signing)
                    .accessibilityIdentifier("moderation.consent.back")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
    }

    private var done: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(OnymType.font(size: 44))
                .foregroundStyle(OnymTokens.green)
            Text("Mandate signed")
                .font(OnymType.font(size: 17, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .accessibilityIdentifier("moderation.consent.done")
    }

    // MARK: - Cards

    /// One violation class with all five mandatory terms visible.
    private func classCard(_ violationClass: ViolationClass) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionLabel(verbatim: violationClass.classId.replacingOccurrences(of: "-", with: " ").uppercased())
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    termRow("Response window", violationClass.responseWindow.display)
                    termRow("Decision deadline", violationClass.decisionDeadline.display)
                    termRow("Ban term", banTermDisplay(violationClass.banTerm))
                    termRow("Appeal window", violationClass.appealWindow.display)
                    termRow("Appeal effect", violationClass.appealEffect == .suspensive
                            ? String(localized: "Suspensive — no ban until the appeal window passes unused")
                            : String(localized: "Non-suspensive — the ban executes at once; appeal can reverse it"))
                    if let lawful = violationClass.lawfulReporting {
                        termRow("Lawful reporting", lawful)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Definition")
                            .font(OnymType.font(size: 13, weight: .semibold))
                            .foregroundStyle(OnymTokens.text)
                        definitionLink(violationClass.definition)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    /// Appellate, new-holder path, and validity — the manifest-level
    /// terms shared by all classes.
    private func proceduralCard(_ reviewing: SignedManifest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionLabel("PROCEDURE")
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    if let appellate = reviewing.manifest.appellate {
                        termRow("Appeals heard by", appellate)
                    }
                    if let newHolder = reviewing.manifest.newHolderAppeal {
                        termRow("New device owner", newHolder)
                    }
                    termRow("Terms valid until", reviewing.manifest.validUntil.formatted(date: .abbreviated, time: .omitted))
                    termRow("Operated by", reviewing.manifest.operatorKey)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func termRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(OnymType.font(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(value)
                .font(OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.text2)
        }
    }

    /// Definitions are content-addressed; when the address is a URL,
    /// make it tappable so the exact wording is one tap away.
    @ViewBuilder
    private func definitionLink(_ address: String) -> some View {
        if let url = URL(string: address), url.scheme == "https" {
            Link(address, destination: url)
                .font(OnymType.mono(size: 12))
        } else {
            Text(address)
                .font(OnymType.mono(size: 12))
                .foregroundStyle(OnymTokens.text2)
                .textSelection(.enabled)
        }
    }

    private func banTermDisplay(_ term: BanTerm) -> String {
        switch term {
        case .permanent:
            return String(localized: "Permanent (appealable at the external appellate for as long as it is in force)")
        case .duration(let duration):
            return duration.display
        }
    }
}

extension ISO8601Duration {
    /// "3 days", "1 day" — the consent surface shows human terms, with
    /// the raw ISO string preserved in the manifest hash it pins.
    var display: String {
        days == 1 ? String(localized: "1 day") : String(localized: "\(days) days")
    }
}
