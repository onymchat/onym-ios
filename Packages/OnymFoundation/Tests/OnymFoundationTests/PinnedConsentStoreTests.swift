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
        let record = try store.accept(
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

        XCTAssertEqual(try store.load(), [record])
        XCTAssertEqual(try store.activeRecord(componentId: record.componentId), record)
    }

    func testReconsentDeactivatesPreviousRecordAndKeepsHistory() throws {
        let first = try ManifestFactory.reviewedSample()
        let second = try ManifestFactory.reviewedSample { object in
            object["name"] = "Sample Notary v2"
        }
        XCTAssertNotEqual(first.signedManifest.manifestHash, second.signedManifest.manifestHash)

        try store.accept(first, acceptedAt: ManifestFactory.now)
        try store.accept(second, acceptedAt: ManifestFactory.now.addingTimeInterval(60))

        let records = try store.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertFalse(records[0].isActive)
        XCTAssertTrue(records[1].isActive)
        XCTAssertEqual(
            try store.activeRecord(componentId: "onym:component:sample-notary")?.manifestHash,
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

        try store.accept(notary, acceptedAt: ManifestFactory.now)
        try store.accept(courier, acceptedAt: ManifestFactory.now)

        XCTAssertNotNil(try store.activeRecord(componentId: "onym:component:sample-notary"))
        XCTAssertNotNil(try store.activeRecord(componentId: "onym:component:sample-courier"))
    }

    func testRecordsSurviveEncodeDecodeRoundTrip() throws {
        let reviewed = try ManifestFactory.reviewedSample()
        let record = try store.accept(
            reviewed,
            sourceLabel: "Manual",
            offerId: nil,
            acceptedAt: ManifestFactory.now
        )

        // A fresh store instance over the same suite must read back
        // identical records (ISO 8601 dates are second-precision, and
        // the factory timestamp has no sub-second component).
        let reread = try UserDefaultsPinnedConsentStore(defaults: defaults).load()
        XCTAssertEqual(reread, [record])
        XCTAssertEqual(reread[0].consentedManifest()?.componentId, record.componentId)
    }

    func testEmptyStoreLoadsEmpty() throws {
        XCTAssertEqual(try store.load(), [])
        XCTAssertNil(try store.activeRecord(componentId: "onym:component:sample-notary"))
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
            try store.accept(reviewed, acceptedAt: ManifestFactory.now.addingTimeInterval(Double(round)))
        }

        let records = try store.load()
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
        try store.accept(courier, acceptedAt: ManifestFactory.now)

        let cap = UserDefaultsPinnedConsentStore.maxInactiveRecordsPerComponent
        for round in 0..<(cap + 4) {
            let reviewed = try ManifestFactory.reviewedSample { object in
                object["name"] = "rev \(round)"
            }
            try store.accept(reviewed, acceptedAt: ManifestFactory.now.addingTimeInterval(Double(round)))
        }

        XCTAssertNotNil(try store.activeRecord(componentId: "onym:component:sample-courier"))
        XCTAssertEqual(
            try store.load().filter { $0.componentId == "onym:component:sample-courier" }.count,
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
            _ = try? store.accept(reviewedManifests[index], acceptedAt: ManifestFactory.now)
        }

        let records = try store.load()
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

    // MARK: - Corruption

    private var recordsKey: String { "app.onym.ios.consent.records" }
    private var corruptKey: String { "app.onym.ios.consent.records.corrupt" }

    func testCorruptStoreThrowsDistinctlyAndParksBlob() throws {
        let garbage = Data("not an array of records".utf8)
        defaults.set(garbage, forKey: recordsKey)

        XCTAssertThrowsError(try store.load()) { error in
            guard case PinnedConsentStoreError.corruptStore = error else {
                return XCTFail("expected corruptStore, got \(error)")
            }
        }
        // The undecodable blob is parked for forensics; the live key
        // is left in place so absent and corrupt stay distinguishable.
        XCTAssertTrue(store.hasCorruptRecords)
        XCTAssertEqual(defaults.data(forKey: corruptKey), garbage)
        XCTAssertEqual(defaults.data(forKey: recordsKey), garbage)
    }

    func testAcceptOnCorruptStoreThrowsAndNeverOverwrites() throws {
        // The exact disaster the corrupt/absent distinction prevents:
        // decode failure reading as "no records", and the next accept
        // saving a fresh array over every prior consent record.
        let garbage = Data(#"[{"componentId":42}]"#.utf8)
        defaults.set(garbage, forKey: recordsKey)

        let reviewed = try ManifestFactory.reviewedSample()
        XCTAssertThrowsError(
            try store.accept(reviewed, acceptedAt: ManifestFactory.now)
        ) { error in
            guard case PinnedConsentStoreError.corruptStore = error else {
                return XCTFail("expected corruptStore, got \(error)")
            }
        }
        XCTAssertEqual(defaults.data(forKey: recordsKey), garbage, "corrupt blob must never be overwritten")
        XCTAssertNil(try? store.activeRecord(componentId: reviewed.signedManifest.componentId))
    }

    func testClearCorruptRecordsRestoresAcceptance() throws {
        defaults.set(Data("garbage".utf8), forKey: recordsKey)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(store.hasCorruptRecords)

        // Explicit, destructive recovery — after it, the store is
        // empty and accepts work again.
        store.clearCorruptRecords()
        XCTAssertFalse(store.hasCorruptRecords)
        XCTAssertEqual(try store.load(), [])

        let reviewed = try ManifestFactory.reviewedSample()
        let record = try store.accept(reviewed, acceptedAt: ManifestFactory.now)
        XCTAssertEqual(try store.load(), [record])
    }

    func testSaveThrowsAreNotSwallowedByAccept() throws {
        // A store whose save fails must fail the accept — a returned
        // record always means persisted consent.
        struct FailingSaveStore: PinnedConsentStore {
            func load() throws -> [PinnedConsentRecord] { [] }
            func save(_ records: [PinnedConsentRecord]) throws {
                throw PinnedConsentStoreError.persistenceFailed(reason: "disk said no")
            }
        }
        let reviewed = try ManifestFactory.reviewedSample()
        XCTAssertThrowsError(
            try FailingSaveStore().accept(reviewed, acceptedAt: ManifestFactory.now)
        ) { error in
            guard case PinnedConsentStoreError.persistenceFailed = error else {
                return XCTFail("expected persistenceFailed, got \(error)")
            }
        }
    }

    // MARK: - Pin freshness

    func testRecordSurfacesValidUntilAndExpiry() throws {
        let reviewed = try ManifestFactory.reviewedSample()
        let record = try store.accept(reviewed, acceptedAt: ManifestFactory.now)

        // Derived from the pinned manifest bytes (factory publishes
        // validUntil 2027-01-01). Not enforced anywhere — the pin
        // stays active — but callers can ask.
        XCTAssertEqual(record.validUntil, ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
        XCTAssertFalse(record.isExpired(now: ManifestFactory.now))
        let afterExpiry = ISO8601DateFormatter().date(from: "2027-06-01T00:00:00Z")!
        XCTAssertTrue(record.isExpired(now: afterExpiry))
        // Expiry never deactivates the pin.
        XCTAssertEqual(try store.activeRecord(componentId: record.componentId), record)
    }

    func testRecordWithoutValidUntilNeverExpires() throws {
        let reviewed = try ManifestFactory.reviewedSample { object in
            object.removeValue(forKey: "validUntil")
        }
        let record = try store.accept(reviewed, acceptedAt: ManifestFactory.now)
        XCTAssertNil(record.validUntil)
        XCTAssertFalse(record.isExpired(now: .distantFuture))
    }
}
