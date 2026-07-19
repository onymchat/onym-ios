import SwiftUI

/// Settings → Anchors → ... → Use existing address. Lets the user
/// paste a Stellar Soroban contract ID (uppercase 56-char `C…`),
/// check its format, optionally label it, and pin it for new chats.
///
/// "Check format" is a client-side address-shape check only — the app
/// has no direct Soroban RPC path (all chain traffic goes through the
/// relayer's allowlisted calls), so it can't inspect the contract's API
/// surface or confirm it exists on-chain. Labeled honestly to avoid
/// implying an on-chain verification it doesn't perform.
struct UseExistingContractView: View {
    let key: AnchorSelectionKey
    @Environment(\.dismiss) private var dismiss

    @State private var addr: String = ""
    @State private var label: String = ""
    @State private var verdict: Verdict?

    enum Verdict: Equatable { case ok, bad }

    private var trimmed: String { addr.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var looksValid: Bool {
        trimmed.count == 56 &&
            trimmed.first == "C" &&
            trimmed == trimmed.uppercased() &&
            trimmed.allSatisfy { $0.isLetter || $0.isNumber }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroCard

                SettingsSectionLabel("STELLAR CONTRACT ADDRESS")
                SettingsCard {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $addr)
                            .font(.system(size: 14, design: .monospaced))
                            .frame(minHeight: 72)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("anchors.use_existing.field")
                            .onChange(of: addr) { _, v in
                                let cleaned = v.replacingOccurrences(of: " ", with: "").uppercased()
                                if cleaned != addr { addr = cleaned }
                                verdict = nil
                            }

                        if !addr.isEmpty {
                            HStack(spacing: 8) {
                                SettingsChip(
                                    text: looksValid ? "Valid format" : "\(addr.count)/56 chars",
                                    fg: looksValid ? OnymTokens.green : OnymTokens.red,
                                    bg: looksValid
                                        ? OnymTokens.green.opacity(0.14)
                                        : OnymTokens.red.opacity(0.14)
                                )
                                Text("Stellar Soroban contract ID")
                                    .font(.system(size: 11))
                                    .foregroundStyle(OnymTokens.text3)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }

                SettingsSectionLabel("LABEL")
                SettingsCard {
                    TextField("My fork v0.0.5", text: $label)
                        .font(.system(size: 16))
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .accessibilityIdentifier("anchors.use_existing.label_field")
                        .onChange(of: label) { _, v in
                            if v.count > 30 { label = String(v.prefix(30)) }
                        }
                }
                SettingsFootnote("Shown alongside the contract address in chats and on the Anchors list.")

                SettingsPrimaryButton(
                    disabled: !looksValid,
                    action: {
                        if verdict == .ok { dismiss() } else { verify() }
                    }
                ) {
                    Text(verdict == .ok ? "Use this contract" : "Check format")
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .accessibilityIdentifier("anchors.use_existing.cta")

                if verdict == .ok { verifiedBanner }
                if verdict == .bad {
                    Text("Address format invalid. Expected 56 chars starting with C.")
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.red)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }

                SettingsSectionLabel("HOW TO FIND IT")
                SettingsCard {
                    SettingsRow(
                        title: "Browse on Stellar Expert",
                        subtitle: "stellar.expert",
                        hasChevron: false,
                        onTap: {
                            // Single host; network is a path segment.
                            let net = key.network == .testnet ? "testnet" : "public"
                            open("https://stellar.expert/explorer/\(net)")
                        }
                    ) {
                        SettingsContentTile(bg: SettingsTile.indigo) {
                            Text("SX").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        }
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                    SettingsRow(
                        title: "Soroban CLI",
                        subtitle: "soroban contract id …",
                        subtitleMono: true,
                        hasChevron: false,
                        last: true,
                        onTap: { open("https://developers.stellar.org/docs/build/smart-contracts/getting-started/setup") }
                    ) {
                        SettingsIconTile(symbol: "terminal.fill", bg: SettingsTile.gray)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle(Text(verbatim: "Use existing · \(key.type.displayName)"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var heroCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.898, green: 0.898, blue: 0.996),
                                                Color(red: 0.78, green: 0.78, blue: 0.957)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "shippingbox.fill")
                    .foregroundStyle(SettingsTile.indigo))
            VStack(alignment: .leading, spacing: 3) {
                Text("Bring your own contract")
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text("Anchor new \(key.type.displayName.lowercased()) chats on a Stellar contract you’ve already deployed.")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                    .lineSpacing(2)
            }
        }
        .padding(18)
        .background(OnymTokens.surface2,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var verifiedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(OnymTokens.green).frame(width: 22, height: 22)
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Address format looks valid")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.09, green: 0.37, blue: 0.18))
                Text("This checks the address shape only, not the on-chain contract. Tap “Use this contract” to anchor new \(key.type.displayName.lowercased()) chats here; existing chats keep their current contract.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.19, green: 0.43, blue: 0.28))
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(OnymTokens.green.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// A client-side address-format check only — no network / on-chain
    /// inspection (the app has no direct RPC path). Instant.
    private func verify() {
        verdict = looksValid ? .ok : .bad
    }

    private func open(_ s: String) {
        guard let u = URL(string: s) else { return }
        UIApplication.shared.open(u)
    }
}
