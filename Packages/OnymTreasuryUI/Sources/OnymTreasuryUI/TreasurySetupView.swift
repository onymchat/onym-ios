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

    // MARK: - Treasury state

    private func existing(_ treasury: Treasury) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("THIS CHAT'S ACCOUNT")
            Card {
                Row(
                    titleText: treasury.account.accountID,
                    titleMono: true,
                    subtitle: treasury.network == .testnet
                        ? "Stellar testnet \u{2014} not real money"
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
                    title: "This chat holds no money",
                    subtitle: "A treasury is a Stellar account that several people in the chat have to agree to spend from.",
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
                            subtitle: flow.nominatable.isEmpty
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
                        subtitle: flow.mine.map(subtitle(for:))
                            ?? "Needed before you can co-sign anything",
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
                        subtitle: member.account?.abbreviated ?? mark.text,
                        subtitleMono: member.account != nil,
                        hasChevron: false,
                        last: index == flow.members.count - 1
                    ) {
                        IconTile(symbol: mark.symbol, bg: mark.tile)
                    } right: {
                        if member.account != nil {
                            Chip(
                                text: mark.text,
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
    public let text: String
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
