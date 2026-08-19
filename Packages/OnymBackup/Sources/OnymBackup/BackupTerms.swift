import Foundation
import OnymFoundation

/// The declared policy this seat exists to make legible: how long a
/// snapshot is kept, where, under whose law, erased how, exported how, and
/// what happens when payment stops.
///
/// Terms are content-addressed and pinned into every snapshot. They bind
/// **forward only** (`UI-Backup.md` §10.2): a retained snapshot keeps the
/// terms it was accepted under, and an operator may publish new terms at
/// any time but cannot restate the ones a stored snapshot already pins.
/// `regresses(against:)` is how that stops being a promise and starts
/// being a check.
///
/// `rawBytes` is preserved because the signature is over the operator's
/// exact bytes; nothing here re-serialises for verification.
public struct BackupTerms: Sendable, Equatable {
    public let termsVersion: Int
    /// `sha256:<hex>` over the canonical bytes with `termsId` and
    /// `signature` omitted. Computed locally, never taken from the
    /// document's own claim about itself.
    public let termsId: String
    public let operatorKey: String

    public let retention: Retention
    public let erasure: Erasure
    public let jurisdictions: [String]
    public let subProcessors: [SubProcessor]
    public let lawfulAccess: LawfulAccess
    public let breachHolderNotice: String
    public let export: Export
    /// Declared window during which export keeps working after the
    /// operator announces shutdown. Optional only because terms written
    /// before this field existed will lack it; its absence is a gap a
    /// consent surface should say out loud.
    public let shutdownNotice: String?
    public let endOfPayment: EndOfPayment
    public let metadataRetention: MetadataRetention

    public let rawBytes: Data
    public let signature: Data?

    public struct Retention: Sendable, Equatable {
        /// `measurable` or `best-effort`, verbatim.
        public let retentionClass: String
        /// An ISO 8601 duration, or `until-erased`.
        public let maximumRetentionPeriod: String
        public let snapshotsRetained: String
        /// `erase` or `notify-then-erase`.
        public let expiryBehavior: String
    }

    public struct Erasure: Sendable, Equatable {
        public let acknowledgementDeadline: String
        public let completionDeadline: String
        /// Free text. Compared for *equality*, never interpreted — see
        /// `regresses(against:)`.
        public let scope: String
        /// What erasure provably does not cover. Mandatory and never
        /// empty; an operator that cannot name this has not understood
        /// what it is signing.
        public let excluded: String
    }

    public struct SubProcessor: Sendable, Equatable, Hashable {
        public let role: String
        public let jurisdiction: String
    }

    public struct LawfulAccess: Sendable, Equatable {
        public let disclosureWhatIsProduced: String
        public let notifyHolderWhenPermitted: Bool
        public let transparencyReporting: String?
    }

    public struct Export: Sendable, Equatable {
        public let format: String
        public let availableWhileUnpaid: Bool
    }

    public struct EndOfPayment: Sendable, Equatable {
        public let notice: String
        public let grace: String
        /// Operations that keep working during grace. `download`,
        /// `export`, and `erase` are the conforming minimum.
        public let duringGrace: [String]
        public let afterGrace: String
    }

    /// What the operator declares it keeps, and for how long.
    ///
    /// Six fields for five record classes: `accessLogs` declares an
    /// *absence* under this profile — its only conforming value is
    /// `none` — and the other five name the records the profile's own
    /// operations require an operator to hold. A declaration that omits
    /// one is understating, which is the failure the field exists to
    /// prevent.
    public struct MetadataRetention: Sendable, Equatable {
        public let accessLogs: String
        public let sizeAndTiming: String
        public let holderIdentifiers: String
        public let operationOutcomes: String
        public let erasureReceipts: String
        public let entitlementRecords: String
    }
}

// MARK: - Decoding

extension BackupTerms {
    /// Decode an operator's terms document from its exact served bytes.
    ///
    /// Every missing or malformed field is `termsUnavailable` rather than
    /// a partial value: terms are a precondition for enrolment
    /// (`UI-Backup.md` §13), and half-read terms are worse than none —
    /// they would be pinned and later compared against.
    public static func decode(raw: Data, signature: Data? = nil) throws -> BackupTerms {
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw BackupError.termsUnavailable
        }
        func string(_ container: [String: Any], _ key: String) throws -> String {
            guard let value = container[key] as? String, !value.isEmpty else {
                throw BackupError.termsUnavailable
            }
            return value
        }
        func nested(_ key: String) throws -> [String: Any] {
            guard let value = object[key] as? [String: Any] else { throw BackupError.termsUnavailable }
            return value
        }

