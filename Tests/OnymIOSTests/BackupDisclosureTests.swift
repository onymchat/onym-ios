import Foundation
import OnymFoundation
import XCTest
@testable import OnymBackup
@testable import OnymBackupUI

/// The consent surface, checked by fixture rather than by review.
///
/// `UI-Backup.md` §18.10 asks for exactly this, and the reason is that a
/// disclosure is the one part of this seat that degrades silently: a
/// paragraph dropped in a refactor still compiles, still renders, and
/// still looks like a consent screen.
final class BackupDisclosureTests: XCTestCase {
    private func disclosure(
        mediaPolicy: BackupMediaPolicy = .descriptorsOnly,
        schedule: BackupSchedule = .default
    ) throws -> BackupDisclosure {
        let terms = try BackupTerms.decode(raw: Self.termsJSON)
        let manifest = try BackupOperatorManifest(
            manifest: SignedServiceManifest(raw: Self.manifestJSON(termsId: terms.termsId)))
        let profile = BackupImplementationProfile(
            implementationVersion: 1,
            implementationProfileId: BackupProfile.implementationProfileId,
            backupProfileId: BackupProfile.portableProfileId,
            digestSuite: BackupProfile.digestSuite,
            sealingSuite: BackupProfile.sealingSuite,
            incrementModel: BackupProfile.incrementModel,
            authentication: [BackupProfile.authentication],
            paymentRefusal: BackupProfile.paymentRefusal)
        return BackupDisclosure.from(
            connection: BackupConnection(manifest: manifest, profile: profile, terms: terms),
            schedule: schedule,
            mediaPolicy: mediaPolicy)
    }

    /// Every declared term reaches the surface. The list is spelled out
    /// rather than counted so that adding a field to `BackupTerms`
    /// without disclosing it fails here.
    func testEveryDeclaredTermIsDisclosed() throws {
        let ids = Set(try disclosure().items.map(\.id))
        let required: Set<String> = [
            "operator",
            "retention.class", "retention.period", "retention.count", "retention.expiry",
            "erasure.acknowledgement", "erasure.completion", "erasure.scope", "erasure.excluded",
            "jurisdictions", "subProcessors",
            "lawfulAccess.produces", "lawfulAccess.notify",
            "breach",
            "export.format", "export.unpaid", "shutdownNotice",
            "endOfPayment.notice", "endOfPayment.grace",
            "endOfPayment.duringGrace", "endOfPayment.afterGrace",
            "metadata.accessLogs", "metadata.sizeAndTiming",
            "media", "termsId",
        ]
        XCTAssertTrue(required.isSubset(of: ids), "missing: \(required.subtracting(ids).sorted())")
    }

    /// The sentence §7.4 requires. Asserted on substance, not wording,
    /// so a rewrite can improve the copy but not quietly drop the point.
    func testThirdPartyConsequenceIsStated() throws {
        let text = try disclosure().thirdPartyConsequence.lowercased()
        XCTAssertTrue(text.contains("both sides of every conversation"))
        XCTAssertTrue(text.contains("did not choose"))
    }

    /// §11: a person must learn there is no recovery here, not later.
    func testAbsentResetPathIsStated() throws {
        let text = try disclosure().noResetPath.lowercased()
        XCTAssertTrue(text.contains("recovery phrase"))
        XCTAssertTrue(text.contains("unreadable"))
        XCTAssertTrue(text.contains("no reset"))
    }

    /// The schedule copy must not promise more than the build does.
    /// Uploads are foreground-only, so "automatic" would be a lie, and
    /// whole-snapshot means every run re-uploads everything.
    func testScheduleCopyDoesNotOverpromise() throws {
        let text = try disclosure().whenBackupsHappen.lowercased()
        XCTAssertTrue(text.contains("cannot back up in the background"))
        XCTAssertTrue(text.contains("whole history"))
        XCTAssertFalse(text.contains("automatically"))
    }

    /// What erasure does *not* reach is the part a person is likeliest
    /// to assume away, so it travels verbatim rather than summarised.
    func testExcludedErasureScopeIsVerbatim() throws {
        let item = try XCTUnwrap(try disclosure().items.first { $0.id == "erasure.excluded" })
        XCTAssertEqual(item.value, "copies other participants hold, and copies you exported")
    }

    /// Descriptors-only must say what it costs, rather than letting
    /// someone discover it when their media is gone.
    func testDescriptorsOnlyDisclosesItsMediaCost() throws {
        let item = try XCTUnwrap(try disclosure().items.first { $0.id == "media" })
        XCTAssertTrue(item.value.contains("gone if it no longer has them"))

        let included = try XCTUnwrap(
            try disclosure(mediaPolicy: .includeCiphertext).items.first { $0.id == "media" })
        XCTAssertEqual(included.value, "Included in the backup")
    }

    /// The schedule sentence follows the policy rather than being
    /// written beside it.
    func testScheduleSentenceTracksThePolicy() {
        var schedule = BackupSchedule.default
        schedule.requiresCharging = false
        let sentence = BackupDisclosure.scheduleSentence(schedule).lowercased()
        XCTAssertTrue(sentence.contains("on wi-fi"))
        XCTAssertFalse(sentence.contains("charging"))
    }

    func testOpportunisticRunRespectsConditions() {
        let schedule = BackupSchedule.default
        let ready = BackupSchedule.Conditions(
            onWiFi: true, charging: true, lastSuccessAt: nil, lastAttemptAt: nil)
        XCTAssertTrue(schedule.permitsOpportunisticRun(ready, jitter: 0))

        var cellular = ready
        cellular.onWiFi = false
        XCTAssertFalse(schedule.permitsOpportunisticRun(cellular, jitter: 0))

        var recent = ready
        recent.lastAttemptAt = Date()
        XCTAssertFalse(schedule.permitsOpportunisticRun(recent, jitter: 0))
    }

