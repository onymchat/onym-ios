import Foundation

/// Deterministic `RandomNumberGenerator` for tests that exercise
/// random-strategy selection. Uses a simple linear congruential
/// generator (LCG) — not cryptographically random, but reproducible
/// across runs given the same seed. Sufficient for asserting that
/// `endpoints.randomElement(using:)` cycles through expected indices.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // Knuth LCG constants
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
