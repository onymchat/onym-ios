import SwiftUI
import OnymDesign
import OnymChain
import OnymIdentity
import OnymIdentityUI
import OnymGroup
import OnymChatsCore
import OnymInbox
import OnymModeration

/// Chats tab — root list of groups the user has created. PR-C only
/// supports Tyranny groups; this list is whatever
/// `GroupRepository.snapshots` emits. Tapping a row is a no-op for
/// now (chat screen is a future slice). The empty state is the only
/// entry point to Create Group post-PR-D wiring.
public struct ChatsView: View {
    let flow: ChatsFlow
    let identitiesFlow: IdentitiesFlow
    let approveRequestsFlow: ApproveRequestsFlow
    let pendingChatsFlow: PendingChatsFlow
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
    let setGroupName: @MainActor (String, String) async -> Void
    let makeModerationReportView: @MainActor (ReportableMessage) -> AnyView

    public init(
        flow: ChatsFlow,
        identitiesFlow: IdentitiesFlow,
        approveRequestsFlow: ApproveRequestsFlow,
        pendingChatsFlow: PendingChatsFlow,
        messageRepository: MessageRepository,
        imageLoader: ChatImageLoader,
        videoLoader: ChatVideoLoader,
        voiceLoader: ChatVoiceLoader,
        sendMessageInteractor: SendMessageInteractor,
        chatReceiptSender: any ChatReceiptSending,
        makeCreateGroupFlow: @escaping @MainActor () -> CreateGroupFlow,
        makeShareInviteFlow: @escaping @MainActor () -> ShareInviteFlow,
        makeJoinFlow: @escaping @MainActor (IntroCapability) -> JoinFlow,
        setGroupAvatar: @escaping @MainActor (String, Data?) async -> Void,
        setGroupName: @escaping @MainActor (String, String) async -> Void,
        makeModerationReportView: @escaping @MainActor (ReportableMessage) -> AnyView
    ) {
        self.flow = flow
        self.identitiesFlow = identitiesFlow
        self.approveRequestsFlow = approveRequestsFlow
        self.pendingChatsFlow = pendingChatsFlow
        self.messageRepository = messageRepository
        self.imageLoader = imageLoader
        self.videoLoader = videoLoader
        self.voiceLoader = voiceLoader
        self.sendMessageInteractor = sendMessageInteractor
        self.chatReceiptSender = chatReceiptSender
        self.makeCreateGroupFlow = makeCreateGroupFlow
        self.makeShareInviteFlow = makeShareInviteFlow
        self.makeJoinFlow = makeJoinFlow
        self.setGroupAvatar = setGroupAvatar
        self.setGroupName = setGroupName
        self.makeModerationReportView = makeModerationReportView
    }

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
    /// The chat awaiting a swipe-to-delete confirmation, if any.
    @State private var pendingDelete: ChatListItem?

