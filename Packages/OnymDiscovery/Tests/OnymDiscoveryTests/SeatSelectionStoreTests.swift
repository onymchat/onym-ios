import Foundation
import XCTest
@testable import OnymDiscovery

/// UserDefaults round-trip with per-test suite isolation — same
/// pattern as the sibling selection-store tests in the app target.
final class SeatSelectionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: UserDefaultsSeatSelectionStore!

    override func setUp() {
        super.setUp()
        suiteName = "app.onym.ios.discovery.selections.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = UserDefaultsSeatSelectionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        super.tearDown()
    }

    private func selection(
        seatType: String = "notary",
        componentId: String = "onym:component:sample-notary",
        providerId: String = "onym:component:onym-discovery",
        manifestHash: String = "sha256:" + String(repeating: "a", count: 64),
        offerId: String? = nil,
        selectedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ModuleSelection {
        ModuleSelection(
            seatType: seatType,
            componentId: componentId,
            providerId: providerId,
            manifestHash: manifestHash,
            offerId: offerId,
            selectedAt: selectedAt
        )
    }

    func test_activeSelection_isNilWhenNothingRecorded() {
        XCTAssertNil(store.activeSelection(seatType: "notary"))
        XCTAssertEqual(store.history(seatType: "notary"), [])
    }

    func test_record_roundTripsThroughUserDefaults() {
        let recorded = selection(offerId: "free-tier")
        store.record(recorded)

        // A fresh store over the same suite sees the persisted record.
        let reloaded = UserDefaultsSeatSelectionStore(defaults: defaults)
        XCTAssertEqual(reloaded.activeSelection(seatType: "notary"), recorded)
        XCTAssertEqual(reloaded.history(seatType: "notary"), [recorded])
    }

    func test_record_replacesActiveSelectionAndKeepsHistory() {
        let first = selection(
            componentId: "onym:component:notary-one",
            selectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = selection(
            componentId: "onym:component:notary-two",
            manifestHash: "sha256:" + String(repeating: "b", count: 64),
            selectedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        store.record(first)
        store.record(second)

        XCTAssertEqual(store.activeSelection(seatType: "notary"), second)
        // Oldest-first history keeps the replaced selection.
        XCTAssertEqual(store.history(seatType: "notary"), [first, second])
    }

    func test_selectionsAreScopedPerSeatType() {
        let notary = selection(seatType: "notary")
        let transport = selection(
            seatType: "transport.message",
            componentId: "onym:component:onym-courier"
        )
        store.record(notary)
        store.record(transport)

        XCTAssertEqual(store.activeSelection(seatType: "notary"), notary)
        XCTAssertEqual(store.activeSelection(seatType: "transport.message"), transport)
        XCTAssertEqual(store.history(seatType: "notary"), [notary])
        XCTAssertEqual(store.history(seatType: "transport.message"), [transport])
        XCTAssertNil(store.activeSelection(seatType: "blob.storage"))
    }

    func test_malformedPersistedBlobDegradesToEmpty() {
        defaults.set(Data("not json".utf8), forKey: "app.onym.ios.discovery.selections")
        XCTAssertNil(store.activeSelection(seatType: "notary"))
        XCTAssertEqual(store.history(seatType: "notary"), [])
        // Recording over the malformed blob starts a fresh history.
        let recorded = selection()
        store.record(recorded)
        XCTAssertEqual(store.history(seatType: "notary"), [recorded])
    }

    func test_record_capsHistoryPerSeatKeepingActivePlusNewest() {
        let cap = UserDefaultsSeatSelectionStore.maxHistoryRecordsPerSeat
        // Record cap + 3 selections for one seat, plus one for another
        // seat that must survive untouched.
        let other = selection(seatType: "blob.storage", componentId: "onym:component:blob")
        store.record(other)
        let recorded = (0..<(cap + 3)).map { index in
            selection(
                componentId: "onym:component:notary-\(index)",
                selectedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
        recorded.forEach(store.record)

        let history = store.history(seatType: "notary")
        // Active + the last `cap` prior records; the oldest two evicted.
        XCTAssertEqual(history.count, cap + 1)
        XCTAssertEqual(history, Array(recorded.suffix(cap + 1)))
        XCTAssertEqual(store.activeSelection(seatType: "notary"), recorded.last)
        // The other seat's record is untouched by the eviction.
        XCTAssertEqual(store.history(seatType: "blob.storage"), [other])
    }

    func test_moduleSelectionCodableRoundTrip() throws {
        let value = selection(offerId: "pro-monthly")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ModuleSelection.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}
