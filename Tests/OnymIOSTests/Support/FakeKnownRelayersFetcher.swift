import Foundation
@testable import OnymIOS

/// `KnownRelayersFetcher` test double. Three modes:
///
/// - `.succeeds(list)` — every call returns the given list.
/// - `.failing(error)` — every call throws.
/// - `.scripted([result])` — return one result per call, in order;
///   asserts on a fourth call (caught by `precondition`).
///
/// Tracks `fetchCallCount` so tests can assert how many fetches
/// happened (e.g. `start()` is idempotent — second call shouldn't
/// re-fetch while the first is still in flight).
final class FakeKnownRelayersFetcher: KnownRelayersFetcher, @unchecked Sendable {
    enum Mode {
        case succeeds([RelayerEndpoint])
        case failing(Error)
        case scripted([Result<[RelayerEndpoint], Error>])
    }

    private let lock = NSLock()
    private var mode: Mode
    private(set) var fetchCallCount: Int = 0
    private var scriptIndex: Int = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func setMode(_ newMode: Mode) {
        lock.withLock {
            self.mode = newMode
            self.scriptIndex = 0
        }
    }

    func fetchLatest() async throws -> [RelayerEndpoint] {
        try lock.withLock {
            fetchCallCount += 1
            switch mode {
            case .succeeds(let list):
                return list
            case .failing(let error):
                throw error
            case .scripted(let results):
                precondition(scriptIndex < results.count,
                             "FakeKnownRelayersFetcher: scripted ran out of results at call #\(scriptIndex + 1)")
                let result = results[scriptIndex]
                scriptIndex += 1
                return try result.get()
            }
        }
    }
}