    public var body: some View {
        Group {
            // The pitch only stands in for an empty list. A chat the
            // user is waiting to be let into is not an empty list — it
            // is the first chat, mid-arrival — so a pending row keeps
            // the pitch away.
            if rows.isEmpty {
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
            // Join requests used to live behind a badged button here,
            // opening a modal list. New users never found it — nothing
            // in the conversation told them someone was waiting. They now
            // render as a row inside the group's own thread, surfaced on
            // the list row itself (see `pendingJoinRequestCounts`), so
            // there is no separate surface to discover.
            // `approveRequestsFlow` is still started below: it collects
            // the requests both of those read.

            // Invitations used to live behind a badged envelope here,
            // opening a modal list of offers. There is no such surface
            // any more: an offer, and a join we have asked for, are rows
            // in the list below like any other chat — see `rows`.
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
            if !rows.isEmpty {
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
        .task { await pendingChatsFlow.start() }
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
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 96, height: 96)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.bottom, 20)

            // Lead with the value, not "you have nothing" — turn the empty
            // state into a pitch for starting the first chat.
            Text("Start a private chat")
                .font(.title2.weight(.bold))
            Text("Spin up an encrypted group and share one link — that's it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 16) {
                benefitRow(
                    icon: "lock.fill",
                    title: "End-to-end encrypted",
                    detail: "Only your group can read what's sent."
                )
                benefitRow(
                    icon: "person.badge.key.fill",
                    title: "No phone number, no email",
                    detail: "Your identity is a key you own — not your contact info."
                )
                benefitRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "No central server",
                    detail: "Group membership is anchored on Stellar, not owned by us."
                )
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)

            Button {
                showCreateGroup = true
            } label: {
                Text("Create a group & share a link")
                    .font(.headline)
                    .frame(maxWidth: 300)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 32)
            .accessibilityIdentifier("chats.create_group_empty_cta")

            Button {
                showScanner = true
            } label: {
                Label("Scan a QR to join", systemImage: "qrcode.viewfinder")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            .padding(.top, 18)
            .accessibilityIdentifier("chats.scan_join_empty_cta")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One privacy-benefit line in the empty state: accent icon + a bold
    /// title over a muted one-line detail.
    private func benefitRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Populated list

    /// Pending join requests per group id, for the chat-list signal.
    ///
    /// Removing the toolbar badge took away the *only* ambient hint that
    /// someone was waiting. A request isn't a `ChatMessage`, so it moves
    /// no `chatListPreview`, and the "X joined" notice it eventually
    /// becomes is deliberately excluded from `unreadCount` — so without
    /// this a founder who never opens that particular thread would see
    /// nothing at all, and the request would age out under
    /// `SwiftDataIntroRequestStore.retention` while the joiner waited.
    /// That's the same discoverability failure this PR set out to fix,
    /// one screen further in.
    ///
    /// Keyed by hex group id to match `ChatListItem.id`.
    ///
    /// Gated on being this group's admin, the same way the thread row is.
    /// "Only the admin's device has entries" is true of the *device* and
    /// not of the active identity: `IntroKeyStore.find(introPublicKey:)`
    /// searches every key on the device rather than the current
    /// identity's, so a request decodes under whichever identity happens
    /// to be selected. With two local identities in one group — which
    /// this app supports — the non-admin one would otherwise see
    /// "Someone wants to join", tap through, and find nothing to act on,
    /// because the thread does apply this check.
    private var pendingJoinRequestCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for request in approveRequestsFlow.pending {
            let hex = request.groupId.map { String(format: "%02x", $0) }.joined()
            guard isAdmin(ofGroupID: hex) else { continue }
            counts[hex, default: 0] += 1
        }
        return counts
    }

    /// Whether the active identity administers this group.
    ///
    /// Same derivation as `ChatThreadView.isGroupAdmin` and
    /// `ChatMembersView.canShareInvite`: compare the active identity's
    /// BLS pubkey against the group's stored admin pubkey, rather than
    /// trusting whoever holds the thread on this device.
    private func isAdmin(ofGroupID groupID: String) -> Bool {
        guard
            let group = flow.items.first(where: { $0.group.id == groupID })?.group,
            let activeID = identitiesFlow.currentID,
            let activeSummary = identitiesFlow.identities.first(where: { $0.id == activeID })
        else { return false }
        return group.isAdmin(blsPublicKey: activeSummary.blsPublicKey)
    }

    /// The two kinds of row this list holds, merged and ordered
    /// together. Merging here rather than inside `ChatsFlow` keeps the
    /// two facts with their owners: `ChatsFlow` knows about groups and
    /// messages, `PendingChatsFlow` knows about waits, and neither has
    /// to learn the other's vocabulary to be sorted next to it.
    private enum Row: Identifiable {
        case chat(ChatListItem)
        case pending(PendingChatsFlow.Row)

        var id: String {
            switch self {
            case .chat(let item): "chat:\(item.id)"
            case .pending(let row): "pending:\(row.id)"
            }
        }

        /// A pending chat sorts by when the wait started, exactly as a
        /// real chat sorts by its newest message — so a join that is
        /// happening right now lands at the top, which is where the
        /// person who just tapped the link will look for it.
        var sortKey: Date {
            switch self {
            case .chat(let item): item.sortKey
            case .pending(let row): row.receivedAt
            }
        }
    }

    private var rows: [Row] {
        let merged = flow.items.map(Row.chat) + pendingChatsFlow.rows.map(Row.pending)
        return merged.sorted { $0.sortKey > $1.sortKey }
    }

    private var groupList: some View {
        // Built once per render rather than per row: as a computed
        // property read inside the row builder it rebuilt the whole
        // dictionary — and re-ran the admin derivation for every pending
        // request — once for each group in the list.
        let joinRequestCounts = pendingJoinRequestCounts
        return List(rows) { row in
            switch row {
            case .chat(let item):
                NavigationLink(value: item.group.id) {
                    ChatsRow(
                        item: item,
                        joinRequestCount: joinRequestCounts[item.group.id] ?? 0
                    )
                }
                .listRowSeparator(.visible)
                // Swipe-to-delete with confirmation. Full-swipe is disabled so
                // a stray swipe can't wipe a chat + its messages without the
                // user confirming in the dialog below.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = item
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier("chats.row.delete.\(item.group.id)")
                }
            case .pending(let pending):
                NavigationLink(value: PendingChatRoute(id: pending.id)) {
                    PendingChatsRow(row: pending)
                }
                .listRowSeparator(.visible)
                // No confirmation dialog: nothing is being destroyed.
                // This is the old Dismiss — it drops a local offer and
                // sends nothing to the founder, whose outstanding intro
                // key simply goes unused.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if pending.isDismissable {
                        Button(role: .destructive) {
                            pendingChatsFlow.dismiss(pending.id)
                        } label: {
                            Label("Dismiss", systemImage: "xmark.bin")
                        }
                        .accessibilityIdentifier("chats.pending.dismiss.\(pending.id)")
                    }
                }
            }
        }
        .listStyle(.plain)
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete Chat", role: .destructive) {
                let flow = flow
                let groupID = item.group.id
                Task { await flow.deleteChat(groupID: groupID) }
            }
            .accessibilityIdentifier("chats.delete.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { item in
            let name = item.group.name.isEmpty ? "this chat" : "\u{201C}\(item.group.name)\u{201D}"
            Text("This removes \(name) and every message in it from this device. It can't be undone.")
        }
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
                setGroupName: setGroupName,
                imageLoader: imageLoader,
                videoLoader: videoLoader,
                voiceLoader: voiceLoader,
                makeModerationReportView: makeModerationReportView,
                approveRequestsFlow: approveRequestsFlow
            )
        }
        // A distinct route type rather than another `String`: a pending
        // chat's id and a group id would otherwise be the same value
        // space, and a stale one would open the wrong screen.
        .navigationDestination(for: PendingChatRoute.self) { route in
            PendingChatThreadView(flow: pendingChatsFlow, rowID: route.id)
        }
    }
}

