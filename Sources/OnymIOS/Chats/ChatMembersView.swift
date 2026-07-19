import SwiftUI

/// Member roster for one chat. Drilled into from a `ChatsRow` tap.
/// Reads the latest `ChatGroup` from `ChatsFlow` by ID so the view
/// re-renders when an admin's PR-5 fanout lands a new joiner via
/// the receive-side dispatcher (PR 6).
///
/// Rendering rules:
/// - Sort by alias case-insensitively; entries with empty aliases
///   sink to the bottom under their BLS-pubkey fingerprint.
/// - Always show the BLS-pubkey hex prefix as a fingerprint —
///   aliases are self-asserted (per `MemberProfile`'s trust note),
///   so the fingerprint is the load-bearing identifier.
/// - "(you)" badge on the entry whose BLS pubkey hex matches the
///   currently-active identity — passed in via `IdentitiesFlow`
///   so a switch flips the badge without reopening the view.
/// - Empty state when the directory hasn't filled in yet (e.g.
///   joiner-side V1, where local materialization hasn't shipped
///   so `memberProfiles` is `[:]`).
struct ChatMembersView: View {
    let groupID: String
    @Bindable var chatsFlow: ChatsFlow
    @Bindable var identitiesFlow: IdentitiesFlow
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow
    let setGroupAvatar: @MainActor (String, Data?) async -> Void
    let setGroupName: @MainActor (String, String) async -> Void

