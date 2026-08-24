import SwiftUI
import OnymDesign
import OnymIdentity

/// Full-screen "Invite Key" sheet — large QR centred on a card, with
/// the truncated BLS fingerprint, the underlying URL, and Copy / Share
/// split actions. Reuses `SettingsQRCode` for the centred-Onym-mark
/// QR rendering.
public struct ShareKeyView: View {
    let identity: IdentitySummary
    let blsPrefix: String

    @Environment(\.dismiss) private var dismiss

    public init(identity: IdentitySummary, blsPrefix: String) {
        self.identity = identity
        self.blsPrefix = blsPrefix
    }

    private var inviteURL: String {
        settingsInviteURL(blsPublicKey: identity.inboxPublicKey)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 14) {
                    SettingsQRCode(value: inviteURL, size: 260)
                        .padding(14)
                        .background(OnymTokens.surface2,
                                    in: RoundedRectangle(cornerRadius: OnymRadius.panel, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: OnymRadius.panel, style: .continuous)
                            .stroke(OnymTokens.hairline, lineWidth: 1))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)

                    HStack(spacing: 8) {
                        IdentityRingTile(active: true, size: 28)
                        Text(identity.name)
                            .font(OnymType.font(size: 17, weight: .semibold))
                            .foregroundStyle(OnymTokens.text)
                    }

                    Text("BLS \(blsPrefix)…")
                        .font(OnymType.mono(size: 12))
                        .foregroundStyle(OnymTokens.text2)

                    Text(inviteURL)
                        .font(OnymType.mono(size: 12))
                        .foregroundStyle(OnymTokens.text2)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(OnymTokens.surface3,
                                    in: RoundedRectangle(cornerRadius: OnymRadius.control))
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(OnymTokens.surface2,
                            in: RoundedRectangle(cornerRadius: OnymRadius.panel, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = inviteURL
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy link")
                                .font(OnymType.font(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(OnymAccent.blue.color)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(OnymAccent.blue.color.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: OnymRadius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("share_key.copy_button")

                    ShareLink(item: inviteURL) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share")
                                .font(OnymType.font(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(OnymTokens.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(OnymAccent.blue.color,
                                    in: RoundedRectangle(cornerRadius: OnymRadius.card, style: .continuous))
                    }
                    .accessibilityIdentifier("share_key.share_button")
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                SettingsFootnote("Anyone who scans this code with Onym can start a private, end-to-end encrypted chat with \(identity.name). The invite key contains your inbox X25519 public key only — no contact info.")
            }
            .padding(.bottom, 24)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Invite Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
