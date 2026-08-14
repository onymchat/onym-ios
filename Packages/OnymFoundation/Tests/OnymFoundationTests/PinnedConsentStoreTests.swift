import Foundation
import XCTest
@testable import OnymFoundation

final class PinnedConsentStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: UserDefaultsPinnedConsentStore!

    override func setUpWithError() throws {
        suiteName = "PinnedConsentStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = UserDefaultsPinnedConsentStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testAcceptPersistsRecordPinningReviewedBytes() throws {
        let reviewed = try ManifestFactory.reviewedSample()
        let record = store.accept(
            reviewed,
            sourceLabel: "Onym Directory",
            offerId: "free-tier",
            acceptedAt: ManifestFactory.now
        )

        XCTAssertEqual(record.componentId, "onym:component:sample-notary")
        XCTAssertEqual(record.seatType, "notary")
        // No-refetch invariant: the pinned bytes and hash are exactly
        // the reviewed manifest's.
        XCTAssertEqual(record.manifestBytes, reviewed.signedManifest.rawBytes)
        XCTAssertEqual(record.manifestHash, reviewed.signedManifest.manifestHash)
        XCTAssertEqual(record.sourceLabel, "Onym Directory")
        XCTAssertEqual(record.offerId, "free-tier")
        XCTAssertTrue(record.isActive)

        XCTAssertEqual(store.load(), [record])
        XCTAssertEqual(store.activeRecord(componentId: record.componentId), record)
    }

    func testReconsentDeactivatesPreviousRecordAndKeepsHistory() throws {
        let first = try ManifestFactory.reviewedSample()
        let second = try ManifestFactory.reviewedSample { object in
            object["name"] = "Sample Notary v2"
        }
        XCTAssertNotEqual(first.signedManifest.manifestHash, second.signedManifest.manifestHash)

        store.accept(first, acceptedAt: ManifestFactory.now)
        store.accept(second, acceptedAt: ManifestFactory.now.addingTimeInterval(60))

        let records = store.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertFalse(records[0].isActive)
        XCTAssertTrue(records[1].isActive)
        XCTAssertEqual(
            store.activeRecord(componentId: "onym:component:sample-notary")?.manifestHash,
            second.signedManifest.manifestHash
        )
        // History still carries the superseded bytes, re-decodable.
        XCTAssertEqual(records[0].consentedManifest()?.rawBytes, first.signedManifest.rawBytes)
    }

    func testConsentToDifferentComponentLeavesOtherRecordsActive() throws {
        let notary = try ManifestFactory.reviewedSample()
        let courier = try ManifestFactory.reviewedSample { object in
            object["componentId"] = "onym:component:sample-courier"
            object["seat"] = "courier"
        }

        store.accept(notary, acceptedAt: ManifestFactory.now)
        store.accept(courier, acceptedAt: ManifestFactory.now)

        XCTAssertNotNil(store.activeRecord(componentId: "onym:component:sample-notary"))
        XCTAssertNotNil(store.activeRecord(componentId: "onym:component:sample-courier"))
    }

    func testRecordsSurviveEncodeDecodeRoundTrip() throws {
        let reviewed = try ManifestFactory.reviewedSample()
        let record = store.accept(
            reviewed,
            sourceLabel: "Manual",
            offerId: nil,
            acceptedAt: ManifestFactory.now
        )

        // A fresh store instance over the same suite must read back
        // identical records (ISO 8601 dates are second-precision, and
        // the factory timestamp has no sub-second component).
        let reread = UserDefaultsPinnedConsentStore(defaults: defaults).load()
        XCTAssertEqual(reread, [record])
        XCTAssertEqual(reread[0].consentedManifest()?.componentId, record.componentId)
    }

    func testEmptyStoreLoadsEmpty() {
        XCTAssertEqual(store.load(), [])
        XCTAssertNil(store.activeRecord(componentId: "onym:component:sample-notary"))
    }

    // MARK: - Retention

    func testHistoryIsCappedPerComponentOldestEvicted() throws {
        // Records carry whole manifest snapshots in UserDefaults, so
        // history is bounded: the active pin plus the last
        // `maxInactiveRecordsPerComponent` inactive records.
        let cap = UserDefaultsPinnedConsentStore.maxInactiveRecordsPerComponent
        var hashes: [String] = []
        for round in 0..<(cap + 4) {
            let reviewed = try ManifestFactory.reviewedSample { object in
                object["name"] = "Sample Notary rev \(round)"
            }
            hashes.append(reviewed.signedManifest.manifestHash)
            store.accept(reviewed, acceptedAt: ManifestFactory.now.addingTimeInterval(Double(round)))
        }

        let records = store.load()
        XCTAssertEqual(records.count, cap + 1, "active record plus capped history")
        XCTAssertEqual(records.filter(\.isActive).count, 1)
        XCTAssertEqual(records.last?.manifestHash, hashes.last)
        // The survivors are exactly the most recent accepts; the
        // oldest three inactive records were evicted.
        XCTAssertEqual(records.map(\.manifestHash), Array(hashes.suffix(cap + 1)))
    }

    func testCapDoesNotTouchOtherComponentsHistory() throws {
        let courier = try ManifestFactory.reviewedSample { object in
            object["componentId"] = "onym:component:sample-courier"
            object["seat"] = "courier"
        }
        store.accept(courier, acceptedAt: ManifestFactory.now)

        let cap = UserDefaultsPinnedConsentStore.maxInactiveRecordsPerComponent
        for round in 0..<(cap + 4) {
            let reviewed = try ManifestFactory.reviewedSample { object in
                object["name"] = "rev \(round)"
            }
            store.accept(reviewed, acceptedAt: ManifestFactory.now.addingTimeInterval(Double(round)))
        }

        XCTAssertNotNil(store.activeRecord(componentId: "onym:component:sample-courier"))
        XCTAssertEqual(
            store.load().filter { $0.componentId == "onym:component:sample-courier" }.count,
            1
        )
    }

    // MARK: - Atomicity

    func testConcurrentAcceptsLoseNoRecordsAndKeepOneActivePerComponent() throws {
        // `accept` is load-modify-save; unserialized, concurrent calls
        // drop each other's appends or leave two actives. Six distinct
        // components accepted from six threads must all land.
        let reviewedManifests = try (0..<6).map { index in
            try ManifestFactory.reviewedSample { object in
                object["componentId"] = "onym:component:concurrent-\(index)"
            }
        }

        DispatchQueue.concurrentPerform(iterations: reviewedManifests.count) { index in
            store.accept(reviewedManifests[index], acceptedAt: ManifestFactory.now)
        }

        let records = store.load()
        XCTAssertEqual(records.count, reviewedManifests.count, "no accept may be lost")
        for index in 0..<reviewedManifests.count {
            let componentId = "onym:component:concurrent-\(index)"
            XCTAssertEqual(
                records.filter { $0.componentId == componentId && $0.isActive }.count,
                1,
                "exactly one active record for \(componentId)"
            )
        }
    }
}
