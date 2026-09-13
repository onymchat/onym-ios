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
                Text("Sign and send the transaction there, then come back and confirm. Onym checks the ledger before telling the group \u{2014} it won't take your word for it.")
                    .font(OnymType.font(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                PrimaryButton("I've sent it", disabled: flow.isCreating) {
                    Task { await flow.confirmExternalCreation() }
                }
                .accessibilityIdentifier("treasury.create.confirm_external")
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
                        subtitle: "Each person picks their own Stellar account first.",
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
                            subtitle: member.account?.abbreviated,
                            subtitleMono: true,
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
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(
                                    selected ? OnymAccent.blue.color : OnymTokens.text3
                                )
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
            Footnote("Out of \(flow.resolvedCoSigners.count) co-signers. Requiring everyone means one lost phone freezes the treasury for good \u{2014} there is no way to remove a key without its own signature.")
        }
        .padding(.top, 8)
    }

    private func stepper(
        title: LocalizedStringKey,
        subtitle: String,
        value: Binding<UInt32>,
        identifier: String,
        last: Bool = false
    ) -> some View {
        // From the resolved co-signers, not the ticks: a member whose
        // declaration stopped verifying is not a signer, and a
        // threshold counted from headcount would exceed the weight that
        // actually exists.
        let maximum = UInt32(max(flow.resolvedCoSigners.count, 1))
        return Row(
            title: title,
            subtitle: subtitle,
            hasChevron: false,
            inset: 20,
            last: last
        ) {
            EmptyView()
        } right: {
            HStack(spacing: 8) {
                Text("\(value.wrappedValue)/\(maximum)")
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
                        subtitle: flow.funderIsUnfunded
                            ? "This account has nothing in it yet"
                            : flow.funderBalance.map { "\($0.decimalString) XLM available" },
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
                Footnote(verbatim: flow.funderIsUnfunded
                    ? "The money comes out of this account, and it is empty. Send XLM to it first \u{2014} the address above is yours."
                    : "The money comes out of this account.")
            }
            Card {
                Row(
                    title: "Spendable balance",
                    subtitle: "XLM the treasury can actually pay out",
                    hasChevron: false,
                    inset: 20,
                    last: true
                ) {
                    EmptyView()
                } right: {
                    TextField("0", text: $flow.spendableField)
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

    private func line(
        _ label: String,
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
            Text("\(amount.decimalString) XLM")
                .font(OnymType.mono(size: 14, weight: emphasised ? .semibold : .regular))
                .foregroundStyle(emphasised ? OnymTokens.text : OnymTokens.text2)
        }
    }

    private var consequences: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this does, permanently")
                .font(OnymType.font(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            bullet("The treasury's own key is switched off as it is created. After that you cannot move its money alone, and neither can anyone else.")
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

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
                .font(OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.text3)
            Text(text)
                .font(OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.text2)
        }
    }
}