    /// A backup that quietly stopped working has to be a visible state
    /// (§7.15), which starts with the flow calling it stale.
    func testNeverBackedUpCountsAsStale() {
        XCTAssertTrue(BackupSchedule.default.isStale(lastSuccessAt: nil))
        XCTAssertFalse(BackupSchedule.default.isStale(lastSuccessAt: Date()))
    }

    /// The gate this screen's central claim rests on.
    ///
    /// The first version set the flag from an `onAppear` sentinel in a
    /// plain `VStack`, which fires at initial layout for offscreen
    /// children — so "Turn On Backup" was enabled before anyone read a
    /// word. Tested through the pure predicate now, because a claim
    /// about consent that only a human can check is the claim most
    /// likely to quietly stop being true.
    func testScrollGateOnlyOpensAtTheEnd() {
        // A long disclosure, sitting at the top: not read.
        XCTAssertFalse(
            BackupEnrolmentView.hasReachedEnd(
                contentOffsetY: 0, containerHeight: 800, contentHeight: 4000))

        // Halfway: still not read.
        XCTAssertFalse(
            BackupEnrolmentView.hasReachedEnd(
                contentOffsetY: 1600, containerHeight: 800, contentHeight: 4000))

        // At the bottom: read.
        XCTAssertTrue(
            BackupEnrolmentView.hasReachedEnd(
                contentOffsetY: 3200, containerHeight: 800, contentHeight: 4000))
    }

    /// Content shorter than the screen has already been read in full.
    /// Gating on a scroll that can never happen would lock the button
    /// forever — a failure that only shows up on a large display.
    func testShortDisclosureCountsAsRead() {
        XCTAssertTrue(
            BackupEnrolmentView.hasReachedEnd(
                contentOffsetY: 0, containerHeight: 1200, contentHeight: 900))
    }

    /// A declared-but-unapplied jitter is decoration on top of the
    /// activity signal it claims to suppress.
    func testJitterDelaysTheOpportunisticRun() {
        let schedule = BackupSchedule.default
        let lastAttempt = Date()
        let conditions = BackupSchedule.Conditions(
            onWiFi: true, charging: true, lastSuccessAt: lastAttempt, lastAttemptAt: lastAttempt)

        // Exactly one interval later, with two hours of jitter drawn:
        // not yet.
        let atInterval = lastAttempt.addingTimeInterval(schedule.minimumInterval)
        XCTAssertFalse(
            schedule.permitsOpportunisticRun(conditions, jitter: 7200, now: atInterval))

        // Past the interval plus the jitter: now.
        let afterJitter = lastAttempt.addingTimeInterval(schedule.minimumInterval + 7201)
        XCTAssertTrue(
            schedule.permitsOpportunisticRun(conditions, jitter: 7200, now: afterJitter))
    }

    /// Drawn jitter stays inside its declared bound, so the copy that
    /// describes the cadence cannot be wrong about it.
    func testDrawnJitterRespectsItsBound() {
        let schedule = BackupSchedule.default
        for _ in 0..<64 {
            let jitter = schedule.drawJitter()
            XCTAssertGreaterThanOrEqual(jitter, 0)
            XCTAssertLessThanOrEqual(jitter, schedule.maximumJitter)
        }
    }

    /// The cadence sentence follows the configured interval rather than
    /// asserting a day beside a value that can change.
    func testCadenceTracksTheInterval() {
        XCTAssertEqual(BackupDisclosure.cadence(24 * 3600), "once a day")
        XCTAssertEqual(BackupDisclosure.cadence(72 * 3600), "once every 3 days")
        XCTAssertEqual(BackupDisclosure.cadence(6 * 3600), "once every 6 hours")
    }

    // MARK: - Fixtures

    static func manifestJSON(termsId: String) -> Data {
        Data("""
        {"version":1,"componentId":"onym:component:op","seat":"storage.backup",
         "operator":"onym:key:\(String(repeating: "1", count: 64))",
         "backupProfileId":"\(BackupProfile.portableProfileId)",
         "implementationProfileId":"\(BackupProfile.implementationProfileId)",
         "endpoints":[{"uri":"https://backup.example","role":"read-write"}],
         "capabilities":["upload","list","download","erase","export"],
         "declaredTerms":"\(termsId)"}
        """.utf8)
    }

    static let termsJSON = Data("""
    {"termsVersion":1,"operator":"onym:key:\(String(repeating: "1", count: 64))",
     "retention":{"class":"measurable","maximumRetentionPeriod":"P1Y",
       "snapshotsRetained":"3","expiryBehavior":"notify-then-erase"},
     "erasure":{"acknowledgementDeadline":"P1D","completionDeadline":"P7D",
       "scope":"primary and declared replicas",
       "excluded":"copies other participants hold, and copies you exported"},
     "jurisdictions":["EE"],"subProcessors":[],
     "lawfulAccess":{"disclosureWhatIsProduced":"sealed-bytes-and-declared-metadata-only",
       "notifyHolderWhenPermitted":true,"transparencyReporting":null},
     "breachDisclosure":{"holderNotice":"P3D"},
     "export":{"format":"tar","availableWhileUnpaid":true},
     "shutdownNotice":"P90D",
     "endOfPayment":{"notice":"P14D","grace":"P30D",
       "duringGrace":["download","export","erase"],"afterGrace":"erase"},
     "metadataRetention":{"accessLogs":"none","sizeAndTiming":"P1Y",
       "holderIdentifiers":"P1Y","operationOutcomes":"PT6H",
       "erasureReceipts":"P1Y","entitlementRecords":"P1Y"}}
    """.utf8)
}
