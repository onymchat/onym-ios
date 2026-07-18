import SwiftUI

/// Chats tab — root list of groups the user has created. PR-C only
/// supports Tyranny groups; this list is whatever
/// `GroupRepository.snapshots` emits. Tapping a row is a no-op for
/// now (chat screen is a future slice). The empty state is the only
/// entry point to Create Group post-PR-D wiring.
struct ChatsView: View {
    let flow: ChatsFlow
    let identitiesFlow: IdentitiesFlow
    let approveRequestsFlow: ApproveRequestsFlow
    let pendingInvitesFlow: PendingInvitesFlow
    let messageRepository: MessageRepository
    let imageLoader: ChatImageLoader
    let videoLoader: ChatVideoLoader
    let voiceLoader: ChatVoiceLoader
    let sendMessageInteractor: SendMessageInteractor
    let chatReceiptSender: any ChatReceiptSending
    let makeCreateGroupFlow: @MainActor () -> CreateGroupFlow
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow
    let makeJoinFlow: @MainActor (IntroCapability) -> JoinFlow
    let setGroupAvatar: @MainActor (String, Data?) async -> Void

    @State private var showCreateGroup = false
    @State private var showScanner = false
    // Stashed across the scanner's dismissal — presenting the join
    // sheet while the full-screen scanner is still tearing down races
    // SwiftUI's presentation machinery, so we hand off in the cover's
    // `onDismiss` instead. Exactly one is non-nil at a time.
    @State private var scannedCapability: IntroCapability?
    @State private var scannedInvalid = false
    @State private var scanRejected = false
    @State private var joinCapability: IntroCapability?