        guard let termsVersion = object["termsVersion"] as? Int, termsVersion == 1 else {
            throw BackupError.termsUnavailable
        }

        let retentionObject = try nested("retention")
        let erasureObject = try nested("erasure")
        let lawfulObject = try nested("lawfulAccess")
        let breachObject = try nested("breachDisclosure")
        let exportObject = try nested("export")
        let paymentObject = try nested("endOfPayment")
        let metadataObject = try nested("metadataRetention")

        let jurisdictions = (object["jurisdictions"] as? [String]) ?? []
        guard !jurisdictions.isEmpty else { throw BackupError.termsUnavailable }

        // Fail closed like every other field: a sub-processor whose role
        // or jurisdiction is missing or not a string is a malformed
        // disclosure, and coercing it to "" would pin a snapshot against
        // terms naming a processor in the empty jurisdiction — a
        // comparison that then passes forever.
        let subProcessors = try ((object["subProcessors"] as? [[String: Any]]) ?? []).map {
            SubProcessor(
                role: try string($0, "role"),
                jurisdiction: try string($0, "jurisdiction")
            )
        }

        let excluded = try string(erasureObject, "excluded")

        let terms = BackupTerms(
            termsVersion: termsVersion,
            termsId: try canonicalTermsId(raw: raw),
            operatorKey: try string(object, "operator"),
            retention: Retention(
                retentionClass: try string(retentionObject, "class"),
                maximumRetentionPeriod: try string(retentionObject, "maximumRetentionPeriod"),
                snapshotsRetained: try string(retentionObject, "snapshotsRetained"),
                expiryBehavior: try string(retentionObject, "expiryBehavior")
            ),
            erasure: Erasure(
                acknowledgementDeadline: try string(erasureObject, "acknowledgementDeadline"),
                completionDeadline: try string(erasureObject, "completionDeadline"),
                scope: try string(erasureObject, "scope"),
                excluded: excluded
            ),
            jurisdictions: jurisdictions,
            subProcessors: subProcessors,
            lawfulAccess: LawfulAccess(
                disclosureWhatIsProduced: try string(lawfulObject, "disclosureWhatIsProduced"),
                notifyHolderWhenPermitted: (lawfulObject["notifyHolderWhenPermitted"] as? Bool) ?? false,
                transparencyReporting: lawfulObject["transparencyReporting"] as? String
            ),
            breachHolderNotice: try string(breachObject, "holderNotice"),
            export: Export(
                format: try string(exportObject, "format"),
                availableWhileUnpaid: (exportObject["availableWhileUnpaid"] as? Bool) ?? false
            ),
            shutdownNotice: object["shutdownNotice"] as? String,
            endOfPayment: EndOfPayment(
                notice: try string(paymentObject, "notice"),
                grace: try string(paymentObject, "grace"),
                duringGrace: (paymentObject["duringGrace"] as? [String]) ?? [],
                afterGrace: try string(paymentObject, "afterGrace")
            ),
            metadataRetention: MetadataRetention(
                accessLogs: try string(metadataObject, "accessLogs"),
                sizeAndTiming: try string(metadataObject, "sizeAndTiming"),
                holderIdentifiers: try string(metadataObject, "holderIdentifiers"),
                operationOutcomes: try string(metadataObject, "operationOutcomes"),
                erasureReceipts: try string(metadataObject, "erasureReceipts"),
                entitlementRecords: try string(metadataObject, "entitlementRecords")
            ),
            rawBytes: raw,
            signature: signature
        )
        return terms
    }

    /// `sha256:<hex>` over the document with `termsId` and `signature`
    /// removed, in the canonical form the profile pins.
    ///
    /// This must be the *same* canonicalization the operator used, or an
    /// honest operator's `declaredTermsDigest` will not match what we
    /// compute and enrolment fails for no reason either side can see. So
    /// it goes through `ServiceManifestCanonical`, the one serializer in
    /// this codebase that implements the pinned rules: keys sorted by
    /// **UTF-8 byte order** (not Foundation's `.sortedKeys`, which is a
    /// different order and the exact trap the profile's §6.3 warns
    /// about), floats refused rather than rendered, and one fixed
    /// escaping set.
    ///
    /// Re-serializing with `JSONSerialization` instead would be
    /// plausible and wrong: a round trip normalizes number formatting
    /// and escaping in ways that are stable for us and need not match a
    /// conforming operator computing the digest properly.
    static func canonicalTermsId(raw: Data) throws -> String {
        guard let canonical = try? ServiceManifestCanonical.signingBytes(
            of: raw,
            omitting: ["termsId", "signature"]
        ) else {
            throw BackupError.termsUnavailable
        }
        return BackupFormat.sha256Digest(of: canonical)
    }
}

