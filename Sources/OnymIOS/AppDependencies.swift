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
    let makeAnchorsPickerFlow: @MainActor () -> AnchorsPickerFlow
    let makeCreateGroupFlow: @MainActor () -> CreateGroupFlow
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow
    let makeChatsFlow: @MainActor () -> ChatsFlow
    /// Single shared instance — the toolbar picker on Chats and the
    /// Settings → Identities screen observe the same state, so a
    /// factory closure here would split them.
    let identitiesFlow: IdentitiesFlow
}
