import SwiftUI

/// Placeholder destination for inbound `https://onym.chat/join?c=…`
/// deeplinks. **PR-7 will replace this** with a real `JoinView` +
/// `JoinFlow` that ships the actual join request via
/// `JoinRequestSender` and watches for the sealed invitation to
/// arrive. PR-6's job is just to prove the deeplink wiring works
/// end-to-end (tap a link → land on a screen that knows the
/// capability).
///
/// Renders the inviter's intro pubkey hex prefix + group_id hex
/// prefix so a manual tester can confirm the right capability was
/// decoded from the URL. No interaction wired beyond Back.
struct JoinInviteCapturedPlaceholderView: View {
    let capability: IntroCapability
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 16) {
                    Spacer().frame(height: 24)
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(OnymAccent.blue.color)
                    Text(capability.groupName ?? "Join invite")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(OnymTokens.text)
                    Text("Capability captured. The full join flow lands in PR-7.")
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.text2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    diagnostics
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
        }
        .background(OnymTokens.bg)
    }

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.text2)
            }
            .accessibilityIdentifier("join_invite.back_button")
            Spacer()
            Text("Join invite")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Spacer()
            Spacer().frame(width: 60)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("intro_pub", value: hexPrefix(capability.introPublicKey))
            row("group_id", value: hexPrefix(capability.groupId))
            if let name = capability.groupName, !name.isEmpty {
                row("group_name", value: name)
            }
        }
        .padding(14)
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func row(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(OnymTokens.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hexPrefix(_ data: Data, count: Int = 8) -> String {
        let prefix = data.prefix(count)
        return prefix.map { String(format: "%02x", $0) }.joined() + "…"
    }
}
