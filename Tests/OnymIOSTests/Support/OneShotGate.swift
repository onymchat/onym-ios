import Foundation

/// A reusable one-shot gate for holding an async call open until the
/// test decides to let it through. Open is sticky: waiters that arrive
/// after `open()` pass immediately. Lock-backed rather than an actor
/// so `open()` can be called from synchronous test code, and one type
/// rather than the two identical private copies the push tests grew.
final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let resumed = waiters
        waiters = []
        lock.unlock()
        for waiter in resumed { waiter.resume() }
    }
}
