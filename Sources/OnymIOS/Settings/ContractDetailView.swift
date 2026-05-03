import SwiftUI

/// Settings → Anchors → Network → Governance → Version → ContractDetail.
/// Read-only view of one published contract release: shows on-chain
/// pointers (Stellar Expert link, contract address) and source
/// pointers (GitHub source at the tag, audit report). The "Use this
/// version" CTA at the bottom calls `flow.tappedVersion` so the
/// existing `AnchorsPickerFlow` machinery records the selection,
/// then pops back two levels.
struct ContractDetailView: View {
    @Bindable var flow: AnchorsPickerFlow
    let key: AnchorSelectionKey
    let release: ContractRelease

    @Environment(\.dismiss) private var dismiss

    private static let contractsRepoURL = URL(string: "https://github.com/onymchat/onym-contracts")!

    private var entry: ContractEntry? {
        release.contracts.first { $0.network == key.network && $0.type == key.type }
    }

    private var auditLabel: String { "Pending — no audits yet" }

    private var explorerURL: URL? {
        guard let entry else { return nil }
        let host = key.network == .testnet ? "testnet.stellar.expert" : "stellar.expert"
        let net  = key.network == .testnet ? "testnet" : "public"
        return URL(string: "https://\(host)/explorer/\(net)/contract/\(entry.id)")
    }

    private var isCurrentSelection: Bool {
        flow.binding(for: key)?.release == release.release
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero

                SettingsSectionLabel("ON-CHAIN")
                SettingsCard {
                    SettingsRow(
                        title: "Stellar Expert",
                        subtitle: explorerSubtitle,
                        subtitleMono: true,
                        hasChevron: false,
                        onTap: explorerURL.map { url in { open(url.absoluteString) } }
                    ) {
                        SettingsContentTile(bg: SettingsTile.indigo) {
                            Text("SX").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        }
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                    .accessibilityIdentifier("contract_detail.stellar_expert")

                    SettingsRow(
                        title: "Copy contract address",
                        hasChevron: false,
                        last: true,
                        onTap: entry.map { e in { UIPasteboard.general.string = e.id } }
                    ) {
                        SettingsIconTile(symbol: "doc.on.doc.fill", bg: SettingsTile.gray)
                    }
                    .accessibilityIdentifier("contract_detail.copy_address")
                }

                SettingsSectionLabel("SOURCE")
                SettingsCard {
                    SettingsRow(
                        title: "View source on GitHub",
                        subtitle: "onymchat/onym-contracts @ \(release.release)",
                        subtitleMono: true,
                        hasChevron: false,
                        onTap: { open(Self.contractsRepoURL.absoluteString + "/tree/\(release.release)") }
                    ) {
                        SettingsIconTile(symbol: "chevron.left.forwardslash.chevron.right",
                                         bg: OnymTokens.text)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                    .accessibilityIdentifier("contract_detail.github")

                    SettingsRow(
                        title: "Audit report",
                        subtitle: auditLabel,
                        hasChevron: false,
                        last: true
                    ) {
                        SettingsIconTile(symbol: "exclamationmark.circle.fill",
                                         bg: SettingsTile.amber)
                    }
                    .accessibilityIdentifier("contract_detail.audit")
                }

                SettingsFootnote("This is the contract that anchors \(key.type.displayName.lowercased()) groups created on \(key.network.displayName.lowercased()). Existing chats keep the contract they were created with — picking a different version only affects new chats.")

                SettingsPrimaryButton(
                    isCurrentSelection ? "Currently selected" : "Use this version",
                    disabled: isCurrentSelection
                ) {
                    flow.tappedVersion(key: key, releaseTag: release.release)
                    dismiss()
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .accessibilityIdentifier("contract_detail.use_version")
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle(Text(verbatim: release.release))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.996, green: 0.941, blue: 0.878),
                                                Color(red: 1.0, green: 0.878, blue: 0.753)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .overlay(OnymMark(size: 32, color: Color(red: 0.82, green: 0.29, blue: 0)))
            VStack(alignment: .leading, spacing: 2) {
                Text("CONTRACT · \(key.type.displayName.uppercased())")
                    .font(.system(size: 11.5, weight: .medium))
                    .tracking(0.46)
                    .foregroundStyle(OnymTokens.text2)
                Text(release.release)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .tracking(-0.26)
                    .foregroundStyle(OnymTokens.text)
                Text("Deployed \(release.publishedAt.formatted(date: .abbreviated, time: .omitted)) · \(auditLabel)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(OnymTokens.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(OnymTokens.surface2,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var explorerSubtitle: String {
        guard let entry else { return "—" }
        let head = entry.id.prefix(6)
        let tail = entry.id.suffix(4)
        return "\(head)…\(tail)"
    }

    private func open(_ s: String) {
        guard let u = URL(string: s) else { return }
        UIApplication.shared.open(u)
    }
}