/// Navigation value for a chat that hasn't opened yet.
struct PendingChatRoute: Hashable {
    let id: String
}

/// Chat-list row for a chat the user is waiting to be let into. Reads as
/// a chat, muted: the same avatar and title layout, no unread badge (no
/// messages exist), and a subtitle that says what is being waited on.
private struct PendingChatsRow: View {
    let row: PendingChatsFlow.Row

    var body: some View {
        HStack(spacing: 12) {
            OnymGroupAvatar(
                size: 44,
                accent: OnymAccent.blue.color,
                ringPulse: false,
                spinning: false,
                brand: false,
                imageData: nil
            )
            .opacity(0.6)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name?.isEmpty == false ? row.name! : String(localized: "(Unnamed)"))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(iconTint)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("chats.pending.subtitle.\(row.id)")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("chats.pending.\(row.id)")
    }

    private var icon: String {
        switch row.state {
        case .offered: "envelope"
        case .waiting, .chainSettling: "hourglass"
        case .founderUnreachable, .chainUnreachable, .chainNotConfigured, .sendFailed:
            "exclamationmark.triangle"
        }
    }

    private var iconTint: Color {
        switch row.state {
        case .offered: OnymAccent.blue.color
        case .waiting, .chainSettling: .secondary
        case .founderUnreachable, .chainUnreachable, .chainNotConfigured, .sendFailed:
            OnymTokens.red
        }
    }

