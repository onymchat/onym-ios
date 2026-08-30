import SwiftUI
import OnymDesign

/// Post-create surface. The just-created group is identified by hex
/// `groupID`; the flow resolves it from the repository, resolves the
/// group's deeplink capability, and surfaces the link. The user
/// shares via the system share sheet, copies it, or skips.
///
/// Reuses the group's link instead of minting per entry, so a QR
/// already screenshotted keeps working. "Generate new link" is the
/// only thing that rotates it.
public struct ShareInviteView: View {
    let groupID: String
    @Bindable var flow: ShareInviteFlow
    let onDone: () -> Void

    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    public init(groupID: String, flow: ShareInviteFlow, onDone: @escaping () -> Void) {
        self.groupID = groupID
        self.flow = flow
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 16) {
                    Spacer().frame(height: 16)
                    Image(systemName: "checkmark.seal.fill")
                        .font(OnymType.font(size: 48))
                        .foregroundStyle(OnymTokens.green)
                    Text("Your group is ready")
                        .font(OnymType.font(size: 20, weight: .bold))
                        .foregroundStyle(OnymTokens.text)
                    Text(
                        "Share this link with the people you want to invite. " +
                        "You'll see and approve each request before they join."
                    )
                    .font(OnymType.font(size: 13))
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

    /// Rotate. The only way a leaked link stops working, framed as
    /// generate-a-new-one so the user always holds a working link.
    private var rotateButton: some View {
        Button {
            copied = false
            flow.rotateLink(groupID: groupID)
        } label: {
            HStack(spacing: 8) {
                if flow.isRotating {
                    ProgressView().controlSize(.small)
                }
                Text(flow.isRotating ? "Generating…" : "Generate new link")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(OnymTokens.text2)
        }
        .disabled(flow.isRotating)
        .accessibilityIdentifier("share_invite.rotate_button")
        .overlay(alignment: .bottom) {
            Text("The old link stops working. Anyone still holding it won't be told.")
                .font(OnymType.font(size: 11))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .offset(y: 16)
        }
        .padding(.bottom, 20)
    }

    /// The create-time offers, one per invitee. Nothing expires, so
    /// this list is the only way they are ever retired.
    @ViewBuilder
    private var otherInvitesSection: some View {
        if !flow.otherInvites.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Direct invites")
                    .font(OnymType.font(size: 13, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text("Sent when you created the group. Each one can still be used to request to join.")
                    .font(OnymType.font(size: 11))
                    .foregroundStyle(OnymTokens.text2)

                ForEach(flow.otherInvites) { row in
                    HStack {
                        // A literal key so it localizes; a String
                        // variable would render verbatim.
                        if let label = row.label {
                            Text(label)
                                .font(OnymType.mono(size: 13))
                                .foregroundStyle(OnymTokens.text)
                        } else {
                            Text("Older link")
                                .font(OnymType.font(size: 13))
                                .foregroundStyle(OnymTokens.text)
                        }
                        Spacer()
                        Button("Revoke") {
                            flow.revoke(row, groupID: groupID)
                        }
                        .font(OnymType.font(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                        // Keyed on the intro pubkey, not the label: two
                        // invitees can share a 4-byte fingerprint (or be
                        // the same person invited twice), and duplicate
                        // ids leave the user unable to tell which Revoke
                        // kills which link.
                        .accessibilityIdentifier(
                            "share_invite.revoke_button.\(row.id.prefix(8).map { String(format: "%02x", $0) }.joined())"
                        )
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(OnymTokens.surface2,
                                in: RoundedRectangle(cornerRadius: OnymRadius.inset, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("share_invite.other_invites")
        }
    }

    private var topBar: some View {
        // The title is centred on the bar, not balanced against a
        // guessed-at 60pt spacer on one side and a Done button of
        // whatever width on the other — that arrangement put "Invite"
        // left of centre, and moved it again in any language where Done
        // is a longer word. Overlaying the two lets each sit where it
        // belongs.
        ZStack {
            Text("Invite")
                .font(OnymType.font(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .font(OnymType.font(size: 14, weight: .semibold))
                    .foregroundStyle(OnymTokens.text2)
                    .accessibilityIdentifier("share_invite.done_button")
            }
        }
        .padding(.horizontal, 16)
        // Clear of the sheet's grabber, which sat right on top of the
        // old 6pt.
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var stateBody: some View {
        switch flow.state {
        case .idle, .minting:
            ProgressView()
                .controlSize(.large)
                .padding(.top, 24)
                .accessibilityIdentifier("share_invite.minting")
        case .ready(let link, _):
            VStack(spacing: 12) {
                SettingsQRCode(value: link, size: 220)
                    .padding(14)
                    .background(OnymTokens.surface2,
                                in: RoundedRectangle(cornerRadius: OnymRadius.panel, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: OnymRadius.panel, style: .continuous)
                        .stroke(OnymTokens.hairline, lineWidth: 1))
                    .accessibilityIdentifier("share_invite.qr_code")

                Text("Have them scan this with their camera to join.")
                    .font(OnymType.font(size: 12))
                    .foregroundStyle(OnymTokens.text2)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 4)

                // Share ONLY the plain link — no `message:` (a second,
                // group-name-decorated item), so the share sheet hands off
                // a single item.
                ShareLink(item: link) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share invite link")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(OnymAccent.blue.color)
                    .foregroundStyle(OnymTokens.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: OnymRadius.inset))
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
                            RoundedRectangle(cornerRadius: OnymRadius.inset)
                                .stroke(OnymTokens.hairline, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: OnymRadius.inset))
                }
                .accessibilityIdentifier("share_invite.copy_button")
                #if DEBUG
                // Expose the raw invite link to UI tests via the
                // accessibility tree so they can read it WITHOUT the
                // system "paste from …" prompt that a UIPasteboard read
                // triggers. DEBUG-only so VoiceOver never reads the raw
                // capability aloud in Release.
                .accessibilityValue(link)
                #endif

                rotateButton
                otherInvitesSection
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
                    .font(OnymType.font(size: 13))
                    .foregroundStyle(OnymTokens.text2)
            }
            .accessibilityIdentifier("share_invite.skip_button")
        }
        // Full width, or the bar is only as wide as the words in it —
        // which the old same-colour background hid and a shadow does
        // not: it drew a floating panel around "I'll do this later".
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
        // Opaque, with a soft shadow cast upward: the QR and the share
        // button scroll under this bar, and without an edge the button
        // simply ended mid-stroke as though it had been cropped.
        .background {
            Rectangle()
                .fill(OnymTokens.bg)
                .shadow(color: footerShadow, radius: 5, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// A dark shadow separates nothing on a dark page — the footer's
    /// fill and the page behind it are the same token — so the edge is
    /// lifted with light there instead.
    private var footerShadow: Color {
        colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.10)
    }
}
