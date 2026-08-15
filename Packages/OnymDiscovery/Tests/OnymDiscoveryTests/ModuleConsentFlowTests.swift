import CryptoKit
import Foundation
import OnymFoundation
import XCTest
@testable import OnymDiscovery

/// The `ModuleConsentFlow` state machine around review + accept: the
/// entry↔manifest identity cross-checks, entitlement gating of the
/// Accept button, and the retry-after-apply-failure guard that must
/// never append a second consent record for the same bytes.
final class ModuleConsentFlowTests: XCTestCase {
    /// Shared mutable box behind the store fakes.
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

    /// A verified catalog entry pointing at `raw`'s exact bytes.
    private func catalogEntry(
        componentId: String,
        seatType: String,
        raw: Data,
        operatorKey: String
    ) throws -> CatalogEntry {
        let digest = DiscoveryFormat.sha256Digest(of: raw)
        let json = """
        {"componentId":"\(componentId)","seatType":"\(seatType)",\
        "manifest":{"uri":"https://service.example.app/manifest.json","digest":"\(digest)"},\
        "operator":"\(operatorKey)","listedAt":"2026-01-01T00:00:00Z",\
        "relationship":"common-owner","placement":"organic"}
        """
        return try DiscoveryJSON.decoder().decode(CatalogEntry.self, from: Data(json.utf8))
    }

