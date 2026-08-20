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
    /// Present only when this identity already backs up somewhere else.
    ///
    /// Adding an operator is not the same decision as choosing one, and
    /// the surface must not let it read as one: a second operator is a
    /// second complete copy, in a second jurisdiction, under a second
    /// company's terms, paid for twice — and it extends the life of
    /// everyone else's messages a second time (`UI-Backup.md` §14.11).
    /// A person who thinks they are switching should find out here.
    public let additionalCopies: String?
    public let operatorName: String
    public let items: [Item]

    public init(
        thirdPartyConsequence: String,
        noResetPath: String,
        whenBackupsHappen: String,
        additionalCopies: String? = nil,
        operatorName: String,
        items: [Item]
    ) {
        self.thirdPartyConsequence = thirdPartyConsequence
        self.noResetPath = noResetPath
        self.whenBackupsHappen = whenBackupsHappen
        self.additionalCopies = additionalCopies
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
    /// An operator this identity is already enrolled with, as far as
    /// its *pinned* terms describe it.
    ///
    /// Jurisdictions come from the terms bytes the person consented to,
    /// not from a live fetch and not from a guess. Nothing here knows
    /// who owns an operator, so nothing here says anything about it.
    public struct OtherOperator: Sendable, Equatable {
        public let name: String
        public let jurisdictions: [String]

        public init(name: String, jurisdictions: [String]) {
            self.name = name
            self.jurisdictions = jurisdictions
        }
    }

    /// `otherOperators` describes the operators this identity is
    /// *already* enrolled with, so the surface can say what adding one
    /// more does.
    public static func from(
        connection: BackupConnection,
        schedule: BackupSchedule,
        mediaPolicy: BackupMediaPolicy,
        otherOperators: [OtherOperator] = []
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
            additionalCopies: Self.additionalCopiesSentence(
                otherOperators, jurisdictions: terms.jurisdictions),
            operatorName: connection.manifest.componentId,
            items: items
        )
    }

    /// What a second operator actually means, when there already is one.
    ///
    /// Every clause is checkable against something signed. An earlier
    /// draft said the new operator was "held by a different company, in
    /// a different country, under different terms" — of which this knows
    /// exactly one: the terms are its own, because a terms digest is
    /// what enrolment pins. Nothing here knows who owns an operator, and
    /// two operators can perfectly well be in the same country, which
    /// would have made a consent screen state something false in order
    /// to sound more reassuring. That is the precise failure §14.11
    /// exists to prevent.
    ///
    /// Jurisdiction is the one part that *is* knowable, from the pinned
    /// terms on both sides — so it is stated as what it is, including
    /// when it is the unhelpful answer: two copies under the same
    /// authorities are two copies one order can reach.
    static func additionalCopiesSentence(
        _ otherOperators: [OtherOperator],
        jurisdictions: [String]
    ) -> String? {
        guard !otherOperators.isEmpty else { return nil }
        let names = otherOperators.map(\.name).joined(separator: ", ")
        var sentence = """
            You already back up to \(names). Setting this one up does not replace it — it adds \
            a second complete copy of your history, kept under this operator's own terms and \
            paid for separately. Everyone in your chats has their messages kept in one more \
            place. Setting this one up does not turn the other one off.
            """
        if let jurisdiction = Self.jurisdictionSentence(otherOperators, jurisdictions: jurisdictions) {
            sentence += " " + jurisdiction
        }
        return sentence
    }

    /// Where the two copies actually sit, when both sides said so.
    ///
    /// Silent when either side's terms did not reach us. An unstated
    /// jurisdiction is not evidence of a different one.
    static func jurisdictionSentence(
        _ otherOperators: [OtherOperator],
        jurisdictions: [String]
    ) -> String? {
        let known = otherOperators.filter { !$0.jurisdictions.isEmpty }
        guard !jurisdictions.isEmpty, !known.isEmpty else { return nil }
        let mine = Set(jurisdictions)
        let shared = known.filter { !mine.isDisjoint(with: Set($0.jurisdictions)) }
        if shared.isEmpty {
            return """
                This one stores in \(jurisdictions.joined(separator: ", ")); \
                \(known.map(\.name).joined(separator: ", ")) stores your backup somewhere else.
                """
        }
        let overlap = shared
            .flatMap { $0.jurisdictions }
            .filter { mine.contains($0) }
        return """
            Both this operator and \(shared.map(\.name).joined(separator: ", ")) store in \
            \(Array(Set(overlap)).sorted().joined(separator: ", ")), so one authority can reach \
            both copies.
            """
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

    /// What this build actually does, which is less than the schedule
    /// describes.
    ///
    /// `BackupSchedule` models an opportunistic run — on Wi-Fi, while
    /// charging, at most once per interval — and `backUpIfDue` executes
    /// it, and *nothing calls it*. So the sentence this screen used to
    /// show ("Onym may also back up on its own while the app is open, on
    /// Wi-Fi") described a policy rather than a behaviour, on the one
    /// screen whose entire job is to say what will happen. Someone
    /// reading it would reasonably never tap the button again.
    ///
    /// It says tap-only until something calls `backUpIfDue`. The
    /// conditions stay in the schedule, where they will be true the day
    /// they are wired.
    static func scheduleSentence(_ schedule: BackupSchedule) -> String {
        _ = schedule
        return """
            Backups run when you tap Back Up Now, and only then. This version does not back up \
            on its own — not in the background, and not while the app is open. Each backup \
            uploads your whole history, not just what changed.
            """
    }
}
