import Foundation
@testable import OnymIOS

/// Reusable in-memory `IntroKeyStore`. Same contract as
/// `KeychainIntroKeyStore` without the Keychain plumbing — fast
/// tests of `InviteIntroducer` and the future request-flow
/// interactors that don't want to touch the Security framework.
actor InMemoryIntroKeyStore: IntroKeyStore {

    private var entries: [IntroKeyEntry] = []

    func save(_ entry: IntroKeyEntry) async {
        entries.removeAll { $0.introPublicKey == entry.introPublicKey }
        entries.append(entry)
    }

    func find(introPublicKey: Data) async -> IntroKeyEntry? {
        entries.first { $0.introPublicKey == introPublicKey }
    }

    func listForOwner(_ ownerIdentityID: IdentityID) async -> [IntroKeyEntry] {
        entries
            .filter { $0.ownerIdentityID == ownerIdentityID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func revoke(introPublicKey: Data) async {
        entries.removeAll { $0.introPublicKey == introPublicKey }
    }

    @discardableResult
    func deleteForOwner(_ ownerIdentityID: IdentityID) async -> Int {
        let before = entries.count
        entries.removeAll { $0.ownerIdentityID == ownerIdentityID }
        return before - entries.count
    }
}
