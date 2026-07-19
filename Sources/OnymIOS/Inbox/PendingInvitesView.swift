import SwiftUI

/// Invitee-side "you've been invited" list — the push counterpart to
/// the deeplink `JoinView`. Mirrors `ApproveRequestsView`: a modal of
/// cards, each offering Accept (ship a join request) or Dismiss. Accept
/// is the explicit step; the group only appears once the admin approves
/// the resulting request on chain.
struct PendingInvitesView: View {
    @Bindable var flow: PendingInvitesFlow
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let error = flow.lastError {
                errorBanner(error)
            }
            if flow.pending.isEmpty && flow.verifying.isEmpty {
                emptyState
            } else {
                inviteList
            }
        }
        .background(OnymTokens.bg)
    }

    private var topBar: some View {
        HStack {
            Text("Invitations")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Spacer()
            Button("Done", action: onClose)
                .font(.system(size: 16))
                .foregroundStyle(OnymAccent.blue.color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OnymTokens.red)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text)
            Spacer()
            Button {
                flow.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnymTokens.text2)
            }
        }
        .padding(12)
        .background(OnymTokens.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "envelope.open")
                .font(.system(size: 34))
                .foregroundStyle(OnymTokens.text2)
            Text("No invitations")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OnymTokens.text)
            Text("Group invites you receive show up here for you to accept.")
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inviteList: some View {
        ScrollView {
            VStack(spacing: 12) {
                Spacer().frame(height: 8)
                ForEach(flow.pending) { invite in
                    inviteCard(invite)
                }
                ForEach(flow.verifying) { entry in
                    verifyingCard(entry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    /// A group accepted but not yet verifiable against the current
    /// on-chain state — kept out of the chats list. Shows progress while
    /// waiting for the admin's current-state reply, and a Retry when the
    /// admin couldn't be reached.
    private func verifyingCard(_ entry: PendingGroupVerification) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.groupName.isEmpty ? "Group" : entry.groupName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            switch entry.status {
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Verifying group state\u{2026}")
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.text2)
                }
            case .unreachable:
                Text("Couldn\u{2019}t verify \u{2014} the admin is offline. The group stays hidden until it can be verified on chain.")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                Button {
                    flow.retry(entry.groupIDHex)
                } label: {
                    Text("Retry")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(OnymAccent.blue.color)
                        .foregroundStyle(OnymTokens.onAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(14)
        .background(OnymTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("pending_invites.verifying.\(entry.groupIDHex)")
    }

    private func inviteCard(_ invite: PendingInvite) -> some View {
        let inFlight = flow.isInFlight(invite.id)
        let requested = flow.isRequested(invite.id)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(displayAlias(invite.inviterAlias))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text("invited you to \u{201C}\(invite.groupName ?? "a group")\u{201D}")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
            }
            if let message = invite.invitationMessage,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(OnymTokens.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(OnymTokens.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("pending_invites.message.\(invite.id)")
            }
            HStack(spacing: 8) {
                Button {
                    flow.dismiss(invite.id)
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(OnymTokens.surface3)
                        .foregroundStyle(OnymTokens.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(inFlight)
                Button {
                    flow.accept(invite.id)
                } label: {
                    HStack(spacing: 6) {
                        if inFlight {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(OnymTokens.onAccent)
                                .scaleEffect(0.8)
                        }
                        Text(acceptLabel(inFlight: inFlight, requested: requested))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(OnymAccent.blue.color.opacity(inFlight || requested ? 0.7 : 1.0))
                    .foregroundStyle(OnymTokens.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(inFlight || requested)
            }
        }
        .padding(14)
        .background(OnymTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("pending_invites.card.\(invite.id)")
    }

    private func acceptLabel(inFlight: Bool, requested: Bool) -> String {
        if requested { return "Requested \u{2014} awaiting approval" }
        if inFlight { return "Sending\u{2026}" }
        return "Accept"
    }

    private func displayAlias(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Someone" : trimmed
    }
}

/// Chats-toolbar entry point: an envelope with a count badge, opening
/// the invitations sheet. Always rendered (like the join-requests
/// button) so the surface is discoverable; the badge only shows when
/// there's at least one pending invite.
struct PendingInvitesToolbarButton: View {
    @Bindable var flow: PendingInvitesFlow
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "envelope")
                    .font(.system(size: 17))
                if flow.badgeCount > 0 {
                    Text("\(flow.badgeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(OnymTokens.red))
                        .offset(x: 8, y: -6)
                        .accessibilityIdentifier("pending_invites.toolbar_badge")
                }
            }
        }
        .accessibilityLabel("Invitations")
        .accessibilityIdentifier("pending_invites.toolbar_button")
        .sheet(isPresented: $showSheet) {
            PendingInvitesView(flow: flow, onClose: { showSheet = false })
        }
    }
}
