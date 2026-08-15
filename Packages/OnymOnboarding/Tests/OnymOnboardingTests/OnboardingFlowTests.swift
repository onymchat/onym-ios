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
            .welcome, .discoveryConfirm, .messageTransport,
            .blobTransport, .notary, .moderation, .done,
        ])
    }

    func testAdvanceOnDoneIsANoOp() async {
        let flow = await makeResolvedFlow()
        while flow.step != .done { flow.advance() }
        flow.advance()
        XCTAssertEqual(flow.step, .done)
    }

    func testStepIndexAndCountDriveTheIndicator() async {
        let flow = await makeResolvedFlow()
        XCTAssertEqual(flow.stepCount, 7)
        XCTAssertEqual(flow.stepIndex, 0)
        flow.advance()
        XCTAssertEqual(flow.stepIndex, 1)
        while flow.step != .done { flow.advance() }
        XCTAssertEqual(flow.stepIndex, 6)
    }

    // MARK: - Back

    func testBackWalksToThePreviousStep() {
        let flow = makeFlow()
        flow.advance()
        flow.advance()
        XCTAssertEqual(flow.step, .messageTransport)
        flow.back()
        XCTAssertEqual(flow.step, .discoveryConfirm)
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
        flow.advance() // discoveryConfirm
        flow.recordOutcome(.consented(componentId: nil))
        flow.advance() // messageTransport
        flow.back() // revisit discoveryConfirm
        XCTAssertEqual(flow.outcomes[.discoveryConfirm], .consented(componentId: nil))
        flow.skip()
        XCTAssertEqual(flow.outcomes[.discoveryConfirm], .skipped)
    }

    // MARK: - Skip

    func testSkipRecordsSkippedAndAdvances() {
        let flow = makeFlow()
        flow.advance() // discoveryConfirm
        flow.skip()
        XCTAssertEqual(flow.step, .messageTransport)
        XCTAssertEqual(flow.outcomes[.discoveryConfirm], .skipped)
    }

    func testAdvanceWithoutDecisionBackfillsNotApplicable() {
        let flow = makeFlow()
        flow.advance()
        XCTAssertEqual(flow.outcomes[.welcome], .notApplicable)
    }

    func testAdvanceDoesNotOverwriteARecordedOutcome() {
        let flow = makeFlow()
        flow.advance() // discoveryConfirm
        flow.recordOutcome(.consented(componentId: "onym:component:onym-discovery"))
        flow.advance()
        XCTAssertEqual(
            flow.outcomes[.discoveryConfirm],
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

    // MARK: - Moderation skippability

    func testModerationSkippableWhileDirectoryEmpty() async {
        let flow = makeFlow(moderationDirectoryNonEmpty: { false })
        flow.start()
        await flow.moderationProbeTask?.value
        XCTAssertTrue(flow.isSkippable(.moderation))

        while flow.step != .moderation { flow.advance() }
        flow.skip()
        XCTAssertEqual(flow.step, .done)
        XCTAssertEqual(flow.outcomes[.moderation], .skipped)
    }

    func testModerationNotSkippableWhenDirectoryHasEntries() async {
        let flow = makeFlow(moderationDirectoryNonEmpty: { true })
        flow.start()
        await flow.moderationProbeTask?.value
        XCTAssertFalse(flow.isSkippable(.moderation))
        // Every other step stays skippable.
        for step: OnboardingStep in [.discoveryConfirm, .messageTransport, .blobTransport, .notary] {
            XCTAssertTrue(flow.isSkippable(step), "\(step) should stay skippable")
        }

        while flow.step != .moderation { flow.advance() }
        flow.skip() // must be a no-op
        XCTAssertEqual(flow.step, .moderation)
        XCTAssertNil(flow.outcomes[.moderation])
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

    func testCompleteBeforeDoneIsANoOp() {
        var completedCalls = 0
        let flow = makeFlow(onCompleted: { completedCalls += 1 })
        flow.advance() // discoveryConfirm — mid-sequence
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
        flow.advance() // discoveryConfirm
        flow.recordOutcome(.consented(componentId: nil))
        flow.advance() // messageTransport
        flow.recordOutcome(.consented(componentId: "onym:component:onym-nostr"))
        flow.advance() // blobTransport
        flow.skip() // notary
        flow.recordOutcome(.consented(componentId: "onym:component:onym-relayer"))
        flow.advance() // moderation
        flow.advance() // done (informational moderation, directory empty)

        XCTAssertEqual(flow.outcomes[.welcome], .notApplicable)
        XCTAssertEqual(flow.outcomes[.discoveryConfirm], .consented(componentId: nil))
        XCTAssertEqual(flow.outcomes[.messageTransport], .consented(componentId: "onym:component:onym-nostr"))
        XCTAssertEqual(flow.outcomes[.blobTransport], .skipped)
        XCTAssertEqual(flow.outcomes[.notary], .consented(componentId: "onym:component:onym-relayer"))
        XCTAssertEqual(flow.outcomes[.moderation], .notApplicable)
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
    /// mandatory — racing the probe must never open a skip window.
    func testModerationFailsClosedWhileProbeUnresolved() async {
        let flow = makeFlow(moderationDirectoryNonEmpty: { false })
        // Probe not started: unresolved.
        XCTAssertFalse(flow.moderationProbeResolved)
        XCTAssertFalse(flow.isSkippable(.moderation))
        XCTAssertTrue(flow.isMandatory(.moderation))

        while flow.step != .moderation { flow.advance() }
        flow.skip() // no-op while unresolved
        XCTAssertEqual(flow.step, .moderation)
        flow.advance() // equally refused — mandatory without an outcome
        XCTAssertEqual(flow.step, .moderation)

        // Empty directory resolves → skippable, not mandatory.
        flow.start()
        await flow.moderationProbeTask?.value
        XCTAssertTrue(flow.moderationProbeResolved)
        XCTAssertTrue(flow.isSkippable(.moderation))
        XCTAssertFalse(flow.isMandatory(.moderation))
        flow.skip()
        XCTAssertEqual(flow.step, .done)
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

    /// The substantive review finding: Continue must not be a back
    /// door around the unskippable-moderation rule.
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
        XCTAssertEqual(flow.step, .done)
        XCTAssertEqual(flow.outcomes[.moderation], .consented(componentId: "onym:component:onym-moderation"))
    }

    func testRecordingAgainOverwrites() {
        let flow = makeFlow()
        flow.advance() // discoveryConfirm
        flow.recordOutcome(.consented(componentId: "onym:component:a"))
        flow.recordOutcome(.consented(componentId: "onym:component:b"))
        XCTAssertEqual(flow.outcomes[.discoveryConfirm], .consented(componentId: "onym:component:b"))
    }
}

/// Actor-isolated counter for the idempotency test — the probe closure
/// runs off the main actor under strict concurrency, so a captured var
/// would be a data race.
private actor ProbeCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
