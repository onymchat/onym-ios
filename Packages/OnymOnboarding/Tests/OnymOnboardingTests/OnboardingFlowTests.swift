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

    /// Walk to `target`, recording an outcome wherever the flow
    /// requires one to advance — the same records the step surfaces
    /// make in the app: identity's readiness proof is
    /// `.notApplicable`, consents everywhere else.
    private func walk(_ flow: OnboardingFlow, to target: OnboardingStep) {
        while flow.step != target {
            if flow.requiresOutcomeToAdvance(flow.step), flow.outcomes[flow.step] == nil {
                flow.recordOutcome(
                    flow.step == .identity ? .notApplicable : .consented(componentId: nil)
                )
            }
            flow.advance()
        }
    }

    // MARK: - Step order

    func testStepsAdvanceInDocumentedOrder() async {
        let flow = await makeResolvedFlow()
        var visited: [OnboardingStep] = [flow.step]
        while flow.step != .done {
            if flow.requiresOutcomeToAdvance(flow.step), flow.outcomes[flow.step] == nil {
                flow.recordOutcome(.notApplicable)
            }
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
        walk(flow, to: .done)
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
        walk(flow, to: .services)
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

    /// Back-then-redo: a revisited step keeps its prior outcome until
    /// a new decision overwrites it — here the recovery step's reveal
    /// consent survives the round trip to Done and is then overwritten
    /// by "Remind me later" (`skip()`).
    func testBackKeepsThePriorOutcomeUntilOverwritten() async {
        let flow = await makeResolvedFlow()
        walk(flow, to: .recoveryPhrase)
        flow.recordOutcome(.consented(componentId: nil)) // the reveal
        flow.advance() // done
        flow.back() // revisit recoveryPhrase
        XCTAssertEqual(flow.outcomes[.recoveryPhrase], .consented(componentId: nil))
        flow.skip() // changed their mind: remind me later
        XCTAssertEqual(flow.outcomes[.recoveryPhrase], .skipped)
        XCTAssertEqual(flow.step, .done)
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
        walk(flow, to: .recoveryPhrase)
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
        walk(flow, to: .services)
        flow.recordOutcome(.consented(componentId: "onym:component:onym-discovery"))
        flow.advance()
        XCTAssertEqual(
            flow.outcomes[.services],
            .consented(componentId: "onym:component:onym-discovery")
        )
    }

    func testDoneIsNeverSkippable() async {
        let flow = await makeResolvedFlow()
        walk(flow, to: .done)
        XCTAssertFalse(flow.isSkippable(.done))
        flow.skip()
        XCTAssertEqual(flow.step, .done)
        XCTAssertNil(flow.outcomes[.done])
    }

    // MARK: - Identity requires proof of keys

    /// The identity step is outcome-gated: Continue refuses until the
    /// step content records that the bootstrap actually produced a
    /// snapshot — a failed bootstrap must not walk the user on to a
    /// recovery step whose reveal cannot work.
    func testIdentityAdvanceRefusedUntilReadinessRecorded() {
        let flow = makeFlow()
        flow.advance() // welcome → identity
        XCTAssertEqual(flow.step, .identity)
        flow.advance() // refused — no readiness recorded
        XCTAssertEqual(flow.step, .identity)
        XCTAssertNil(flow.outcomes[.identity],
                     "a refused advance must not backfill an outcome")

        flow.recordOutcome(.notApplicable) // bootstrap produced a snapshot
        flow.advance()
        XCTAssertEqual(flow.step, .services)
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
        walk(empty, to: .moderation)
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

        walk(flow, to: .moderation)
        flow.advance() // plain Continue
        XCTAssertEqual(flow.step, .recoveryPhrase)
        XCTAssertEqual(flow.outcomes[.moderation], .unavailable)
    }

    /// Non-empty directory: must consent — no skip, and Continue
    /// refuses until the consent outcome is recorded.
    func testModerationMustConsentWhenDirectoryHasEntries() async {
        let flow = await makeResolvedFlow(directoryNonEmpty: true)
        XCTAssertFalse(flow.isSkippable(.moderation))
        XCTAssertTrue(flow.isMandatory(.moderation))

        walk(flow, to: .moderation)
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
        walk(flow, to: .done)
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
        walk(flow, to: .done)
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
        walk(flow, to: .done)
        flow.complete()
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { false }))
    }

    // MARK: - Outcome recording

    func testRecordOutcomePerStepAcrossTheWholeWalk() async {
        let flow = await makeResolvedFlow()
        flow.advance() // identity
        flow.recordOutcome(.notApplicable) // readiness proof
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

        walk(flow, to: .moderation)
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
        walk(flow, to: .moderation)
        flow.advance()
        XCTAssertEqual(flow.step, .moderation)
        XCTAssertNil(flow.outcomes[.moderation], "a refused advance must not backfill an outcome")
    }

    func testAdvanceOnMandatoryModerationWithRecordedConsentAdvances() async {
        let flow = await makeResolvedFlow(directoryNonEmpty: true)
        walk(flow, to: .moderation)
        flow.recordOutcome(.consented(componentId: "onym:component:onym-moderation"))
        flow.advance()
        XCTAssertEqual(flow.step, .recoveryPhrase)
        XCTAssertEqual(flow.outcomes[.moderation], .consented(componentId: "onym:component:onym-moderation"))
    }

    // MARK: - Recovery phrase requires an outcome

    /// "I've written it down" must not advance before the phrase was
    /// ever revealed: without a recorded outcome the advance is
    /// refused; the honest exits are the reveal (which records) or
    /// "Remind me later" (skip).
    func testRecoveryPhraseAdvanceRefusedWithoutOutcome() async {
        let flow = await makeResolvedFlow()
        walk(flow, to: .recoveryPhrase)
        flow.advance() // refused — nothing revealed, nothing recorded
        XCTAssertEqual(flow.step, .recoveryPhrase)
        XCTAssertNil(flow.outcomes[.recoveryPhrase],
                     "a refused advance must not backfill an outcome")

        flow.recordOutcome(.consented(componentId: nil)) // the reveal
        flow.advance()
        XCTAssertEqual(flow.step, .done)
    }

    /// A `.skipped` outcome must NOT satisfy the gate: after
    /// "Remind me later" → Done → Back, the recovery step's primary
    /// ("I've written it down") re-locks — the recorded skip survives
    /// (back-preservation), but it must never enable a claim about a
    /// phrase that was never revealed. Regression for the gate hole
    /// dev-onym found on the Android port.
    func testSkipThenBackReGatesTheRecoveryPrimary() async {
        let flow = await makeResolvedFlow()
        walk(flow, to: .recoveryPhrase)
        flow.skip()
        XCTAssertEqual(flow.step, .done)
        flow.back()
        XCTAssertEqual(flow.step, .recoveryPhrase)
        XCTAssertEqual(flow.outcomes[.recoveryPhrase], .skipped,
                       "the skip decision survives Back")
        XCTAssertFalse(flow.outcomeSatisfiesGate(.recoveryPhrase),
                       "a skip must not satisfy the reveal gate")
        flow.advance() // refused — the primary is re-locked
        XCTAssertEqual(flow.step, .recoveryPhrase)
        flow.skip() // skipping again remains the honest exit
        XCTAssertEqual(flow.step, .done)
    }

    /// The outcome-gate matrix: identity and recovery always;
    /// moderation only while mandatory; nothing else ever.
    func testRequiresOutcomeToAdvanceMatrix() async {
        let alwaysGated: Set<OnboardingStep> = [.identity, .recoveryPhrase]
        let empty = await makeResolvedFlow(directoryNonEmpty: false)
        for step in OnboardingStep.allCases {
            XCTAssertEqual(empty.requiresOutcomeToAdvance(step),
                           alwaysGated.contains(step),
                           "\(step) with empty directory")
        }
        let nonEmpty = await makeResolvedFlow(directoryNonEmpty: true)
        for step in OnboardingStep.allCases {
            XCTAssertEqual(nonEmpty.requiresOutcomeToAdvance(step),
                           alwaysGated.contains(step) || step == .moderation,
                           "\(step) with non-empty directory")
        }
    }

    // MARK: - Recovery backup state

    /// The backup progression lives on the flow so the step body's
    /// status card survives navigation, and so the Done summary can
    /// tell "saw the words" (revealed) apart from "verified them" —
    /// both record the same consent outcome.
    func testRecoveryBackupStateDefaultsToNoneAndPersists() async {
        let flow = await makeResolvedFlow()
        XCTAssertEqual(flow.recoveryBackupState, RecoveryBackupState.none)
        walk(flow, to: .recoveryPhrase)
        flow.recoveryBackupState = .revealed
        flow.recordOutcome(.consented(componentId: nil))
        flow.advance() // done
        flow.back() // revisit recoveryPhrase
        XCTAssertEqual(flow.recoveryBackupState, .revealed,
                       "the backup state must survive navigation")
    }

    // MARK: - Services choice

    /// The services path lives on the flow so Back/forward navigation
    /// can't reset the step body's selection chip: recommended by
    /// default, and a written choice survives leaving the step.
    func testServicesChoiceDefaultsToRecommendedAndPersists() async {
        let flow = await makeResolvedFlow()
        XCTAssertEqual(flow.servicesChoice, .recommended)
        walk(flow, to: .services)
        flow.servicesChoice = .custom
        flow.recordOutcome(.consented(componentId: nil))
        flow.advance() // moderation
        flow.back() // revisit services
        XCTAssertEqual(flow.servicesChoice, .custom,
                       "the choice must survive navigation")
    }

    func testRecordingAgainOverwrites() {
        let flow = makeFlow()
        walk(flow, to: .services)
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
