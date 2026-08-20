import Foundation
import OnymBackup

/// Everything the enrolment surface must say before a single byte
/// leaves the device.
///
/// Built as data rather than assembled inline in a view so a fixture can
/// assert its content. `UI-Backup.md` §18.10 asks for exactly that: the
/// consent surface is verified "by fixture rather than by review",
/// because a disclosure that quietly loses a paragraph in a refactor is
/// worse than one that was never written.
public struct BackupDisclosure: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let value: String
    }

    /// The sentence §7.4 and §10.4 require, and the reason this seat
    /// treats disclosure as a contract term rather than a courtesy: a
    /// snapshot extends the life of both sides of every conversation in
    /// it, for people who never chose this operator.
    public let thirdPartyConsequence: String
    /// The absent reset path (§11). Stated as plainly as it deserves —
    /// there is no recovery, and a person should learn that here rather
    /// than when they need it.
    public let noResetPath: String
    /// What this build actually does about scheduling. Copy that
    /// promises "automatic" while uploads are foreground-only would be
    /// the easiest lie in the product.
    public let whenBackupsHappen: String
    public let operatorName: String
    public let items: [Item]

    public init(
        thirdPartyConsequence: String,
        noResetPath: String,
        whenBackupsHappen: String,
        operatorName: String,
        items: [Item]
    ) {
        self.thirdPartyConsequence = thirdPartyConsequence
        self.noResetPath = noResetPath
        self.whenBackupsHappen = whenBackupsHappen
        self.operatorName = operatorName
        self.items = items
    }

    /// Compose from what the operator actually published.
    ///
    /// Every declared field is rendered, including the ones that read
    /// badly. An operator that excludes a great deal from erasure, or
    /// keeps access logs, or names four sub-processors, has said so in a
    /// signed document, and the surface's job is to repeat it rather
    /// than summarise it into something more comfortable.
    public static func from(
        connection: BackupConnection,
        schedule: BackupSchedule,
        mediaPolicy: BackupMediaPolicy
    ) -> BackupDisclosure {
        let terms = connection.terms
        var items: [Item] = [
            Item(id: "operator", label: "Operator", value: connection.manifest.componentId),
            Item(id: "retention.class", label: "Retention class", value: terms.retention.retentionClass),
            Item(
                id: "retention.period", label: "Kept for",
                value: terms.retention.maximumRetentionPeriod),
            Item(
                id: "retention.count", label: "Snapshots kept",
                value: terms.retention.snapshotsRetained),
            Item(
                id: "retention.expiry", label: "When retention ends",
                value: terms.retention.expiryBehavior),
            Item(
                id: "erasure.acknowledgement", label: "Erasure acknowledged within",
                value: terms.erasure.acknowledgementDeadline),
            Item(
                id: "erasure.completion", label: "Erasure completed within",
                value: terms.erasure.completionDeadline),
            Item(id: "erasure.scope", label: "Erasure covers", value: terms.erasure.scope),
            // Verbatim, and never summarised. What erasure does *not*
            // reach is the part a person is most likely to assume away.
            Item(id: "erasure.excluded", label: "Erasure does not cover", value: terms.erasure.excluded),
            Item(
                id: "jurisdictions", label: "Stored and processed in",
                value: terms.jurisdictions.joined(separator: ", ")),
            Item(
                id: "subProcessors", label: "Sub-processors",
                value: terms.subProcessors.isEmpty
                    ? "None declared"
                    : terms.subProcessors
                        .map { "\($0.role) (\($0.jurisdiction))" }
                        .joined(separator: ", ")),
            Item(
                id: "lawfulAccess.produces", label: "A legal demand produces",
                value: terms.lawfulAccess.disclosureWhatIsProduced),
            Item(
                id: "lawfulAccess.notify", label: "You are told when permitted",
                value: terms.lawfulAccess.notifyHolderWhenPermitted ? "Yes" : "No"),
            Item(
                id: "breach", label: "Breach notice",
                value: terms.breachHolderNotice),
            Item(id: "export.format", label: "Export format", value: terms.export.format),
            Item(
                id: "export.unpaid", label: "Export while unpaid",
                value: terms.export.availableWhileUnpaid ? "Available" : "Not available"),
            Item(
                id: "shutdownNotice", label: "If the operator shuts down",
                value: terms.shutdownNotice.map { "Export works for \($0)" }
                    ?? "No notice period declared"),
            Item(id: "endOfPayment.notice", label: "Notice if payment stops", value: terms.endOfPayment.notice),
            Item(id: "endOfPayment.grace", label: "Grace period", value: terms.endOfPayment.grace),
            Item(
                id: "endOfPayment.duringGrace", label: "Still works during grace",
                value: terms.endOfPayment.duringGrace.joined(separator: ", ")),
            Item(
                id: "endOfPayment.afterGrace", label: "After grace",
                value: terms.endOfPayment.afterGrace),
            Item(
                id: "metadata.accessLogs", label: "Access logs kept",
                value: terms.metadataRetention.accessLogs),
            Item(
                id: "metadata.sizeAndTiming", label: "Size and timing kept",
                value: terms.metadataRetention.sizeAndTiming),
            Item(
                id: "media", label: "Attachments",
                value: mediaPolicy == .includeCiphertext
                    ? "Included in the backup"
                    : "Not included — they reload from your media provider, and are gone if it no longer has them"),
        ]
        items.append(
            Item(
                id: "termsId", label: "Terms digest",
                value: connection.acceptedTermsId))

        return BackupDisclosure(
            thirdPartyConsequence: """
                A backup keeps a copy of both sides of every conversation on this phone. \
                The other people in those chats did not choose this operator, this country, \
                or how long it keeps things. Backing up extends how long their messages exist.
                """,
            noResetPath: """
                Only your recovery phrase can open this backup — not the operator, and not Onym. \
                If you lose the phrase, the backup is unreadable forever. There is no reset, \
                and nobody can make one for you.
                """,
            whenBackupsHappen: Self.scheduleSentence(schedule),
            operatorName: connection.manifest.componentId,
            items: items
        )
    }

    /// Describes the configured interval rather than asserting a day.
    /// A hardcoded cadence beside a configurable one is a sentence that
    /// starts true and quietly stops being.
    static func cadence(_ interval: TimeInterval) -> String {
        let hours = interval / 3600
        if hours >= 48 { return "once every \(Int((hours / 24).rounded())) days" }
        if hours >= 24 { return "once a day" }
        if hours >= 2 { return "once every \(Int(hours.rounded())) hours" }
        return "once an hour"
    }

    static func scheduleSentence(_ schedule: BackupSchedule) -> String {
        var conditions: [String] = []
        if schedule.requiresWiFi { conditions.append("on Wi-Fi") }
        if schedule.requiresCharging { conditions.append("while charging") }
        let when = conditions.isEmpty ? "" : " " + conditions.joined(separator: " and ")
        let cadence = Self.cadence(schedule.minimumInterval)
        return """
            Backups run when you tap Back Up Now. Onym may also back up on its own while \
            the app is open\(when), at most \(cadence). It cannot back up in the background, \
            so if you never open the app, nothing is backed up. Each backup uploads your \
            whole history, not just what changed.
            """
    }
}
