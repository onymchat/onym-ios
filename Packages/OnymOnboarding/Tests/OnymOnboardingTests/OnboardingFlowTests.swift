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

    // MARK: - Step order

    func testStepsAdvanceInDocumentedOrder() {
        let flow = makeFlow()
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

    func testAdvanceOnDoneIsANoOp() {
        let flow = makeFlow()
        while flow.step != .done { flow.advance() }
        flow.advance()
        XCTAssertEqual(flow.step, .done)
    }

    func testStepIndexAndCountDriveTheIndicator() {
        let flow = makeFlow()
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

    func testDoneIsNeverSkippable() {
        let flow = makeFlow()
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
        for step: OnboardingStep in [.welcome, .discoveryConfirm, .messageTransport, .blobTransport, .notary] {
            XCTAssertTrue(flow.isSkippable(step), "\(step) should stay skippable")
        }

        while flow.step != .moderation { flow.advance() }
        flow.skip() // must be a no-op
        XCTAssertEqual(flow.step, .moderation)
        XCTAssertNil(flow.outcomes[.moderation])
    }

    func testStartIsIdempotent() async {
        var probes = 0
        let flow = makeFlow(moderationDirectoryNonEmpty: {
            probes += 1
            return true
        })
        flow.start()
        flow.start()
        await flow.moderationProbeTask?.value
        XCTAssertEqual(probes, 1)
        XCTAssertTrue(flow.moderationDirectoryHasEntries)
    }

    // MARK: - Completion

    func testCompleteWritesFlagAndFiresOnCompleted() {
        var completedCalls = 0
        let flow = makeFlow(onCompleted: { completedCalls += 1 })
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
    func testCompletionClosesTheGate() {
        let flow = makeFlow()
        while flow.step != .done { flow.advance() }
        flow.complete()
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { false }))
    }

    // MARK: - Outcome recording

    func testRecordOutcomePerStepAcrossTheWholeWalk() {
        let flow = makeFlow()
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

    func testRecordingAgainOverwrites() {
        let flow = makeFlow()
        flow.advance() // discoveryConfirm
        flow.recordOutcome(.consented(componentId: "onym:component:a"))
        flow.recordOutcome(.consented(componentId: "onym:component:b"))
        XCTAssertEqual(flow.outcomes[.discoveryConfirm], .consented(componentId: "onym:component:b"))
    }
}
