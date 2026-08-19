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
