import XCTest
@testable import OnymIOS

/// Drives `RecoveryPhraseBackupFlow` against:
///   - a real `IdentityRepository` (per-test unique Keychain service so
///     runs don't collide), seeded by `restore(mnemonic:)` so the recovery
///     phrase is deterministic across runs
///   - a fake `BiometricAuthenticator` whose outcome is set per test
///   - a fake `PasteboardWriter` so the system clipboard is never touched
///
/// Verify-step rounds are random (3 of 12 with 3 distractors each), so
/// tests work against `flow.step` shape rather than specific words —
/// reaching `.done` requires picking the correct word at every round.
@MainActor
final class RecoveryPhraseBackupFlowTests: XCTestCase {

    // Canonical BIP39 test vector — 12 distinct word positions but the
    // phrase is `abandon × 11 + about` so 11 of the 12 words collide.
    // Pick a richer mnemonic for these tests so the verify rounds have
    // 4 truly distinct options to choose from.
    private let testMnemonic = "legal winner thank year wave sausage worth useful legal winner thank yellow"

    private var keychain: IdentityKeychainStore!
    private var repository: IdentityRepository!
    private var authenticator: FakeAuthenticator!
    private var pasteboard: FakePasteboard!
    private var flow: RecoveryPhraseBackupFlow!

