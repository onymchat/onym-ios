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
import OnymDiscovery
import OnymOnboarding
import OnymBackupUI

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
    /// Single shared instance — the Chats list's per-group join-request
    /// signal and each thread's in-thread request rows observe the same
    /// `pending` list, and the underlying collector should run for the
    /// app's lifetime regardless of which surface is mounted.
    let approveRequestsFlow: ApproveRequestsFlow
    /// Single shared instance — the invitee-side push-invitation
    /// surface. Backs the Chats toolbar "Invitations" badge + modal,
    /// and its store watcher runs for the app's lifetime like
    /// `approveRequestsFlow`.
    let pendingChatsFlow: PendingChatsFlow
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
    /// Discovery Providers drill-down factory. Optional so Settings
    /// renders without the discovery stack (nil under the UI-test
    /// harness — same pattern as the moderation factories).
    let makeDiscoverySettingsFlow: (@MainActor () -> DiscoverySettingsFlow)?
    /// The consented backup operators, cheap to read. Lets the root view
    /// tell "an operator was added, removed or changed" from "Settings
    /// was opened again" without rebuilding the whole stack to find out.
    let consentedBackupComponentIds: (@MainActor () -> [String])?
    /// Settings → Device Backup. Async and optional: resolving it reads
    /// the pinned consent record and derives a seat key, and it is
    /// legitimately `nil` when no backup operator has been consented to
    /// or the identity has no recovery phrase to derive from. The
    /// section hides rather than offering a screen that cannot work.
    let makeDeviceBackupView: (@MainActor () async -> DeviceBackupVendorsView?)?
    /// Settings → Backup Operators: the catalog picker a backup
    /// operator is discovered and consented to through. Optional on the
    /// same terms as the discovery factories — nil in a build with no
    /// discovery stack, where there is no catalog to pick from.
    ///
    /// Non-nil independently of `makeDeviceBackupView`, and that is the
    /// point: this is the surface that exists BEFORE any consent, and
    /// the one that makes the other appear.
    let makeBackupOperatorSettingsFlow: (@MainActor () -> BackupOperatorSettingsFlow)?
    /// Raised by the backup picker's consent apply step so the root
    /// view re-resolves the Device Backup screen immediately. Without
    /// it a consent given from a Settings sheet — where the tab never
    /// changes — leaves the section missing until the tab is visited
    /// again.
    let backupConsentSignal: BackupConsentSignal?
    /// Onboarding flow factory. Non-nil whenever onboarding is
    /// AVAILABLE in this build (always in production; under
    /// `--ui-testing` only with `--ui-onboarding`, so every existing
    /// UI test launches exactly as before). Whether the cover presents
    /// at launch is `presentOnboardingAtLaunch` — the factory alone no
    /// longer implies presentation, because Settings → Restart
    /// Onboarding can present a fresh walk mid-session.
    let makeOnboardingFlow: (@MainActor () -> OnboardingFlow)?
    /// The cold-boot gate decision (`OnboardingGate.shouldOnboard`,
    /// grandfathering included): RootView presents the cover on first
    /// mount exactly when this is true.
    let presentOnboardingAtLaunch: Bool
    /// Settings → Restart Onboarding bridge: Settings raises it, the
    /// RootView observes `pendingRestart` and presents a fresh walk.
    /// nil exactly when `makeOnboardingFlow` is nil (the Settings row
    /// hides too).
    let onboardingRestart: OnboardingRestartController?
    /// Step-content slot for `OnboardingView`: the app-layer surfaces
    /// (discovery TOFU confirm, catalog pickers, the moderation
    /// mandate flow) pre-bound to the same repositories and pickers
    /// the Settings screens use. nil falls back to the package's
    /// built-in step bodies.
    let makeOnboardingStepContent: (@MainActor (OnboardingFlow, OnboardingStep) -> AnyView?)?
}