    var body: some View {
        Group {
            if flow.groups.isEmpty {
                emptyState
            } else {
                groupList
            }
        }
        .navigationTitle(currentIdentityName)
        .toolbar {
            // Identity picker — top-bar leading slot. Always shown so
            // the user can switch identities even from the empty state.
            ToolbarItem(placement: .topBarLeading) {
                IdentityPickerMenu(flow: identitiesFlow)
            }
            // Pending join requests — always rendered so the surface
            // is discoverable even before the first request lands;
            // the badge only appears when `pending.count > 0`.
            ToolbarItem(placement: .topBarTrailing) {
                ApproveRequestsToolbarButton(flow: approveRequestsFlow)
            }
            // Invitations received by this identity (push offers). Same
            // always-rendered + badge-on-nonempty treatment.
            ToolbarItem(placement: .topBarTrailing) {
                PendingInvitesToolbarButton(flow: pendingInvitesFlow)
            }
            // Scan-to-join — the joiner-side counterpart to the host's
            // invite QR (shown from Group Settings). Always available so
            // a brand-new user can scan their way into a first group
            // without a chat of their own yet.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                }
                .accessibilityLabel("Scan invite QR")
                .accessibilityIdentifier("chats.scan_join_toolbar")
            }
            // Plus button mirrors iOS Mail / Messages — useful once
            // the user already has at least one chat. Hidden in the
            // empty state because the central CTA already covers it.
            if !flow.groups.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateGroup = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityIdentifier("chats.create_group_toolbar")
                }
            }
        }
        .task { flow.start() }
        .task { await identitiesFlow.start() }
        .task { await approveRequestsFlow.start() }
        .task { await pendingInvitesFlow.start() }
        .fullScreenCover(isPresented: $showCreateGroup) {
            CreateGroupViewHost(
                makeFlow: makeCreateGroupFlow,
                makeShareInviteFlow: makeShareInviteFlow,
                onClose: { showCreateGroup = false }
            )
        }
        .fullScreenCover(isPresented: $showScanner, onDismiss: handleScannerDismiss) {
            QRCodeScannerView(
                onScanned: { raw in
                    // Same allowlist + decode the deeplink path uses, so
                    // a scanned link and a tapped link reach JoinView
                    // identically. A non-invite QR yields nil → reject.
                    if let cap = DeeplinkCapture.introCapability(fromString: raw) {
                        scannedCapability = cap
                    } else {
                        scannedInvalid = true
                    }
                    showScanner = false
                },
                onCancel: { showScanner = false }
            )
        }
        .sheet(item: $joinCapability) { cap in
            JoinView(
                flow: makeJoinFlow(cap),
                onClose: { joinCapability = nil }
            )
        }
        .alert("Not an Onym invite", isPresented: $scanRejected) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That QR code isn't an Onym group invite. Ask the host to show the invite QR from the group's member list.")
        }
    }

    /// Hands off the scan result once the full-screen scanner has fully
    /// dismissed — see the `joinCapability`/`scannedCapability` note above.
    private func handleScannerDismiss() {
        if let cap = scannedCapability {
            scannedCapability = nil
            joinCapability = cap
        } else if scannedInvalid {
            scannedInvalid = false
            scanRejected = true
        }
    }

    /// "Chats" when no identity exists yet (pre-bootstrap), otherwise
    /// the active identity's display name. SwiftUI re-renders on every
    /// `currentID` change because `identitiesFlow` is `@Observable`.
    private var currentIdentityName: String {
        guard let id = identitiesFlow.currentID,
              let summary = identitiesFlow.identities.first(where: { $0.id == id })
        else { return "Chats" }
        return summary.name
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 88, height: 88)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 6) {
                Text("No chats yet")
                    .font(.title3.weight(.semibold))
                Text("Create an end-to-end encrypted group anchored on Stellar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                showCreateGroup = true
            } label: {
                Text("Create Group")
                    .font(.headline)
                    .frame(maxWidth: 220)
                    .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            .accessibilityIdentifier("chats.create_group_empty_cta")
            Button {
                showScanner = true
            } label: {
                Label("Scan a QR to join", systemImage: "qrcode.viewfinder")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("chats.scan_join_empty_cta")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Populated list

    private var groupList: some View {
        List(flow.groups) { group in
            NavigationLink(value: group.id) {
                ChatsRow(group: group)
            }
            .listRowSeparator(.visible)
        }
        .listStyle(.plain)
        .navigationDestination(for: String.self) { groupID in
            // PR 5 of the chat stack: tapping a group opens the
            // UIKit chat thread instead of the members roster. The
            // thread's info button pushes `ChatMembersView` from
            // there, so the existing surface is still reachable —
            // just one tap deeper.
            ChatThreadView(
                groupID: groupID,
                chatsFlow: flow,
                identitiesFlow: identitiesFlow,
                messageRepository: messageRepository,
                sendMessageInteractor: sendMessageInteractor,
                chatReceiptSender: chatReceiptSender,
                makeShareInviteFlow: makeShareInviteFlow,
                setGroupAvatar: setGroupAvatar,
                imageLoader: imageLoader,
                videoLoader: videoLoader,
                voiceLoader: voiceLoader
            )
        }
    }
}

private struct ChatsRow: View {
    let group: ChatGroup

    var body: some View {
        HStack(spacing: 12) {
            // Group photo when set, else the broken-ring brand mark —
            // same identity the user saw on the Create Group hero.
            OnymGroupAvatar(
                size: 44,
                accent: OnymAccent.blue.color,
                ringPulse: false,
                spinning: false,
                brand: false,
                imageData: group.avatarJPEG
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name.isEmpty ? "(Unnamed)" : group.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if group.isPublishedOnChain {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Color.green)
                    .accessibilityLabel("Published on chain")
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("chats.row.\(group.id)")
    }

    private var subtitle: String {
        let count = group.memberProfiles.count
        let memberText: String?
        switch count {
        case 0:  memberText = nil
        case 1:  memberText = "1 member"
        default: memberText = "\(count) members"
        }
        let parts = [group.groupType.label.capitalized, memberText].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

private extension SEPGroupType {
    /// Display-friendly label for the row subtitle. Matches
    /// `OnymUIGovernance.label` but doesn't need the no-break hyphen
    /// treatment here.
    var label: String {
        switch self {
        case .anarchy:   "Anarchy"
        case .oneOnOne:  "1-on-1"
        case .democracy: "Democracy"
        case .oligarchy: "Oligarchy"
        case .tyranny:   "Founder"
        }
    }
}