    /// One line, and it has to answer "why isn't this a chat yet?" from
    /// the list alone — a person scanning past it should not have to open
    /// the row to learn that it is stuck rather than merely slow.
    private var subtitle: String {
        switch row.state {
        case .offered:
            let alias = row.inviterAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            return alias.isEmpty
                ? String(localized: "You\u{2019}ve been invited")
                : String(localized: "\(alias) invited you")
        case .waiting:
            return String(localized: "Waiting until you\u{2019}re in")
        case .chainSettling:
            return String(localized: "Almost in")
        case .founderUnreachable, .chainUnreachable, .chainNotConfigured:
            return String(localized: "Couldn\u{2019}t verify \u{2014} tap to retry")
        case .sendFailed:
            return String(localized: "Request didn\u{2019}t send \u{2014} tap to retry")
        }
    }
}

private struct ChatsRow: View {
    let item: ChatListItem
    /// Join requests waiting in this group's thread. Drives the row's
    /// "someone wants in" signal — the replacement for the toolbar badge
    /// this change removed.
    var joinRequestCount: Int = 0

    private var group: ChatGroup { item.group }

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
                // The join hint leads, because it is the only line in the
                // row that needs an action and a badge alone was what
                // nobody noticed on the toolbar. It no longer *replaces*
                // the rest: a founder with unread messages and a pending
                // request was losing both the preview and the count, and
                // the two signals answer different questions.
                HStack(spacing: 6) {
                    if joinRequestCount > 0 {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.caption2)
                            .foregroundStyle(OnymAccent.blue.color)
                        Text(joinRequestSubtitle)
                            .font(.caption)
                            .foregroundStyle(OnymAccent.blue.color)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .accessibilityIdentifier("chats.row.join_request.\(group.id)")
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if item.latestPreview == nil {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(subtitle)
                        .font(.caption)
                        // Unread rows read a touch stronger than the muted
                        // "no messages / metadata" line.
                        .foregroundStyle(item.unreadCount > 0 ? .primary : .secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("chats.row.subtitle.\(group.id)")
                }
            }

            Spacer(minLength: 0)

            // Both badges when both apply. They mean different things —
            // one is work waiting for the founder, the other is reading
            // waiting for the reader — and dropping the unread count
            // because someone asked to join loses a signal the row was
            // already carrying.
            if joinRequestCount > 0 {
                JoinRequestBadge(count: joinRequestCount)
                    .accessibilityIdentifier("chats.row.join_request_badge.\(group.id)")
            }
            if item.unreadCount > 0 {
                UnreadBadge(count: item.unreadCount)
                    .accessibilityIdentifier("chats.row.unread.\(group.id)")
            } else if group.isPublishedOnChain {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Color.green)
                    .accessibilityLabel("Published on chain")
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("chats.row.\(group.id)")
    }

    /// Prefixed to the subtitle line while requests are outstanding,
    /// ahead of the message preview rather than in place of it (the row
    /// renders both, separated by a `·`). The founder can see there is
    /// something to act on without opening the thread, and the chat
    /// doesn't lose its last message to say so.
    private var joinRequestSubtitle: String {
        joinRequestCount == 1
            ? String(localized: "Someone wants to join")
            : String(localized: "\(joinRequestCount) people want to join")
    }

    /// Latest message preview when the group has messages; otherwise the
    /// governance + member-count metadata (so a brand-new chat still shows
    /// something meaningful).
    private var subtitle: String {
        if let preview = item.latestPreview, !preview.isEmpty {
            return preview
        }
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

/// Accent-coloured counterpart to `UnreadBadge` for pending join
/// requests. Deliberately not red: this is an invitation to act, not a
/// backlog of unread messages, and a founder should be able to tell the
/// two apart at a glance down the list.
private struct JoinRequestBadge: View {
    let count: Int

    var body: some View {
        // The number is shown, not only implied by the glyph. A
        // person-vs-people icon distinguishes one from many and nothing
        // else — two pending requests and nine looked identical unless
        // you read the subtitle or used VoiceOver, while the unread badge
        // beside it has always carried its count.
        HStack(spacing: 3) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 12, weight: .semibold))
            if count > 1 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(OnymTokens.onAccent)
        .padding(.horizontal, 7)
        .frame(minHeight: 20)
        .background(OnymAccent.blue.color, in: Capsule())
        .accessibilityLabel(
            count == 1
                ? String(localized: "1 join request")
                : String(localized: "\(count) join requests")
        )
    }
}

/// Red pill showing the unread-message count on a chat row (caps at 99+).
private struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Color.red, in: Capsule())
            .accessibilityLabel("\(count) unread")
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
