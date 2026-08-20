import Foundation
import XCTest
@testable import OnymBackup
@testable import OnymBackupUI
@testable import OnymBilling

/// The two things a restore sweep must not get wrong across several
/// operators: who a recovered purchase belongs to, and what may be
/// claimed when the App Store was never successfully asked.
///
/// Both are cross-operator properties, which is why neither showed up
/// in a single-operator build and why they are pinned here rather than
/// left to the next review.
@MainActor
final class BackupPurchaseRestoreTests: XCTestCase {
    /// A purchase recovered for one operator says nothing about
    /// another.
    ///
    /// With two paid operators, one restore and one that recovered
    /// nothing, a total-based check told the operator that got nothing
    /// that its purchase had been restored — on the row whose whole job
    /// is telling someone whether they still owe a payment.
    func testARestoredPurchaseIsAttributedOnlyToTheOperatorItWasRestoredFor() async throws {
        let paidA = try vendor(componentId: "onym:component:a", displayName: "A")
        let paidB = try vendor(componentId: "onym:component:b", displayName: "B")
        // Both operators are sitting on a refusal for payment, which is
        // the only state in which the note under test is rendered — and
        // it comes from their state files, because the sweep refreshes
        // from those before it notes anything.
        paidA.flow.refresh()
        paidB.flow.refresh()
        XCTAssertTrue(paidA.flow.isPaymentRequired)
        XCTAssertTrue(paidB.flow.isPaymentRequired)

        let flow = DeviceBackupVendorsFlow(
            vendors: [paidA, paidB],
            fanOut: BackupFanOut(vendors: [], composer: try composer(), archiveRoot: material().archiveRoot),
            restorePurchasesForOperator: { componentId in
                // Only A's purchase is on this device's Apple account.
                componentId == "onym:component:a"
                    ? SeatPurchaseFlow.RestoreResult(
                        restored: ["o"], alreadyHeld: [], heldUnknown: false, failures: [:])
                    : SeatPurchaseFlow.RestoreResult(
                        restored: [], alreadyHeld: [], heldUnknown: false, failures: [:])
            },
            syncPurchasesWithStore: { true }
        )

        await flow.restorePurchases()

        XCTAssertEqual(
            paidA.flow.lastRunNote,
            "Purchase restored — tap Back Up Now to finish this backup.",
            "the operator whose purchase was restored should say so")
        XCTAssertNil(
            paidB.flow.lastRunNote,
            "an operator that recovered nothing must not claim a restored purchase")
    }

    /// A sync that did not work is not an answer about what the store
    /// holds.
    ///
    /// The person this matters to is on a replacement phone with a
    /// subscription they have already paid for; "the App Store has no
    /// purchase for this identity" is the one sentence that would send
    /// them to buy it again.
    func testAFailedSyncDoesNotProduceANoPurchaseClaim() async throws {
        let paid = try vendor(componentId: "onym:component:a", displayName: "A")
        let flow = DeviceBackupVendorsFlow(
            vendors: [paid],
            fanOut: BackupFanOut(vendors: [], composer: try composer(), archiveRoot: material().archiveRoot),
            restorePurchasesForOperator: { _ in
                SeatPurchaseFlow.RestoreResult(
                    restored: [], alreadyHeld: [], heldUnknown: false, failures: [:])
            },
            syncPurchasesWithStore: { false }
        )

        await flow.restorePurchases()

        guard case .finished(_, _, _, _, let syncFailed, _) = flow.purchaseRestore else {
            return XCTFail("the sweep did not finish: \(flow.purchaseRestore)")
        }
        XCTAssertTrue(syncFailed, "a failed sync must reach the surface that renders the claim")
    }

    /// A purchase the store has but cannot verify is not a purchase
    /// the store does not have.
    ///
    /// The third instance of one shape in this flow: something unknown
    /// rendered as a definitive negative. Here the negative is "the App
    /// Store has no purchase for this identity", and the person reading
    /// it is deciding whether to buy their subscription again.
    func testAnUnverifiableTransactionIsReportedRatherThanReadAsNoPurchase() async throws {
        let paid = try vendor(componentId: "onym:component:a", displayName: "A")
        let flow = DeviceBackupVendorsFlow(
            vendors: [paid],
            fanOut: BackupFanOut(vendors: [], composer: try composer(), archiveRoot: material().archiveRoot),
            restorePurchasesForOperator: { _ in
                SeatPurchaseFlow.RestoreResult(
                    restored: [],
                    alreadyHeld: [],
                    heldUnknown: false,
                    failures: [
                        "o": BillingError.transactionUnverified(reason: "signature")
                            .errorDescription ?? "",
                    ])
            },
            syncPurchasesWithStore: { true }
        )

        await flow.restorePurchases()

        guard case .finished(_, _, _, _, _, let failures) = flow.purchaseRestore else {
            return XCTFail("the sweep did not finish: \(flow.purchaseRestore)")
        }
        XCTAssertEqual(failures.count, 1, "an unverifiable transaction must survive to the surface")
        XCTAssertTrue(
            failures[0].contains("did not verify"),
            "the row must say what happened, not report an absence: \(failures[0])")
    }

