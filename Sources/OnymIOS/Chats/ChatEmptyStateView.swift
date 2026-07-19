import SwiftUI

/// Rich empty-state shown in a chat thread that has no messages yet.
/// Surfaces the group's invitation message (if any), the member roster
/// (when there's more than just you), and the app's privacy selling
/// points — reusing the same benefit copy as the Chats empty state.
///
/// Hosted by `ChatThreadViewController` in the message-list region
/// (above the composer) via a `UIHostingController` child.
struct ChatEmptyStateView: View {
    let invitationMessage: String?
    /// Member display aliases (already resolved + sorted). More than one
    /// means the group isn't just the creator.
    let memberNames: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("No messages yet. Say hi.")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                    .frame(maxWidth: .infinity, alignment: .center)

                if let invitation = invitationMessage,
                   !invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    section("INVITATION") {
                        Text(invitation)
                            .font(.system(size: 14))
                            .foregroundStyle(OnymTokens.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(14)
                            .background(OnymTokens.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                if memberNames.count > 1 {
                    section("MEMBERS") {
                        Text(memberNames.joined(separator: ", "))
                            .font(.system(size: 14))
                            .foregroundStyle(OnymTokens.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    benefit(
                        icon: "lock.fill",
                        title: "End-to-end encrypted",
                        detail: "Only your group can read what's sent."
                    )
                    benefit(
                        icon: "person.badge.key.fill",
                        title: "No phone number, no email",
                        detail: "Your identity is a key you own — not your contact info."
                    )
                    benefit(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "No central server",
                        detail: "Group membership is anchored on Stellar, not owned by us."
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("chat.empty_state")
    }

    @ViewBuilder
    private func section(_ label: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            content()
        }
    }

    private func benefit(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnymAccent.blue.color)
                .frame(width: 24, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
