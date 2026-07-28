import Foundation
import LocalAuthentication

/// Async biometric / device-passcode prompt. Wrapped behind a protocol
/// so `RecoveryPhraseBackupFlow` can be unit-tested without standing up a
/// real `LAContext` (which requires UI presentation and user interaction).
protocol BiometricAuthenticator: Sendable {
    /// Prompts the user. Returns on success; throws on cancel / failure.
    /// On devices/simulators where `canEvaluatePolicy` is false (no enrolled
    /// biometric and no passcode), behaviour depends on the build: DEBUG
    /// returns successfully ("fail open") so dev/simulator flows work, while
    /// Release throws ("fail closed") so the recovery phrase is never revealed
    /// without authentication.
    func authenticate(reason: String) async throws
}

/// Raised by `LAContextAuthenticator` when the device cannot evaluate the
/// auth policy (no passcode / no enrolled biometric) and the build is
/// configured to fail closed. The message never reveals the phrase.
enum BiometricAuthError: LocalizedError {
    case deviceSecurityUnavailable

    var errorDescription: String? {
        switch self {
        case .deviceSecurityUnavailable:
            return String(localized: "Set a device passcode to view your recovery phrase.")
        }
    }
}

struct LAContextAuthenticator: BiometricAuthenticator {
    /// Whether an unevaluable auth policy fails CLOSED (throws) or OPEN
    /// (returns). Defaults to the compile-time posture: Release fails closed
    /// so production never bypasses auth; DEBUG fails open so a fresh
    /// simulator dev flow still works. Injectable so both branches stay
    /// unit-testable under the DEBUG test build.
    #if DEBUG
    static let failClosedByDefault = false
    #else
    static let failClosedByDefault = true
    #endif

    let failClosed: Bool
    private let canEvaluate: @Sendable (LAContext) -> Bool

    init(
        failClosed: Bool = LAContextAuthenticator.failClosedByDefault,
        canEvaluate: @escaping @Sendable (LAContext) -> Bool = { context in
            var error: NSError?
            return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        }
    ) {
        self.failClosed = failClosed
        self.canEvaluate = canEvaluate
    }

    func authenticate(reason: String) async throws {
        let context = LAContext()
        guard canEvaluate(context) else {
            // No biometric / no passcode set up. Fail CLOSED in Release so the
            // phrase is never revealed without authentication; fail OPEN in
            // DEBUG so the dev flow still works on a fresh simulator.
            if failClosed {
                throw BiometricAuthError.deviceSecurityUnavailable
            }
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
