import XCTest
@testable import OnymIOS

/// Per-identity keychain store tests. Each test gets a unique
/// `testNamespace` so concurrent runs don't stomp on each other; the
/// `tearDown` `wipeAll()` only clears items inside that namespace.
final class IdentityKeychainStoreTests: XCTestCase {
    private var store: IdentityKeychainStore!

    override func setUp() {
        super.setUp()
        store = IdentityKeychainStore(testNamespace: "tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? store.wipeAll()
        store = nil
        super.tearDown()
    }

    // MARK: - Read / write

    func test_read_unknownID_returnsNil() throws {
        XCTAssertNil(try store.read(IdentityID()))
    }

    func test_writeThenRead_roundTripsBundle() throws {
        let id = IdentityID()
        let snapshot = StoredSnapshot(
            entropy: Data(repeating: 0xAA, count: 16),
            nostrSecretKey: Data(repeating: 0x01, count: 32),
            blsSecretKey: Data(repeating: 0x02, count: 32)
        )
        try store.write(id, snapshot)
        let loaded = try store.read(id)
        XCTAssertEqual(loaded, snapshot)
    }

    func test_write_isUpdateInPlace() throws {
        let id = IdentityID()
        let v1 = StoredSnapshot(
            entropy: nil,
            nostrSecretKey: Data(repeating: 0x01, count: 32),
            blsSecretKey: Data(repeating: 0x02, count: 32)
        )
        let v2 = StoredSnapshot(
            entropy: Data(repeating: 0x99, count: 16),
            nostrSecretKey: Data(repeating: 0x03, count: 32),
            blsSecretKey: Data(repeating: 0x04, count: 32)
        )
        try store.write(id, v1)
        try store.write(id, v2)
        XCTAssertEqual(try store.read(id), v2,
                       "second write must overwrite, not duplicate the keychain item")
    }

    // MARK: - List

    func test_list_emptyByDefault() throws {
        XCTAssertEqual(try store.list(), [])
    }

    func test_list_returnsEveryWrittenID() throws {
        let ids = (0..<3).map { _ in IdentityID() }
        for id in ids {
            try store.write(id, sampleSnapshot())
        }
        let listed = try store.list()
        XCTAssertEqual(Set(listed), Set(ids),
                       "list() returns every written ID; order isn't guaranteed")
    }

    func test_list_namespaceIsolated() throws {
        let other = IdentityKeychainStore(testNamespace: "other-\(UUID().uuidString)")
        defer { try? other.wipeAll() }
        try store.write(IdentityID(), sampleSnapshot())
        try other.write(IdentityID(), sampleSnapshot())
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try other.list().count, 1,
                       "test namespaces must not see each other's identities")
    }

    // MARK: - Wipe

    func test_wipe_dropsOneIdentityLeavesOthers() throws {
        let keep = IdentityID()
        let drop = IdentityID()
        try store.write(keep, sampleSnapshot())
        try store.write(drop, sampleSnapshot())
        try store.wipe(drop)
        XCTAssertNotNil(try store.read(keep))
        XCTAssertNil(try store.read(drop))
    }

    func test_wipe_unknownID_isNoOp() throws {
        XCTAssertNoThrow(try store.wipe(IdentityID()))
    }

    func test_wipeAll_clearsEverythingInNamespace() throws {
        for _ in 0..<3 {
            try store.write(IdentityID(), sampleSnapshot())
        }
        try store.wipeAll()
        XCTAssertEqual(try store.list(), [])
    }

    // MARK: - Helpers

    private func sampleSnapshot() -> StoredSnapshot {
        StoredSnapshot(
            entropy: nil,
            nostrSecretKey: Data(repeating: 0x42, count: 32),
            blsSecretKey: Data(repeating: 0x43, count: 32)
        )
    }
}
