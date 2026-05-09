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

    @State private var showShareInvite = false
    @State private var shareInviteFlow: ShareInviteFlow?

    var body: some View {
        Group {
            if let group = currentGroup {
                if group.memberProfiles.isEmpty {
                    emptyState
                } else {
                    list(for: group)
                }
            } else {
                missingGroupState
            }
        }
        .navigationTitle(currentGroup?.name ?? "Members")
        .navigationBarTitleDisplayMode(.inline)
        .background(OnymTokens.bg)
        .toolbar {
            // Only the local owner of the group can mint a useful
            // invite link — joiners' invites would point requests at
            // their own intro inbox, where they can't actually admit
            // anyone (admin approval is what materializes the group
            // for the new joiner). Showing the entry-point only on
            // owner-side groups removes a footgun.
            if isLocalOwner {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareInviteFlow = makeShareInviteFlow()
                        showShareInvite = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .accessibilityLabel("Share invite link")
                    .accessibilityIdentifier("members.share_invite_button")
                }
            }
        }
        .sheet(isPresented: $showShareInvite) {
            if let flow = shareInviteFlow {
                ShareInviteView(
                    groupID: groupID,
                    flow: flow,
                    onDone: {
                        showShareInvite = false
                        shareInviteFlow = nil
                    }
                )
            }
        }
    }

    // MARK: - State

    private var currentGroup: ChatGroup? {
        chatsFlow.groups.first { $0.id == groupID }
    }

    /// True iff the active identity owns this group locally — i.e.
    /// they're the device that created it. Used to gate the
    /// "Share invite" entry-point: only the owner's intro inbox can
    /// usefully receive join requests, since approval requires the
    /// admin's keys.
    private var isLocalOwner: Bool {
        guard
            let group = currentGroup,
            let activeID = identitiesFlow.currentID
        else { return false }
        return group.ownerIdentityID == activeID
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

    private func list(for group: ChatGroup) -> some View {
        ScrollView {
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
