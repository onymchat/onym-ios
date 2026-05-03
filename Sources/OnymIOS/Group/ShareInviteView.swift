import SwiftUI

/// Post-create surface. The just-created group is identified by hex
/// `groupID`; the flow resolves it from the repository, mints a
/// fresh deeplink capability, and surfaces the link. The user
/// shares via the system share sheet, copies it, or skips.
///
/// Mints exactly once per screen entry — re-entry (after Done →
/// back) re-mints with a fresh intro keypair so the previous share
/// stays revocable independently.
struct ShareInviteView: View {
    let groupID: String
    @Bindable var flow: ShareInviteFlow
    let onDone: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 16) {
                    Spacer().frame(height: 16)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(OnymTokens.green)
                    Text("Your group is ready")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(OnymTokens.text)
                    Text(
                        "Share this link with the people you want to invite. " +
                        "You'll see and approve each request before they join."
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                    stateBody
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            footer
        }
        .background(OnymTokens.bg)
        .onAppear { flow.mintFor(groupID: groupID) }
    }

    private var topBar: some View {
        HStack {
            Spacer().frame(width: 60)
            Spacer()
            Text("Invite")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Spacer()
            Button("Done", action: onDone)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.text2)
                .accessibilityIdentifier("share_invite.done_button")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var stateBody: some View {
        switch flow.state {
        case .idle, .minting:
            ProgressView()
                .controlSize(.large)
                .padding(.top, 24)
                .accessibilityIdentifier("share_invite.minting")
        case .ready(let link, let groupName):
            VStack(spacing: 12) {
                ShareLink(
                    item: link,
                    subject: Text(groupName ?? "Onym invite"),
                    message: Text(IntroCapability.shareText(link: link, groupName: groupName))
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share invite link")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(OnymAccent.blue.color)
                    .foregroundStyle(OnymTokens.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("share_invite.share_button")

                Button {
                    UIPasteboard.general.string = link
                    copied = true
                } label: {
                    Text(copied ? "Copied!" : "Copy invite link")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(OnymTokens.surface2)
                        .foregroundStyle(OnymTokens.text)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(OnymTokens.hairline, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("share_invite.copy_button")
            }
            .padding(.top, 24)
        case .failed(let reason):
            VStack(spacing: 12) {
                Text("Couldn't generate an invite: \(reason)")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Button("Retry") {
                    flow.mintFor(groupID: groupID)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("share_invite.retry_button")
            }
            .padding(.top, 24)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: onDone) {
                Text("I'll do this later")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
            }
            .accessibilityIdentifier("share_invite.skip_button")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .background(OnymTokens.bg)
    }
}
