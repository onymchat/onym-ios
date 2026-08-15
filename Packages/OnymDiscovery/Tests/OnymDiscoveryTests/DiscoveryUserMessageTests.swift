import XCTest
@testable import OnymDiscovery

/// `DiscoveryUserMessage` — one rendering of discovery failures for
/// both the per-source status badges and the add-provider sheet, and
/// the integrity-vs-outage split the badges key on.
final class DiscoveryUserMessageTests: XCTestCase {
    func testIntegrityClassification() {
        // Verification failures — the document arrived and failed a
        // check about the provider itself.
        XCTAssertTrue(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryTrustError.providerManifestInvalid(reason: "bad signature")
        ))
        XCTAssertTrue(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryTrustError.snapshotInvalid(reason: "rollback")
        ))
        XCTAssertTrue(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryTrustError.policyUnavailable
        ))
        XCTAssertTrue(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryTrustError.entryManifestMismatch
        ))
        XCTAssertTrue(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryTrustError.entryManifestInvalid(reason: "expired")
        ))
        XCTAssertTrue(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryTrustError.sourceConflict
        ))

        // An expired snapshot means the provider stopped republishing
        // — an operational lapse (FAILED badge), not evidence of
        // tampering (red INTEGRITY badge).
        XCTAssertFalse(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryTrustError.snapshotExpired
        ))

        // Reachability / throttling — nothing verified, nothing to
        // hold against the provider's integrity.
        XCTAssertFalse(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryFetchError.badStatus(503)
        ))
        XCTAssertFalse(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryFetchError.rateLimited
        ))
        XCTAssertFalse(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryFetchError.oversize
        ))
        XCTAssertFalse(DiscoveryUserMessage.isIntegrityFailure(
            URLError(.notConnectedToInternet)
        ))
        XCTAssertFalse(DiscoveryUserMessage.isIntegrityFailure(
            DiscoveryTrustError.rateLimited
        ))
    }

    func testMessagesAreReadable() {
        XCTAssertEqual(
            DiscoveryUserMessage.message(
                for: DiscoveryTrustError.providerManifestInvalid(reason: "unsupported version 2")
            ),
            "Provider manifest rejected: unsupported version 2"
        )
        XCTAssertEqual(
            DiscoveryUserMessage.message(for: DiscoveryTrustError.snapshotExpired),
            "Catalog snapshot has expired."
        )
        XCTAssertEqual(
            DiscoveryUserMessage.message(for: DiscoveryFetchError.badStatus(404)),
            "Couldn't reach the provider (status 404)."
        )
        // The integrity-classified trust errors each get a specific
        // message — not the generic refresh fallback.
        XCTAssertEqual(
            DiscoveryUserMessage.message(for: DiscoveryTrustError.policyUnavailable),
            "The provider's policy document couldn't be verified against its pinned digest."
        )
        XCTAssertEqual(
            DiscoveryUserMessage.message(for: DiscoveryTrustError.entryManifestMismatch),
            "A listed service's manifest doesn't match the bytes its catalog entry pinned."
        )
        XCTAssertEqual(
            DiscoveryUserMessage.message(
                for: DiscoveryTrustError.entryManifestInvalid(reason: "bad signature")
            ),
            "A listed service's manifest failed verification: bad signature"
        )
        XCTAssertEqual(
            DiscoveryUserMessage.message(for: DiscoveryTrustError.sourceConflict),
            "Two of your providers list the same service with different manifests."
        )
        XCTAssertEqual(
            DiscoveryUserMessage.message(for: URLError(.timedOut)),
            "Couldn't reach the provider."
        )
        // Unknown errors still render something actionable.
        struct Mystery: Error {}
        XCTAssertEqual(
            DiscoveryUserMessage.message(for: Mystery()),
            "Couldn't refresh the provider."
        )
    }
}
