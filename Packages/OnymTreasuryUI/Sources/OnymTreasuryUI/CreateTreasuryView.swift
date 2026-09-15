import OnymDesign
import OnymDesignTokens
import OnymStellar
import OnymTreasury
import SwiftUI

/// The founder's one-time setup: who controls the treasury, how many of
/// them it takes, and what goes in.
///
/// The screen is built around telling the founder what they are giving
/// up, because they are giving up a lot and it is irreversible. The
/// account is created with its own master key renounced in the same
/// transaction, so from the moment it exists the founder is one
/// co-signer among several — and if enough co-signers lose their keys,
/// the money is gone. Both facts are on the screen, not in a help page.
public struct CreateTreasuryView: View {
    @State private var copiedTransaction = false
    @Bindable var flow: TreasuryFlow
    @Environment(\.openURL) private var openURL

    public init(flow: TreasuryFlow) {
        self.flow = flow
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                intro
                coSigners
                thresholds
                funding
                consequences

                stageAction

                if let error = flow.creationError {
                    Text(error)
                        .font(OnymType.font(size: 13))
                        .foregroundStyle(OnymTokens.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .accessibilityIdentifier("treasury.create.error")
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.bg)
        .navigationTitle("New treasury")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await flow.refreshEstimate()
            await flow.refreshFunder()
        }
        .onChange(of: flow.selectedCoSigners) { _, _ in
            Task { await flow.refreshEstimate() }
        }
        .onChange(of: flow.spendableField) { _, _ in
            Task { await flow.refreshEstimate() }
        }
        .onChange(of: flow.pendingWalletRequest) { _, request in
            guard let url = request?.url else { return }
            openURL(url)
            flow.clearWalletRequest()
        }
    }

