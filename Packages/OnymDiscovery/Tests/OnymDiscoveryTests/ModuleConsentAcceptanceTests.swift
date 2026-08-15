import XCTest
import CryptoKit
import OnymFoundation
@testable import OnymDiscovery

/// The generalized consent accept path (`ModuleConsentAcceptance`):
/// pins the reviewed manifest first, records the selection provenance
/// second, and refuses the moderation seat outright.
final class ModuleConsentAcceptanceTests: XCTestCase {
    /// Shared mutable box behind the store fakes, with an event log so
    /// the write *ordering* is observable.
    final class StoreBox: @unchecked Sendable {
        var records: [PinnedConsentRecord] = []
        var selections: [ModuleSelection] = []
        var events: [String] = []
    }

    struct FakePinnedConsentStore: PinnedConsentStore, @unchecked Sendable {
        let box: StoreBox
        func load() -> [PinnedConsentRecord] { box.records }
        func save(_ records: [PinnedConsentRecord]) {
            box.records = records
            box.events.append("consent")
        }
    }

    struct FakeSeatSelectionStore: SeatSelectionStore, @unchecked Sendable {
        let box: StoreBox
        func activeSelection(seatType: String) -> ModuleSelection? {
            history(seatType: seatType).last
        }
        func history(seatType: String) -> [ModuleSelection] {
            box.selections.filter { $0.seatType == seatType }
        }
        func record(_ selection: ModuleSelection) {
            box.selections.append(selection)
            box.events.append("selection")
        }
    }

    private let attribution = SourceAttribution(
        providerId: "onym:component:onym-discovery",
        sourceLabel: "Onym Discovery",
        catalogId: "main",
        snapshotDigest: "sha256:" + String(repeating: "0", count: 64),
        relationship: "common-owner",
        placement: "organic"
    )

    /// Reviewed token minted from the byte-exact destination-manifest
    /// fixture (seat "transport.message", one free offer).
    private func reviewedFixture() throws -> ReviewedServiceManifest {
        let raw = try Fixture.bytes("destination-manifest.json")
        return try ServiceManifestReviewer().review(raw: raw, now: Fixture.now)
    }

