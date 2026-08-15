import Foundation
import XCTest
@testable import OnymDiscovery

final class DiscoveryTrustTests: XCTestCase {
    // MARK: - Provider manifest

    func testProviderManifestFixtureVerifiesOnFirstAdd() throws {
        let raw = try Fixture.bytes("provider-manifest.json")
        let signed = try DiscoveryTrust.verifyProviderManifest(
            raw: raw,
            pinnedOperatorKeyHex: nil,
            now: Fixture.now
        )
        // TOFU: the manifest's own operator key is what verified the
        // signature and is returned for pinning.
        XCTAssertEqual(signed.operatorPublicKeyHex, Fixture.operatorKeyHex)
        XCTAssertEqual(signed.manifest.providerId, "onym:component:onym-discovery")
        XCTAssertEqual(signed.manifest.seat, "discovery")
        XCTAssertEqual(signed.manifest.catalogs.map(\.catalogId), ["public-all-seats"])
        XCTAssertEqual(signed.rawBytes, raw)
        XCTAssertEqual(signed.manifestDigest, DiscoveryFormat.sha256Digest(of: raw))
    }

    func testProviderManifestVerifiesAgainstMatchingPinnedKey() throws {
        let raw = try Fixture.bytes("provider-manifest.json")
        XCTAssertNoThrow(try DiscoveryTrust.verifyProviderManifest(
            raw: raw,
            pinnedOperatorKeyHex: Fixture.operatorKeyHex,
            now: Fixture.now
        ))
    }

    func testProviderManifestRejectsMismatchedPinnedKey() throws {
        let raw = try Fixture.bytes("provider-manifest.json")
        let otherKey = String(repeating: "ab", count: 32)
        assertThrowsTrustError(try DiscoveryTrust.verifyProviderManifest(
            raw: raw,
            pinnedOperatorKeyHex: otherKey,
            now: Fixture.now
        )) {
            if case .providerManifestInvalid = $0 { return true }
            return false
        }
    }

    func testProviderManifestRejectsExpiredValidUntil() throws {
        let raw = try Fixture.bytes("provider-manifest.json")
        // 2027-06-01, past the fixture's 2026-12-31 validUntil.
        let late = Date(timeIntervalSince1970: 1_811_808_000)
        assertThrowsTrustError(try DiscoveryTrust.verifyProviderManifest(
            raw: raw, pinnedOperatorKeyHex: nil, now: late
        )) {
            if case .providerManifestInvalid = $0 { return true }
            return false
        }
    }

    // MARK: - Tamper cases

    func testFlippedSignatureByteIsRejected() throws {
        let raw = try Fixture.bytes("provider-manifest.json")
        var text = String(data: raw, encoding: .utf8)!
        // Flip one character inside the base64 signature value.
        text = text.replacingOccurrences(of: "G3c5sbqg", with: "H3c5sbqg")
        XCTAssertNotEqual(Data(text.utf8), raw)
        assertThrowsTrustError(try DiscoveryTrust.verifyProviderManifest(
            raw: Data(text.utf8), pinnedOperatorKeyHex: nil, now: Fixture.now
        )) {
            if case .providerManifestInvalid(let reason) = $0 {
                return reason.contains("signature")
            }
            return false
        }
    }

