import SwiftUI

@main
struct OnymIOSApp: App {
    private let repository = IdentityRepository.shared
    private let authenticator: BiometricAuthenticator = LAContextAuthenticator()

    var body: some Scene {
        WindowGroup {
            RecoveryPhraseBackupView(
                repository: repository,
                authenticator: authenticator
            )
        }
    }
}
