import Foundation
import XCTest
@testable import OnymIOS
import OnymDiscovery

/// Tests for `SeededDiscoveryConfirmation.confirmIfUnpinned` — the
/// programmatic TOFU confirm the onboarding recommended path runs when
/// the services step is left with the recommended setup accepted.
///
/// Runs the REAL trust pipeline against the byte-pinned fixtures the
/// `--ui-discovery` harness serves (`UITestDiscoveryFixtures`): real
/// signatures, fixture-era clock, in-memory store — offline and
/// deterministic, same recipe as the UI tests' repository wiring.
final class SeededDiscoveryConfirmationTests: XCTestCase {

    private func makeRepository(
        fetcher: any DiscoveryFetching = UITestDiscoveryFetcher()
    ) -> DiscoveryRepository {
        DiscoveryRepository(
            fetcher: fetcher,
            store: InMemoryDiscoveryStore(),
            now: { UITestDiscoveryFixtures.now }
        )
    }

    /// The recommended-path accept pins the seeded default and its
    /// catalogs land in the aggregate — the exact gap this seam fixes:
    /// before, the seed stayed unpinned and the aggregate stayed empty.
    func test_confirm_pinsSeededSource_andPopulatesAggregate() async throws {
        let repository = makeRepository()
        // start() seeds the unconfirmed default; its background
        // refresh SKIPS the unpinned source by design.
        await repository.start()
        var state = await repository.currentState()
        let seeded = try XCTUnwrap(
            state.sources.first { $0.id == DiscoverySource.onymDefault.providerId }
        )
        XCTAssertNil(seeded.source.pinnedOperatorKeyHex,
                     "the seeded default must start unpinned (TOFU by design)")

        await SeededDiscoveryConfirmation.confirmIfUnpinned(repository: repository)

        state = await repository.currentState()
        let confirmed = try XCTUnwrap(
            state.sources.first { $0.id == DiscoverySource.onymDefault.providerId }
        )
        XCTAssertNotNil(confirmed.source.pinnedOperatorKeyHex,
                        "accepting the recommended setup must pin the seeded source")
        XCTAssertEqual(confirmed.source.operatorKeyFingerprint,
                       UITestDiscoveryFixtures.operatorKeyFingerprint,
                       "the pinned key must be the one the manifest is signed with")
        XCTAssertFalse(state.aggregate.isEmpty,
                       "the targeted refresh after the pin must populate the catalog aggregate")
    }

    /// Already pinned → the confirm is a no-op: same pinned key, no
    /// re-pin churn (idempotence makes the trigger's possible double
    /// fire harmless).
    func test_confirm_isIdempotent_whenAlreadyPinned() async throws {
        let repository = makeRepository()
        await repository.start()
        await SeededDiscoveryConfirmation.confirmIfUnpinned(repository: repository)
        let first = await repository.currentState()
        let firstKey = first.sources.first?.source.pinnedOperatorKeyHex
        XCTAssertNotNil(firstKey)

        await SeededDiscoveryConfirmation.confirmIfUnpinned(repository: repository)

        let second = await repository.currentState()
        XCTAssertEqual(second.sources.first?.source.pinnedOperatorKeyHex, firstKey)
        XCTAssertEqual(second.sources.count, first.sources.count)
        XCTAssertFalse(second.aggregate.isEmpty)
    }

    /// Offline first run: the fetch fails, the source stays unpinned
    /// (the summary then reports "Not confirmed"), and nothing throws
    /// out of the walk.
    func test_confirm_failureLeavesSourceUnpinned() async throws {
        struct OfflineFetcher: DiscoveryFetching {
            func fetchProviderManifest(url: URL) async throws -> Data {
                throw DiscoveryFetchError.badStatus(503)
            }
            func fetchSnapshot(url: URL) async throws -> Data {
                throw DiscoveryFetchError.badStatus(503)
            }
        }
        let repository = makeRepository(fetcher: OfflineFetcher())
        await repository.start()

        await SeededDiscoveryConfirmation.confirmIfUnpinned(repository: repository)

        let state = await repository.currentState()
        let seeded = try XCTUnwrap(
            state.sources.first { $0.id == DiscoverySource.onymDefault.providerId }
        )
        XCTAssertNil(seeded.source.pinnedOperatorKeyHex,
                     "a failed fetch must leave the seed unpinned, not block or crash")
        XCTAssertTrue(state.aggregate.isEmpty)
    }
}