    @State private var shareInviteFlow: ShareInviteFlow?
    /// Drives the admin-only rename alert.
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        Group {
            if let group = currentGroup {
                VStack(spacing: 0) {
                    header(for: group)
                    if group.memberProfiles.isEmpty {
                        emptyState
                    } else {
                        list(for: group)
                    }
                }
            } else {
                missingGroupState
            }
        }
        .navigationTitle(currentGroup?.name ?? "Members")
        .navigationBarTitleDisplayMode(.inline)
        .background(OnymTokens.bg)
        .toolbar {
            // Only the cryptographic admin can mint a useful invite
            // link — non-admin members minting invites would surface
            // join requests in their own intro inbox, but the
            // approver's PR-13 anchor flow would short-circuit with
            // `.notAdminOfThisGroup` because they don't hold the
            // admin BLS secret. Hiding the entry-point removes the
            // footgun + matches the cryptographic constraint
            // already enforced on chain (sep-tyranny rejects
            // `update_commitment` proofs from non-admins).
            if canShareInvite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareInviteFlow = makeShareInviteFlow()
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .accessibilityLabel("Share invite link")
                    .accessibilityIdentifier("members.share_invite_button")
                }
            }
        }
        .sheet(item: $shareInviteFlow) { flow in
            ShareInviteView(
                groupID: groupID,
                flow: flow,
                onDone: { shareInviteFlow = nil }
            )
        }
        .alert("Rename group", isPresented: $showRename) {
            TextField("Group name", text: $renameText)
                .accessibilityIdentifier("members.rename_field")
            Button("Save") {
                let name = renameText
                Task { await setGroupName(groupID, name) }
            }
            .accessibilityIdentifier("members.rename_save")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone in the group will see the new name.")
        }
    }

    // MARK: - State

    private var currentGroup: ChatGroup? {
        chatsFlow.groups.first { $0.id == groupID }
    }

    /// True iff the active identity is the cryptographic admin of
    /// this group — i.e. their BLS pubkey hex matches
    /// `group.adminPubkeyHex`. Gates the "Share invite" toolbar
    /// entry-point.
    ///
    /// Why not `group.ownerIdentityID == activeID`? `ownerIdentityID`
    /// is per-device; for a joiner-side group materialized from an
    /// invitation, it gets stamped as the joiner's local identity
    /// (so the chats-list filter routes it to the right tab). That
    /// would falsely report "you own this" for every joiner — the
    /// stronger BLS-pubkey-matches-stored-admin check is the right
    /// one. For Anarchy / OneOnOne we hide regardless: anarchy
    /// admit ceremonies aren't wired in V1, OneOnOne is fixed
    /// 2-party.
    private var canShareInvite: Bool {
        guard
            let group = currentGroup,
            group.groupType == .tyranny,
            let storedAdminHex = group.adminPubkeyHex?.lowercased(),
            let activeID = identitiesFlow.currentID,
            let activeSummary = identitiesFlow.identities.first(where: { $0.id == activeID })
        else { return false }
        let activeHex = activeSummary.blsPublicKey
            .map { String(format: "%02x", $0) }.joined()
            .lowercased()
        return activeHex == storedAdminHex
    }

    /// Whether to show the editable (picker) avatar vs a read-only one.
    /// Same gate as `canShareInvite`: only the Tyranny admin can change
    /// the photo, because only their broadcast passes the receiver-side
    /// admin-signature check. Anarchy / OneOnOne have no admin, so the
    /// photo stays as set at create time in this pass.
    private var canChangeAvatar: Bool { canShareInvite }

    /// Bridges the picker to the broadcaster: reads the live group photo,
    /// and on a pick/clear ships it via `setGroupAvatar` (which applies
    /// locally + fans out). The local store write flows back through
    /// `chatsFlow.groups`, so the `get` reflects the change on the next
    /// render without extra @State.
    private var avatarBinding: Binding<Data?> {
        Binding(
            get: { currentGroup?.avatarJPEG },
            set: { [groupID, setGroupAvatar] newValue in
                Task { await setGroupAvatar(groupID, newValue) }
            }
        )
    }

    private var activeBlsHex: String? {
        guard
            let id = identitiesFlow.currentID,
            let summary = identitiesFlow.identities.first(where: { $0.id == id })
        else { return nil }
        return summary.blsPublicKey
            .map { String(format: "%02x", $0) }
            .joined()
            .lowercased()
    }

    // MARK: - Subviews

    /// Group-photo hero. Editable picker for the admin; a plain
    /// photo-or-mark for everyone else.
    @ViewBuilder
    private func header(for group: ChatGroup) -> some View {
        VStack(spacing: 8) {
            Group {
                if canChangeAvatar {
                    GroupAvatarPickerButton(
                        imageData: avatarBinding,
                        size: 72,
                        accent: OnymAccent.blue.color,
                        conceptText: group.name
                    )
                } else {
                    OnymGroupAvatar(size: 72, imageData: group.avatarJPEG)
                }
            }
            // Group name. Admin can rename (pencil affordance); everyone
            // else sees it read-only.
            if canChangeName {
                Button {
                    renameText = group.name
                    showRename = true
                } label: {
                    HStack(spacing: 5) {
                        Text(group.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(OnymTokens.text)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OnymTokens.text3)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("members.rename_button")
            } else {
                Text(group.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                    .lineLimit(1)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// Same admin gate as the avatar: only the Tyranny admin can rename,
    /// because only their broadcast passes the receiver's admin check.
    private var canChangeName: Bool { canShareInvite }

    private func list(for group: ChatGroup) -> some View {
        ScrollView {
            if let message = group.invitationMessage,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                invitationSection(message)
            }
            VStack(spacing: 0) {
                ForEach(rows(for: group)) { row in
                    memberRow(row)
                    if row.id != rows(for: group).last?.id {
                        Divider()
                            .background(OnymTokens.hairline)
                            .padding(.leading, 56)
                    }
                }
            }
            .background(OnymTokens.surface2)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(OnymTokens.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Text("\(group.memberProfiles.count) member\(group.memberProfiles.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(OnymTokens.text3)
                .padding(.top, 8)
                .padding(.bottom, 24)
        }
    }

    /// The group's invitation message (greeting / policy / articles),
    /// shown as the group's intro at the top of the info screen.
    private func invitationSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INVITATION")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
                .padding(.leading, 4)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(OnymTokens.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(14)
                .background(OnymTokens.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(OnymTokens.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("members.invitation")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func memberRow(_ row: MemberRow) -> some View {
        HStack(spacing: 12) {
            avatar(for: row)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayAlias)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                    if row.isSelf {
                        Text("(you)")
                            .font(.system(size: 12))
                            .foregroundStyle(OnymTokens.text2)
                    }
                }
                Text("BLS \(row.blsPrefix)\u{2026}")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(OnymTokens.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityIdentifier("members.row.\(row.id)")
    }

    private func avatar(for row: MemberRow) -> some View {
        let initial = row.displayAlias.first.map(String.init)?.uppercased() ?? "?"
        return ZStack {
            Circle()
                .fill(OnymAccent.blue.color.opacity(row.isSelf ? 1.0 : 0.6))
                .frame(width: 36, height: 36)
            Text(initial)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.onAccent)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2")
                .font(.system(size: 40))
                .foregroundStyle(OnymTokens.text3)
            Text("No members yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text("Invite people from the chat to see them here.")
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("members.empty")
    }

    private var missingGroupState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(OnymTokens.text3)
            Text("Group not found")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("members.missing")
    }

    // MARK: - Row construction

    private func rows(for group: ChatGroup) -> [MemberRow] {
        let activeKey = activeBlsHex
        return group.memberProfiles
            .map { (key, profile) in
                MemberRow(
                    id: key,
                    blsHex: key,
                    blsPrefix: String(key.prefix(12)),
                    displayAlias: profile.alias.isEmpty ? "(unnamed)" : profile.alias,
                    isSelf: activeKey.map { $0 == key } ?? false
                )
            }
            .sorted { lhs, rhs in
                // Self always first, then alias case-insensitively.
                if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
                return lhs.displayAlias.localizedCaseInsensitiveCompare(rhs.displayAlias)
                    == .orderedAscending
            }
    }

    private struct MemberRow: Identifiable {
        let id: String
        let blsHex: String
        let blsPrefix: String
        let displayAlias: String
        let isSelf: Bool
    }
}