    /// The button, and what replaces it once creation has gone
    /// somewhere. Previously success set an error to nil and stopped,
    /// and the wallet handoff did nothing at all — both left the
    /// founder on an enabled "Create the treasury" button with no idea
    /// whether anything had happened.
    @ViewBuilder
    private var stageAction: some View {
        switch flow.creationStage {
        case .idle:
            PrimaryButton(
                "Create the treasury",
                disabled: flow.isCreating || flow.resolvedCoSigners.isEmpty
            ) {
                Task { await flow.create() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .accessibilityIdentifier("treasury.create.submit")

        case .awaitingWallet:
            VStack(alignment: .leading, spacing: 10) {
                Text("Waiting for your wallet")
                    .font(OnymType.font(size: 14, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text("Your wallet only funds the account \u{2014} that is all wallets will send. Sign it there, then come back: Onym locks the treasury down itself, checks the ledger, and only then tells the group.")
                    .font(OnymType.font(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                PrimaryButton("I've sent it", disabled: flow.isCreating) {
                    Task { await flow.confirmExternalCreation() }
                }
                .accessibilityIdentifier("treasury.create.confirm_external")
                if let deadline = flow.walletDeadline {
                    Footnote("Signable until \(deadline.formatted(date: .omitted, time: .shortened)). After that a wallet may refuse it \u{2014} some do so without saying anything \u{2014} and you can start over.")
                }
                if flow.canReopenWallet {
                    Button { flow.reopenWallet() } label: {
                        Text("Open my wallet again")
                            .font(OnymType.font(size: 14, weight: .medium))
                    }
                    .accessibilityIdentifier("treasury.create.reopen_wallet")
                }
                // The far end of a handoff is somebody else's app. When
                // it stalls, these bytes are the whole transaction and
                // can be finished anywhere that speaks Stellar.
                if let xdr = flow.walletTransactionXDR {
                    Button {
                        UIPasteboard.general.string = xdr
                        copiedTransaction = true
                    } label: {
                        Text(copiedTransaction ? "Copied" : "Copy the transaction")
                            .font(OnymType.font(size: 14, weight: .medium))
                    }
                    .accessibilityIdentifier("treasury.create.copy_xdr")
                    Footnote("If your wallet won't send it, copy the transaction and submit it anywhere that takes signed Stellar XDR. It needs one signature \u{2014} yours.")
                }
                // The way out. Without it this screen had one button,
                // and it could only ever fail for a transaction the
                // wallet refused or the founder changed their mind
                // about.
                Button(role: .destructive) {
                    Task { await flow.abandonExternalCreation() }
                } label: {
                    Text("Start over")
                        .font(OnymType.font(size: 14))
                        .foregroundStyle(OnymTokens.text3)
                }
                .accessibilityIdentifier("treasury.create.abandon_external")
                Footnote("Starting over forgets this handoff, and the key that finishes it. Do it only if the funding was never sent \u{2014} an account that was funded and not locked down cannot be recovered afterwards.")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

        case .created:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OnymTokens.green)
                Text("The treasury exists. Everyone in the chat can see it now.")
                    .font(OnymType.font(size: 14))
                    .foregroundStyle(OnymTokens.text)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .accessibilityIdentifier("treasury.create.done")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            LargeTitle("A treasury for this chat")
            Text("A Stellar account that no one person controls \u{2014} including you.")
                .font(OnymType.font(size: 15))
                .foregroundStyle(OnymTokens.text2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var coSigners: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("CO-SIGNERS")
            if flow.nominatable.isEmpty {
                Card {
                    Row(
                        title: "Nobody has chosen an account yet",
                        subtitleKey: "Each person picks their own Stellar account first.",
                        subtitleLineLimit: nil,
                        hasChevron: false,
                        last: true
                    ) {
                        IconTile(symbol: "person.badge.clock", bg: OnymTile.gray)
                    } right: { EmptyView() }
                }
            } else {
                Card {
                    ForEach(Array(flow.nominatable.enumerated()), id: \.element.id) { index, member in
                        let selected = flow.selectedCoSigners.contains(member.blsPubkeyHex)
                        Row(
                            titleText: member.isSelf ? "\(member.alias) (you)" : member.alias,
                            // The address when they are not on it, the
                            // gloss when they are.
                            //
                            // The gloss sat in the row's trailing slot
                            // beside the stepper, which has no width to
                            // spare: "one signature" wrapped to one
                            // character per line. It belongs here
                            // anyway — a subtitle is where the design
                            // teaches `weight`, with the plain meaning
                            // reading as part of the person's row
                            // rather than as a label on a control.
                            subtitle: selected ? nil : member.account?.abbreviated,
                            subtitleKey: selected ? Self.gloss(flow.weight(of: member)) : nil,
                            subtitleMono: !selected,
                            hasChevron: false,
                            last: index == flow.nominatable.count - 1,
                            onTap: { flow.toggle(member) }
                        ) {
                            IconTile(
                                symbol: member.standing == .declaredOnym
                                    ? "key.horizontal.fill"
                                    : "wallet.bifold.fill",
                                bg: member.standing == .declaredOnym
                                    ? OnymTile.green
                                    : OnymTile.indigo
                            )
                        } right: {
                            HStack(spacing: 10) {
                                // The weight, and only while they are on
                                // it. A stepper beside somebody who is
                                // not a co-signer sets a number that
                                // governs nothing.
                                if selected {
                                    weightStepper(for: member)
                                }
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        selected ? OnymAccent.blue.color : OnymTokens.text3
                                    )
                            }
                            // The trailing slot takes what is left of
                            // the row, so anything in it that can wrap,
                            // will.
                            .fixedSize()
                        }
                        .accessibilityIdentifier("treasury.create.cosigner.\(member.blsPubkeyHex)")
                    }
                }
            }
            if flow.hasUnprovenCoSigners {
                Footnote("Some of these accounts are held outside Onym and haven't signed anything yet, so nobody has confirmed they can. If one of them can't, the treasury may end up short of signatures.")
            }
        }
    }

    /// How far one person's signature carries.
    ///
    /// Everyone is one by default, which is what the old design could
    /// express and the only thing it could express. The gloss under the
    /// name — "counts double", "one signature" — is where the word
    /// `weight` is taught; the number is beside it, never instead of
    /// it.
    private func weightStepper(for member: TreasuryMemberRow) -> some View {
        HStack(spacing: 8) {
            Stepper(
                value: Binding(
                    get: { flow.weight(of: member) },
                    set: { flow.setWeight($0, for: member) }
                ),
                // The protocol's ceiling, not the enumeration cap —
                // those are unrelated numbers that happened to be
                // usable in the same place.
                in: 1...TreasuryCoSigner.maximumWeight
            ) { EmptyView() }
                .labelsHidden()
                .accessibilityIdentifier("treasury.create.weight.\(member.blsPubkeyHex)")
        }
    }

    /// What a weight means, in the words the design teaches it with.
    static func gloss(_ weight: UInt32) -> LocalizedStringKey {
        weight == 1 ? "one signature" : "counts \(Int(weight))"
    }

    private var thresholds: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("SIGNATURES REQUIRED")
            Card {
                stepper(
                    title: "To spend",
                    subtitle: "Payments and trustlines",
                    value: $flow.mediumThreshold,
                    identifier: "medium"
                )
                stepper(
                    title: "To change who can spend",
                    subtitle: "Adding or removing a co-signer",
                    value: $flow.highThreshold,
                    identifier: "high",
                    last: true
                )
            }
            quorumReadout
            Footnote("Out of \(Int(flow.quorum.totalWeight)) total weight. The second bar is deliberately higher than the first \u{2014} changing who holds the keys should be harder than spending.")
        }
        .padding(.top, 8)
    }

    /// What it takes to spend, as a sentence naming people.
    ///
    /// The screen this replaces showed "1/1" twice, with nothing to say
    /// what either number governed or who could satisfy it. This
    /// recomputes on every tap, and the arithmetic sits under the
    /// sentence rather than in place of it.
    @ViewBuilder
    private var quorumReadout: some View {
        let quorum = flow.quorum
        if !quorum.coSigners.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("RIGHT NOW, SPENDING TAKES")
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.spendingSentence(
                            quorum,
                            names: flow.memberNames,
                            me: flow.myBlsPubkeyHex
                        ))
                            .font(OnymType.font(size: 16.5, weight: .medium))
                            .foregroundStyle(OnymTokens.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(Int(quorum.thresholds.medium)) of \(Int(quorum.totalWeight)) weight")
                            .font(OnymType.font(size: 13))
                            .foregroundStyle(OnymTokens.text3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                // Governed by the bar for *changing* the signer set,
                // which is what removing a lost key costs — not by the
                // spending bar, which is what the first version
                // checked and which says nothing about three signers
                // at 1 with high 3.
                if !quorum.signersWhoseLossWouldFreezeIt.isEmpty {
                    Footnote("If any one of these phones is lost, this account freezes forever \u{2014} a key cannot be removed without its own signature, so the weight left behind can never clear the bar for changing who can spend.")
                }
            }
            .padding(.top, 8)
        }
    }

    /// "You and Aino together — or either of you plus both Mira and
    /// Sam." Built from the minimal combinations, because a list of
    /// every set that clears the bar is true and unreadable.
    ///
    /// `names` is why `TreasuryCoSigner` carries a roster key at all.
    /// The first version of this rendered `account.abbreviated` and
    /// produced "GBOIQE… and GCXRT…", which is the sentence the
    /// redesign exists to replace, written in a nicer font.
    static func spendingSentence(
        _ quorum: TreasuryQuorum,
        names: [String: String],
        me: String?
    ) -> String {
        // Two different failures, and only one of them has those
        // remedies. A bar above the total weight is fixed by lowering
        // it or adding weight; `high` below `medium` is fixed by
        // raising `high`, and telling someone to lower the spending bar
        // would send them the wrong way. `clampThresholdsToWeight`
        // keeps them ordered today, so the second is latent — which is
        // exactly when copy quietly starts lying.
        guard quorum.thresholds.high >= quorum.thresholds.medium else {
            return String(
                localized: "Changing who can spend is set lower than spending itself, which would let one person take the account over."
            )
        }
        // Unreachable and not-enumerated are different facts, and the
        // first version reported both as "nobody can reach this bar" —
        // a false statement about a perfectly good nine-signer
        // treasury.
        guard quorum.isReachable else {
            return String(
                localized: "Nobody can reach this bar \u{2014} lower it or give someone more weight."
            )
        }
        let combinations = quorum.minimalCombinations(reaching: quorum.thresholds.medium)
        guard !combinations.isEmpty else {
            return String(
                localized: "Any signatures adding up to \(Int(quorum.thresholds.medium)) of \(Int(quorum.totalWeight))."
            )
        }
        let spelled = combinations.prefix(3).map { combination in
            Self.names(combination, names: names, me: me)
        }
        // Localised, like the other two joiners. A plain Swift literal
        // here produced "вы и Aino, or либо…" — half a sentence in each
        // language, which `LocalizationCatalogTests` cannot see because
        // it only checks keys that are already in the catalog.
        let separator = String(localized: ", or ")
        if combinations.count > spelled.count {
            return spelled.joined(separator: separator)
                + String(localized: " \u{2014} and other combinations")
        }
        return spelled.joined(separator: separator)
    }

    private static func names(
        _ group: [TreasuryCoSigner],
        names: [String: String],
        me: String?
    ) -> String {
        let labels = group.map { coSigner -> String in
            guard let key = coSigner.memberBlsPubkeyHex else { return coSigner.account.abbreviated }
            if key == me { return String(localized: "you") }
            return names[key] ?? coSigner.account.abbreviated
        }
        if labels.count == 1 { return labels[0] }
        return labels.dropLast().joined(separator: ", ")
            + String(localized: " and ") + (labels.last ?? "")
    }

    private func stepper(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        value: Binding<UInt32>,
        identifier: String,
        last: Bool = false
    ) -> some View {
        // From the resolved co-signers, not the ticks: a member whose
        // declaration stopped verifying is not a signer, and a
        // threshold counted from headcount would exceed the weight that
        // actually exists.
        //
        // Against the total weight, not the headcount. With everyone
        // at 1 those were the same number; with anyone at 2 they are
        // not, and the bar the ledger enforces is the weight one. The
        // ceiling is what makes an unreachable threshold unreachable
        // rather than merely discouraged.
        let maximum = max(flow.quorum.totalWeight, 1)
        return Row(
            title: title,
            subtitleKey: subtitle,
            hasChevron: false,
            inset: 20,
            last: last
        ) {
            EmptyView()
        } right: {
            HStack(spacing: 8) {
                Text(verbatim: "\(value.wrappedValue)/\(maximum)")
                    .font(OnymType.mono(size: 14))
                    .foregroundStyle(OnymTokens.text2)
                    .monospacedDigit()
                Stepper(value: value, in: 1...max(maximum, 1)) { EmptyView() }
                    .labelsHidden()
                    // The two steppers move independently, so this is
                    // where "3 to spend, 1 to change who can spend"
                    // gets caught — a setting any single co-signer
                    // could use to take sole control of the account.
                    .onChange(of: value.wrappedValue) { _, _ in
                        flow.thresholdsChanged()
                    }
                    .accessibilityIdentifier("treasury.create.threshold.\(identifier)")
                    .accessibilityLabel(title)
                    .accessibilityValue("\(value.wrappedValue) of \(maximum)")
            }
        }
    }

    private var funding: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("FUNDING")
            // The account being debited, named.
            //
            // The screen itemised "You send N XLM" and never said from
            // where. For the option the declaration screen lists first
            // — the Onym-derived account — that address is empty by
            // construction, so creation failed on the Horizon read with
            // an unexplained "could not read the funding account". On a
            // screen whose thesis is telling the founder what they are
            // giving up, this belongs on it.
            if let funder = flow.funderAccount {
                Card {
                    Row(
                        titleText: funder.accountID,
                        titleMono: true,
                        // The unfunded line is UI copy; the balance is
                        // runtime data with a number in it.
                        subtitle: flow.funderIsUnfunded
                            ? nil
                            : flow.funderBalance.map { "\($0.decimalString) XLM available" },
                        subtitleKey: flow.funderIsUnfunded
                            ? "This account has nothing in it yet"
                            : nil,
                        subtitleLineLimit: nil,
                        hasChevron: false,
                        last: true
                    ) {
                        IconTile(
                            symbol: flow.funderIsUnfunded
                                ? "exclamationmark.triangle.fill"
                                : "arrow.up.circle.fill",
                            bg: flow.funderIsUnfunded ? OnymTile.amber : OnymTile.blue
                        )
                    } right: { EmptyView() }
                }
                // Two catalog keys chosen by a branch, not one string
                // built by a branch: `Footnote(verbatim:)` is the
                // non-localizing overload, and both of these are
                // ordinary English sentences with nothing interpolated.
                if flow.funderIsUnfunded {
                    Footnote("The assets come out of this account, and it is empty. Send XLM to it first \u{2014} the address above is yours.")
                } else {
                    Footnote("The assets come out of this account.")
                }
            }
            Card {
                Row(
                    title: "Spendable balance",
                    subtitleKey: "XLM the treasury can actually pay out",
                    hasChevron: false,
                    inset: 20,
                    last: true
                ) {
                    EmptyView()
                } right: {
                    TextField(TreasuryFlow.defaultSpendableXLM, text: $flow.spendableField)
                        .font(OnymType.mono(size: 15))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                        .accessibilityIdentifier("treasury.create.spendable")
                }
            }
            if let estimate = flow.estimate {
                estimateBreakdown(estimate)
            }
        }
        .padding(.top, 8)
    }

    /// The arithmetic, itemised.
    ///
    /// Somebody is being asked to send real money to an account they
    /// will not solely control. The least this screen can do is show
    /// them where every lumen goes, and which part of it they are never
    /// getting back while the account exists.
    private func estimateBreakdown(_ estimate: TreasuryFundingEstimate) -> some View {
        VStack(spacing: 6) {
            line(
                "Locked reserve",
                estimate.minimumBalance,
                detail: "2 + \(estimate.signerCount) signers, \u{00D7} \(estimate.baseReserve.decimalString)"
            )
            line("Spendable", estimate.spendable, detail: nil)
            line("Network fee", estimate.fee, detail: nil)
            Divider().overlay(OnymTokens.hairline)
            line("You send", estimate.total, detail: nil, emphasised: true)
        }
        .padding(14)
        .background(OnymTokens.surface2)
        .clipShape(OnymRadius.shape(OnymRadius.inset))
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .accessibilityIdentifier("treasury.create.estimate")
    }

    /// `label` is UI copy and must be a `LocalizedStringKey`; `detail`
    /// is assembled from runtime numbers and stays verbatim. Taking
    /// both as `String` picked `Text`'s non-localizing overload, so the
    /// whole funding breakdown could never be translated even once the
    /// catalog had the words — the bug `JoinConfirmView` documents.
    private func line(
        _ label: LocalizedStringKey,
        _ amount: StellarAmount,
        detail: String?,
        emphasised: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(OnymType.font(size: 14, weight: emphasised ? .semibold : .regular))
                    .foregroundStyle(emphasised ? OnymTokens.text : OnymTokens.text2)
                if let detail {
                    Text(detail)
                        .font(OnymType.font(size: 11))
                        .foregroundStyle(OnymTokens.text3)
                }
            }
            Spacer()
            // An amount, not copy.
            Text(verbatim: "\(amount.decimalString) XLM")
                .font(OnymType.mono(size: 14, weight: emphasised ? .semibold : .regular))
                .foregroundStyle(emphasised ? OnymTokens.text : OnymTokens.text2)
        }
    }

    private var consequences: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this does, permanently")
                .font(OnymType.font(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            bullet("The treasury's own key is switched off as it is created. After that you cannot move its assets alone, and neither can anyone else.")
            bullet("Adding or removing a co-signer later is a proposal the current co-signers have to approve \u{2014} including yours.")
            bullet("If enough co-signers lose their keys to reach the numbers above, the balance is locked away for good. Nobody can undo that.")
            bullet("The account and every payment it makes are public on Stellar, forever.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(OnymTokens.surface2)
        .clipShape(OnymRadius.shape(OnymRadius.inset))
        .overlay(
            OnymRadius.shape(OnymRadius.inset)
                .stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\u{2022}")
                .font(OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.text3)
            Text(text)
                .font(OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.text2)
        }
    }
}
