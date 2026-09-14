import OnymDesign
import OnymDesignTokens
import OnymStellar
import OnymTreasury
import SwiftUI

/// The treasury tab of a group: what it is, whether there is one, and
/// where everyone stands.
///
/// Deliberately renders a group with **no** treasury as a first-class
/// state rather than an empty screen. Most chats will never have one,
/// and "this chat has no treasury, here is what that would mean" is the
/// honest thing to show them.
public struct TreasurySetupView: View {
    @Bindable var flow: TreasuryFlow

    public init(flow: TreasuryFlow) {
        self.flow = flow
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let treasury = flow.treasury {
                    existing(treasury)
                } else {
                    absent
                }
                addressDisclosure
                yourAccount
                roster
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.bg)
        .navigationTitle("Treasury")
        .navigationBarTitleDisplayMode(.inline)
        .task { await flow.start() }
    }

    /// What was published about you, and what that cannot be undone.
    ///
    /// The address is broadcast without anyone asking, which is what
    /// lets a founder create a treasury before everyone has linked a
    /// wallet. The trade is only defensible if the person it is made
    /// about is told, in the second person, and told the part that
    /// cannot be retracted — so this is a screen, not a banner, and it
    /// does not go away until it is read.
    ///
    /// This is the small half of the board's 1c. The thread event and
    /// the leaving flow are not built yet, and this is deliberately the
    /// thing that had to exist before the publishing did.
    @ViewBuilder
    private var addressDisclosure: some View {
        if let mine = flow.mine, mine.source == .onym, !flow.hasSeenAddressDisclosure {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("YOUR ADDRESS IS NOW PUBLIC")
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Onym published the Stellar account it keeps for you to this chat, so a treasury can be set up without waiting for everyone.")
                            .font(OnymType.font(size: 14))
                            .foregroundStyle(OnymTokens.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: mine.account.accountID)
                            .font(OnymType.mono(size: 11.5))
                            .foregroundStyle(OnymTokens.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("It is on Stellar's public ledger beside this chat's treasury, and it stays there. Leaving a treasury later does not remove that record \u{2014} nothing can.")
                            .font(OnymType.font(size: 13))
                            .foregroundStyle(OnymTokens.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("You can name a different wallet below. If a treasury already exists, coming off it takes the other co-signers' agreement.")
                            .font(OnymType.font(size: 13))
                            .foregroundStyle(OnymTokens.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                PrimaryButton("Got it") { flow.acknowledgeAddressDisclosure() }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .accessibilityIdentifier("treasury.address_disclosure.ack")
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Treasury state

    private func existing(_ treasury: Treasury) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("THIS CHAT'S ACCOUNT")
            Card {
                Row(
                    titleText: treasury.account.accountID,
                    titleMono: true,
                    subtitleKey: treasury.network == .testnet
                        ? "Stellar testnet \u{2014} not real assets"
                        : "Stellar",
                    subtitleLineLimit: nil,
                    hasChevron: false,
                    last: true
                ) {
                    IconTile(symbol: "building.columns.fill", bg: OnymTile.green)
                } right: { EmptyView() }
            }
            Footnote("Anyone with this address can look up the treasury's balance and its whole payment history on Stellar.")
        }
        .padding(.top, 8)
    }

    private var absent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("NO TREASURY YET")
            Card {
                Row(
                    title: "This chat holds no assets",
                    subtitleKey: "A treasury is a Stellar account that several people in the chat have to agree to spend from.",
                    subtitleLineLimit: nil,
                    hasChevron: false,
                    last: true
                ) {
                    IconTile(symbol: "building.columns", bg: OnymTile.gray)
                } right: { EmptyView() }
            }

            if flow.isAdmin {
                NavigationLink {
                    CreateTreasuryView(flow: flow)
                } label: {
                    Card {
                        Row(
                            title: "Create a treasury",
                            subtitleKey: flow.nominatable.isEmpty
                                ? "Waiting for people to choose their accounts"
                                : "\(flow.nominatable.count) ready to co-sign",
                            last: true
                        ) {
                            IconTile(symbol: "plus.circle.fill", bg: OnymTile.blue)
                        } right: { EmptyView() }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("treasury.create_row")
            } else {
                Footnote("Only the founder can create it \u{2014} but once it exists, spending from it takes agreement, theirs included.")
            }
        }
        .padding(.top, 8)
    }

    // MARK: - This identity

    private var yourAccount: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("YOU")
            NavigationLink {
                DeclareSignerView(flow: flow)
            } label: {
                Card {
                    Row(
                        title: flow.mine == nil ? "Choose your Stellar account" : "Your Stellar account",
                        // Runtime data when there is an account (the
                        // address), UI copy when there is not — so the
                        // two go through different parameters rather
                        // than one `String?` that means both.
                        subtitle: flow.mine.map(subtitle(for:)),
                        subtitleKey: flow.mine == nil
                            ? "Needed before you can co-sign anything"
                            : nil,
                        subtitleMono: flow.mine != nil,
                        last: true
                    ) {
                        IconTile(
                            symbol: flow.mine == nil
                                ? "questionmark.circle.fill"
                                : "checkmark.circle.fill",
                            bg: flow.mine == nil ? OnymTile.amber : OnymTile.green
                        )
                    } right: { EmptyView() }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("treasury.declare_row")
        }
        .padding(.top, 8)
    }

    private func subtitle(for record: TreasurySignerDeclarationRecord) -> String {
        record.account.abbreviated
    }

    // MARK: - Everyone else

    private var roster: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("EVERYONE")
            Card {
                ForEach(Array(flow.members.enumerated()), id: \.element.id) { index, member in
                    let mark = TreasurySignerMark(member.standing)
                    Row(
                        titleText: member.isSelf ? "\(member.alias) (you)" : member.alias,
                        // The address when there is one, the standing's
                        // label when there is not — runtime data and UI
                        // copy through their own parameters.
                        subtitle: member.account?.abbreviated,
                        subtitleKey: member.account == nil ? mark.text : nil,
                        subtitleMono: member.account != nil,
                        hasChevron: false,
                        last: index == flow.members.count - 1
                    ) {
                        IconTile(symbol: mark.symbol, bg: mark.tile)
                    } right: {
                        if member.account != nil {
                            Chip(
                                key: mark.text,
                                fg: mark.color,
                                bg: mark.color.opacity(0.14)
                            )
                        }
                    }
                    .accessibilityIdentifier("treasury.member.\(member.blsPubkeyHex)")
                }
            }
        }
        .padding(.top, 8)
    }
}

