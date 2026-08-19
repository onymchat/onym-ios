import Foundation

/// An operator's signed commitment about an erasure, measured against the
/// terms the erased snapshot pinned.
///
/// It is **not** proof of destruction, and a client must never render it
/// as one (`UI-Backup.md` §10.3). What it is: a statement, attributable and
/// timestamped, that an operator will be held to.
///
/// `excludedScope` is mandatory and non-empty by construction. There is
/// always something excluded — at minimum the copies held by the other
/// participants in every conversation the snapshot contained, and any copy
/// the holder exported. A receipt that names nothing is malformed rather
/// than generous, so decoding rejects it.
public struct ErasureReceipt: Sendable, Equatable {
    public let receiptVersion: Int
    public let receiptId: String
    public let operatorKey: String
    public let scope: String
    public let acknowledgedAt: Date
    public let completionCommittedBy: Date
    public let coveredScope: String
    public let excludedScope: String
    /// The terms this erasure was measured against — the *pinned* terms of
    /// the erased snapshot, not the operator's current ones.
    public let termsId: String
    public let rawBytes: Data
    public let signature: Data?

    public init(
        receiptId: String,
        operatorKey: String,
        scope: String,
        acknowledgedAt: Date,
        completionCommittedBy: Date,
        coveredScope: String,
        excludedScope: String,
        termsId: String,
        rawBytes: Data,
        signature: Data?
    ) {
        self.receiptVersion = 1
        self.receiptId = receiptId
        self.operatorKey = operatorKey
        self.scope = scope
        self.acknowledgedAt = acknowledgedAt
        self.completionCommittedBy = completionCommittedBy
        self.coveredScope = coveredScope
        self.excludedScope = excludedScope
        self.termsId = termsId
        self.rawBytes = rawBytes
        self.signature = signature
    }

    /// True while the operator's own committed deadline has not passed.
    /// A client shows "acknowledged, not proven destroyed" in this window
    /// rather than "erased".
    public func isCompletionPending(now: Date = Date()) -> Bool {
        now < completionCommittedBy
    }

    public static func decode(raw: Data, signature: Data? = nil) throws -> ErasureReceipt {
        guard
            let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
            let version = object["receiptVersion"] as? Int, version == 1,
            let receiptId = object["receiptId"] as? String, !receiptId.isEmpty,
            let operatorKey = object["operator"] as? String, !operatorKey.isEmpty,
            let scope = object["scope"] as? String, !scope.isEmpty,
            let acknowledgedAtString = object["acknowledgedAt"] as? String,
            let acknowledgedAt = BackupFormat.date(fromRFC3339: acknowledgedAtString),
            let committedByString = object["completionCommittedBy"] as? String,
            let completionCommittedBy = BackupFormat.date(fromRFC3339: committedByString),
            let coveredScope = object["coveredScope"] as? String, !coveredScope.isEmpty,
            let termsId = object["termsId"] as? String, BackupFormat.isDigest(termsId)
        else {
            throw BackupError.rejected(code: "malformed_receipt", message: nil)
        }
        // The one field worth its own guard: an empty excluded scope is a
        // claim no honest operator can make.
        guard
            let excludedScope = object["excludedScope"] as? String,
            !excludedScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw BackupError.rejected(
                code: "malformed_receipt",
                message: "excludedScope is mandatory and must not be empty"
            )
        }
        return ErasureReceipt(
            receiptId: receiptId,
            operatorKey: operatorKey,
            scope: scope,
            acknowledgedAt: acknowledgedAt,
            completionCommittedBy: completionCommittedBy,
            coveredScope: coveredScope,
            excludedScope: excludedScope,
            termsId: termsId,
            rawBytes: raw,
            signature: signature
        )
    }
}
