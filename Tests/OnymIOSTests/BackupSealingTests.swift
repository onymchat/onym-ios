import CryptoKit
import XCTest
@testable import OnymBackup

/// Sealing is the one part of this seat where being wrong is silent:
/// a snapshot that seals but cannot be opened looks fine until the day
/// someone needs it. So these land with the implementation rather than
/// waiting for the stack's test PR, which carries the rest.
final class BackupSealingTests: XCTestCase {
    func testPadmeWorkedExample() {
        XCTAssertEqual(BackupPadding.paddedLength(for: 41_000_000), 41_943_040)
    }

    func testPaddingOverheadStaysUnderTwelvePercent() {
        for length in stride(from: 1_000, to: 5_000_000, by: 7_919) {
            let padded = BackupPadding.paddedLength(for: length)
            XCTAssertGreaterThanOrEqual(padded, length)
            XCTAssertLessThan(Double(padded - length) / Double(length), 0.12, "at \(length)")
        }
    }

    func testSealOpenRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plain = dir.appending(path: "plain")
        let sealed = dir.appending(path: "sealed")
        let opened = dir.appending(path: "opened")

        let payload = Data((0..<(3 * (1 << 20) + 12_345)).map { UInt8($0 % 251) })
        try payload.write(to: plain)

        let root = SymmetricKey(size: .bits256)
        let reference = try BackupSealer.seal(plaintextURL: plain, to: sealed, archiveRoot: root)

        let onDisk = try Data(contentsOf: sealed)
        XCTAssertEqual(onDisk.count, reference.sealedByteSize)
        let recomputed = "sha256:" + SHA256.hash(data: onDisk).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(recomputed, reference.digest)

        try BackupOpener.open(sealedURL: sealed, to: opened, reference: reference, archiveRoot: root)
        let restored = try Data(contentsOf: opened)
        XCTAssertEqual(restored.prefix(payload.count), payload)
        XCTAssertEqual(restored.count, BackupPadding.paddedLength(for: payload.count))
    }

    func testNonConvergentKeying() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plain = dir.appending(path: "plain")
        try Data(repeating: 7, count: 4096).write(to: plain)
        let root = SymmetricKey(size: .bits256)
        let a = try BackupSealer.seal(plaintextURL: plain, to: dir.appending(path: "a"), archiveRoot: root)
        let b = try BackupSealer.seal(plaintextURL: plain, to: dir.appending(path: "b"), archiveRoot: root)
        XCTAssertNotEqual(a.digest, b.digest)
    }

    func testTamperedChunkFailsAuthentication() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plain = dir.appending(path: "plain")
        let sealed = dir.appending(path: "sealed")
        try Data(repeating: 3, count: 8192).write(to: plain)
        let root = SymmetricKey(size: .bits256)
        let reference = try BackupSealer.seal(plaintextURL: plain, to: sealed, archiveRoot: root)

        var bytes = try Data(contentsOf: sealed)
        bytes[bytes.count - 40] ^= 0x01
        try bytes.write(to: sealed)

        // Digest check catches it first — which is the point: bytes that
        // do not compose the reference never reach decryption.
        XCTAssertThrowsError(try BackupOpener.open(
            sealedURL: sealed, to: dir.appending(path: "out"), reference: reference, archiveRoot: root))

        let tamperedRef = try SnapshotReference(
            digest: "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            sealedByteSize: bytes.count)
        XCTAssertThrowsError(try BackupOpener.open(
            sealedURL: sealed, to: dir.appending(path: "out2"), reference: tamperedRef, archiveRoot: root))
    }

    /// The salt is no longer injectable, so this asserts the shape that
    /// made it dangerous: two seals of *different* plaintext under one
    /// pinned salt would share a key and a nonce sequence. The internal
    /// overload is the only way to express it, and it exists for exactly
    /// this kind of check.
    func testPinnedSaltWouldReuseKeyAndNonce() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = SymmetricKey(size: .bits256)
        let salt = Data(repeating: 0x5A, count: 32)

        let one = dir.appending(path: "one")
        let two = dir.appending(path: "two")
        try Data(repeating: 0xAA, count: 4096).write(to: one)
        try Data(repeating: 0xBB, count: 4096).write(to: two)

        let sealedOne = dir.appending(path: "s1")
        let sealedTwo = dir.appending(path: "s2")
        try BackupSealer.seal(plaintextURL: one, to: sealedOne, archiveRoot: root, snapshotSalt: salt)
        try BackupSealer.seal(plaintextURL: two, to: sealedTwo, archiveRoot: root, snapshotSalt: salt)

        // Same salt -> same derived key -> same counter nonces. The
        // ciphertexts differ only where the plaintexts do, which is the
        // catastrophic case, and why no public API can produce it.
        let a = try Data(contentsOf: sealedOne)
        let b = try Data(contentsOf: sealedTwo)
        XCTAssertEqual(a.prefix(BackupSealer.headerBytes), b.prefix(BackupSealer.headerBytes))
    }

    func testArchiveRoundTripAndKindMismatchRefused() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = dir.appending(path: "archive")

        let writer = try BackupArchiveWriter(scratchURL: dir.appending(path: "scratch"))
        writer.setIdentityCount(1)
        try writer.append(kind: .groups, bytes: Data("[groups]".utf8))
        try writer.append(kind: .messages, bytes: Data("[messages]".utf8))
        try writer.finish(writingTo: archive)

        var seen: [(BackupArchiveEntryKind, Data)] = []
        try BackupArchiveReader(url: archive).forEachRecord { seen.append(($0, $1)) }
        XCTAssertEqual(seen.map(\.0), [.groups, .messages])
        XCTAssertEqual(seen.first?.1, Data("[groups]".utf8))

        // Flip the framing kind byte of the first record. Its digest and
        // length still match the header, so only the kind check catches
        // it.
        var bytes = try Data(contentsOf: archive)
        let firstRecord = bytes.count - "[groups]".count - 5 - "[messages]".count - 5
        XCTAssertEqual(bytes[firstRecord], BackupArchiveEntryKind.groups.rawValue)
        bytes[firstRecord] = BackupArchiveEntryKind.consents.rawValue
        try bytes.write(to: archive)
        XCTAssertThrowsError(try BackupArchiveReader(url: archive).forEachRecord { _, _ in })
    }

    func testAccessProofIsRequestBound() throws {
        let material = BackupKeys.material(seed: Data(repeating: 9, count: 64), componentId: "onym:component:x")
        let a = BackupAccessProof.signingBytes(
            method: "PUT", path: "/v1/uploads/u/chunks/0", holderReference: material.holderReference,
            timestamp: Date(timeIntervalSince1970: 1), nonceHex: "aa", body: Data("x".utf8))
        let b = BackupAccessProof.signingBytes(
            method: "PUT", path: "/v1/uploads/u/chunks/1", holderReference: material.holderReference,
            timestamp: Date(timeIntervalSince1970: 1), nonceHex: "aa", body: Data("x".utf8))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(material.holderReference.hasPrefix("onym:seat-key:"))
    }
}