    /// Reviewed token over a freshly self-signed manifest, for shapes
    /// the byte-pinned fixture set doesn't carry (e.g. a paid offer).
    private func selfSignedManifest(
        seat: String,
        offers: [[String: Any]] = []
    ) throws -> ReviewedServiceManifest {
        let key = Curve25519.Signing.PrivateKey()
        let keyHex = key.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        var object: [String: Any] = [
            "componentId": "onym:component:sample-service",
            "seat": seat,
            "operator": "onym:key:\(keyHex)",
            "validUntil": "2027-01-01T00:00:00Z",
        ]
        if !offers.isEmpty { object["offers"] = offers }
        let unsigned = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let signature = try key.signature(
            for: ServiceManifestCanonical.signingBytes(of: unsigned)
        )
        object["signature"] = signature.base64EncodedString()
        let raw = try JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        )
        return try ServiceManifestReviewer().review(raw: raw, now: Fixture.now)
    }

    func testAcceptPinsConsentThenRecordsSelection() throws {
        let box = StoreBox()
        let reviewed = try reviewedFixture()
        let acceptedAt = Fixture.now

        let (record, selection) = try ModuleConsentAcceptance.accept(
            reviewed: reviewed,
            source: attribution,
            offerId: "courier-free-v1",
            consentStore: FakePinnedConsentStore(box: box),
            selectionStore: FakeSeatSelectionStore(box: box),
            acceptedAt: acceptedAt
        )

        // Ordering: the consent pin lands before the selection that
        // references it.
        XCTAssertEqual(box.events, ["consent", "selection"])

        // The pin is active and byte-exact.
        XCTAssertTrue(record.isActive)
        XCTAssertEqual(record.componentId, "onym:component:onym-courier")
        XCTAssertEqual(record.seatType, "transport.message")
        XCTAssertEqual(record.manifestBytes, reviewed.signedManifest.rawBytes)
        XCTAssertEqual(record.sourceLabel, "Onym Discovery")
        XCTAssertEqual(record.offerId, "courier-free-v1")
        XCTAssertEqual(box.records, [record])

        // The selection provenance ties back to the same hash, the
        // listing provider, and the accepted offer.
        XCTAssertEqual(selection.manifestHash, record.manifestHash)
        XCTAssertEqual(selection.seatType, "transport.message")
        XCTAssertEqual(selection.componentId, "onym:component:onym-courier")
        XCTAssertEqual(selection.providerId, "onym:component:onym-discovery")
        XCTAssertEqual(selection.offerId, "courier-free-v1")
        XCTAssertEqual(selection.selectedAt, acceptedAt)
        XCTAssertEqual(box.selections, [selection])
    }

    /// The headline first-consent path: NO consent record exists for
    /// the component, the manifest under review carries one free
    /// offer. The review-scoped entitlement provider must grant it
    /// (i.e. the radio is selectable), and accepting with it must land
    /// the offerId in BOTH the pinned record and the selection.
    func testFirstConsentFreeOnlyManifestOfferIsGrantedAndRecorded() async throws {
        let box = StoreBox()
        let consentStore = FakePinnedConsentStore(box: box)
        let reviewed = try reviewedFixture()
        let manifest = reviewed.signedManifest

        // Before ANY consent exists — the moment the consent surface
        // computes its entitlements.
        XCTAssertNil(try consentStore.activeRecord(componentId: manifest.componentId))
        let provider = FreeTierEntitlementProvider(reviewing: manifest, consentStore: consentStore)
        let entitlement = await provider.entitlement(
            for: "courier-free-v1",
            component: manifest.componentId
        )
        XCTAssertNotNil(entitlement, "the free offer must be selectable on first consent")

        let (record, selection) = try ModuleConsentAcceptance.accept(
            reviewed: reviewed,
            source: attribution,
            offerId: entitlement?.offerId,
            consentStore: consentStore,
            selectionStore: FakeSeatSelectionStore(box: box),
            acceptedAt: Fixture.now
        )
        XCTAssertEqual(record.offerId, "courier-free-v1")
        XCTAssertEqual(selection.offerId, "courier-free-v1")
    }

    /// Same first-consent moment, manifest carrying a paid offer next
    /// to the free one: the paid offer must stay unselectable.
    func testFirstConsentPaidOfferStaysDisabled() async throws {
        let manifest = try selfSignedManifest(
            seat: "notary",
            offers: [
                ["offerId": "free-tier", "model": "free"],
                ["offerId": "pro-monthly", "model": "subscription", "period": "monthly"],
            ]
        ).signedManifest

        let provider = FreeTierEntitlementProvider(
            reviewing: manifest,
            consentStore: FakePinnedConsentStore(box: StoreBox())
        )
        let free = await provider.entitlement(for: "free-tier", component: manifest.componentId)
        XCTAssertNotNil(free)
        let paid = await provider.entitlement(for: "pro-monthly", component: manifest.componentId)
        XCTAssertNil(paid, "paid offers must not be selectable pre-StoreKit")
    }

    // MARK: - Apply endpoint

    func testRequiredEndpointURLPicksFirstMatchingSchemeCaseInsensitively() throws {
        let url = try ModuleConsentAcceptance.requiredEndpointURL(
            in: ["wss://relay.example", "HTTPS://second.example/a", "https://third.example"],
            scheme: "https"
        )
        XCTAssertEqual(url.absoluteString, "HTTPS://second.example/a")
    }

    func testRequiredEndpointURLThrowsWhenNoEndpointMatches() {
        // The no-endpoint manifest path: the apply step must throw —
        // never silently no-op behind a "Service added" screen.
        for uris in [[String](), ["https://relay.example"], ["not a uri"]] {
            XCTAssertThrowsError(
                try ModuleConsentAcceptance.requiredEndpointURL(in: uris, scheme: "wss")
            ) { error in
                XCTAssertEqual(error as? ModuleApplyError, .noUsableEndpoint)
            }
        }
    }

    func testAcceptWithoutOfferRecordsNilOffer() throws {
        let box = StoreBox()
        let (record, selection) = try ModuleConsentAcceptance.accept(
            reviewed: try reviewedFixture(),
            source: attribution,
            offerId: nil,
            consentStore: FakePinnedConsentStore(box: box),
            selectionStore: FakeSeatSelectionStore(box: box),
            acceptedAt: Fixture.now
        )
        XCTAssertNil(record.offerId)
        XCTAssertNil(selection.offerId)
    }

    func testModerationSeatIsExcludedAndWritesNothing() throws {
        // Self-signed manifest claiming the moderation seat — its
        // consent is a signed mandate, never this generic pin.
        let reviewed = try selfSignedManifest(seat: "moderation")

        let box = StoreBox()
        XCTAssertThrowsError(try ModuleConsentAcceptance.accept(
            reviewed: reviewed,
            source: attribution,
            offerId: nil,
            consentStore: FakePinnedConsentStore(box: box),
            selectionStore: FakeSeatSelectionStore(box: box),
            acceptedAt: Fixture.now
        )) { error in
            XCTAssertEqual(error as? ModuleConsentError, .moderationSeatExcluded)
        }
        XCTAssertTrue(box.records.isEmpty)
        XCTAssertTrue(box.selections.isEmpty)
        XCTAssertTrue(box.events.isEmpty)
    }
}
