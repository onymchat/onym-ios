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
        text = text.replacingOccurrences(of: "tdOfrr8u", with: "udOfrr8u")
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

    func testHTTPSnapshotURIIsRejected() throws {
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
                return reason.contains("URI")
            }
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

    func testThreeSnapshotChainVerifiesInOrder() throws {
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        let s2 = try Fixture.bytes("snapshot-2.json")
        let s3 = try Fixture.bytes("snapshot-3.json")

        let a1 = try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, previousRaw: nil, now: Fixture.now
        )
        XCTAssertEqual(a1.snapshot.sequence, 1)
        XCTAssertNil(a1.snapshot.previousDigest)
        XCTAssertEqual(a1.snapshot.entries.count, 1)
        XCTAssertEqual(a1.snapshot.skippedEntryCount, 0)

        let a2 = try DiscoveryTrust.verifySnapshot(
            raw: s2, manifest: manifest, previousRaw: s1, now: Fixture.now
        )
        XCTAssertEqual(a2.snapshot.sequence, 2)
        XCTAssertEqual(a2.snapshot.previousDigest, a1.digest)

        let a3 = try DiscoveryTrust.verifySnapshot(
            raw: s3, manifest: manifest, previousRaw: s2, now: Fixture.now
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
            raw: s1, manifest: manifest, previousRaw: s2, now: Fixture.now
        )) {
            if case .snapshotInvalid(let reason) = $0 {
                return reason.contains("rollback") || reason.contains("sequence")
            }
            return false
        }
    }

    func testSequenceGapIsRejected() throws {
        // Snapshot 3 directly after snapshot 1: gap.
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        let s3 = try Fixture.bytes("snapshot-3.json")
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: s3, manifest: manifest, previousRaw: s1, now: Fixture.now
        )) {
            if case .snapshotInvalid = $0 { return true }
            return false
        }
    }

    func testFirstObservedSnapshotMustBeSequenceOne() throws {
        let manifest = try verifiedManifest()
        let s2 = try Fixture.bytes("snapshot-2.json")
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: s2, manifest: manifest, previousRaw: nil, now: Fixture.now
        )) {
            if case .snapshotInvalid = $0 { return true }
            return false
        }
    }

    func testExpiredSnapshotIsRejected() throws {
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        // 2026-10-01, past the fixture's 2026-09-12 expiresAt (but the
        // manifest's validUntil still holds, so use a pre-verified
        // manifest from the fixture date).
        let late = Date(timeIntervalSince1970: 1_790_812_800)
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, previousRaw: nil, now: late
        )) { $0 == .snapshotExpired }
    }

    func testSnapshotSignatureTamperIsRejected() throws {
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        var text = String(data: s1, encoding: .utf8)!
        text = text.replacingOccurrences(of: "tcU3eQry", with: "tcU3eQrz")
        assertThrowsTrustError(try DiscoveryTrust.verifySnapshot(
            raw: Data(text.utf8), manifest: manifest, previousRaw: nil, now: Fixture.now
        )) {
            if case .snapshotInvalid(let reason) = $0 {
                return reason.contains("signature")
            }
            return false
        }
    }

    // MARK: - Destination manifest binding

    func testDestinationManifestDigestBinds() throws {
        let bytes = try Fixture.bytes("destination-manifest.json")
        // The digest pinned by every snapshot fixture's single entry.
        let manifest = try verifiedManifest()
        let s1 = try Fixture.bytes("snapshot-1.json")
        let accepted = try DiscoveryTrust.verifySnapshot(
            raw: s1, manifest: manifest, previousRaw: nil, now: Fixture.now
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
            raw: s1, manifest: manifest, previousRaw: nil, now: Fixture.now
        )
        let pinned = try XCTUnwrap(accepted.snapshot.entries.first?.manifest.digest)
        assertThrowsTrustError(try DiscoveryTrust.verifyDestination(
            bytes: bytes, pinnedDigest: pinned
        )) { $0 == .entryManifestMismatch }
    }
}
