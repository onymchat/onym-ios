import OnymBackup
import OnymDesign
import SwiftUI

/// Settings → Device Backup, listing every operator this identity keeps
/// its history with.
public struct DeviceBackupVendorsView: View {
    @State private var flow: DeviceBackupVendorsFlow
    private let makeEnrolment: (String) -> BackupEnrolmentView?
    private let makeRestore: () -> BackupRestoreView

    public init(
        flow: DeviceBackupVendorsFlow,
        makeEnrolment: @escaping (String) -> BackupEnrolmentView?,
        makeRestore: @escaping () -> BackupRestoreView
    ) {
        _flow = State(wrappedValue: flow)
        self.makeEnrolment = makeEnrolment
        self.makeRestore = makeRestore
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSectionLabel("STATUS")
                SettingsCard {
                    SettingsRow(title: statusTitle, subtitle: statusSubtitle, last: true) {
                        SettingsIconTile(symbol: statusSymbol, bg: SettingsTile.blue)
                    }
                    .accessibilityIdentifier("backup.status_row")
                }
                SettingsFootnote(verbatim: statusFootnote)

                if flow.enrolledCount > 0 {
                    SettingsCard {
                        Button {
                            Task { await flow.backUpAllNow() }
                        } label: {
                            SettingsRow(
                                title: flow.enrolledCount > 1 ? "Back Up To All" : "Back Up Now",
                                subtitle: backUpSubtitle,
                                last: true
                            ) {
                                SettingsIconTile(symbol: "arrow.up.circle", bg: SettingsTile.blue)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(flow.isRunning)
                        .accessibilityIdentifier("backup.back_up_now_row")
                    }
                    SettingsFootnote(
                        "Each backup uploads everything, not just what changed — there is no incremental upload yet.")

                    SettingsCard {
                        NavigationLink { makeRestore() } label: {
                            SettingsRow(
                                title: "Restore From Backup",
                                subtitle: "Adds messages and chats — nothing is deleted",
                                last: true
                            ) {
                                SettingsIconTile(symbol: "arrow.down.circle", bg: SettingsTile.green)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("backup.restore_row")
                    }
                }

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
            SettingsSectionLabel("OPERATORS")
            SettingsCard {
                ForEach(Array(flow.vendors.enumerated()), id: \.element.id) { index, vendor in
                    NavigationLink {
                        DeviceBackupSettingsView(
                            flow: vendor.flow,
                            makeEnrolment: { makeEnrolment(vendor.id) }
                        )
                    } label: {
                        SettingsRow(
                            title: "Operator",
                            subtitle: Self.subtitle(for: vendor, run: flow.lastRun(for: vendor.id)),
                            // Two lines, because the thing worth reading
                            // here is a failure message, and one line
                            // middle-truncates it exactly when it
                            // matters.
                            subtitleLineLimit: 2,
                            last: index == flow.vendors.count - 1
                        ) {
                            SettingsIconTile(
                                symbol: Self.symbol(for: vendor.flow.state.status),
                                bg: DeviceBackupSettingsFlow.needsEnrolment(for: vendor.flow.state.status)
                                    ? SettingsTile.gray
                                    : SettingsTile.green)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("backup.operator_row.\(vendor.id)")
                }
            }
            SettingsFootnote(
                "Every operator you set up keeps its own separate copy, sealed with its own key and paid for separately. One of them shutting down or losing your data does not take the others with it — and each one extends the life of this history for everyone in it, under its own jurisdiction.")
        }
    }

    /// The operator's name, then what it is actually doing. The name is
    /// runtime data, so it lives in the subtitle: `SettingsRow` takes a
    /// localization key for its title, and looking up user-facing data
    /// as one would be a bug waiting for a translator.
    private static func subtitle(
        for vendor: DeviceBackupVendorsFlow.Vendor,
        run: BackupFanOut.Outcome?
    ) -> String {
        var line = vendor.displayName + " · " + describe(vendor.flow.state.status)
        if case .failed(let message) = run?.result {
            line += " · last run: " + message
        } else if run?.resumedPayment == true {
            // It backed up, and not the same thing everyone else got.
            line += " · the backup you paid for went up; the newest changes go next time"
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
                : "Your history stays on this phone until you set an operator up"
        case .on(let operators, let lastSuccessAt):
            let when = lastSuccessAt.map {
                "last backup \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? "no backup has completed yet"
            return operators == 1 ? "1 operator · \(when)" : "\(operators) operators · \(when)"
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
