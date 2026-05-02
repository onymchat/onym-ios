import Foundation
import LocalAuthentication

/// Async biometric / device-passcode prompt. Wrapped behind a protocol
/// so `RecoveryPhraseBackupFlow` can be unit-tested without standing up a
/// real `LAContext` (which requires UI presentation and user interaction).
protocol BiometricAuthenticator: Sendable {
    /// Prompts the user. Returns on success; throws on cancel / failure.
    /// On devices/simulators where `canEvaluatePolicy` is false (no enrolled
    /// biometric and no passcode), the call returns successfully without
    /// prompting — matches the reference impl's "fail open in dev" behaviour.
    func authenticate(reason: String) async throws
}

struct LAContextAuthenticator: BiometricAuthenticator {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometric / no passcode set up — proceed so the dev flow
            // still works on a fresh simulator. Production devices in this
            // state are extremely rare and the user has explicitly opted
            // out of device security.
            return
        }
        try await context.evaluatePolicyAsync(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )
    }
}

#if DEBUG
/// `BiometricAuthenticator` impl that always succeeds without prompting.
/// Compiled out of Release builds so production never has a code path that
/// silently bypasses biometric auth. Wired in by `OnymIOSApp.init` only
/// when launched under XCUITest with the `--mock-biometric` argument.
struct AlwaysAcceptAuthenticator: BiometricAuthenticator {
    func authenticate(reason: String) async throws {}
}
#endif

private extension LAContext {
    func evaluatePolicyAsync(_ policy: LAPolicy, localizedReason: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            evaluatePolicy(policy, localizedReason: localizedReason) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? LAError(.authenticationFailed))
                }
            }
        }
    }
}
