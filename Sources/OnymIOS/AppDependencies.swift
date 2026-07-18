import Foundation

/// App-wide composition root. Constructed exactly once by `OnymIOSApp`
/// and threaded down to views via `RootView`. Each member is a factory
/// closure that captures the repositories / I/O affordances it needs —
/// views receive only these factories so they never hold a repository
/// reference themselves.
@MainActor
struct AppDependencies {
    let makeRecoveryPhraseBackupFlow: @MainActor () -> RecoveryPhraseBackupFlow
    let makeRelayerSettingsFlow: @MainActor () -> RelayerSettingsFlow
    let makeNostrRelaySettingsFlow: @MainActor () -> NostrRelaySettingsFlow
    let makeAnchorsPickerFlow: @MainActor () -> AnchorsPickerFlow
    let makeCreateGroupFlow: @MainActor () -> CreateGroupFlow
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow
    let makeJoinFlow: @MainActor (IntroCapability) -> JoinFlow
    let makeChatsFlow: @MainActor () -> ChatsFlow
    /// Single shared instance — the toolbar picker on Chats and the
    /// Settings → Identities screen observe the same state, so a
    /// factory closure here would split them.
    let identitiesFlow: IdentitiesFlow
    /// Single shared instance — the toolbar badge on Chats and the
    /// modal `ApproveRequestsView` observe the same `pending` list,
    /// and the underlying collector should run for the app's
    /// lifetime regardless of which surface is mounted.
    let approveRequestsFlow: ApproveRequestsFlow
    /// Single shared instance — the invitee-side push-invitation
    /// surface. Backs the Chats toolbar "Invitations" badge + modal,
    /// and its store watcher runs for the app's lifetime like
    /// `approveRequestsFlow`.
    let pendingInvitesFlow: PendingInvitesFlow
    /// Single shared instance — the chat-thread screen subscribes to
    /// per-group message snapshots, and the receive-side dispatcher
    /// writes into the same actor. Constructed once in
    /// `OnymIOSApp.init` and threaded down.
    let messageRepository: MessageRepository
    let imageLoader: ChatImageLoader
    /// Fetches + decrypts video blobs for the full-screen player. Shared
    /// like `imageLoader` so the on-disk decrypted-clip cache is reused
    /// across thread opens.
    let videoLoader: ChatVideoLoader
    /// Fetches + decrypts voice blobs for playback. Shared like
    /// `videoLoader` so the on-disk decrypted-clip cache is reused across
    /// thread opens.
    let voiceLoader: ChatVoiceLoader
    /// Stateless façade over identity + transport + repositories
    /// for outgoing chat messages. Safe to share across screens
    /// (it's an actor); each chat-thread view captures it and
    /// dispatches `send(groupID:body:)` on the send-button tap.
    let sendMessageInteractor: SendMessageInteractor
    /// Seals + ships delivery/read receipts. Shared so the chat thread
    /// can emit read receipts when the user opens it (delivered receipts
    /// are emitted from the receive-side dispatcher instead).
    let chatReceiptSender: any ChatReceiptSending
    /// Admin sets/clears a group photo: applies it locally and fans a
    /// `GroupAvatarPayload` out to members. Backs the admin-only picker
    /// in `ChatMembersView`; `nil` JPEG clears the photo.
    let setGroupAvatar: @MainActor (_ groupIDHex: String, _ jpeg: Data?) async -> Void
}