/// The one place a `TreasurySignerStanding` becomes a symbol, a word
/// and a colour — the same role `GroupRulesMark` plays for rules, and
/// kept separate for the same reason: so two screens cannot drift into
/// describing the same state differently.
///
/// `declaredExternalUnproven` is drawn in amber rather than red. It is
/// not a fault — it is the normal state of an account Onym has never
/// been asked to sign with — but it is the one a founder should look at
/// twice before handing it a share of control.
public struct TreasurySignerMark: Equatable, Sendable {
    public let symbol: String
    /// UI copy, so a key rather than a `String` — the same reason
    /// `Row.subtitleKey` and `Chip(key:)` exist. As a `String` these
    /// five labels rendered English under `ru` while sitting in the
    /// catalog looking translated.
    public let text: LocalizedStringKey
    public let color: Color
    public let tile: Color

    public init(_ standing: TreasurySignerStanding) {
        switch standing {
        case .notDeclared:
            symbol = "questionmark.circle"
            text = "No account yet"
            color = OnymTokens.text3
            tile = OnymTile.gray
        case .declaredOnym:
            symbol = "key.horizontal.fill"
            text = "Onym key"
            color = OnymTokens.green
            tile = OnymTile.green
        case .declaredExternalUnproven:
            symbol = "wallet.bifold"
            text = "Own wallet"
            color = OnymTokens.amber
            tile = OnymTile.indigo
        case .declaredExternalProven:
            symbol = "wallet.bifold.fill"
            text = "Own wallet \u{2014} signed"
            color = OnymTokens.green
            tile = OnymTile.indigo
        case .doesNotVerify:
            symbol = "exclamationmark.triangle.fill"
            text = "Doesn't check out"
            color = OnymTokens.red
            tile = OnymTile.red
        }
    }
}
