import Foundation

/// Wraps a `ChainStateReading` with two defenses against the launch-time
/// `get_commitment` request storm and the relayer throttling it triggers:
///
///  1. **Bounded retry** — a single transient read failure (relayer 429 /
///     network blip) no longer surfaces as "couldn't verify". We retry a
///     few times with linear backoff before giving up, so a momentarily
///     throttled relayer doesn't make a fresh join silently fail.
///  2. **Short TTL cache** — collapses a burst of reads for the *same*
///     group (e.g. an invitation plus several member announcements
///     replayed together on a relay reconnect) into one round-trip.
///
/// The TTL is deliberately short: a stale entry can only ever make a
/// caller see an older `(commitment, epoch)`, which the dispatcher treats
/// as "chain behind → defer + retry" (never a reject), so staleness
/// self-heals once the entry expires. It is therefore safe to cache
/// without risking a false rejection — the worst case is a brief deferral.
///
/// `SEPContractChainStateReader` itself stays cache-free (chain state is
/// the source of truth); this decorator is the single place that trades a
/// little staleness for far fewer relayer calls. Mirrors the posture
/// onym-android should adopt around its own commitment reads.
actor CachingChainStateReader: ChainStateReading {
    private let inner: any ChainStateReading
    private let ttl: TimeInterval
    private let maxAttempts: Int
    private let baseRetryDelayMillis: UInt64
    private let now: @Sendable () -> Date

    private var cache: [Data: (entry: SEPCommitmentEntry, at: Date)] = [:]

    init(
        inner: any ChainStateReading,
        ttl: TimeInterval = 10,
        maxAttempts: Int = 3,
        baseRetryDelayMillis: UInt64 = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inner = inner
        self.ttl = ttl
        self.maxAttempts = max(1, maxAttempts)
        self.baseRetryDelayMillis = baseRetryDelayMillis
        self.now = now
    }

    func tyrannyCommitment(groupID: Data) async throws -> SEPCommitmentEntry {
        if let hit = cache[groupID], now().timeIntervalSince(hit.at) < ttl {
            return hit.entry
        }

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                let entry = try await inner.tyrannyCommitment(groupID: groupID)
                cache[groupID] = (entry, now())
                return entry
            } catch {
                lastError = error
                // Linear backoff between attempts; no sleep after the last.
                if attempt < maxAttempts - 1, baseRetryDelayMillis > 0 {
                    let delay = baseRetryDelayMillis * UInt64(attempt + 1)
                    try? await Task.sleep(nanoseconds: delay * 1_000_000)
                }
            }
        }
        throw lastError ?? ChainReadError.noActiveRelayer
    }
}
