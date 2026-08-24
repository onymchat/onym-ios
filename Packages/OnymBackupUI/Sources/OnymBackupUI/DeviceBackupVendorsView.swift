import OnymBackup
import OnymDesign
import SwiftUI

/// Settings → Device Backup, listing every operator this identity keeps
/// its history with.
/// The flow is held as a plain `let`, not `@State`.
///
/// `@State(wrappedValue:)` keeps the *first* value for the lifetime of
/// the view's identity, so once this screen was on the navigation stack
/// a newly consented operator never reached it: the root view rebuilds
/// the whole stack when the consented set changes, and the pushed screen
/// went on listing the operators it was born with. `@Observable` needs
/// no `@State` to be observed — only to be owned, and this one is owned
/// by the composition root.
public struct DeviceBackupVendorsView: View {
    private let flow: DeviceBackupVendorsFlow
    private let makeEnrolment: (String) -> BackupEnrolmentView?
    private let makeRestore: () -> BackupRestoreView

    public init(
        flow: DeviceBackupVendorsFlow,
        makeEnrolment: @escaping (String) -> BackupEnrolmentView?,
        makeRestore: @escaping () -> BackupRestoreView
    ) {
        self.flow = flow
        self.makeEnrolment = makeEnrolment
        self.makeRestore = makeRestore
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel("STATUS")
                Card {
                    Row(title: statusTitle, subtitle: statusSubtitle, last: true) {
                        IconTile(symbol: statusSymbol, bg: OnymTile.blue)
                    }
                    .accessibilityIdentifier("backup.status_row")
                }
                Footnote(verbatim: statusFootnote)

                if flow.enrolledCount > 0 {
                    Card {
                        Button {
                            Task { await flow.backUpAllNow() }
                        } label: {
                            Row(
                                title: flow.enrolledCount > 1 ? "Back Up To All" : "Back Up Now",
                                subtitle: backUpSubtitle,
                                last: true
                            ) {
                                IconTile(symbol: "arrow.up.circle", bg: OnymTile.blue)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(flow.isRunning)
                        .accessibilityIdentifier("backup.back_up_now_row")
                    }
                    Footnote(
                        "Each backup uploads everything, not just what changed — there is no incremental upload yet.")
                }

                // Outside the enrolled gate on purpose. Reading a backup
                // needs the recovery phrase and the operator's name, not
                // a terms pin — `listSnapshots` and `download` consult no
                // local state at all. Inside the gate it disappeared
                // exactly when it was most wanted: a new phone with an
                // operator consented to and nothing set up yet, or every
                // operator republishing its terms at once, which counts
                // as not-enrolled and took the restore route with it.
                // Hiding restore until someone agrees to *store* a
                // backup asks them to take on a new obligation before
                // they may read what they already have.
                Card {
                    NavigationLink { makeRestore() } label: {
                        Row(
                            title: "Restore From Backup",
                            subtitle: "Adds messages and chats — nothing is deleted",
                            last: true
                        ) {
                            IconTile(symbol: "arrow.down.circle", bg: OnymTile.green)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("backup.restore_row")
                }

                restorePurchases

                operators
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("Device Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            flow.refresh()
            await flow.loadSnapshots()
        }
        // Its own task, so it runs beside the snapshot list rather than
        // in front of it. On the overwhelmingly common path it recovers
        // nothing, and making everyone wait for StoreKit and a credential
        // verification per operator to find that out delays the screen
        // for no one's benefit. The sweep reloads the list itself if it
        // actually recovers something — which is the only case where the
        // list's answer would have changed.
        .task {
            await flow.restorePurchasesIfNeeded()
        }
    }

    /// Recovering what was already paid for.
    ///
    /// Its own row rather than a line inside the payment-needed state,
    /// because the person who needs it most cannot see that state yet:
    /// on a new phone nothing has been uploaded, so no operator has
    /// refused anything, and the refusal that would have offered a
    /// purchase has not happened. They arrive knowing only that they
    /// paid for this once.
    @ViewBuilder
    private var restorePurchases: some View {
        if flow.canRestorePurchases {
            Card {
                Button {
                    Task { await flow.restorePurchases() }
                } label: {
                    Row(
                        title: "Restore Purchases",
                        subtitle: purchaseRestoreSubtitle,
                        last: true
                    ) {
                        IconTile(symbol: "arrow.clockwise.circle", bg: OnymTile.gray)
                    }
                }
                .buttonStyle(.plain)
                .disabled(flow.purchaseRestore == .running)
                .accessibilityIdentifier("backup.restore_purchases_row")
            }
            Footnote(
                "If you paid for storage on another phone, this brings that purchase to this one. You are not charged again.")
        }
    }

    private var purchaseRestoreSubtitle: String {
        switch flow.purchaseRestore {
        case .idle:
            return "Bring a subscription bought on another phone to this one"
        case .running:
            return "Checking with the App Store…"
        case .finished(
            let restored, let held, let checked, let heldUnknown, let syncFailed, let failures):
            if let first = failures.first {
                // The operator's own words, not a count. A failure here
                // is the difference between someone getting what they
                // paid for and buying it twice.
                return first
            }
            if restored > 0 {
                return restored == 1
                    ? "1 purchase restored"
                    : "\(restored) purchases restored"
            }
            if syncFailed, restored == 0 {
                // Nothing was asked, so nothing may be concluded. The
                // person on a replacement phone is exactly who would
                // act on a wrong answer here.
                return "Could not reach the App Store — try again"
            }
            if heldUnknown {
                // Neither "already set up" nor "nothing there": this
                // phone could not read what it holds, and both of the
                // other answers would be claims it cannot make.
                return "Could not check what this phone already has — try again"
            }
            if held > 0 { return "Nothing to restore — this phone is already set up" }
            // Only claimable if something actually asked. An operator
            // with no pinned issuer is never checked, and reporting that
            // as the App Store's answer is a positive claim made without
            // a question.
            return checked > 0
                ? "The App Store has no purchase for this identity to restore"
                : "No operator here sells storage through this app"
        }
    }

    /// One row per operator, each leading to its own screen.
    ///
    /// Never merged into a single "backup" row, however tidy that would
    /// be. These are separate companies, in separate jurisdictions, under
    /// separate terms, each paid separately and each able to fail on its
    /// own — and the row is where a person finds out which one is the
    /// problem.
    private var operators: some View {
        Group {
            SectionLabel("OPERATORS")
            Card {
                ForEach(Array(flow.vendors.enumerated()), id: \.element.id) { index, vendor in
                    NavigationLink {
                        DeviceBackupSettingsView(
                            flow: vendor.flow,
                            makeEnrolment: { makeEnrolment(vendor.id) }
                        )
                    } label: {
                        Row(
                            title: "Operator",
                            subtitle: Self.subtitle(for: vendor),
                            // Two lines, because the thing worth reading
                            // here is a failure message, and one line
                            // middle-truncates it exactly when it
                            // matters.
                            subtitleLineLimit: 2,
                            last: index == flow.vendors.count - 1
                        ) {
                            IconTile(
                                symbol: Self.symbol(for: vendor.flow.state.status),
                                bg: Self.tint(for: vendor.flow.state.status))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("backup.operator_row.\(vendor.id)")
                }
            }
            Footnote(
                "Every operator you set up keeps its own separate copy, sealed with its own key and paid for separately. One of them shutting down or losing your data does not take the others with it — and each one extends the life of this history for everyone in it, under its own jurisdiction.")
        }
    }

    /// The operator's name, then what it is actually doing. The name is
    /// runtime data, so it lives in the subtitle: `Row` takes a
    /// localization key for its title, and looking up user-facing data
    /// as one would be a bug waiting for a translator.
    /// The note comes from the operator's own flow rather than from the
    /// last fan-out, so it cannot outlive the run it describes — a
    /// per-operator backup refreshes that flow and clears it.
    private static func subtitle(for vendor: DeviceBackupVendorsFlow.Vendor) -> String {
        var line = vendor.displayName + " · " + describe(vendor.flow.state.status)
        if let note = vendor.flow.lastRunNote {
            line += " · " + note
        }
        return line
    }

    private static func describe(_ status: DeviceBackupSettingsFlow.Status) -> String {
        switch status {
        case .off: "not set up"
        case .idle(let at):
            at.map { "backed up \($0.formatted(date: .abbreviated, time: .shortened))" }
                ?? "set up, nothing uploaded yet"
        case .running: "backing up…"
        case .stale: "out of date"
        case .paymentRequired: "payment needed"
        case .termsChanged: "new terms to read"
        case .operatorChanged: "needs setting up again"
        case .checkingEarlierBackup: "checking an earlier backup"
        case .failed: "something went wrong"
        }
    }

    /// Green is reserved for an operator that is actually holding what
    /// it is supposed to hold.
    ///
    /// It used to be keyed on `needsEnrolment` alone, which painted
    /// every failing, stale, unpaid and unresolved operator the same
    /// green as a healthy one — on the list whose whole purpose is
    /// finding out which operator is the problem — and gave the two
    /// stopped-accepting-uploads states the same gray as one that was
    /// never turned on.
    private static func tint(for status: DeviceBackupSettingsFlow.Status) -> Color {
        switch status {
        case .idle, .running: OnymTile.green
        case .off: OnymTile.gray
        case .failed: OnymTile.red
        case .stale, .paymentRequired, .checkingEarlierBackup: OnymTile.amber
        // Set up, and no longer accepting uploads until somebody reads
        // something. Not a failure, and not "off" either.
        case .termsChanged, .operatorChanged: OnymTile.orange
        }
    }

    private static func symbol(for status: DeviceBackupSettingsFlow.Status) -> String {
        switch status {
        case .off, .operatorChanged: "externaldrive"
        case .idle: "externaldrive.badge.checkmark"
        case .running: "arrow.triangle.2.circlepath"
        case .stale: "exclamationmark.triangle"
        case .paymentRequired: "creditcard"
        case .termsChanged: "doc.badge.ellipsis"
        case .checkingEarlierBackup: "questionmark.circle"
        case .failed: "xmark.octagon"
        }
    }

    private var backUpSubtitle: String {
        flow.enrolledCount > 1
            ? "Uploads your whole history to all \(flow.enrolledCount) operators"
            : "Uploads your whole history"
    }

    private var statusTitle: LocalizedStringKey {
        switch flow.summary {
        case .off: "Off"
        case .on: "On"
        case .running: "Backing up…"
        case .needsAttention: "Needs attention"
        }
    }

    /// Counts, not adjectives. "On" with one of three operators failing
    /// is the reassuring summary this stack exists to refuse.
    private var statusSubtitle: String {
        switch flow.summary {
        case .off(let consented):
            return consented == 0
                ? "Your history stays on this phone only"
                : "Nothing is being backed up yet — you can still restore an earlier backup below"
        case .on(let operators, let notSetUp, let lastSuccessAt):
            // The oldest of the operators' last successes, so the
            // sentence describes the copy a person is actually relying
            // on rather than the freshest one.
            let when = lastSuccessAt.map {
                "oldest copy \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? "no backup has completed yet"
            var line = operators == 1 ? "1 operator · \(when)" : "\(operators) operators · \(when)"
            if notSetUp > 0 {
                // A consented operator holding nothing is not covered by
                // the ones that are, and it is the row someone would
                // otherwise never notice.
                line += notSetUp == 1
                    ? " · 1 more not set up"
                    : " · \(notSetUp) more not set up"
            }
            return line
        case .running:
            return "Uploading"
        case .needsAttention(let attention, let healthy):
            let needing = attention == 1
                ? "1 operator needs attention"
                : "\(attention) operators need attention"
            return healthy == 0 ? needing : "\(healthy) up to date · \(needing)"
        }
    }

    private var statusFootnote: String {
        switch flow.summary {
        case .off:
            "Only your recovery phrase can open a backup. An operator stores bytes it cannot read."
        case .needsAttention:
            "An operator that is out of date is not holding your recent history. Open it below to see what it is waiting for."
        default:
            "Backups run only when you tap Back Up Now. Nothing is uploaded on its own, so if you have not backed up in a while, nothing has been backed up."
        }
    }

    private var statusSymbol: String {
        switch flow.summary {
        case .off: "externaldrive"
        case .on: "externaldrive.badge.checkmark"
        case .running: "arrow.triangle.2.circlepath"
        case .needsAttention: "exclamationmark.triangle"
        }
    }
}
