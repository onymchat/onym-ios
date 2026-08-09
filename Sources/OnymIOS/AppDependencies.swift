import Foundation
import SwiftUI
import OnymIdentity
import OnymGroup
import OnymChatsCore
import OnymInbox
import OnymRecovery
import OnymChatsUI
import OnymSettings
import OnymModerationUI
import OnymModeration

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
    let makeBlossomRelaySettingsFlow: @MainActor () -> BlossomRelaySettingsFlow
    let makeAnchorsPickerFlow: @MainActor () -> AnchorsPickerFlow
    let makeCreateGroupFlow: @MainActor () -> CreateGroupFlow
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow
    let makeJoinFlow: @MainActor (IntroCapability) -> JoinFlow
    /// Single shared instance — the Chats tab, search destination, and
    /// thread screens must observe the same list state. Recreating this
    /// flow during a RootView redraw can leave its startup task attached
    /// to an old view instance, making chats appear only after Settings
    /// recreates the tab.
    let chatsFlow: ChatsFlow
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
    /// Admin renames a group: applies it locally and fans a
    /// `GroupNamePayload` out to members. Backs the admin-only rename
    /// affordance in `ChatMembersView`.
    let setGroupName: @MainActor (_ groupIDHex: String, _ name: String) async -> Void
    /// Single shared instance — the app root switches on its gate
    /// (consent / banned / check-required / operational) and Settings
    /// observes the same state, so a factory would split them.
    let moderationGateFlow: ModerationGateFlow
    let makeModerationConsentFlow: @MainActor (ModerationConsentFlow.Mode) -> ModerationConsentFlow
    let makeModerationSettingsFlow: @MainActor () -> ModerationSettingsFlow
    /// Opaque report-sheet factory: the chats layer presents whatever
    /// view this returns, keeping OnymChatsUI free of any
    /// OnymModerationUI dependency.
    let makeModerationReportView: @MainActor (ReportableMessage) -> AnyView
    /// Case screen for a served notice — carries both the caseId and
    /// the mandateRef the repository resolves standing by.
    let makeModerationCaseFlow: @MainActor (CaseNotice) -> ModerationCaseFlow
    /// Case screen from the ban surface: appeal + new-holder filings.
    let makeModerationBanCaseFlow: @MainActor (_ caseId: String, _ mandateRef: String) -> ModerationCaseFlow
    /// Recovery case screen after a reinstall: resolves the retained
    /// identity's active mandate before opening the signed appeal flow.
    let makeModerationRecoveryCaseFlow: @MainActor (_ caseId: String) async -> ModerationCaseFlow?
    /// Authenticated recovery lookup; the Authority returns case IDs only.
    let lookupModerationRecoveryCaseIDs: @MainActor () async -> [String]
    /// Device recovery behind `reidentificationRequired`: file a claim
    /// with the authority's human moderator, poll it, and redeem the
    /// signed grant at the enforcement backend. Nothing self-serve.
    let makeDeviceRecoveryFlow: @MainActor () async -> DeviceRecoveryFlow
}
