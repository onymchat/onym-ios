import SwiftUI
import OnymDesign
import OnymIdentity

/// Settings → Privacy & Encryption. Scaffold screen — encryption hero,
/// "How it works" explainers, your-keys summary, and toggles for app
/// lock + read receipts. Hooks into the live `IdentitiesFlow` for the
/// active identity name; the toggles persist locally for now and will
/// move into the relevant repositories when those features land.
struct PrivacyEncryptionView: View {
    @Bindable var identitiesFlow: IdentitiesFlow

    @AppStorage("settings.privacy.readReceipts") private var readReceipts = false
    @AppStorage("settings.privacy.appLock")      private var appLock = true
    @AppStorage("settings.privacy.autoLockMin")  private var autoLockMin = 1

    private let autoLockOptions: [Int] = [0, 1, 5, 15, -1]

    private var activeName: String {
        guard let id = identitiesFlow.currentID,
              let s = identitiesFlow.identities.first(where: { $0.id == id })
        else { return "—" }
        return s.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroCard.padding(.top, 8)

                SettingsSectionLabel("HOW IT WORKS")
                SettingsCard {
                    SettingsRow(
                        title: "End-to-end encryption",
                        subtitle: "MLS · forward secrecy",
                        hasChevron: false
                    ) {
                        SettingsIconTile(symbol: "key.fill", bg: OnymTile.purple)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                    SettingsRow(
                        title: "Anonymous on-chain",
                        subtitle: "No phone, no email, no IP",
                        hasChevron: false
                    ) {
                        SettingsIconTile(symbol: "sparkles", bg: OnymTile.indigo)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                    SettingsRow(
                        title: "Verifiable by anyone",
                        subtitle: "Group state anchored on Stellar",
                        hasChevron: false,
                        last: true
                    ) {
                        SettingsIconTile(symbol: "shield.fill", bg: OnymTile.green)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                }

                SettingsSectionLabel("YOUR KEYS")
                SettingsCard {
                    SettingsRow(
                        title: "Active identity",
                        subtitle: activeName,
                        hasChevron: false
                    ) {
                        IdentityRingTile(active: true, size: 30)
                    } right: {
                        Text("Backed up")
                            .foregroundStyle(OnymTokens.green)
                            .font(OnymType.font(size: 13.5))
                    }
                    SettingsRow(title: "BIP-39 wordlist", hasChevron: false) {
                        SettingsIconTile(symbol: "checkmark", bg: OnymTile.gray)
                    } right: {
                        Text("English").foregroundStyle(OnymTokens.text2).font(OnymType.font(size: 14))
                    }
                    SettingsRow(title: "Identity key", hasChevron: false) {
                        SettingsContentTile(bg: OnymTile.indigo) {
                            Text("npub").font(OnymType.font(size: 9, weight: .bold)).foregroundStyle(.white)
                        }
                    } right: {
                        Text("Nostr (npub)").foregroundStyle(OnymTokens.text2).font(OnymType.font(size: 14))
                    }
                    SettingsRow(title: "Signature scheme", hasChevron: false, last: true) {
                        SettingsContentTile(bg: OnymTile.gray) {
                            Text("BLS").font(OnymType.font(size: 9.5, weight: .bold)).foregroundStyle(.white)
                        }
                    } right: {
                        Text("BLS12-381").foregroundStyle(OnymTokens.text2).font(OnymType.font(size: 14))
                    }
                }
                SettingsFootnote("Your recovery phrase generates a master seed. Onym derives a Nostr keypair (your public identity, shown as npub1…), a Stellar keypair (for anchoring), and a BLS key (for group signatures).")

                SettingsSectionLabel("APP LOCK")
                SettingsCard {
                    SettingsRow(
                        title: "Require Face ID",
                        subtitle: "Unlock Onym with biometrics",
                        hasChevron: false
                    ) {
                        SettingsIconTile(symbol: "faceid", bg: OnymTile.gray)
                    } right: {
                        Toggle("", isOn: $appLock)
                            .labelsHidden()
                            .tint(OnymTokens.green)
                            .accessibilityIdentifier("privacy.app_lock")
                    }
                    SettingsRow(
                        title: "Auto-lock",
                        inset: 16,
                        last: true,
                        onTap: {
                            let i = autoLockOptions.firstIndex(of: autoLockMin) ?? 0
                            autoLockMin = autoLockOptions[(i + 1) % autoLockOptions.count]
                        }
                    ) {
                        EmptyView()
                    } right: {
                        Text(autoLockLabel(autoLockMin))
                            .foregroundStyle(OnymTokens.text2)
                            .font(OnymType.font(size: 14))
                    }
                }

                SettingsSectionLabel("METADATA")
                SettingsCard {
                    SettingsRow(
                        title: "Send read receipts",
                        subtitle: "Show others when you’ve read their messages",
                        hasChevron: false,
                        last: true
                    ) {
                        SettingsIconTile(symbol: "checkmark.circle.fill", bg: OnymTile.blue)
                    } right: {
                        Toggle("", isOn: $readReceipts)
                            .labelsHidden()
                            .tint(OnymTokens.green)
                            .accessibilityIdentifier("privacy.read_receipts")
                    }
                }
                SettingsFootnote("Read receipts are end-to-end encrypted, but they reveal you’re online. Turn off for stricter privacy.")
                // The DATA section (Clear local message cache) moved to the
                // Settings home, above About, where it does real work.
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Privacy & Encryption")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func autoLockLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0:  return "Immediately"
        case -1: return "Never"
        case 1:  return "After 1 min"
        default: return "After \(minutes) min"
        }
    }

    private var heroCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: OnymRadius.card, style: .continuous)
                .fill(LinearGradient(colors: [OnymTint.greenSoft,
                                                OnymTint.greenSoft2],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .overlay(RoundedRectangle(cornerRadius: OnymRadius.card, style: .continuous)
                    .stroke(OnymTokens.green.opacity(0.35), lineWidth: 1.5))
                .overlay(Image(systemName: "lock.shield.fill")
                    .font(OnymType.font(size: 28))
                    .foregroundStyle(OnymTokens.green))
            VStack(alignment: .leading, spacing: 3) {
                Text("Everything is encrypted")
                    .font(OnymType.font(size: 17, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text("Messages, group state, and keys are encrypted on this device. No one — not even Onym — can read your chats.")
                    .font(OnymType.font(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                    .lineSpacing(2)
            }
        }
        .padding(18)
        .background(OnymTokens.surface2,
                    in: RoundedRectangle(cornerRadius: OnymRadius.panel, style: .continuous))
        .padding(.horizontal, 16)
    }
}
