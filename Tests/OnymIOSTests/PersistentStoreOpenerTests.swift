import SwiftData
import XCTest
import OnymFoundation

/// The store-open recovery policy: a store that can't be opened is
/// moved aside as `.bak` — never deleted — and a healthy store is
/// reopened untouched. Born from the 2026-08-16 incident where the
/// old wipe-on-any-error policy destroyed a device's chat history
/// with no log line to explain why.
@Model
private final class Row {
    var value: String
    init(value: String) { self.value = value }
}

final class PersistentStoreOpenerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opener-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        try super.tearDownWithError()
    }

    private var url: URL { dir.appendingPathComponent("Rows.store") }

    func testHealthyStoreReopensWithDataIntactAndNoBackup() throws {
        autoreleasepool {
            let container = try! PersistentStoreOpener.openContainer(
                schema: Schema([Row.self]), url: url
            )
            let context = ModelContext(container)
            context.insert(Row(value: "survives"))
            try! context.save()
        }

        let reopened = try PersistentStoreOpener.openContainer(
            schema: Schema([Row.self]), url: url
        )
        let rows = try ModelContext(reopened).fetch(FetchDescriptor<Row>())
        XCTAssertEqual(rows.map(\.value), ["survives"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path),
            "a clean reopen must not manufacture a backup"
        )
    }

    func testUnopenableStoreIsMovedAsideNotDeleted() throws {
        let garbage = Data("not a sqlite database, definitely".utf8)
        try garbage.write(to: url)

        let container = try PersistentStoreOpener.openContainer(
            schema: Schema([Row.self]), url: url
        )

        // Fresh, usable store at the original path…
        let context = ModelContext(container)
        context.insert(Row(value: "fresh"))
        try context.save()

        // …and the unopenable original preserved byte-for-byte.
        let backup = url.appendingPathExtension("bak")
        XCTAssertEqual(try Data(contentsOf: backup), garbage)
    }

    func testSecondIncidentReplacesTheBackup() throws {
        let first = Data("first broken store".utf8)
        try first.write(to: url)
        _ = try PersistentStoreOpener.openContainer(schema: Schema([Row.self]), url: url)

        try FileManager.default.removeItem(at: url)
        for suffix in ["-shm", "-wal"] {
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent("Rows.store\(suffix)")
            )
        }
        let second = Data("second broken store".utf8)
        try second.write(to: url)
        _ = try PersistentStoreOpener.openContainer(schema: Schema([Row.self]), url: url)

        XCTAssertEqual(
            try Data(contentsOf: url.appendingPathExtension("bak")),
            second,
            "one generation of backup, newest incident wins"
        )
    }
}
