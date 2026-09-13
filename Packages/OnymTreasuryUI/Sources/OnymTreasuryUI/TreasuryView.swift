import OnymDesign
import OnymDesignTokens
import OnymStellar
import OnymTreasury
import SwiftUI

/// The treasury itself: what it holds, who controls it, what is waiting
/// to be signed, and what it has done.
public struct TreasuryView: View {
    @Bindable var flow: TreasuryProposalsFlow
    @Environment(\.openURL) private var openURL
    @State private var compose: ComposeSheet?

    private enum ComposeSheet: String, Identifiable {
        case payment, trustline
        var id: String { rawValue }
    }

    public init(flow: TreasuryProposalsFlow) {
        self.flow = flow
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if flow.treasury == nil {
                    absent
                } else {
                    holdings
                    control
                    proposals
                    actions
                    history
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.bg)
        .navigationTitle("Treasury")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await flow.start()
        }
        .task {
            await flow.loadHistory()
        }
        .refreshable {
            await flow.refresh()
            await flow.loadHistory()
        }
        .sheet(item: $compose) { sheet in
            NavigationStack {
                switch sheet {
                case .payment: ProposePaymentView(flow: flow) { compose = nil }
                case .trustline: ProposeTrustlineView(flow: flow) { compose = nil }
                }
            }
        }
        // Two `.sheet` modifiers, which the compose one above and this
        // one can get away with because they are never owed at the same
        // time: `compose` is set by a row tap, and `pasteTargetID` only
        // by a wallet handoff that dismisses the compose sheet first.
        // `ChatMembersView`'s one-enum rule applies where two sheets can
        // genuinely race; these cannot.
        .sheet(isPresented: pasteBinding) {
            NavigationStack {
                PasteSignedTransactionView(flow: flow)
            }
        }
        .onChange(of: flow.walletRequest) { _, request in
            // Only the surface that asked opens the link — see
            // `TreasuryProposalsFlow.Surface`.
            guard flow.walletRequestSurface == .screen, let url = request?.url else {
                return
            }
            openURL(url)
            flow.clearWalletRequest()
        }
        .reasonAlert("Treasury", reason: Binding(
            get: { flow.error(for: .screen) },
            set: { if $0 == nil { flow.clearError() } }
        ))
    }

    /// The paste sheet is owed exactly when a wallet handoff named a
    /// proposal to bring a signature back to.
    private var pasteBinding: Binding<Bool> {
        Binding(
            get: { flow.ownsPastePrompt(.screen) },
            set: { if !$0 { flow.pasteTargetID = nil } }
        )
    }

    // MARK: - Sections

    private var absent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("NO TREASURY")
            Card {
                Row(
                    title: "This chat holds no money",
                    subtitle: "The founder can set one up from the members screen.",
                    subtitleLineLimit: nil,
                    hasChevron: false,
                    last: true
                ) {
                    IconTile(symbol: "building.columns", bg: OnymTile.gray)
                } right: { EmptyView() }
            }
        }
        .padding(.top, 8)
    }

    private var holdings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("BALANCE")
            Card {
                if flow.balances.isEmpty {
                    Row(
                        title: flow.hasLiveAccount ? "Nothing yet" : "Checking\u{2026}",
                        hasChevron: false,
                        last: true
                    ) {
                        IconTile(symbol: "circle.dashed", bg: OnymTile.gray)
                    } right: { EmptyView() }
                } else {
                    ForEach(Array(flow.balances.enumerated()), id: \.offset) { index, balance in
                        Row(
                            titleText: balance.asset.code,
                            subtitle: balance.asset.issuer?.abbreviated,
                            subtitleMono: true,
                            hasChevron: false,
                            last: index == flow.balances.count - 1
                        ) {
                            IconTile(
                                symbol: balance.asset == .native ? "star.fill" : "dollarsign.circle",
                                bg: balance.asset == .native ? OnymTile.amber : OnymTile.teal
                            )
                        } right: {
                            Text(balance.balance.decimalString)
                                .font(OnymType.mono(size: 15, weight: .semibold))
                                .foregroundStyle(OnymTokens.text)
                                .monospacedDigit()
                        }
                    }
                }
            }
            // Two catalog keys chosen by a branch, not one string built
            // by a branch — the rule `CreateTreasuryView` already states.
            // `Footnote(verbatim:)` is the non-localizing overload, so
            // both of these rendered English under `ru` even though the
            // catalog has held a Russian translation for each since the
            // scanner put them there.
            if let treasury = flow.treasury {
                if treasury.network == .testnet {
                    Footnote("Stellar testnet \u{2014} this is not real money.")
                } else {
                    Footnote("Part of this balance is a reserve Stellar locks while the account exists. It can't be spent.")
                }
            }
        }
        .padding(.top, 8)
    }

    private var control: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("WHO CONTROLS IT")
            Card {
                ForEach(Array(flow.signers.enumerated()), id: \.offset) { index, signer in
                    Row(
                        titleText: signer.key.abbreviated,
                        titleMono: true,
                        subtitle: signer.key == flow.treasury?.account
                            ? "The account's own key"
                            : nil,
                        hasChevron: false,
                        last: index == flow.signers.count - 1
                    ) {
                        IconTile(
                            symbol: signer.weight == 0 ? "xmark.circle" : "person.fill.checkmark",
                            bg: signer.weight == 0 ? OnymTile.gray : OnymTile.green
                        )
                    } right: {
                        // A key, not runtime data: "weight" is a word
                        // this app chose. Cast, so the placeholder is
                        // `%lld` rather than whatever SwiftUI picks for
                        // a `UInt32` — see the card's signature count.
                        Text("weight \(Int(signer.weight))")
                            .font(OnymType.mono(size: 12))
                            .foregroundStyle(OnymTokens.text3)
                    }
                }
            }
            if let thresholds = flow.thresholds {
                Footnote("It takes \(Int(thresholds.medium)) signature(s) to spend, and \(Int(thresholds.high)) to change who can.")
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var proposals: some View {
        let open = flow.rows.filter { $0.standing?.isActionable ?? true }
        if !open.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("WAITING ON SIGNATURES")
                ForEach(open) { row in
                    TreasuryProposalCard(row: row, flow: flow, surface: .screen)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
        }
        refused
    }

    /// Proposals this device turned down.
    ///
    /// Shown rather than hidden. Both call sites filtered on
    /// `isActionable`, which is false for every rejection — so eight
    /// carefully-worded refusals could never render, and a member whose
    /// proposal was refused saw the same nothing as one whose message
    /// never arrived. Only one of those is worth telling someone about.
    /// The thread stays quiet; this is the screen where it belongs.
    @ViewBuilder
    private var refused: some View {
        // Refusals, lapses *and* dismissals. `.superseded` and
        // `.expired` are not actionable and are not rejections, so they
        // rendered on no surface at all — a member whose proposal was
        // overtaken or ran out of time was told nothing, which is the
        // same failure this section was added to fix for refusals.
        //
        // Dismissals get their own section below rather than joining
        // these: a proposal somebody set aside did not fail, and filing
        // it under "didn't go through" would be the card saying
        // something untrue about a transaction that can still be put
        // back. But it was the third instance of the same mistake, and
        // the worst one — the card carries the only way back, so with
        // no section picking it up, "Put it back" and `flow.restore`
        // were unreachable and "Set aside" was a one-way door.
        let refusals = flow.rows.filter { row in
            switch row.standing {
            case .rejected, .superseded, .expired: true
            default: false
            }
        }
        if !refusals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("DIDN'T GO THROUGH")
                ForEach(refusals) { row in
                    TreasuryProposalCard(row: row, flow: flow, surface: .screen)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
        }
        setAside
    }

    /// Proposals this device put down, and the only place they appear.
    @ViewBuilder
    private var setAside: some View {
        let dismissed = flow.rows.filter { $0.standing == .dismissed }
        if !dismissed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("SET ASIDE")
                ForEach(dismissed) { row in
                    TreasuryProposalCard(row: row, flow: flow, surface: .screen)
                        .padding(.horizontal, 16)
                }
                Footnote("Set aside on this phone only. Nobody else sees this, and putting one back makes it signable again.")
            }
            .padding(.top, 8)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("PROPOSE")
            Card {
                Row(
                    title: "Send a payment",
                    subtitle: "Needs the group's signatures before it goes",
                    onTap: { compose = .payment }
                ) {
                    IconTile(symbol: "paperplane.fill", bg: OnymTile.blue)
                } right: { EmptyView() }
                .accessibilityIdentifier("treasury.propose_payment")

                Row(
                    title: "Hold a new asset",
                    subtitle: "Open a trustline so the treasury can receive it",
                    last: true,
                    onTap: { compose = .trustline }
                ) {
                    IconTile(symbol: "link.badge.plus", bg: OnymTile.purple)
                } right: { EmptyView() }
                .accessibilityIdentifier("treasury.propose_trustline")
            }
            nominations
        }
        .padding(.top, 8)
    }

    /// Nominating a co-signer.
    ///
    /// Offered to **every** member, not only the founder. After
    /// creation the treasury has no owner — the master key was
    /// renounced — so there is nobody whose privilege this could be.
    /// What decides the outcome is the high threshold: a nomination
    /// goes nowhere unless the current co-signers sign it.
    @ViewBuilder
    private var nominations: some View {
        if !flow.nominees.isEmpty {
            SectionLabel("NOMINATE A CO-SIGNER")
            Card {
                ForEach(Array(flow.nominees.enumerated()), id: \.element.id) { index, nominee in
                    Row(
                        titleText: nominee.alias,
                        subtitle: nominee.account.abbreviated,
                        subtitleMono: true,
                        hasChevron: false,
                        last: index == flow.nominees.count - 1
                    ) {
                        IconTile(symbol: "person.badge.plus", bg: OnymTile.indigo)
                    } right: {
                        Button("Propose") {
                            Task { await flow.proposeAddSigner(nominee.account) }
                        }
                        .font(OnymType.font(size: 14, weight: .semibold))
                        .disabled(flow.isComposing)
                        .accessibilityIdentifier("treasury.nominate.\(nominee.id)")
                    }
                }
            }
            Footnote("Adding a co-signer takes the same agreement as any other change to who controls the treasury \u{2014} the founder cannot do it alone.")
        }
    }

    @ViewBuilder
    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("HISTORY")
            Card {
                if flow.isLoadingHistory && flow.history.isEmpty {
                    Row(title: "Loading\u{2026}", hasChevron: false, last: true) {
                        IconTile(symbol: "clock", bg: OnymTile.gray)
                    } right: { EmptyView() }
                } else if flow.history.isEmpty {
                    Row(
                        title: "Nothing has happened yet",
                        hasChevron: false,
                        last: true
                    ) {
                        IconTile(symbol: "clock", bg: OnymTile.gray)
                    } right: { EmptyView() }
                } else {
                    ForEach(Array(flow.history.enumerated()), id: \.element.hash) { index, entry in
                        Row(
                            titleText: entry.hash,
                            titleMono: true,
                            subtitle: entry.ledgerCloseTime.formatted(
                                date: .abbreviated,
                                time: .shortened
                            ),
                            hasChevron: false,
                            last: index == flow.history.count - 1
                        ) {
                            IconTile(
                                symbol: entry.successful
                                    ? "checkmark.circle.fill"
                                    : "xmark.circle.fill",
                                bg: entry.successful ? OnymTile.green : OnymTile.red
                            )
                        } right: { EmptyView() }
                    }
                }
            }
            Footnote("Read from Stellar, not from this app's records \u{2014} it is what actually happened.")
        }
        .padding(.top, 8)
    }
}
