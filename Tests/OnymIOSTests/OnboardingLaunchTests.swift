import XCTest
@testable import OnymIOS
import OnymChain
import OnymModeration
import OnymOnboarding
import OnymTransportBlossom
import OnymTransportNostr

/// The launch-time existing-user probe behind
/// `OnboardingGate.shouldOnboard`: a fresh install onboards; any
/// touched configuration or a moderation mandate grandfathers the
/// user past the walk. All pure reads — the probe writes nothing.
final class OnboardingLaunchTests: XCTestCase {

    // MARK: - Fresh install

    func test_freshInstall_isNotExistingUser() {
        XCTAssertFalse(OnboardingLaunch.isExistingUser(
            relayerStore: FakeRelayerStore(),
            nostrStore: FakeNostrStore(),
            blossomStore: FakeBlossomStore(),
            mandateStore: FakeMandateStore()
        ))
    }

    /// The Nostr/Blossom repositories seed their configuration with
    /// `hasUserInteracted == false` — a seeded-but-untouched install
    /// must still onboard.
    func test_seededDefaults_doNotCountAsExistingUser() {
        let url = URL(string: "https://official.example")!
        XCTAssertFalse(OnboardingLaunch.isExistingUser(
            relayerStore: FakeRelayerStore(),
            nostrStore: FakeNostrStore(configuration: NostrRelaysConfiguration(
                endpoints: [NostrRelayEndpoint.custom(url: url)],
                hasUserInteracted: false
            )),
            blossomStore: FakeBlossomStore(configuration: BlossomServersConfiguration(
                endpoints: [BlossomServerEndpoint.custom(url: url)],
                hasUserInteracted: false
            )),
            mandateStore: FakeMandateStore()
        ))
    }

    // MARK: - Grandfathering signals

    func test_relayerInteraction_grandfathers() {
        let store = FakeRelayerStore(configuration: RelayerConfiguration(
            endpoints: [],
            primaryURL: nil,
            strategy: .primary,
            hasUserInteracted: true
        ))
        XCTAssertTrue(OnboardingLaunch.isExistingUser(
            relayerStore: store,
            nostrStore: FakeNostrStore(),
            blossomStore: FakeBlossomStore(),
            mandateStore: FakeMandateStore()
        ))
    }

    func test_nostrInteraction_grandfathers() {
        XCTAssertTrue(OnboardingLaunch.isExistingUser(
            relayerStore: FakeRelayerStore(),
            nostrStore: FakeNostrStore(configuration: NostrRelaysConfiguration(
                endpoints: [], hasUserInteracted: true
            )),
            blossomStore: FakeBlossomStore(),
            mandateStore: FakeMandateStore()
        ))
    }

    func test_blossomInteraction_grandfathers() {
        XCTAssertTrue(OnboardingLaunch.isExistingUser(
            relayerStore: FakeRelayerStore(),
            nostrStore: FakeNostrStore(),
            blossomStore: FakeBlossomStore(configuration: BlossomServersConfiguration(
                endpoints: [], hasUserInteracted: true
            )),
            mandateStore: FakeMandateStore()
        ))
    }

    func test_mandatePresence_grandfathers() {
        XCTAssertTrue(OnboardingLaunch.isExistingUser(
            relayerStore: FakeRelayerStore(),
            nostrStore: FakeNostrStore(),
            blossomStore: FakeBlossomStore(),
            mandateStore: FakeMandateStore(records: [Self.mandateRecord()])
        ))
    }

    // MARK: - Gate composition

    func test_gate_onboardsExactlyOnFreshWorld() {
        let suite = "onboarding.launch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsOnboardingStore(defaults: defaults)

        XCTAssertTrue(OnboardingGate.shouldOnboard(store: store, isExistingUser: { false }))
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { true }))
        store.markOnboardingCompleted()
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { false }))
    }

    // MARK: - Fakes

    private struct FakeRelayerStore: RelayerSelectionStore {
        var configuration: RelayerConfiguration = .empty
        func loadConfiguration() -> RelayerConfiguration { configuration }
        func saveConfiguration(_ configuration: RelayerConfiguration) {}
        func loadCachedKnownList() -> [RelayerEndpoint] { [] }
        func saveCachedKnownList(_ list: [RelayerEndpoint]) {}
    }

    private struct FakeNostrStore: NostrRelaysSelectionStore {
        var configuration: NostrRelaysConfiguration = .empty
        func load() -> NostrRelaysConfiguration { configuration }
        func save(_ configuration: NostrRelaysConfiguration) {}
    }

    private struct FakeBlossomStore: BlossomServersSelectionStore {
        var configuration: BlossomServersConfiguration = .empty
        func load() -> BlossomServersConfiguration { configuration }
        func save(_ configuration: BlossomServersConfiguration) {}
    }

    private struct FakeMandateStore: MandateStore {
        var records: [MandateRecord] = []
        func load() -> [MandateRecord] { records }
        func save(_ records: [MandateRecord]) {}
    }

    private static func mandateRecord() -> MandateRecord {
        MandateRecord(
            mandate: ModerationMandate(
                user: "onym:key:user",
                interface: "onym:component:onym-ios",
                authority: "onym:component:authority",
                manifestHash: "aa",
                classes: ["csam"],
                deviceBinding: "enrollment-1",
                acceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
                signatures: ["user-sig"]
            ),
            manifestBytes: Data("{}".utf8),
            authorityName: "A",
            countersigned: false,
            isActive: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
