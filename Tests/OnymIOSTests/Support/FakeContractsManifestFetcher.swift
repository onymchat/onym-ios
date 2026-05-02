import Foundation
@testable import OnymIOS

/// `ContractsManifestFetcher` test double. Three modes mirror the
/// `FakeKnownRelayersFetcher` pattern from PR #18 so tests look the
/// same regardless of which seam they're driving.
final class FakeContractsManifestFetcher: ContractsManifestFetcher, @unchecked Sendable {
    enum Mode {
        case succeeds(ContractsManifest)
        case failing(Error)
        case scripted([Result<ContractsManifest, Error>])
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

    func fetchLatest() async throws -> ContractsManifest {
        try lock.withLock {
            fetchCallCount += 1
            switch mode {
            case .succeeds(let manifest):
                return manifest
            case .failing(let error):
                throw error
            case .scripted(let results):
                precondition(scriptIndex < results.count,
                             "FakeContractsManifestFetcher: scripted ran out of results at call #\(scriptIndex + 1)")
                let result = results[scriptIndex]
                scriptIndex += 1
                return try result.get()
            }
        }
    }
}