// MARK: - Forward-only binding

extension BackupTerms {
    /// The name of the first field on which `self` is **weaker** than
    /// `pinned`, or `nil` when `self` may be applied to a snapshot that
    /// pinned `pinned`.
    ///
    /// Fails closed everywhere. An unparseable duration counts as a
    /// regression; free-text scope fields count as a regression on *any*
    /// change, because nothing here can prove a reworded scope is a
    /// widening rather than a narrowing. The consequence is that an
    /// operator improving its own wording must obtain fresh consent, which
    /// is the correct direction to be wrong in.
    public func regresses(against pinned: BackupTerms) -> String? {
        // Retention may not be extended over a snapshot already accepted.
        if longer(retention.maximumRetentionPeriod, than: pinned.retention.maximumRetentionPeriod) {
            return "retention.maximumRetentionPeriod"
        }
        if retention.expiryBehavior != pinned.retention.expiryBehavior {
            return "retention.expiryBehavior"
        }
        // `measurable` -> `best-effort` is a downgrade of what the
        // operator claims it can be held to, and the class values are a
        // small vocabulary this layer should not rank: any change is a
        // regression, same as the free-text fields below.
        if retention.retentionClass != pinned.retention.retentionClass {
            return "retention.retentionClass"
        }
        // A cut in how many snapshots are kept destroys history the
        // person is already relying on. Free text ("3", "latest only",
        // "all"), so any change requires fresh consent.
        if retention.snapshotsRetained != pinned.retention.snapshotsRetained {
            return "retention.snapshotsRetained"
        }
        // Erasure may not become slower or narrower.
        if longer(erasure.acknowledgementDeadline, than: pinned.erasure.acknowledgementDeadline) {
            return "erasure.acknowledgementDeadline"
        }
        if longer(erasure.completionDeadline, than: pinned.erasure.completionDeadline) {
            return "erasure.completionDeadline"
        }
        if erasure.scope != pinned.erasure.scope { return "erasure.scope" }
        if erasure.excluded != pinned.erasure.excluded { return "erasure.excluded" }
        // Jurisdictions and sub-processors may be removed, never added.
        if !Set(jurisdictions).subtracting(pinned.jurisdictions).isEmpty {
            return "jurisdictions"
        }
        if !Set(subProcessors).subtracting(pinned.subProcessors).isEmpty {
            return "subProcessors"
        }
        // Lawful-access practice may not become less protective.
        if lawfulAccess.disclosureWhatIsProduced != pinned.lawfulAccess.disclosureWhatIsProduced {
            return "lawfulAccess.disclosureWhatIsProduced"
        }
        if pinned.lawfulAccess.notifyHolderWhenPermitted && !lawfulAccess.notifyHolderWhenPermitted {
            return "lawfulAccess.notifyHolderWhenPermitted"
        }
        // Dropping a declared transparency cadence, or changing it at
        // all, removes a commitment the person weighed at enrolment.
        // Optional, so nil-to-nil is fine and anything else is not.
        if lawfulAccess.transparencyReporting != pinned.lawfulAccess.transparencyReporting {
            return "lawfulAccess.transparencyReporting"
        }
        if longer(breachHolderNotice, than: pinned.breachHolderNotice) {
            return "breachDisclosure.holderNotice"
        }
        // The export path may not be removed or narrowed.
        if export.format != pinned.export.format { return "export.format" }
        if pinned.export.availableWhileUnpaid && !export.availableWhileUnpaid {
            return "export.availableWhileUnpaid"
        }
        if shorter(shutdownNotice, than: pinned.shutdownNotice) { return "shutdownNotice" }
        // Notice and grace may not shrink; grace may not lose an operation.
        if shorter(endOfPayment.notice, than: pinned.endOfPayment.notice) {
            return "endOfPayment.notice"
        }
        if shorter(endOfPayment.grace, than: pinned.endOfPayment.grace) {
            return "endOfPayment.grace"
        }
        if !Set(pinned.endOfPayment.duringGrace).subtracting(endOfPayment.duringGrace).isEmpty {
            return "endOfPayment.duringGrace"
        }
        if endOfPayment.afterGrace != pinned.endOfPayment.afterGrace {
            return "endOfPayment.afterGrace"
        }
        // Metadata may not be kept longer — every declared class, or the
        // check only covers the two the schema happened to start with.
        let metadataAxes: [(String, String, String)] = [
            ("accessLogs", metadataRetention.accessLogs, pinned.metadataRetention.accessLogs),
            ("sizeAndTiming", metadataRetention.sizeAndTiming, pinned.metadataRetention.sizeAndTiming),
            ("holderIdentifiers", metadataRetention.holderIdentifiers, pinned.metadataRetention.holderIdentifiers),
            ("operationOutcomes", metadataRetention.operationOutcomes, pinned.metadataRetention.operationOutcomes),
            ("erasureReceipts", metadataRetention.erasureReceipts, pinned.metadataRetention.erasureReceipts),
            ("entitlementRecords", metadataRetention.entitlementRecords, pinned.metadataRetention.entitlementRecords),
        ]
        for (name, candidate, pinnedValue) in metadataAxes where longer(candidate, than: pinnedValue) {
            return "metadataRetention.\(name)"
        }
        return nil
    }

