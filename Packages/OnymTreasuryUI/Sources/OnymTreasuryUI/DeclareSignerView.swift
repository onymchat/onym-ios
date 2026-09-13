import OnymDesign
import OnymDesignTokens
import OnymStellar
import OnymTreasury
import SwiftUI

/// "Which Stellar account should sign for you here?"
///
/// Two answers, and the screen does not push either. Onym can derive an
/// account for this identity and sign with it in one tap; or the person
/// names one they already have, which Onym cannot sign for and never
/// sees the key to. The second is the reason this screen exists — an
/// Onym identity is for talking, and nobody should have to move their
/// money into it to use a treasury.
public struct DeclareSignerView: View {
    @Bindable var flow: TreasuryFlow

    public init(flow: TreasuryFlow) {
        self.flow = flow
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                intro

                if let mine = flow.mine {
                    SectionLabel("YOUR CHOICE")
                    Card {
                        Row(
                            titleText: mine.account.abbreviated,
                            titleMono: true,
                            subtitleKey: mine.source == .onym
                                ? "Derived by Onym — this app can sign"
                                : "Held in your own wallet",
                            hasChevron: false,
                            last: true
                        ) {
                            IconTile(
                                symbol: mine.source == .onym
                                    ? "key.horizontal.fill"
                                    : "wallet.bifold.fill",
                                bg: mine.source == .onym ? OnymTile.green : OnymTile.indigo
                            )
                        } right: { EmptyView() }
                    }
                    Footnote("Choosing again replaces this. It won't remove you from a treasury that already exists \u{2014} that takes a proposal the other co-signers approve.")
                }

                onymOption
                externalOption

                if let error = flow.declarationError {
                    Text(error)
                        .font(OnymType.font(size: 13))
                        .foregroundStyle(OnymTokens.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .accessibilityIdentifier("treasury.declare.error")
                }

                publicityNote
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.bg)
        .navigationTitle("Your Stellar account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            LargeTitle("Sign with which account?")
            Text("A treasury is controlled by a set of Stellar accounts. Tell \(flow.groupName) which one is yours.")
                .font(OnymType.font(size: 15))
                .foregroundStyle(OnymTokens.text2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var onymOption: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("USE THE ONE ONYM DERIVES")
            // No `Card` at all when there is no derived account, rather
            // than an empty one: a bordered box with nothing in it reads
            // as a loading failure.
            if let account = flow.onymDerivedAccount {
                Card {
                    Row(
                        titleText: account.accountID,
                        titleMono: true,
                        subtitleLineLimit: nil,
                        hasChevron: false,
                        last: true
                    ) {
                        IconTile(symbol: "key.horizontal.fill", bg: OnymTile.green)
                    } right: { EmptyView() }
                }
            }
            PrimaryButton(
                "Use this account",
                disabled: flow.isDeclaring || flow.onymDerivedAccount == nil
            ) {
                Task { await flow.declareOnymDerived() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .accessibilityIdentifier("treasury.declare.use_onym")

            Footnote("Onym holds the key for this one, so signing is a single tap. It comes back with your recovery phrase, and it is a different key from the one that signs your messages.")
        }
        .padding(.top, 8)
    }

    private var externalOption: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("OR NAME ONE YOU ALREADY HAVE")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $flow.externalAccountField)
                        .font(OnymType.mono(size: 14))
                        .frame(minHeight: 66)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("treasury.declare.field")

                    if !flow.externalAccountField.isEmpty {
                        Chip(
                            // `key:`, not `text:` — both arms are UI
                            // copy, and `text:` is the verbatim
                            // initialiser, so the Russian translation of
                            // "Valid address" could never be reached.
                            key: flow.externalAccountIsValid
                                ? "Valid address"
                                : "\(flow.externalAccountField.count)/56 characters",
                            fg: flow.externalAccountIsValid ? OnymTokens.green : OnymTokens.red,
                            bg: (flow.externalAccountIsValid ? OnymTokens.green : OnymTokens.red)
                                .opacity(0.14)
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            PrimaryButton(
                "Use this account",
                disabled: flow.isDeclaring || !flow.externalAccountIsValid
            ) {
                Task { await flow.declareExternal() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .accessibilityIdentifier("treasury.declare.use_external")

            Footnote("Onym never sees this key. When there is something to sign, it hands the transaction to your wallet and takes back only the signature.")
        }
        .padding(.top, 16)
    }

    /// Said plainly, once, where the decision is made.
    ///
    /// Declaring an account is the moment a pseudonymous chat identity
    /// gets tied to a public ledger history, for everyone in the group
    /// and for anyone they tell. That is not a footnote to bury.
    private var publicityNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This is public")
                .font(OnymType.font(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text("Everyone in this chat will see the address you choose, and anyone who has it can read that account's entire history on Stellar \u{2014} its balance, and every payment it has ever made or received. If you would rather that history not be linked to you here, use an account you keep for this.")
                .font(OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.text2)
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
}
