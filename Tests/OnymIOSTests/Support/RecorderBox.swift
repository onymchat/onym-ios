import Foundation

/// A lock-backed box for a value recorded inside a `@Sendable` handler
/// on some other thread (a URLProtocol callback, a failure hook) and
/// read back from the test thread. The awaits in a test usually give a
/// happens-after in practice, but under Swift 5 mode nothing checks —
/// this box makes the crossing explicit, safe, and typed where an
/// `NSMutableDictionary` is none of the three.
final class RecorderBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func record(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        stored = value
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
