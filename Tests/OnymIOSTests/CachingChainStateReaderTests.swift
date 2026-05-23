import XCTest
@testable import OnymIOS

/// Tests for the cache + retry decorator that tames the launch-time
/// `get_commitment` storm and survives transient relayer throttling.
final class CachingChainStateReaderTests: XCTestCase {

    private let groupID = Data(repeating: 0x42, count: 32)

    func test_cacheHit_collapsesRepeatReadsWithinTTL() async throws {
        let inner = CountingChainState()
        await inner.setResult(.success(entry(epoch: 3)))
        let reader = CachingChainStateReader(inner: inner, ttl: 60, baseRetryDelayMillis: 0)

        _ = try await reader.tyrannyCommitment(groupID: groupID)
        _ = try await reader.tyrannyCommitment(groupID: groupID)

        let calls = await inner.callCount
        XCTAssertEqual(calls, 1, "second read within TTL is served from cache")
    }

    func test_cacheExpiry_readsAgainAfterTTL() async throws {
        let inner = CountingChainState()
        await inner.setResult(.success(entry(epoch: 3)))
        // Clock the reader off a controllable now() so we can step past TTL.
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_000))
        let reader = CachingChainStateReader(
            inner: inner, ttl: 10, baseRetryDelayMillis: 0, now: clock.now
        )

        _ = try await reader.tyrannyCommitment(groupID: groupID)
        clock.advance(by: 11)  // past the 10s TTL
        _ = try await reader.tyrannyCommitment(groupID: groupID)

        let calls = await inner.callCount
        XCTAssertEqual(calls, 2, "an expired cache entry triggers a fresh read")
    }

    func test_retry_recoversFromTransientFailure() async throws {
        let inner = CountingChainState()
        // Throw twice, then succeed — within the 3-attempt budget.
        await inner.setSequence([
            .failure(ChainReadError.noActiveRelayer),
            .failure(ChainReadError.noActiveRelayer),
            .success(entry(epoch: 7)),
        ])
        let reader = CachingChainStateReader(
            inner: inner, ttl: 10, maxAttempts: 3, baseRetryDelayMillis: 0
        )

        let result = try await reader.tyrannyCommitment(groupID: groupID)
        XCTAssertEqual(result.epoch, 7, "retry rides out two transient failures")
        let calls = await inner.callCount
        XCTAssertEqual(calls, 3)
    }

    func test_retry_exhausted_rethrows() async throws {
        let inner = CountingChainState()
        await inner.setResult(.failure(ChainReadError.noContractBinding))
        let reader = CachingChainStateReader(
            inner: inner, ttl: 10, maxAttempts: 3, baseRetryDelayMillis: 0
        )

        do {
            _ = try await reader.tyrannyCommitment(groupID: groupID)
            XCTFail("should have thrown after exhausting retries")
        } catch {
            XCTAssertEqual(error as? ChainReadError, .noContractBinding)
        }
        let calls = await inner.callCount
        XCTAssertEqual(calls, 3, "all attempts are spent before giving up")
    }

    // MARK: - Helpers

    private func entry(epoch: UInt64) -> SEPCommitmentEntry {
        SEPCommitmentEntry(
            commitment: Data(repeating: 0xCC, count: 32),
            epoch: epoch,
            timestamp: 0,
            tier: 0,
            active: nil
        )
    }
}

/// Inner reader that counts calls and yields a configurable result (fixed
/// or a per-call sequence).
private actor CountingChainState: ChainStateReading {
    private(set) var callCount = 0
    private var fixed: Result<SEPCommitmentEntry, Error> = .failure(ChainReadError.noActiveRelayer)
    private var sequence: [Result<SEPCommitmentEntry, Error>] = []

    func setResult(_ result: Result<SEPCommitmentEntry, Error>) { fixed = result }
    func setSequence(_ results: [Result<SEPCommitmentEntry, Error>]) { sequence = results }

    func tyrannyCommitment(groupID: Data) async throws -> SEPCommitmentEntry {
        callCount += 1
        if !sequence.isEmpty {
            return try sequence.removeFirst().get()
        }
        return try fixed.get()
    }
}

/// Tiny mutable clock so a test can step `now()` past the cache TTL
/// deterministically (no real sleeping). `@unchecked Sendable` because the
/// test drives it single-threaded.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { current = start }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current.addTimeInterval(seconds) }
    }

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { current } }
    }
}
