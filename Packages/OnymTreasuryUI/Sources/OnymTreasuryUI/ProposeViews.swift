import OnymDesign
import OnymDesignTokens
import OnymStellar
import OnymTreasury
import SwiftUI

/// Compose a payment from the treasury.
///
/// The asset is chosen from what the treasury actually holds rather
/// than typed. A free-text asset field lets someone propose a payment
/// in a token the treasury has no trustline for — which fails at
/// submit, after the group has already signed it.
struct ProposePaymentView: View {
    @Bindable var flow: TreasuryProposalsFlow
    let onDone: () -> Void
    @State private var selected: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("PAY")
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("0", text: $flow.paymentAmount)
                            .font(OnymType.mono(size: 28, weight: .semibold))
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("treasury.payment.amount")

                        if flow.payableAssets.count > 1 {
                            Picker("Asset", selection: $selected) {
                                ForEach(Array(flow.payableAssets.enumerated()), id: \.offset) {
                                    index, asset in
                                    Text(asset.code).tag(index)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("treasury.payment.asset")
                        } else if flow.payableAssets.isEmpty {
                            Text("Checking what this treasury holds\u{2026}")
                                .font(OnymType.font(size: 13))
                                .foregroundStyle(OnymTokens.text3)
                        } else if let only = flow.payableAssets.first {
                            Text(only.code)
                                .font(OnymType.font(size: 14, weight: .medium))
                                .foregroundStyle(OnymTokens.text2)
                        }
                    }
                    .padding(.vertical, 6)
                }

                SectionLabel("TO")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $flow.paymentDestination)
                            .font(OnymType.mono(size: 14))
                            .frame(minHeight: 66)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("treasury.payment.destination")
                        if !flow.paymentDestination.isEmpty {
                            Chip(
                                text: flow.paymentDestinationIsValid
                                    ? "Valid address"
                                    : "Not a valid address",
                                fg: flow.paymentDestinationIsValid
                                    ? OnymTokens.green : OnymTokens.red,
                                bg: (flow.paymentDestinationIsValid
                                    ? OnymTokens.green : OnymTokens.red).opacity(0.14)
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                Footnote("Check this address character by character. A payment that leaves the treasury cannot be recalled by anyone, including the people who signed it.")

                // Also gated on knowing what the treasury holds. With no
                // live account read there are no payable assets, the
                // picker draws nothing, and the composer fell through to
                // `.native` — a proposal denominated in XLM that nobody
                // chose.
                PrimaryButton(
                    "Put it to the group",
                    disabled: flow.isComposing
                        || !flow.paymentDestinationIsValid
                        || flow.payableAssets.isEmpty
                ) {
                    Task {
                        applyAsset()
                        await flow.proposePayment()
                        if flow.composeError == nil { onDone() }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .accessibilityIdentifier("treasury.payment.submit")

                if let error = flow.composeError {
                    Text(error)
                        .font(OnymType.font(size: 13))
                        .foregroundStyle(OnymTokens.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.bg)
        .navigationTitle("New payment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { onDone() }
            }
        }
    }

    /// Clamps rather than bails.
    ///
    /// Bailing left `paymentAssetCode` empty, and an empty code is how
    /// `proposePayment` spells XLM — so a balance list that shrank while
    /// the sheet was open (index 2 selected, a refresh returns two
    /// assets) left the button enabled and asked the group to sign a
    /// payment denominated in XLM that nobody chose. The selection
    /// moving to a neighbouring asset is visible on screen; silently
    /// changing what is being paid is not.
    private func applyAsset() {
        let assets = flow.payableAssets
        guard !assets.isEmpty else {
            flow.paymentAssetCode = ""
            flow.paymentAssetIssuer = ""
            return
        }
        if selected >= assets.count { selected = assets.count - 1 }
        let asset = assets[selected]
        flow.paymentAssetCode = asset == .native ? "" : asset.code
        flow.paymentAssetIssuer = asset.issuer?.accountID ?? ""
    }
}

/// Open a trustline so the treasury can hold a token.
struct ProposeTrustlineView: View {
    @Bindable var flow: TreasuryProposalsFlow
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("ASSET CODE")
                Card {
                    TextField("USDC", text: $flow.trustlineCode)
                        .font(OnymType.mono(size: 16))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("treasury.trustline.code")
                }

                SectionLabel("ISSUER")
                Card {
                    TextEditor(text: $flow.trustlineIssuer)
                        .font(OnymType.mono(size: 14))
                        .frame(minHeight: 66)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("treasury.trustline.issuer")
                }
                Footnote("Anyone can issue a token called anything. The issuer account is what tells a real one from a copy \u{2014} get it from the issuer themselves, not from whoever asked you to add it.")

                PrimaryButton("Put it to the group", disabled: flow.isComposing) {
                    Task {
                        await flow.proposeTrustline()
                        if flow.composeError == nil { onDone() }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .accessibilityIdentifier("treasury.trustline.submit")

                if let error = flow.composeError {
                    Text(error)
                        .font(OnymType.font(size: 13))
                        .foregroundStyle(OnymTokens.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                }

                Footnote("Holding one more asset locks one more base reserve in the treasury for as long as the trustline is open.")
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.bg)
        .navigationTitle("Hold an asset")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { onDone() }
            }
        }
    }
}

/// Where a transaction signed in someone's own wallet comes back.
///
/// The screen is explicit that only the signature is taken. A wallet —
/// or anything between here and it — can hand back a correctly-signed
/// envelope for a *different* payment, and the app would happily store
/// it if it adopted what it was given. It doesn't: the transaction in
/// the pasted envelope is thrown away, and the signature is checked
/// against the hash this device computed from the proposal it already
/// holds.
struct PasteSignedTransactionView: View {
    @Bindable var flow: TreasuryProposalsFlow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    LargeTitle("Bring the signature back")
                    Text("If your wallet sent the transaction itself, there's nothing to do here \u{2014} it will show up in the treasury's history shortly. Otherwise paste what it gave you.")
                        .font(OnymType.font(size: 15))
                        .foregroundStyle(OnymTokens.text2)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)

                SectionLabel("SIGNED TRANSACTION")
                Card {
                    TextEditor(text: $flow.pastedXDR)
                        .font(OnymType.mono(size: 12))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("treasury.paste.field")
                }
                Footnote("Only your signature is taken from this. The transaction itself is discarded and the signature is checked against the proposal already on this device \u{2014} so a wallet that hands back something different simply won't count.")

                PrimaryButton("Add my signature", disabled: flow.pastedXDR.isEmpty) {
                    Task { await flow.adoptPasted() }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .accessibilityIdentifier("treasury.paste.submit")

                // Rendered here, not by the parent's alert.
                //
                // `adoptPasted` sets `actionError`, which only the
                // parent surface shows — and that alert is attached
                // *beneath* this sheet, so it cannot present. A wallet
                // handing back a foreign or malformed envelope gave the
                // co-signer silent nothing with the button still live.
                if let error = flow.pasteError {
                    Text(error)
                        .font(OnymType.font(size: 13))
                        .foregroundStyle(OnymTokens.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .accessibilityIdentifier("treasury.paste.error")
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.bg)
        .navigationTitle("Signed elsewhere")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { flow.pasteTargetID = nil }
            }
        }
    }
}
