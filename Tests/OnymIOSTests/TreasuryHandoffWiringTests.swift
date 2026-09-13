import XCTest
@testable import OnymIOS

/// The guard that a guard is reachable.
///
/// `TreasuryCreationInteractor.abandonExternalCreation` refuses to throw
/// away a pending row once the wallet has funded the account, because
/// the key in that row is the only one that can ever reach it. It was
/// written, tested, and called by nothing: `TreasuryFlow` still went
/// straight to `repository.clearPendingCreation`, so the button in
/// `CreateTreasuryView` kept the old behaviour and the tests passed
/// because they called the interactor directly.
///
/// Reading source is a blunt way to assert wiring, and it is the only
/// way available here — there is no test that drives `TreasuryFlow`,
/// which is why nothing noticed. The scan is narrow on purpose: it
/// names one method and one call it must not contain.
final class TreasuryHandoffWiringTests: XCTestCase {

    func test_abandoningAHandoff_goesThroughTheInteractor() throws {
        let body = try methodBody(
            of: "public func abandonExternalCreation() async {",
            in: "TreasuryFlow.swift"
        )
        XCTAssertTrue(
            body.contains("creation.abandonExternalCreation"),
            "the flow must ask the interactor, which is the only layer that can read a ledger"
        )
        XCTAssertFalse(
            body.contains("repository.clearPendingCreation"),
            "clearing the row here skips the check that the funding has not already landed"
        )
        // Every answer handled, including the one that means "the
        // ledger did not say".
        for outcome in ["discarded", "accountAlreadyFunded", "couldNotTell"] {
            XCTAssertTrue(body.contains(outcome), "unhandled outcome: \(outcome)")
        }
    }

    /// The interactor's refusal is only useful if the person reading
    /// the screen is told why, so the string it maps to has to exist.
    func test_theRefusalIsSaidOutLoud() throws {
        let body = try methodBody(
            of: "public func abandonExternalCreation() async {",
            in: "TreasuryFlow.swift"
        )
        XCTAssertTrue(body.contains("creationError = String("), body)
    }

    /// The stranded-funding branch has to be reachable without the
    /// create screen.
    ///
    /// Once another admin's anchor lands, `CreateTreasuryView` is no
    /// longer presented, so the only button that could finish a funded
    /// account disappears while the row and its key persist. The flow
    /// reconciles on the snapshot instead, and this fails if that call
    /// is removed from `apply`.
    func test_aStrandedHandoff_isReconciledWithoutTheCreateScreen() throws {
        let body = try methodBody(
            of: "private func apply(_ snapshot: TreasurySnapshot) async {",
            in: "TreasuryFlow.swift"
        )
        XCTAssertTrue(body.contains("reconcileStrandedFunding"), body)

        let reconcile = try methodBody(
            of: "private func reconcileStrandedFunding(_ snapshot: TreasurySnapshot) async {",
            in: "TreasuryFlow.swift"
        )
        XCTAssertTrue(reconcile.contains("completeExternalCreation"), reconcile)
        // Only when the row disagrees with the anchor, and only once —
        // a snapshot arrives on every change and this reads a ledger.
        XCTAssertTrue(reconcile.contains("treasuryAccount != anchored.account"), reconcile)
        XCTAssertTrue(reconcile.contains("hasReconciledStrandedFunding"), reconcile)
    }

    // MARK: - Helpers

    /// Source of one method, from its signature to the line that closes
    /// it at the same indentation.
    private func methodBody(of signature: String, in file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Packages/OnymTreasuryUI/Sources/OnymTreasuryUI")
            .appendingPathComponent(file)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(file) not reachable from \(#filePath)")
        }
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else {
            XCTFail("no \(signature) in \(file)")
            return ""
        }
        let indent = String(repeating: " ", count: 4) + "}"
        guard let end = lines[(start + 1)...].firstIndex(where: { $0 == indent }) else {
            return ""
        }
        return lines[start...end].joined(separator: "\n")
    }
}