    private func longer(_ candidate: String, than pinned: String) -> Bool {
        if candidate == pinned { return false }
        // "until-erased" is unbounded: it is longer than everything, and
        // nothing is longer than it.
        if candidate == BackupDuration.untilErased { return true }
        if pinned == BackupDuration.untilErased { return false }
        guard let a = BackupDuration.seconds(candidate), let b = BackupDuration.seconds(pinned) else {
            return true  // unparseable: fail closed
        }
        return a > b
    }

    private func shorter(_ candidate: String?, than pinned: String?) -> Bool {
        guard let pinned else { return false }
        guard let candidate else { return true }  // a declared window was dropped
        if candidate == pinned { return false }
        if pinned == BackupDuration.untilErased { return candidate != BackupDuration.untilErased }
        if candidate == BackupDuration.untilErased { return false }
        guard let a = BackupDuration.seconds(candidate), let b = BackupDuration.seconds(pinned) else {
            return true
        }
        return a < b
    }
}

/// Minimal ISO 8601 duration reader, for *comparison only*.
///
/// Years and months are approximated (365 and 30 days). That is unfit for
/// calendar arithmetic and perfectly fit for the one question asked here —
/// is this declared window longer than that one — where the alternative is
/// refusing to compare `P1M` against `P30D` at all.
enum BackupDuration {
    static let untilErased = "until-erased"
    /// Declared absence. The object-HTTP profile requires `accessLogs:
    /// "none"`, and a declaration of nothing is a real, comparable
    /// window of length zero — without this, moving from a 30-day log to
    /// no log at all would read as an unparseable value and be refused
    /// as a regression, which is backwards.
    static let none = "none"

    static func seconds(_ value: String) -> TimeInterval? {
        if value == none { return 0 }
        guard value.hasPrefix("P") else { return nil }
        var total: TimeInterval = 0
        var number = ""
        var inTime = false
        var sawUnit = false
        for character in value.dropFirst() {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let magnitude = Double(number) else { return nil }
            number = ""
            sawUnit = true
            switch (character, inTime) {
            case ("Y", false): total += magnitude * 365 * 86_400
            case ("M", false): total += magnitude * 30 * 86_400
            case ("W", false): total += magnitude * 7 * 86_400
            case ("D", false): total += magnitude * 86_400
            case ("H", true): total += magnitude * 3_600
            case ("M", true): total += magnitude * 60
            case ("S", true): total += magnitude
            default: return nil
            }
        }
        guard number.isEmpty, sawUnit else { return nil }
        return total
    }
}
