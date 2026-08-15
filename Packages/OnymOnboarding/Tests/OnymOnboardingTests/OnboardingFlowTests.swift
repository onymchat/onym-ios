import Foundation
import XCTest
@testable import OnymOnboarding

@MainActor
final class OnboardingFlowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: UserDefaultsOnboardingStore!

    override func setUp() {
        super.setUp()
        suiteName = "app.onym.ios.onboarding.flow.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = UserDefaultsOnboardingStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        super.tearDown()
    }

    private func makeFlow(
        moderationDirectoryNonEmpty: @escaping () async -> Bool = { false },
        onCompleted: @escaping @MainActor () -> Void = {}
    ) -> OnboardingFlow {
        OnboardingFlow(
            store: store,
            moderationDirectoryNonEmpty: moderationDirectoryNonEmpty,
            onCompleted: onCompleted
        )
    }

    /// A flow whose directory probe has already answered — most walk
    /// tests need this, because an unresolved probe leaves moderation
    /// mandatory (fail-closed) and `advance()` refuses to pass it.
    private func makeResolvedFlow(
        directoryNonEmpty: Bool = false,
        onCompleted: @escaping @MainActor () -> Void = {}
    ) async -> OnboardingFlow {
        let flow = makeFlow(
            moderationDirectoryNonEmpty: { directoryNonEmpty },
            onCompleted: onCompleted
        )
        flow.start()
        await flow.moderationProbeTask?.value
        return flow
    }

    // MARK: - Step order

    func testStepsAdvanceInDocumentedOrder() async {
        let flow = await makeResolvedFlow()
        var visited: [OnboardingStep] = [flow.step]
        while flow.step != .done {
            flow.advance()
            visited.append(flow.step)
        }
        XCTAssertEqual(visited, [
            .welcome, .identity, .services,
            .moderation, .recoveryPhrase, .done,
        ])
    }

    func testAdvanceOnDoneIsANoOp() async {
        let flow = await makeResolvedFlow()
        while flow.step != .done { flow.advance() }
        flow.advance()
        XCTAssertEqual(flow.step, .done)
    }

    // MARK: - Step indicator

    /// The indicator counts the three core steps only — welcome, the
    /// recovery phrase, and Done are unnumbered.
    func testIndicatorCoversExactlyTheThreeCoreSteps() {
        let flow = makeFlow()
        XCTAssertNil(flow.indicatorPosition(for: .welcome))
        XCTAssertNil(flow.indicatorPosition(for: .recoveryPhrase))
        XCTAssertNil(flow.indicatorPosition(for: .done))
        XCTAssertEqual(flow.indicatorPosition(for: .identity)?.index, 0)
        XCTAssertEqual(flow.indicatorPosition(for: .services)?.index, 1)
        XCTAssertEqual(flow.indicatorPosition(for: .moderation)?.index, 2)
        XCTAssertEqual(flow.indicatorPosition(for: .identity)?.count, 3)
    }

    // MARK: - Back

    func testBackWalksToThePreviousStep() {
        let flow = makeFlow()
        flow.advance()
        flow.advance()
        XCTAssertEqual(flow.step, .services)
        flow.back()
        XCTAssertEqual(flow.step, .identity)
        flow.back()
        XCTAssertEqual(flow.step, .welcome)
    }

    func testBackOnWelcomeIsANoOp() {
        let flow = makeFlow()
        flow.back()
        XCTAssertEqual(flow.step, .welcome)
    }

    func testBackKeepsThePriorOutcomeUntilOverwritten() {
        let flow = makeFlow()
        flow.advance() // identity
        flow.advance() // services
        flow.recordOutcome(.consented(componentId: nil))
        flow.back() // revisit identity
        flow.advance() // services again
        XCTAssertEqual(flow.outcomes[.services], .consented(componentId: nil))
        flow.recordOutcome(.notApplicable)
        XCTAssertEqual(flow.outcomes[.services], .notApplicable)
    }

    // MARK: - Skip

    /// The recovery phrase is the ONLY skippable step ("Remind me
    /// later") — everything else advances through Continue alone.
    func testOnlyRecoveryPhraseIsSkippable() {
        let flow = makeFlow()
        for step in OnboardingStep.allCases {
            XCTAssertEqual(
                flow.isSkippable(step),
                step == .recoveryPhrase,
                "\(step) skippability"
            )
        }
    }

    func testSkipOnRecoveryPhraseRecordsSkippedAndAdvances() async {
        let flow = await makeResolvedFlow()
        while flow.step != .recoveryPhrase { flow.advance() }
        flow.skip()
        XCTAssertEqual(flow.step, .done)
        XCTAssertEqual(flow.outcomes[.recoveryPhrase], .skipped)
    }

    func testSkipOnUnskippableStepIsANoOp() {
        let flow = makeFlow()
        flow.advance() // identity
        flow.skip()
        XCTAssertEqual(flow.step, .identity)
        XCTAssertNil(flow.outcomes[.identity])
    }

    func testAdvanceWithoutDecisionBackfillsNotApplicable() {
        let flow = makeFlow()
        flow.advance()
        XCTAssertEqual(flow.outcomes[.welcome], .notApplicable)
    }

    func testAdvanceDoesNotOverwriteARecordedOutcome() {
        let flow = makeFlow()
        flow.advance() // identity
        flow.advance() // services
        flow.recordOutcome(.consented(componentId: "onym:component:onym-discovery"))
        flow.advance()
        XCTAssertEqual(
            flow.outcomes[.services],
            .consented(componentId: "onym:component:onym-discovery")
        )
    }

    func testDoneIsNeverSkippable() async {
        let flow = await makeResolvedFlow()
        while flow.step != .done { flow.advance() }
        XCTAssertFalse(flow.isSkippable(.done))
        flow.skip()
        XCTAssertEqual(flow.step, .done)
        XCTAssertNil(flow.outcomes[.done])
    }

    // MARK: - Moderation is never skippable

    /// The rule, across every probe state: moderation offers NO skip
    /// path. Unresolved, resolved-empty, resolved-non-empty — always
    /// unskippable, and `skip()` is always a no-op there.
    func testModerationNeverSkippableInAnyProbeState() async {
        // Unresolved (probe not started).
        let unresolved = makeFlow(moderationDirectoryNonEmpty: { false })
        XCTAssertFalse(unresolved.isSkippable(.moderation))

        // Resolved empty.
        let empty = await makeResolvedFlow(directoryNonEmpty: false)
        XCTAssertFalse(empty.isSkippable(.moderation))
        while empty.step != .moderation { empty.advance() }
        empty.skip() // no-op — there is no skip path
        XCTAssertEqual(empty.step, .moderation)
        XCTAssertNil(empty.outcomes[.moderation])

        // Resolved non-empty.
        let nonEmpty = await makeResolvedFlow(directoryNonEmpty: true)
        XCTAssertFalse(nonEmpty.isSkippable(.moderation))
    }

    /// EMPTY directory: nothing is selectable, so the step must not
    /// hard-block — it turns Continue-only informational. The advance
    /// is an acknowledgment, recorded as the distinct `.unavailable`
    /// (never `.skipped` — opting out of moderation is not a thing).
    func testModerationEmptyDirectoryIsContinueOnlyAcknowledgment() async {
        let flow = await makeResolvedFlow(directoryNonEmpty: false)
        XCTAssertFalse(flow.isMandatory(.moderation))
        XCTAssertFalse(flow.isSkippable(.moderation))

        while flow.step != .moderation { flow.advance() }
        flow.advance() // plain Continue
        XCTAssertEqual(flow.step, .recoveryPhrase)
        XCTAssertEqual(flow.outcomes[.moderation], .unavailable)
    }

    /// Non-empty directory: must consent — no skip, and Continue
    /// refuses until the consent outcome is recorded.
    func testModerationMustConsentWhenDirectoryHasEntries() async {
        let flow = makeFlow(moderationDirectoryNonEmpty: { true })
        flow.start()
        await flow.moderationProbeTask?.value
        XCTAssertFalse(flow.isSkippable(.moderation))
        XCTAssertTrue(flow.isMandatory(.moderation))

        while flow.step != .moderation { flow.advance() }
        flow.skip() // must be a no-op
        XCTAssertEqual(flow.step, .moderation)
        XCTAssertNil(flow.outcomes[.moderation])
        flow.advance() // equally refused without a consent outcome
        XCTAssertEqual(flow.step, .moderation)

        flow.recordOutcome(.consented(componentId: "onym:component:authority"))
        flow.advance()
        XCTAssertEqual(flow.step, .recoveryPhrase)
    }

    func testStartIsIdempotent() async {
        let probes = ProbeCounter()
        let flow = makeFlow(moderationDirectoryNonEmpty: {
            await probes.increment()
            return true
        })
        flow.start()
        flow.start()
        await flow.moderationProbeTask?.value
        let count = await probes.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(flow.moderationDirectoryHasEntries, true)
    }

    // MARK: - Completion

    func testCompleteWritesFlagAndFiresOnCompleted() async {
        var completedCalls = 0
        let flow = await makeResolvedFlow(onCompleted: { completedCalls += 1 })
        while flow.step != .done { flow.advance() }
        XCTAssertFalse(store.hasCompletedOnboarding())
        flow.complete()
        XCTAssertTrue(store.hasCompletedOnboarding())
        XCTAssertEqual(completedCalls, 1)
        XCTAssertEqual(flow.outcomes[.done], .notApplicable)
    }

    /// `isCompleted` is the presenter's dismissal signal: false for the
    /// whole walk, true only after `complete()` on the Done step — and
    /// never from a mid-sequence `complete()` call.
    func testIsCompletedFlipsOnlyFromDone() async {
        let flow = await makeResolvedFlow()
        XCTAssertFalse(flow.isCompleted)
        flow.advance()
        flow.complete() // mid-sequence — refused
        XCTAssertFalse(flow.isCompleted)
        while flow.step != .done { flow.advance() }
        flow.complete()
        XCTAssertTrue(flow.isCompleted)
    }

    func testCompleteBeforeDoneIsANoOp() {
        var completedCalls = 0
        let flow = makeFlow(onCompleted: { completedCalls += 1 })
        flow.advance() // identity — mid-sequence
        flow.complete()
        XCTAssertFalse(store.hasCompletedOnboarding())
        XCTAssertEqual(completedCalls, 0)
    }

    /// Completion closes the gate: a flow over a completed store means
    /// `OnboardingGate.shouldOnboard` answers false next launch.
    func testCompletionClosesTheGate() async {
        let flow = await makeResolvedFlow()
        while flow.step != .done { flow.advance() }
        flow.complete()
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { false }))
    }

    // MARK: - Outcome recording

    func testRecordOutcomePerStepAcrossTheWholeWalk() async {
        let flow = await makeResolvedFlow()
        flow.advance() // identity
        flow.advance() // services
        flow.recordOutcome(.consented(componentId: "onym:component:onym-nostr"))
        flow.advance() // moderation
        flow.advance() // recoveryPhrase (Continue-only moderation, directory empty)
        flow.skip() // remind me later

        XCTAssertEqual(flow.outcomes[.welcome], .notApplicable)
        XCTAssertEqual(flow.outcomes[.identity], .notApplicable)
        XCTAssertEqual(flow.outcomes[.services], .consented(componentId: "onym:component:onym-nostr"))
        XCTAssertEqual(flow.outcomes[.moderation], .unavailable)
        XCTAssertEqual(flow.outcomes[.recoveryPhrase], .skipped)
    }

    // MARK: - Welcome skippability

    func testWelcomeIsNotSkippable() {
        let flow = makeFlow()
        XCTAssertFalse(flow.isSkippable(.welcome))
        flow.skip() // must be a no-op — Continue is welcome's only path
        XCTAssertEqual(flow.step, .welcome)
        XCTAssertNil(flow.outcomes[.welcome])
    }

    // MARK: - Probe race (fail-closed until resolved)

    /// Before the probe answers, moderation reads unskippable AND
    /// mandatory — racing the probe must never open an advance window.
    func testModerationFailsClosedWhileProbeUnresolved() async {
        let flow = makeFlow(moderationDirectoryNonEmpty: { false })
        // Probe not started: unresolved.
        XCTAssertFalse(flow.moderationProbeResolved)
        XCTAssertFalse(flow.isSkippable(.moderation))
        XCTAssertTrue(flow.isMandatory(.moderation))

        while flow.step != .moderation { flow.advance() }
        flow.skip() // no-op — always, on moderation
        XCTAssertEqual(flow.step, .moderation)
        flow.advance() // refused — mandatory without an outcome
        XCTAssertEqual(flow.step, .moderation)

        // Empty directory resolves → Continue-only informational:
        // still not skippable, no longer mandatory, and the plain
        // Continue records the distinct `.unavailable` outcome.
        flow.start()
        await flow.moderationProbeTask?.value
        XCTAssertTrue(flow.moderationProbeResolved)
        XCTAssertFalse(flow.isSkippable(.moderation))
        XCTAssertFalse(flow.isMandatory(.moderation))
        flow.advance()
        XCTAssertEqual(flow.step, .recoveryPhrase)
        XCTAssertEqual(flow.outcomes[.moderation], .unavailable)
    }

    /// The other transition: unresolved (fail-closed) → resolved
    /// non-empty keeps moderation locked down.
    func testResolvedNonEmptyDirectoryStaysMandatory() async {
        let flow = makeFlow(moderationDirectoryNonEmpty: { true })
        XCTAssertFalse(flow.isSkippable(.moderation))
        XCTAssertTrue(flow.isMandatory(.moderation))
        flow.start()
        await flow.moderationProbeTask?.value
        XCTAssertTrue(flow.moderationProbeResolved)
        XCTAssertFalse(flow.isSkippable(.moderation))
        XCTAssertTrue(flow.isMandatory(.moderation))
    }

    // MARK: - Mandatory moderation blocks advance()

    /// Continue must not be a back door around the
    /// unskippable-moderation rule.
    func testAdvanceOnMandatoryModerationWithoutOutcomeIsANoOp() async {
        let flow = await makeResolvedFlow(directoryNonEmpty: true)
        while flow.step != .moderation { flow.advance() }
        flow.advance()
        XCTAssertEqual(flow.step, .moderation)
        XCTAssertNil(flow.outcomes[.moderation], "a refused advance must not backfill an outcome")
    }

    func testAdvanceOnMandatoryModerationWithRecordedConsentAdvances() async {
        let flow = await makeResolvedFlow(directoryNonEmpty: true)
        while flow.step != .moderation { flow.advance() }
        flow.recordOutcome(.consented(componentId: "onym:component:onym-moderation"))
        flow.advance()
        XCTAssertEqual(flow.step, .recoveryPhrase)
        XCTAssertEqual(flow.outcomes[.moderation], .consented(componentId: "onym:component:onym-moderation"))
    }

    func testRecordingAgainOverwrites() {
        let flow = makeFlow()
        flow.advance() // identity
        flow.advance() // services
        flow.recordOutcome(.consented(componentId: "onym:component:a"))
        flow.recordOutcome(.consented(componentId: "onym:component:b"))
        XCTAssertEqual(flow.outcomes[.services], .consented(componentId: "onym:component:b"))
    }
}

/// Actor-isolated counter for the idempotency test — the probe closure
/// runs off the main actor under strict concurrency, so a captured var
/// would be a data race.
private actor ProbeCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