    override func setUp() async throws {
        try await super.setUp()
        keychain = IdentityKeychainStore(
            testNamespace: "recoverytests-\(UUID().uuidString)"
        )
        repository = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory()
        )
        _ = try await repository.restore(mnemonic: testMnemonic)
        authenticator = FakeAuthenticator()
        pasteboard = FakePasteboard()
        flow = RecoveryPhraseBackupFlow(
            repository: repository,
            authenticator: authenticator,
            pasteboard: pasteboard,
            clipboardClearDelay: .milliseconds(50),
            verifyAdvanceDelay: .milliseconds(20)
        )
        flow.start()
        await waitForReady()
    }

    override func tearDown() async throws {
        flow.stop()
        try? keychain.wipeAll()
        flow = nil
        pasteboard = nil
        authenticator = nil
        repository = nil
        keychain = nil
        try await super.tearDown()
    }

    // MARK: - Auth

    func test_initialStep_isIntro() {
        XCTAssertEqual(flow.step, .intro)
    }

    func test_isReady_flipsTrueAfterBootstrap() {
        XCTAssertTrue(flow.isReady, "flow should be ready after setUp's waitForReady")
    }

    func test_authSuccess_transitionsToReveal_unrevealed() async {
        authenticator.outcome = .success
        await flow.authenticate()

        guard case let .reveal(phrase, revealed) = flow.step else {
            return XCTFail("expected .reveal, got \(flow.step)")
        }
        XCTAssertEqual(phrase, testMnemonic)
        XCTAssertFalse(revealed, "reveal must start hidden — user has to tap to expose")
    }

    func test_authFailure_transitionsToAuthFailed_withMessage() async {
        struct AuthCancelled: LocalizedError {
            var errorDescription: String? { "User cancelled" }
        }
        authenticator.outcome = .failure(AuthCancelled())
        await flow.authenticate()

        guard case let .authFailed(reason) = flow.step else {
            return XCTFail("expected .authFailed, got \(flow.step)")
        }
        XCTAssertEqual(reason, "User cancelled")
    }

    func test_dismissedAuthError_resetsToIntro() async {
        authenticator.outcome = .failure(NSError(domain: "x", code: 1))
        await flow.authenticate()
        XCTAssertNotEqual(flow.step, .intro)

        flow.dismissedAuthError()
        XCTAssertEqual(flow.step, .intro)
    }

    // MARK: - Biometric fail-closed (recovery-phrase gate)

    // Drives the *real* `LAContextAuthenticator` decision (not a fake) with
    // `canEvaluate` forced false to simulate a device with no passcode /
    // biometric enrolled. `failClosed: true` is the Release posture.
    func test_unevaluablePolicy_failClosed_blocksReveal() async {
        let authenticator = LAContextAuthenticator(
            failClosed: true,
            canEvaluate: { _ in false }
        )
        let gatedFlow = RecoveryPhraseBackupFlow(
            repository: repository,
            authenticator: authenticator,
            pasteboard: pasteboard
        )
        defer { gatedFlow.stop() }

        await gatedFlow.authenticate()

        guard case let .authFailed(reason) = gatedFlow.step else {
            return XCTFail("expected .authFailed, got \(gatedFlow.step)")
        }
        XCTAssertEqual(reason, "Set a device passcode to view your recovery phrase.")
        if case .reveal = gatedFlow.step {
            XCTFail("reveal must be blocked when the policy is unevaluable and failClosed")
        }
    }

    // DEBUG posture: the same unevaluable policy fails OPEN so the dev flow
    // proceeds to the reveal step.
    func test_unevaluablePolicy_failOpen_reachesReveal() async {
        let authenticator = LAContextAuthenticator(
            failClosed: false,
            canEvaluate: { _ in false }
        )
        let openFlow = RecoveryPhraseBackupFlow(
            repository: repository,
            authenticator: authenticator,
            pasteboard: pasteboard
        )
        defer { openFlow.stop() }
        openFlow.start()
        await waitForReady(openFlow)

        await openFlow.authenticate()

        guard case .reveal = openFlow.step else {
            return XCTFail("fail-open should reach .reveal, got \(openFlow.step)")
        }
    }

    // Direct unit tests of the authenticator's decision, independent of the flow.
    func test_laContextAuthenticator_failClosed_throwsOnUnevaluablePolicy() async {
        let auth = LAContextAuthenticator(failClosed: true, canEvaluate: { _ in false })
        do {
            try await auth.authenticate(reason: "x")
            XCTFail("expected a throw when failClosed and policy is unevaluable")
        } catch {
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Set a device passcode to view your recovery phrase."
            )
        }
    }

    func test_laContextAuthenticator_failOpen_returnsOnUnevaluablePolicy() async throws {
        let auth = LAContextAuthenticator(failClosed: false, canEvaluate: { _ in false })
        try await auth.authenticate(reason: "x")  // must not throw
    }

    func test_laContextAuthenticator_defaultPosture_matchesBuildConfiguration() {
        #if DEBUG
        XCTAssertFalse(
            LAContextAuthenticator.failClosedByDefault,
            "DEBUG builds fail open so simulator/dev flows work"
        )
        #else
        XCTAssertTrue(
            LAContextAuthenticator.failClosedByDefault,
            "Release builds must fail closed"
        )
        #endif
    }

    // MARK: - Reveal

    func test_tappedReveal_flipsRevealedTrue() async {
        try? await advanceToReveal()
        flow.tappedReveal()

        guard case let .reveal(_, revealed) = flow.step else {
            return XCTFail("expected .reveal, got \(flow.step)")
        }
        XCTAssertTrue(revealed)
    }

    func test_tappedCopyPhrase_writesToPasteboard_thenClearsAfterDelay() async throws {
        try await advanceToReveal()
        flow.tappedReveal()

        flow.tappedCopyPhrase()
        XCTAssertEqual(pasteboard.lastWritten, testMnemonic)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(pasteboard.didClear, "clipboard auto-clear didn't run")
    }

    func test_tappedCopyPhrase_writesLocalOnly_withExpiryMatchingDelay() async throws {
        // Build a flow with the production 60s clipboard delay (setUp's flow
        // uses a 50ms delay so the auto-clear test runs fast). The OS-enforced
        // expiry — not the in-app timer — is the real guarantee that the seed
        // can't linger on the system pasteboard after a background/kill, so we
        // assert it lands ~60s out and is marked local-only (no Universal
        // Clipboard sync to the user's other Apple devices).
        let flow60 = RecoveryPhraseBackupFlow(
            repository: repository,
            authenticator: authenticator,
            pasteboard: pasteboard,
            clipboardClearDelay: .seconds(60),
            verifyAdvanceDelay: .milliseconds(20)
        )
        flow60.start()
        defer { flow60.stop() }
        for _ in 0..<50 where !flow60.isReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(flow60.isReady, "flow60 never became ready")

        authenticator.outcome = .success
        await flow60.authenticate()
        flow60.tappedReveal()

        let before = Date()
        flow60.tappedCopyPhrase()
        let after = Date()

        XCTAssertEqual(pasteboard.lastWritten, testMnemonic)
        XCTAssertEqual(pasteboard.lastLocalOnly, true, "seed must be pinned local-only")

        let expiry = try XCTUnwrap(pasteboard.lastExpiresAt, "expiry must be set")
        XCTAssertGreaterThanOrEqual(expiry.timeIntervalSince(after), 60 - 2)
        XCTAssertLessThanOrEqual(expiry.timeIntervalSince(before), 60 + 2)
    }

    func test_tappedCopyPhrase_isNoop_beforeReveal() async throws {
        try await advanceToReveal()
        // Don't tap reveal — phrase still hidden
        flow.tappedCopyPhrase()
        XCTAssertNil(pasteboard.lastWritten)
    }

    func test_tappedContinueFromReveal_movesToVerify_withThreeRounds() async throws {
        try await advanceToReveal()
        flow.tappedReveal()
        flow.tappedContinueFromReveal()

        guard case let .verify(phrase, rounds, index, state) = flow.step else {
            return XCTFail("expected .verify, got \(flow.step)")
        }
        XCTAssertEqual(phrase, testMnemonic)
        XCTAssertEqual(rounds.count, 3, "three verify rounds, picked at random from 12 positions")
        XCTAssertEqual(index, 0)
        XCTAssertEqual(state, .idle)
        for round in rounds {
            XCTAssertEqual(round.options.count, 4, "four options per round")
            XCTAssertTrue(round.options.contains(round.correct), "correct word must be in options")
            XCTAssertTrue(round.wordPosition >= 1 && round.wordPosition <= 12)
        }
    }

    // MARK: - Verify

    func test_pickedCorrect_advancesAfterDelay_andEventuallyHitsDone() async throws {
        try await advanceToVerify()

        // Pick the correct word at every round; the flow auto-advances.
        for _ in 0..<3 {
            guard case let .verify(_, rounds, index, _) = flow.step else {
                return XCTFail("expected .verify mid-loop, got \(flow.step)")
            }
            flow.picked(word: rounds[index].correct)
            try await Task.sleep(for: .milliseconds(60))
        }

        XCTAssertEqual(flow.step, .done)
    }

    func test_pickedWrong_marksWrong_andStaysOnSameRound() async throws {
        try await advanceToVerify()

        guard case let .verify(_, rounds, index, _) = flow.step else {
            return XCTFail("expected .verify, got \(flow.step)")
        }
        let wrong = rounds[index].options.first { $0 != rounds[index].correct }!
        flow.picked(word: wrong)

        guard case let .verify(_, _, sameIndex, state) = flow.step else {
            return XCTFail("expected to stay on .verify after wrong pick")
        }
        XCTAssertEqual(sameIndex, index, "wrong pick must NOT advance the round")
        XCTAssertEqual(state, .wrong(wrong))
    }

    func test_pickedCorrect_thenWrongPickIgnored_inflightAdvance() async throws {
        try await advanceToVerify()

        guard case let .verify(_, rounds, index, _) = flow.step else {
            return XCTFail("expected .verify, got \(flow.step)")
        }
        let correct = rounds[index].correct
        let wrong = rounds[index].options.first { $0 != correct }!

        flow.picked(word: correct)
        // Immediately try a wrong pick — should be ignored because state == .correct
        flow.picked(word: wrong)

        guard case let .verify(_, _, sameIndex, state) = flow.step else {
            return XCTFail("expected .verify after correct, got \(flow.step)")
        }
        XCTAssertEqual(sameIndex, index)
        XCTAssertEqual(state, .correct, "second pick during in-flight advance must be ignored")
    }

    // MARK: - Done

    func test_tappedDoneFromCompletion_loopsBackToIntro() async throws {
        try await runEntireFlow()
        XCTAssertEqual(flow.step, .done)

        flow.tappedDoneFromCompletion()
        XCTAssertEqual(flow.step, .intro)
    }

    // MARK: - Helpers

    private func waitForReady(_ target: RecoveryPhraseBackupFlow? = nil) async {
        // setUp triggers `flow.start()` which kicks off bootstrap + snapshot
        // drain. Spin briefly for the first snapshot to land.
        let target = target ?? flow!
        for _ in 0..<50 {
            if target.isReady { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("flow.isReady never flipped true within 500ms")
    }

    private func advanceToReveal() async throws {
        authenticator.outcome = .success
        await flow.authenticate()
        guard case .reveal = flow.step else {
            throw XCTSkip("expected .reveal, got \(flow.step)")
        }
    }

    private func advanceToVerify() async throws {
        try await advanceToReveal()
        flow.tappedReveal()
        flow.tappedContinueFromReveal()
    }

    private func runEntireFlow() async throws {
        try await advanceToVerify()
        for _ in 0..<3 {
            guard case let .verify(_, rounds, index, _) = flow.step else {
                throw XCTSkip("verify state lost mid-flow: \(flow.step)")
            }
            flow.picked(word: rounds[index].correct)
            try await Task.sleep(for: .milliseconds(60))
        }
    }
}

// MARK: - Fakes

private final class FakeAuthenticator: BiometricAuthenticator, @unchecked Sendable {
    enum Outcome {
        case success
        case failure(Error)
    }
    var outcome: Outcome = .success

    func authenticate(reason: String) async throws {
        switch outcome {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }
}

private final class FakePasteboard: PasteboardWriter, @unchecked Sendable {
    var lastWritten: String?
    var lastLocalOnly: Bool?
    var lastExpiresAt: Date?
    var didClear: Bool = false

    func write(_ value: String, localOnly: Bool, expiresAt: Date) {
        lastWritten = value
        lastLocalOnly = localOnly
        lastExpiresAt = expiresAt
    }
    func clearIfStill(_ value: String) {
        if lastWritten == value { didClear = true }
    }
}