    func testUnknownTopLevelFieldIsRejected() throws {
        let raw = try Fixture.bytes("provider-manifest.json")
        var text = String(data: raw, encoding: .utf8)!
        text = text.replacingOccurrences(of: #"{"capabilities""#, with: #"{"extraField":1,"capabilities""#)
        assertThrowsTrustError(try DiscoveryTrust.verifyProviderManifest(
            raw: Data(text.utf8), pinnedOperatorKeyHex: nil, now: Fixture.now
        )) {
            if case .providerManifestInvalid(let reason) = $0 {
                return reason.contains("extraField")
            }
            return false
        }
    }

    func testHTTPSnapshotURILeavesZeroSurvivingDescriptors() throws {
        // §4.1: a malformed descriptor (here, an http snapshot URI) is
        // skipped, not document-fatal — but a manifest whose only
        // descriptor was skipped has zero survivors and is invalid.
        let raw = try Fixture.bytes("provider-manifest.json")
        var text = String(data: raw, encoding: .utf8)!
        text = text.replacingOccurrences(
            of: "https://discovery.onym.app/catalogs/public-all-seats.json",
            with: "http://discovery.onym.app/catalogs/public-all-seats.json"
        )
        assertThrowsTrustError(try DiscoveryTrust.verifyProviderManifest(
            raw: Data(text.utf8), pinnedOperatorKeyHex: nil, now: Fixture.now
        )) {
            if case .providerManifestInvalid(let reason) = $0 {
                return reason.contains("no surviving catalog descriptors")
            }
            return false
        }
    }

    func testMissingPrivacyProfileIsRejected() throws {
        // privacyProfile / privacyProfileUri are required (§4.1).
        let raw = try Fixture.bytes("provider-manifest.json")
        var text = String(data: raw, encoding: .utf8)!
        text = text.replacingOccurrences(
            of: #""privacyProfile":"sha256:3333333333333333333333333333333333333333333333333333333333333333","#,
            with: ""
        )
        XCTAssertNotEqual(Data(text.utf8), raw, "removal must have matched")
        assertThrowsTrustError(try DiscoveryTrust.verifyProviderManifest(
            raw: Data(text.utf8), pinnedOperatorKeyHex: nil, now: Fixture.now
        )) {
            if case .providerManifestInvalid = $0 { return true }
            return false
        }
    }

    // MARK: - Snapshot chain

    private func verifiedManifest() throws -> SignedProviderManifest {
        try DiscoveryTrust.verifyProviderManifest(
            raw: try Fixture.bytes("provider-manifest.json"),
            pinnedOperatorKeyHex: nil,
            now: Fixture.now
        )
    }

    /// Retained acceptance state derived from a previously accepted
    /// snapshot's exact bytes — what the repository persists per §8.
    private func retained(
        _ data: Data,
        previousPolicy: String? = nil
    ) throws -> RetainedCatalogAcceptance {
        let snapshot = try DiscoveryJSON.decoder().decode(CatalogSnapshot.self, from: data)
        return RetainedCatalogAcceptance(
            sequence: snapshot.sequence,
            digest: DiscoveryFormat.sha256Digest(of: data),
            previousPolicyDigest: previousPolicy
        )
    }

    func testThreeSnapshotChainVerifiesInOrder() throws {
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        let s2 = try Fixture.bytes("snapshot-2.json")
        let s3 = try Fixture.bytes("snapshot-3.json")

        let a1 = try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil, now: Fixture.now
        )
        XCTAssertEqual(a1.snapshot.sequence, 1)
        XCTAssertNil(a1.snapshot.previousDigest)
        XCTAssertEqual(a1.snapshot.entries.count, 1)
        XCTAssertEqual(a1.snapshot.skippedEntryCount, 0)
        XCTAssertEqual(a1.outcome, .firstAcceptance)
        XCTAssertFalse(a1.policyTransition)

        let a2 = try DiscoveryTrust.verifySnapshot(
            raw: s2, manifest: manifest, expectedCatalogId: "public-all-seats", retained: try retained(s1), now: Fixture.now
        )
        XCTAssertEqual(a2.snapshot.sequence, 2)
        XCTAssertEqual(a2.snapshot.previousDigest, a1.digest)
        XCTAssertEqual(a2.outcome, .successor)

        let a3 = try DiscoveryTrust.verifySnapshot(
            raw: s3, manifest: manifest, expectedCatalogId: "public-all-seats", retained: try retained(s2), now: Fixture.now
        )
        XCTAssertEqual(a3.snapshot.sequence, 3)
        XCTAssertEqual(a3.snapshot.previousDigest, a2.digest)
    }

