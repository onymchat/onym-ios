import Foundation
import SwiftData
import os

/// Shared open-with-recovery policy for the app's SwiftData stores
/// (`Groups.store`, `Messages.store`, `Invitations.store`,
/// `IntroRequests.store`).
///
/// History: each store used to answer ANY `ModelContainer` open error
/// by deleting the SQLite trio and retrying — silently. On 2026-08-16
/// that policy destroyed a device's chat history twice in one day
/// (once at a TestFlight-over-debug install, once at the
/// debug-over-TestFlight reinstall), with nothing in the logs to say
/// why the open failed. Two properties of that incident drive the
/// policy here:
///
/// - The open error was never recorded, so the root cause is
///   unknowable after the fact. Every failure is now logged as a
///   fault with the store name and the thrown error.
/// - Deletion is unrecoverable, and "failed to open" does not imply
///   "worth destroying": a transiently unreadable file (Complete file
///   protection while the device is locked — e.g. a prewarmed or
///   background launch) throws the same way a genuine schema mismatch
///   does. The trio is now moved aside as a `.bak`, never deleted,
///   and only when the store file is actually readable — an
///   unreadable file means the data is fine and the *launch context*
///   is wrong, so the error is rethrown and the caller's in-memory
///   fallback covers the session.
public enum PersistentStoreOpener {
    private static let log = Logger(subsystem: "app.onym.ios", category: "PersistentStoreOpener")

    /// The directory every store shares:
    /// `Application Support/OnymIOS/`, Complete file protection.
    public static func storeDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = appSupport.appendingPathComponent("OnymIOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return dir
    }

    /// Open the on-disk container at `url`; on failure, move the
    /// store trio aside (recoverable) and retry once with a fresh
    /// store. Throws when the store exists but can't be read at all
    /// (locked-device launch) — the data on disk is untouched then.
    public static func openContainer(schema: Schema, url: URL) throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            let name = url.lastPathComponent
            log.fault("open failed for \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            guard isReadable(url) else {
                // Complete file protection while locked (prewarm /
                // background launch) reads exactly like corruption to
                // ModelContainer. The data is intact; destroying or
                // moving it here is the bug this type exists to stop.
                log.fault("\(name, privacy: .public) is unreadable (file protection?) — leaving the store untouched")
                throw error
            }
            moveAsideTrio(at: url)
            return try ModelContainer(for: schema, configurations: [config])
        }
    }

    /// A store that exists but yields no bytes is protected-locked,
    /// not broken. A store that doesn't exist can't lose data either
    /// way — treat it as "readable" so the retry can create it.
    private static func isReadable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil
    }

    /// Rename the SQLite trio to `<name>.bak` siblings, replacing any
    /// previous backup — one generation deep keeps disk use bounded
    /// while making the newest incompatible store recoverable.
    private static func moveAsideTrio(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            let source = url.deletingPathExtension()
                .appendingPathExtension("store\(suffix)")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let backup = source.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            do {
                try FileManager.default.moveItem(at: source, to: backup)
            } catch {
                // A move that fails must not leave the incompatible
                // file in place — the retry would fail identically
                // and the caller would run in-memory forever.
                log.fault("backup move failed for \(source.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: source)
            }
        }
    }
}