    /// Raw bytes of a freshly self-signed service manifest, for shapes
    /// the byte-pinned fixture set doesn't carry (paid-only offers, no
    /// offers).
    private func selfSignedRaw(
        seat: String,
        offers: [[String: Any]] = []
    ) throws -> Data {
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
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        )
    }

    /// Flow over `raw`, with the entry naming `entryComponentId` when
    /// it should deliberately mismatch the manifest.
    @MainActor
    private func makeFlow(
        raw: Data,
        box: StoreBox,
        entryComponentId: String? = nil,
        entryOperatorKey: String? = nil,
        fetchManifestBytes: (@Sendable (URL) async throws -> Data)? = nil,
        apply: @escaping (SignedServiceManifest) async throws -> Void = { _ in }
    ) throws -> ModuleConsentFlow {
        let manifest = try SignedServiceManifest(raw: raw)
        let consentStore = FakePinnedConsentStore(box: box)
        let entry = try catalogEntry(
            componentId: entryComponentId ?? manifest.componentId,
            seatType: manifest.seat,
            raw: raw,
            operatorKey: entryOperatorKey ?? manifest.operatorKey
        )
        return ModuleConsentFlow(
            entry: AttributedCatalogEntry(entry: entry, source: attribution),
            fetchManifestBytes: fetchManifestBytes ?? { _ in raw },
            consentStore: consentStore,
            selectionStore: FakeSeatSelectionStore(box: box),
            makeEntitlements: { manifest in
                FreeTierEntitlementProvider(reviewing: manifest, consentStore: consentStore)
            },
            apply: apply
        )
    }

    // MARK: - Entitlement gating (Accept)

    /// Free-only manifest: the free offer is auto-selected and Accept
    /// is enabled — first consent, no record in the store yet.
    @MainActor
    func testFreeOnlyManifestAutoSelectsItsFreeOfferAndEnablesAccept() async throws {
        let flow = try makeFlow(raw: try Fixture.bytes("destination-manifest.json"), box: StoreBox())
        flow.start()
        await flow.loadTask?.value

        XCTAssertEqual(flow.step, .reviewing)
        XCTAssertEqual(flow.selectedOfferId, "courier-free-v1")
        XCTAssertTrue(flow.canAccept)
    }

    /// Paid-only manifest: nothing is selectable pre-StoreKit, so
    /// Accept must be disabled AND tapping it must write nothing —
    /// never a consent with `offerId: nil` for a paid-only service.
    @MainActor
    func testPaidOnlyManifestDisablesAcceptAndTapWritesNothing() async throws {
        let box = StoreBox()
        let raw = try selfSignedRaw(seat: "notary", offers: [
            ["offerId": "pro-monthly", "model": "subscription", "period": "monthly"],
        ])
        let flow = try makeFlow(raw: raw, box: box)
        flow.start()
        await flow.loadTask?.value

        XCTAssertEqual(flow.step, .reviewing)
        XCTAssertNil(flow.selectedOfferId)
        XCTAssertFalse(flow.canAccept)

        flow.tappedAccept()
        XCTAssertNil(flow.acceptTask, "a gated Accept must not start an accept task")
        XCTAssertEqual(flow.step, .reviewing)
        XCTAssertTrue(box.records.isEmpty)
        XCTAssertTrue(box.selections.isEmpty)
    }

    /// A manifest without offers carries no commercial terms to pick —
    /// Accept stays available.
    @MainActor
    func testManifestWithoutOffersCanAccept() async throws {
        let flow = try makeFlow(raw: try selfSignedRaw(seat: "notary"), box: StoreBox())
        flow.start()
        await flow.loadTask?.value

        XCTAssertEqual(flow.step, .reviewing)
        XCTAssertTrue(flow.canAccept)
    }

    // MARK: - Entry ↔ manifest identity

    /// A fetched manifest naming a different componentId than the
    /// catalog entry is a hard failure: consent would be recorded
    /// under one id while the catalog rows look it up by the other —
    /// the row would read "REVIEW" forever and every accept would
    /// append another record. TERMINAL `.failed`, not a retryable
    /// fetch error: the fetch is pinned to the entry's digest, so a
    /// refetch can only return the same bytes and repeat the mismatch.
    @MainActor
    func testComponentIdMismatchIsTerminalFailed() async throws {
        let flow = try makeFlow(
            raw: try Fixture.bytes("destination-manifest.json"),
            box: StoreBox(),
            entryComponentId: "onym:component:other-service"
        )
        flow.start()
        await flow.loadTask?.value

        XCTAssertEqual(flow.step, .failed, "a mismatched manifest must never reach .reviewing")
        XCTAssertNil(flow.reviewed)
        let message = try XCTUnwrap(flow.errorMessage)
        XCTAssertTrue(message.contains("different component"), message)
        XCTAssertFalse(flow.canAccept)

        flow.tappedRetry()
        XCTAssertEqual(flow.step, .failed, "retry must not re-arm a digest-pinned mismatch")
        XCTAssertNil(flow.loadTask, "retry must not start another load")
    }

    /// Same terminal shape for the operator-key cross-check: the entry
    /// (the verified side) names one key, the digest-pinned manifest
    /// another — no refetch changes either.
    @MainActor
    func testOperatorKeyMismatchIsTerminalFailed() async throws {
        let otherKeyHex = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let flow = try makeFlow(
            raw: try Fixture.bytes("destination-manifest.json"),
            box: StoreBox(),
            entryOperatorKey: "onym:key:\(otherKeyHex)"
        )
        flow.start()
        await flow.loadTask?.value

        XCTAssertEqual(flow.step, .failed)
        XCTAssertNil(flow.reviewed)
        let message = try XCTUnwrap(flow.errorMessage)
        XCTAssertTrue(message.contains("operator key"), message)

        flow.tappedRetry()
        XCTAssertEqual(flow.step, .failed, "retry must not re-arm a digest-pinned mismatch")
        XCTAssertNil(flow.loadTask)
    }

    // MARK: - Reload after fetch failure

    /// A retry after a FETCH failure (genuinely retryable) reloads the
    /// manifest and recomputes entitlements — any offer id left over
    /// in `selectedOfferId` must be cleared first, or the
    /// preselect-on-nil logic would keep a selection the reloaded
    /// manifest doesn't entitle (or carry).
    @MainActor
    func testRetryAfterFetchFailureClearsStaleOfferSelection() async throws {
        final class FailOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var hasFailed = false
            func shouldFail() -> Bool {
                lock.withLock {
                    if hasFailed { return false }
                    hasFailed = true
                    return true
                }
            }
        }
        let raw = try Fixture.bytes("destination-manifest.json")
        let failOnce = FailOnce()
        let flow = try makeFlow(
            raw: raw,
            box: StoreBox(),
            fetchManifestBytes: { _ in
                if failOnce.shouldFail() { throw URLError(.notConnectedToInternet) }
                return raw
            }
        )
        flow.start()
        await flow.loadTask?.value
        XCTAssertEqual(flow.step, .loading, "a fetch failure stays retryable")
        XCTAssertNotNil(flow.errorMessage)

        // Stale state from a previous render (e.g. a row the UI keyed
        // to an offer id that this reload no longer resolves).
        flow.selectedOfferId = "stale-offer"

        flow.tappedRetry()
        await flow.loadTask?.value

        XCTAssertEqual(flow.step, .reviewing)
        XCTAssertEqual(
            flow.selectedOfferId, "courier-free-v1",
            "the reload must recompute the selection, not keep the stale id"
        )
        XCTAssertTrue(flow.canAccept)
    }

    // MARK: - Terminal failures (no Retry that can't succeed)

    /// A moderation entry can never be consented through this surface
    /// — its consent is a signed mandate. The step must be the
    /// TERMINAL `.failed` (rendered without a Retry button), and
    /// `tappedRetry` must not re-arm it: no refetch changes the
    /// entry's seat.
    @MainActor
    func testModerationEntryIsTerminalFailedWithoutRetry() async throws {
        let flow = try makeFlow(raw: try selfSignedRaw(seat: "moderation"), box: StoreBox())
        flow.start()
        await flow.loadTask?.value

        XCTAssertEqual(flow.step, .failed)
        XCTAssertNil(flow.reviewed)
        let message = try XCTUnwrap(flow.errorMessage)
        XCTAssertTrue(message.lowercased().contains("moderation"), message)

        flow.tappedRetry()
        XCTAssertEqual(flow.step, .failed, "retry must not re-arm a terminal failure")
        XCTAssertEqual(flow.errorMessage, message)
        XCTAssertNil(flow.loadTask, "retry must not start another load")
    }

    // (The missing-manifest-URL guard is the same terminal `.failed`
    // shape, but `CatalogEntry`'s decoder rejects any entry whose
    // `manifest.uri` violates the profile URI rules, so an entry with
    // an unparseable URL cannot be constructed to exercise it — the
    // guard is pure defense in depth.)

    // MARK: - Retry after apply failure

    /// `noUsableEndpoint` leaves the consent pinned and returns to
    /// `.reviewing`; a second Accept must retry ONLY the apply — two
    /// attempts end with exactly one consent record and one selection.
    @MainActor
    func testApplyFailureRetryDoesNotReappendConsentOrSelection() async throws {
        let box = StoreBox()
        let flow = try makeFlow(
            raw: try Fixture.bytes("destination-manifest.json"),
            box: box,
            apply: { _ in throw ModuleApplyError.noUsableEndpoint }
        )
        flow.start()
        await flow.loadTask?.value
        XCTAssertEqual(flow.step, .reviewing)

        flow.tappedAccept()
        await flow.acceptTask?.value
        XCTAssertEqual(flow.step, .reviewing)
        XCTAssertNotNil(flow.errorMessage)
        XCTAssertEqual(box.records.count, 1)
        XCTAssertEqual(box.selections.count, 1)

        flow.tappedAccept()
        await flow.acceptTask?.value
        XCTAssertEqual(flow.step, .reviewing)
        XCTAssertEqual(box.records.count, 1, "retry must not append a second consent record")
        XCTAssertEqual(box.selections.count, 1, "retry must not append a second selection")
        XCTAssertEqual(box.events, ["consent", "selection"])
        XCTAssertTrue(try XCTUnwrap(box.records.first).isActive)
    }

    /// The already-pinned probe keys on the manifest hash AND the
    /// selected offer: a retry after the user CHANGED the selection
    /// must take the full accept path (the store's accept supersedes
    /// the active record), so the recorded offerId always matches
    /// what the screen shows — never the original selection.
    @MainActor
    func testRetryWithChangedOfferRecordsTheNewOffer() async throws {
        let box = StoreBox()
        let raw = try selfSignedRaw(seat: "notary", offers: [
            ["offerId": "free-a", "model": "free"],
            ["offerId": "free-b", "model": "free"],
        ])
        let flow = try makeFlow(
            raw: raw,
            box: box,
            apply: { _ in throw ModuleApplyError.noUsableEndpoint }
        )
        flow.start()
        await flow.loadTask?.value
        XCTAssertEqual(flow.step, .reviewing)
        XCTAssertEqual(flow.selectedOfferId, "free-a", "first entitled offer preselects")

        flow.tappedAccept()
        await flow.acceptTask?.value
        XCTAssertEqual(flow.step, .reviewing, "apply failed; consent for free-a is pinned")
        XCTAssertEqual(box.records.count, 1)
        XCTAssertEqual(box.records.last?.offerId, "free-a")

        // The user picks the other offer, then retries.
        flow.selectedOfferId = "free-b"
        flow.tappedAccept()
        await flow.acceptTask?.value

        let active = try XCTUnwrap(box.records.last { $0.isActive })
        XCTAssertEqual(
            active.offerId, "free-b",
            "the ACTIVE record must carry the offer on screen, not the original selection"
        )
        XCTAssertEqual(box.records.count, 2, "changed selection supersedes: deactivate-and-append")
        XCTAssertEqual(box.records.filter(\.isActive).count, 1)
        XCTAssertEqual(box.selections.last?.offerId, "free-b",
                       "the ModuleSelection must record the new offer too")
    }

    // MARK: - Corrupt store on accept

    /// A store that throws on every load — the UserDefaults store's
    /// behavior once its blob stops decoding (accepts are refused
    /// until the history is explicitly cleared).
    struct CorruptPinnedConsentStore: PinnedConsentStore, @unchecked Sendable {
        func load() throws -> [PinnedConsentRecord] {
            throw PinnedConsentStoreError.corruptStore(reason: "test corruption")
        }
        func save(_ records: [PinnedConsentRecord]) throws {
            XCTFail("a corrupt store must never be overwritten by accept")
        }
    }

    /// The corrupt-store accept branch: nothing this surface can do
    /// makes another attempt succeed (the store refuses every accept
    /// until the corrupt history is explicitly cleared), so the step
    /// must be the TERMINAL `.failed` — rendered without any retry
    /// affordance — with the honest nothing-was-changed message.
    @MainActor
    func testCorruptStoreOnAcceptIsTerminalFailedWithHonestMessage() async throws {
        let box = StoreBox()
        let raw = try Fixture.bytes("destination-manifest.json")
        let manifest = try SignedServiceManifest(raw: raw)
        let corruptStore = CorruptPinnedConsentStore()
        let entry = try catalogEntry(
            componentId: manifest.componentId,
            seatType: manifest.seat,
            raw: raw,
            operatorKey: manifest.operatorKey
        )
        let flow = ModuleConsentFlow(
            entry: AttributedCatalogEntry(entry: entry, source: attribution),
            fetchManifestBytes: { _ in raw },
            consentStore: corruptStore,
            selectionStore: FakeSeatSelectionStore(box: box),
            makeEntitlements: { manifest in
                // The reviewing convenience answers free offers from
                // the manifest itself, so the corrupt store doesn't
                // gate the review step — only the accept.
                FreeTierEntitlementProvider(reviewing: manifest, consentStore: corruptStore)
            },
            apply: { _ in XCTFail("apply must not run when consent could not be recorded") }
        )
        flow.start()
        await flow.loadTask?.value
        XCTAssertEqual(flow.step, .reviewing)
        XCTAssertTrue(flow.canAccept)

        flow.tappedAccept()
        await flow.acceptTask?.value

        XCTAssertEqual(flow.step, .failed, "a corrupt store is terminal for this surface")
        let message = try XCTUnwrap(flow.errorMessage)
        XCTAssertTrue(message.contains("couldn't be read"), message)
        XCTAssertTrue(message.contains("Nothing was changed"), message)
        XCTAssertTrue(box.selections.isEmpty, "no selection may reference an unpinned consent")

        flow.tappedRetry()
        XCTAssertEqual(flow.step, .failed, "retry must not re-arm a corrupt-store failure")
        XCTAssertNil(flow.loadTask, "retry must not start another load")
    }
}