    /// And the error itself must not read as a debugger's output.
    func testUnverifiedTransactionsSayWhatHappened() {
        XCTAssertEqual(
            BillingError.transactionUnverified(reason: "anything").errorDescription,
            "The App Store's record of this purchase did not verify on this phone. Try again.")
        XCTAssertEqual(
            BillingError.brokerRejected(code: "invalid_transaction", message: "Already refunded.")
                .errorDescription,
            "Already refunded.",
            "the broker's own words are the ones worth showing")
        XCTAssertEqual(
            BillingError.brokerRejected(code: "invalid_transaction", message: nil).errorDescription,
            "The billing service refused this purchase (invalid_transaction).",
            "an unrecognised refusal still names its code, which is what support asks for")
    }

    // MARK: - Fixtures

    private func material() -> BackupKeyMaterial {
        BackupKeys.material(seed: Data(repeating: 0x5E, count: 64), componentId: "onym:component:a")
    }

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func composer() throws -> BackupComposer {
        BackupComposer(
            source: SilentSource(), mediaPolicy: .descriptorsOnly, workingDirectory: try directory())
    }

    /// An operator enrolled, and holding a snapshot the operator
    /// refused for payment.
    private func vendor(componentId: String, displayName: String) throws -> DeviceBackupVendorsFlow.Vendor {
        var state = BackupState()
        state.componentId = componentId
        state.acceptedTermsId = "sha256:" + String(repeating: "b", count: 64)
        state.awaitingPayment = BackupState.PendingPayment(
            operationId: "0123456789abcdef",
            digest: "sha256:" + String(repeating: "a", count: 64),
            sealedByteSize: 16,
            sealedBytesFilename: "pending-test",
            acceptedTermsId: state.acceptedTermsId!,
            supersedesDigest: nil,
            supersedesByteSize: nil,
            sealedAt: Date(timeIntervalSince1970: 0),
            refusedAt: Date(timeIntervalSince1970: 0)
        )
        let store = SilentStateStore(state: state)
        return DeviceBackupVendorsFlow.Vendor(
            flow: DeviceBackupSettingsFlow(
                componentId: componentId,
                displayName: displayName,
                repository: BackupRepository(
                    port: SilentPort(),
                    composer: try composer(),
                    stateStore: store,
                    keyMaterial: material()),
                stateStore: store
            )
        )
    }
}

private struct SilentStateStore: BackupStateStoring {
    var state = BackupState()
    func load() throws -> BackupState { state }
    func save(_ state: BackupState) throws {}
}

private struct SilentPort: BackupPort {
    func connect() async throws -> BackupConnection { throw BackupError.operatorUnavailable }
    func preflight(_ snapshot: SealedSnapshot) async throws -> BackupPreflight {
        throw BackupError.operatorUnavailable
    }
    func uploadSnapshot(_ snapshot: SealedSnapshot, grant: BackupUploadGrant) async throws -> BackupOutcome {
        throw BackupError.operatorUnavailable
    }
    func listSnapshots() async throws -> [RetainedSnapshot] { [] }
    func downloadSnapshot(_ reference: SnapshotReference, to destination: URL) async throws {
        throw BackupError.operatorUnavailable
    }
    func eraseSnapshot(scope: ErasureScope) async throws -> ErasureReceipt {
        throw BackupError.operatorUnavailable
    }
    func exportSnapshots(to directory: URL) async throws -> BackupExport {
        throw BackupError.operatorUnavailable
    }
    func queryOutcome(operationId: String) async throws -> BackupOutcome? { nil }
}

private actor SilentSource: BackupSourceProviding {
    func identityCount() async -> Int { 0 }
    func groups() async throws -> [BackupGroupRecord] { [] }
    func messages(groupID: String, ownerIdentityID: String) async throws -> [BackupMessageRecord] { [] }
    func invitations() async throws -> [BackupInvitationRecord] { [] }
    func consents() async throws -> [BackupConsentRecord] { [] }
    func blobCiphertext(sha256: String) async throws -> BackupBlobAvailability { .gone }
}
