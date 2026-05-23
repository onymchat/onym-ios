import Foundation

/// Admin-side counterpart to `GroupAvatarPayload`: applies a new (or
/// cleared) group photo locally, then fans it out to every member's
/// inbox, sealed per recipient — the same best-effort broadcast shape
/// as `JoinRequestApprover`'s member-announcement loop.
///
/// The caller is expected to be the group admin (the change-photo UI is
/// admin-gated); receivers independently verify the envelope's Ed25519
/// signer against the group's stored admin key and drop anything else,
/// so a non-admin sender can't move another device's avatar.
actor GroupAvatarBroadcaster {
    private let identity: IdentityRepository
    private let inboxTransport: any InboxTransport
    private let groupRepository: GroupRepository

    init(
        identity: IdentityRepository,
        inboxTransport: any InboxTransport,
        groupRepository: GroupRepository
    ) {
        self.identity = identity
        self.inboxTransport = inboxTransport
        self.groupRepository = groupRepository
    }

    /// Set (or clear, with `jpeg == nil`) the photo for `groupIDHex`.
    /// Persists the local change first so the UI reflects it even if
    /// every send fails, then ships one sealed `GroupAvatarPayload` to
    /// each member inbox except the admin's own.
    func setAvatar(groupIDHex: String, jpeg: Data?) async {
        let groups = await groupRepository.currentGroups()
        guard var group = groups.first(where: { $0.id == groupIDHex }) else { return }

        // Local apply + persist up front — broadcast is best-effort.
        group.avatarJPEG = jpeg
        await groupRepository.insert(group)

        let payload = GroupAvatarPayload(
            version: 1,
            groupID: group.groupIDData,
            senderBlsPubkeyHex: group.adminPubkeyHex?.lowercased() ?? "",
            sentAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            avatar: jpeg
        )
        guard let payloadBytes = try? JSONEncoder().encode(payload) else { return }

        let adminKey = group.adminPubkeyHex?.lowercased()
        for (memberKey, profile) in group.memberProfiles {
            // Skip self — the admin already applied the change locally.
            if let adminKey, memberKey == adminKey { continue }
            guard let sealed = try? await identity.sealInvitation(
                payload: payloadBytes,
                to: profile.inboxPublicKey
            ) else { continue }
            let tag = TransportInboxID(
                rawValue: IntroInboxPump.inboxTag(from: profile.inboxPublicKey)
            )
            // Receipt discarded — a member that misses this update will
            // catch the photo on the next snapshot / refresh.
            _ = try? await inboxTransport.send(sealed, to: tag)
        }
    }
}
