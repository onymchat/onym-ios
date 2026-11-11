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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Switching is a normal, abandonable settings task, and
                // the `.done` step has no other way out — `onConsented`
                // belongs to the app factory and can't dismiss us.
                // Onboarding and re-consent deliberately have no escape:
                // consent is the gate.
                if flow.isDismissable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: dismissSymbol)
                        }
                        .accessibilityLabel(Text(dismissLabel))
                        .accessibilityIdentifier("moderation.consent.dismiss")
                    }
                }
            }
            .task { flow.start() }
            .onDisappear { flow.stop() }
        }
        .interactiveDismissDisabled(!flow.isDismissable)
    }

    /// "Cancel" while the task can still be abandoned; "Done" once the
    /// mandate exists, whichever terms it ended up binding.
    private var dismissLabel: LocalizedStringKey {
        switch flow.state.step {
        case .done: return "Done"
        default: return "Cancel"
        }
    }

    private var dismissSymbol: String {
        switch flow.state.step {
        case .done: return "checkmark"
        default: return "xmark"
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
    /// False where the embedder already carries a title and a sentence
    /// of its own — the onboarding step's scaffold states "Reports &
    /// safety" and what an authority is before this view is reached,
    /// and repeating both here stacked two large titles and two
    /// paragraphs above the fold, leaving the authorities themselves
    /// entirely below it.
    private let showsPickerHeader: Bool
    /// The embedder signs with its own button (the onboarding step's
    /// primary calls `flow.tappedAgree()`), so the review drops its
    /// sign button and offers re-choosing the authority instead of Back.
    private let hostOwnsSigning: Bool
    @State private var showsAuthorities = false
    @State private var showsTermsText = false

    /// Embedded (no header), the onboarding scaffold centres this
    /// content itself; standalone it sits under the header, pushed
    /// down so it doesn't crowd the top.
    private var topInset: CGFloat { showsPickerHeader ? 120 : 0 }

    public init(
        flow: ModerationConsentFlow,
        showsPickerHeader: Bool = true,
        hostOwnsSigning: Bool = false
    ) {
        self.flow = flow
        self.showsPickerHeader = showsPickerHeader
        self.hostOwnsSigning = hostOwnsSigning
    }

    public var body: some View {
        VStack(spacing: 0) {
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
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.top, topInset)
            .accessibilityLabel(Text("Loading moderation authorities…"))
    }

    /// The authorities sit behind one configure icon — the same
    /// sliders the welcome screen uses for "set up myself" — opening
    /// the list as a sheet.
    @ViewBuilder
    private var picker: some View {
        if showsPickerHeader {
            Image(systemName: pickerSymbol)
                .font(OnymType.fixed(size: 56, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .accessibilityElement()
                .accessibilityLabel(Text(pickerTitle))
                .accessibilityHint(Text(pickerBlurb))
        }

        supersededHashes

        VStack(spacing: 16) {
            switch flow.state.fetchStatus {
            case .failed(let message):
                Image(systemName: "wifi.exclamationmark")
                    .font(OnymType.fixed(size: 28, weight: .semibold))
                    .foregroundStyle(OnymTokens.red)
                    .accessibilityLabel(Text(verbatim: message))
                roundButton("arrow.clockwise", label: "Retry") { flow.tappedRetry() }
                    .accessibilityIdentifier("moderation.consent.retry")
            case .fetching, .idle:
                ProgressView()
                    .controlSize(.large)
            case .success where flow.state.authorities.isEmpty:
                Image(systemName: "tray")
                    .font(OnymType.fixed(size: 28, weight: .semibold))
                    .foregroundStyle(OnymTokens.text3)
                    .accessibilityLabel(Text("No authorities are published yet."))
            case .success:
                roundButton("slider.horizontal.3", label: pickerTitle, size: 64) {
                    showsAuthorities = true
                }
                .accessibilityHint(Text(pickerBlurb))
                .accessibilityIdentifier("moderation.consent.choose")
            }

            errorSymbol
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showsAuthorities) {
            authorityList
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var authorityList: some View {
        NavigationStack {
            ScrollView {
                Card {
                    ForEach(Array(flow.state.authorities.enumerated()), id: \.element.componentId) { idx, listing in
                        Button {
                            showsAuthorities = false
                            flow.selectedAuthority(listing)
                        } label: {
                            // The name is data — the one word the pick
                            // needs. Your current authority is marked by
                            // its tile.
                            Row(
                                titleText: listing.name,
                                last: idx == flow.state.authorities.count - 1
                            ) {
                                IconTile(
                                    symbol: isCurrent(listing) ? "checkmark.shield.fill" : "checkmark.shield",
                                    bg: isCurrent(listing) ? OnymTile.green : OnymTile.indigo
                                )
                            }
                            .accessibilityValue(Text(verbatim: rowSubtitle(for: listing)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("moderation.consent.authority.\(listing.componentId)")
                    }
                }
                .padding(.top, 8)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsAuthorities = false } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Cancel"))
                }
            }
        }
    }

    /// A failure the flow reports (terms that wouldn't load, a signing
    /// that failed): a warning glyph, the message on its VoiceOver label.
    @ViewBuilder
    private var errorSymbol: some View {
        if let error = flow.state.errorMessage {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(OnymType.fixed(size: 22, weight: .semibold))
                .foregroundStyle(OnymTokens.red)
                .accessibilityLabel(Text(verbatim: error))
                .accessibilityIdentifier("moderation.consent.error")
        }
    }

    private func roundButton(
        _ symbol: String,
        label: LocalizedStringKey,
        size: CGFloat = 44,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(OnymType.fixed(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(label))
    }

    /// The two documents the "terms have changed" claim is about. Only
    /// on the re-consent surface, and only once both are known — on
    /// every other path there is no prior hash to contrast.
    @ViewBuilder
    private var supersededHashes: some View {
        if case .reconsent(.termsChanged) = flow.mode,
           let pinned = flow.state.pinnedManifestHash,
           let published = flow.state.publishedManifestHash {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    hashRow("signature", "Terms you signed", pinned)
                    hashRow("globe", "Published now", published)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func hashRow(_ symbol: String, _ label: LocalizedStringKey, _ hash: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SymbolHint(symbol, label: label)
            Text(hash)
                .font(OnymType.mono(size: 11))
                .foregroundStyle(OnymTokens.text2)
                .textSelection(.enabled)
        }
    }

    private var pickerSymbol: String {
        switch flow.mode {
        case .onboarding, .switching: return "shield.lefthalf.filled"
        case .reconsent(.termsChanged): return "doc.badge.clock"
        case .reconsent(.authorityDelisted): return "shield.slash"
        }
    }

    private func isCurrent(_ listing: AuthorityListing) -> Bool {
        if case .reconsent = flow.mode {
            return listing.componentId == flow.state.currentAuthorityId
        }
        return false
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

    /// The terms on one screen: the classes as symbols (tap one for
    /// its name), the full terms in words one tap away, then Back and
    /// sign. What is signed is exactly the manifest the text sheet
    /// shows — both read `reviewingManifest`.
    @ViewBuilder
    private var review: some View {
        if let reviewing = flow.state.reviewingManifest?.signedManifest {
            VStack(spacing: 24) {
                HStack(spacing: 24) {
                    ForEach(reviewing.manifest.violationClasses, id: \.classId) { violationClass in
                        ViolationClassSymbol(classId: violationClass.classId)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(verbatim: flow.state.selectedListing?.name ?? ""))

                roundButton("doc.plaintext", label: "Read the terms", size: 64) {
                    showsTermsText = true
                }
                .accessibilityIdentifier("moderation.consent.terms_text")

                errorSymbol

                if hostOwnsSigning {
                    if flow.state.step == .signing {
                        ProgressView()
                            .controlSize(.large)
                            .accessibilityLabel(Text("I agree and sign"))
                    } else {
                        // Back to the list, with it already open — the
                        // same configure icon the picker shows.
                        roundButton("slider.horizontal.3", label: "Choose a moderation authority", size: 50) {
                            flow.tappedBack()
                            showsAuthorities = true
                        }
                        .accessibilityIdentifier("moderation.consent.rechoose")
                    }
                } else {
                    HStack(spacing: 12) {
                        roundButton("arrow.left", label: "Back", size: 50) { flow.tappedBack() }
                            .disabled(flow.state.step == .signing)
                            .accessibilityIdentifier("moderation.consent.back")

                        PrimaryButton(action: { flow.tappedAgree() }) {
                            if flow.state.step == .signing {
                                ProgressView().tint(OnymTokens.onAccent)
                            } else {
                                Image(systemName: "signature")
                                    .font(OnymType.fixed(size: 22, weight: .semibold))
                            }
                        }
                        .disabled(flow.state.step == .signing)
                        .accessibilityLabel(Text("I agree and sign"))
                        .accessibilityIdentifier("moderation.consent.agree")
                    }
                    .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, showsPickerHeader ? 48 : 0)
            .sheet(isPresented: $showsTermsText) {
                ModerationTermsText(
                    authorityName: flow.state.selectedListing?.name,
                    reviewing: reviewing
                )
            }
        }
    }

    private var done: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(OnymType.fixed(size: 64))
            .foregroundStyle(OnymTokens.green)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("Mandate signed"))
            .padding(.top, topInset)
            .accessibilityIdentifier("moderation.consent.done")
    }
}

/// The terms in words — what the consent screen's text icon opens.
/// Every violation class with all five terms, the procedure, and the
/// hash being pinned, labelled in full and nothing collapsed: the
/// written form of what the symbols on the consent screen stand for.
struct ModerationTermsText: View {
    let authorityName: String?
    let reviewing: SignedManifest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LargeTitle(verbatim: authorityName ?? String(localized: "Terms"))

                    Text("These are the exact terms you're consenting to. A case can only ever reach you under a violation class listed here, with these windows and this appeal path.")
                        .font(OnymType.font(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                        .lineSpacing(3)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)

                    ForEach(reviewing.manifest.violationClasses, id: \.classId) { violationClass in
                        classCard(violationClass)
                    }

                    proceduralCard

                    SectionLabel("WHAT YOU'RE SIGNING")
                    Card {
                        termRow("Manifest hash", reviewing.manifestHash, mono: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    Footnote("Your consent binds to this hash of these exact terms. The authority cannot edit them under your mandate — changed terms bind only new consents.")
                }
                .padding(.bottom, 32)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Done"))
                    .accessibilityIdentifier("moderation.consent.terms_text.close")
                }
            }
        }
    }

    private func classCard(_ violationClass: ViolationClass) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(verbatim: ViolationClassSymbol.name(for: violationClass.classId).uppercased())
            Card {
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
    private var proceduralCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("PROCEDURE")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    if let appellate = reviewing.manifest.appellate {
                        termRow("Appeals heard by", appellate)
                    }
                    if let newHolder = reviewing.manifest.newHolderAppeal {
                        termRow("New device owner", newHolder)
                    }
                    termRow("Terms valid until", reviewing.manifest.validUntil.formatted(date: .abbreviated, time: .omitted))
                    termRow("Operated by", reviewing.manifest.operatorKey, mono: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func termRow(_ label: LocalizedStringKey, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(OnymType.font(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(verbatim: value)
                .font(mono ? OnymType.mono(size: 11) : OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .textSelection(.enabled)
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

/// A violation class as a symbol — child safety for CSAM, and so on.
/// Unknown classes fall back to a generic shield, labelled with the
/// class id so the popover still says exactly which class it is.
struct ViolationClassSymbol: View {
    let classId: String

    var body: some View {
        SymbolHint(symbol, verbatimLabel: Self.name(for: classId), size: 34, color: OnymTokens.red)
    }

    private var symbol: String {
        switch classId {
        case "csam": return "figure.and.child.holdinghands"
        case "unsolicited-pornography": return "eye.slash.fill"
        case "spam": return "envelope.badge.fill"
        default: return "exclamationmark.shield.fill"
        }
    }

    static func name(for classId: String) -> String {
        switch classId {
        case "csam": return String(localized: "Child sexual abuse material")
        case "unsolicited-pornography": return String(localized: "Unsolicited pornography")
        case "spam": return String(localized: "Spam")
        default: return classId.replacingOccurrences(of: "-", with: " ")
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
