import Foundation

/// App-wide composition root. Constructed exactly once by `OnymIOSApp`
/// and threaded down to views via `RootView`. Each member is a factory
/// closure that captures the repositories / I/O affordances it needs —
/// views receive only these factories so they never hold a repository
/// reference themselves.
struct AppDependencies {
    let makeRecoveryPhraseBackupFlow: @MainActor () -> RecoveryPhraseBackupFlow
    let makeRelayerPickerFlow: @MainActor () -> RelayerPickerFlow
}