    func testRollbackIsRejected() throws {
        // Snapshot 1 arriving after snapshot 2 was accepted: sequence
        // regresses — snapshot_invalid, never silently accepted.
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        let s2 = try Fixture.bytes("snapshot-2.json")
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, expectedCatalogId: "public-all-seats", retained: try retained(s2), now: Fixture.now
        )) {
            if case .snapshotInvalid(let reason) = $0 {
                return reason.contains("rollback") || reason.contains("sequence")
            }
            return false
        }
    }

    func testForwardJumpIsAcceptedWithNote() throws {
        // §6/§10 item 8: snapshot 3 after a retained snapshot 1 — the
        // client missed a publication. Accepted, with the jump
        // surfaced as an outcome (never a permanent rejection of an
        // honest catalog).
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        let s3 = try Fixture.bytes("snapshot-3.json")
        let accepted = try DiscoveryTrust.verifySnapshot(
            raw: s3, manifest: manifest, expectedCatalogId: "public-all-seats", retained: try retained(s1), now: Fixture.now
        )
        XCTAssertEqual(accepted.outcome, .forwardJump(missed: 1))
    }

    func testNoOpRefreshIsNotAWarning() throws {
        // §6/§10 item 11: identical latest snapshot re-fetched — the
        // provider simply hasn't published since.
        let manifest = try verifiedManifest()
        let s2 = try Fixture.bytes("snapshot-2.json")
        let accepted = try DiscoveryTrust.verifySnapshot(
            raw: s2, manifest: manifest, expectedCatalogId: "public-all-seats", retained: try retained(s2), now: Fixture.now
        )
        XCTAssertEqual(accepted.outcome, .noOpRefresh)
    }

    func testSameSequenceForkIsRejected() throws {
        // Fork: the retained sequence republished with different
        // bytes — equivocation, never resolved toward either side.
        let manifest = try verifiedManifest()
        let s2 = try Fixture.bytes("snapshot-2.json")
        var text = String(data: s2, encoding: .utf8)!
        text = text.replacingOccurrences(of: #""placement":"policy-ranked""#, with: #""placement":"reordered""#)
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: Data(text.utf8), manifest: manifest, expectedCatalogId: "public-all-seats", retained: try retained(s2), now: Fixture.now
        )) {
            if case .snapshotInvalid(let reason) = $0 { return reason.contains("fork") }
            return false
        }
    }

    func testFirstAcceptanceTakesAnySequence() throws {
        // §6: on first acceptance there is no retained state to
        // compare against — an established catalog past its first
        // snapshot must be addable (TOFU covers trust).
        let manifest = try verifiedManifest()
        let s2 = try Fixture.bytes("snapshot-2.json")
        let accepted = try DiscoveryTrust.verifySnapshot(
            raw: s2, manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil, now: Fixture.now
        )
        XCTAssertEqual(accepted.snapshot.sequence, 2)
        XCTAssertEqual(accepted.outcome, .firstAcceptance)
    }

    func testFutureDatedSnapshotIsRejected() throws {
        // §4.2: generatedAt beyond the 10-minute skew in the future is
        // snapshot_invalid — the 90-day ceiling must not be mintable
        // forward. Fixture generatedAt is 2026-08-13; verify from
        // 2026-08-01.
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        let early = Date(timeIntervalSince1970: 1_785_542_400)
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil, now: early
        )) {
            if case .snapshotInvalid(let reason) = $0 { return reason.contains("future") }
            return false
        }
    }

    func testBornExpiredSnapshotIsRejected() throws {
        // §4.2: expiresAt must be STRICTLY after generatedAt —
        // equality is snapshot_invalid (born expired), not merely
        // expired. The check precedes signature verification, so a
        // textual tamper exercises it.
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        var text = String(data: s1, encoding: .utf8)!
        text = text.replacingOccurrences(
            of: #""expiresAt":"2026-09-12T00:00:00Z""#,
            with: #""expiresAt":"2026-08-13T00:00:00Z""#
        )
        XCTAssertNotEqual(Data(text.utf8), s1)
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: Data(text.utf8), manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil, now: Fixture.now
        )) {
            if case .snapshotInvalid(let reason) = $0 { return reason.contains("not after") }
            return false
        }
    }

    func testPolicyTransitionGrace() throws {
        // §4.2/§10 item 10: manifest updated to a new policy digest,
        // snapshot still citing the previous one — accepted with the
        // transition note when (and only when) the previous
        // declaration was retained; any third digest fails.
        let transitionManifest = try DiscoveryTrust.verifyProviderManifest(
            raw: try Fixture.bytes("policy-transition-manifest.json"),
            pinnedOperatorKeyHex: nil,
            now: Fixture.now
        )
        let s1 = try Fixture.bytes("snapshot-1.json")
        let previousPolicy = "sha256:" + String(repeating: "11", count: 32)

        // Without the retained previous declaration: snapshot_invalid.
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: transitionManifest, expectedCatalogId: "public-all-seats", retained: nil, now: Fixture.now
        )) {
            if case .snapshotInvalid(let reason) = $0 { return reason.contains("policy") }
            return false
        }
        // With it: accepted, transition surfaced.
        let accepted = try DiscoveryTrust.verifySnapshot(
            raw: s1,
            manifest: transitionManifest,
            expectedCatalogId: "public-all-seats", retained: try retained(s1, previousPolicy: previousPolicy),
            now: Fixture.now
        )
        XCTAssertTrue(accepted.policyTransition)
        // A third digest matches neither: snapshot_invalid.
        let third = "sha256:" + String(repeating: "99", count: 32)
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: s1,
            manifest: transitionManifest,
            expectedCatalogId: "public-all-seats", retained: try retained(s1, previousPolicy: third),
            now: Fixture.now
        )) {
            if case .snapshotInvalid = $0 { return true }
            return false
        }
    }

    func testAudienceSkipManifestIsValidAndEmpty() throws {
        // §1/§10 item 13: a manifest of decodable but non-public
        // catalogs is a valid, empty-by-policy source; the skip count
        // is surfaced, and the source is never provider_manifest_invalid.
        let signed = try DiscoveryTrust.verifyProviderManifest(
            raw: try Fixture.bytes("audience-skip-manifest.json"),
            pinnedOperatorKeyHex: nil,
            now: Fixture.now
        )
        XCTAssertTrue(signed.manifest.catalogs.isEmpty)
        XCTAssertEqual(signed.manifest.audienceSkippedCatalogCount, 1)
        XCTAssertEqual(signed.manifest.skippedCatalogCount, 0)
    }

    func testSponsoredDisclosureAndStatusSurvive() throws {
        // §10 item 6 + §4.2 status: the sponsored-placement disclosure
        // and a valid warning status must SURVIVE decoding — an entry
        // carrying a valid status is never skipped (that would be the
        // exact warning-dropping failure the field exists to prevent).
        let manifest = try verifiedManifest()
        let raw = try Fixture.bytes("snapshot-sponsored.json")
        let accepted = try DiscoveryTrust.verifySnapshot(
            raw: raw, manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil, now: Fixture.now
        )
        XCTAssertEqual(accepted.snapshot.entries.count, 2)
        XCTAssertEqual(accepted.snapshot.skippedEntryCount, 0)
        XCTAssertEqual(accepted.snapshot.entries[0].relationship, "sponsored-placement")
        XCTAssertEqual(accepted.snapshot.entries[0].placement, "sponsored")
        let status = try XCTUnwrap(accepted.snapshot.entries[1].status)
        XCTAssertEqual(status.state, "warning")
        XCTAssertNotNil(status.uri)
    }

    func testExpiredSnapshotIsRejected() throws {
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        // 2026-10-01, past the fixture's 2026-09-12 expiresAt (but the
        // manifest's validUntil still holds, so use a pre-verified
        // manifest from the fixture date).
        let late = Date(timeIntervalSince1970: 1_790_812_800)
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil, now: late
        )) { $0 == .snapshotExpired }
    }

    func testExpirySkewBoundary() throws {
        // §4.2/§9: expired only when expiresAt is MORE than 10 minutes
        // in the past. Fixture expiresAt is 2026-09-12T00:00:00Z.
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        let expiresAt = Date(timeIntervalSince1970: 1_789_171_200)
        // Exactly 10 minutes past expiry: within the skew allowance.
        XCTAssertNoThrow(try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil,
            now: expiresAt.addingTimeInterval(10 * 60)
        ))
        // One second beyond the allowance: snapshot_expired.
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil,
            now: expiresAt.addingTimeInterval(10 * 60 + 1)
        )) { $0 == .snapshotExpired }
    }

    func testSnapshotSignatureTamperIsRejected() throws {
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        var text = String(data: s1, encoding: .utf8)!
        text = text.replacingOccurrences(of: "tcU3eQry", with: "tcU3eQrz")
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: Data(text.utf8), manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil, now: Fixture.now
        )) {
            if case .snapshotInvalid(let reason) = $0 {
                return reason.contains("signature")
            }
            return false
        }
    }

    func testCrossCatalogSubstitutionIsRejected() throws {
        // A correctly signed snapshot of catalog A served where catalog
        // B's snapshot was expected must be snapshot_invalid — resolved
        // against the EXPECTED catalog id, never the document's own
        // claim, or B's retained chain state would be clobbered by A's
        // digest/sequence (permanent wedge).
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json") // catalogId public-all-seats
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, expectedCatalogId: "beta-seats",
            retained: nil, now: Fixture.now
        )) {
            if case .snapshotInvalid(let reason) = $0 {
                return reason.contains("cross-catalog")
            }
            return false
        }
    }

    func testManifestValidUntilGetsTheSymmetricSkewAllowance() throws {
        // §4.2/§9: the same 10-minute clock-skew allowance as snapshot
        // expiry. Fixture validUntil is 2026-12-31T23:59:59Z.
        let raw = try Fixture.bytes("provider-manifest.json")
        let validUntil = Date(timeIntervalSince1970: 1_798_761_599)
        XCTAssertNoThrow(try DiscoveryTrust.verifyProviderManifest(
            raw: raw, pinnedOperatorKeyHex: nil,
            now: validUntil.addingTimeInterval(10 * 60)
        ))
        assertThrowsTrustError(try DiscoveryTrust.verifyProviderManifest(
            raw: raw, pinnedOperatorKeyHex: nil,
            now: validUntil.addingTimeInterval(10 * 60 + 1)
        )) {
            if case .providerManifestInvalid(let reason) = $0 {
                return reason.contains("validUntil")
            }
            return false
        }
    }

    func testDuplicateKeyDocumentCannotSplitSignedAndDecodedValues() throws {
        // Dual-parser hardening: plant a duplicate top-level providerId
        // ahead of the real one. The model is decoded from the same
        // JSONSerialization parse the signature canonicalizes, so the
        // planted value can never verify: either the document is
        // rejected outright, or the decoded providerId is exactly the
        // one the signature covered.
        let raw = try Fixture.bytes("provider-manifest.json")
        var text = String(data: raw, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("{"))
        text = "{\"providerId\":\"onym:component:evil\"," + text.dropFirst()
        do {
            let signed = try DiscoveryTrust.verifyProviderManifest(
                raw: Data(text.utf8), pinnedOperatorKeyHex: nil, now: Fixture.now
            )
            XCTAssertEqual(
                signed.manifest.providerId, "onym:component:onym-discovery",
                "a planted duplicate value must never come out of verification"
            )
        } catch {
            // Outright rejection also closes the divergence.
        }
    }

    // MARK: - Destination manifest binding

    func testDestinationManifestDigestBinds() throws {
        let bytes = try Fixture.bytes("destination-manifest.json")
        // The digest pinned by every snapshot fixture's single entry.
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        let accepted = try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil, now: Fixture.now
        )
        let pinned = try XCTUnwrap(accepted.snapshot.entries.first?.manifest.digest)
        XCTAssertNoThrow(try DiscoveryTrust.verifyDestination(bytes: bytes, pinnedDigest: pinned))
    }

    func testDriftedDestinationManifestIsRejected() throws {
        var bytes = try Fixture.bytes("destination-manifest.json")
        bytes[0] = UInt8(ascii: " ")
        let s1 = try Fixture.bytes("snapshot-1.json")
        let manifest = try verifiedManifest()
        let accepted = try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, expectedCatalogId: "public-all-seats", retained: nil, now: Fixture.now
        )
        let pinned = try XCTUnwrap(accepted.snapshot.entries.first?.manifest.digest)
        assertThrowsTrustError(try DiscoveryTrust.verifyDestination(
            bytes: bytes, pinnedDigest: pinned
        )) { $0 == .entryManifestMismatch }
    }
}
