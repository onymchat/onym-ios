import SwiftUI

@main
struct OnymIOSApp: App {
    private let repository = IdentityRepository.shared

    var body: some Scene {
        WindowGroup {
            IdentityBootstrapView(repository: repository)
        }
    }
}
