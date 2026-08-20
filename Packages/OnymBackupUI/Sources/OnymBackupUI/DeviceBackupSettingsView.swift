import OnymBackup
import OnymDesign
import SwiftUI

/// Settings → Device Backup.
public struct DeviceBackupSettingsView: View {
    @State private var flow: DeviceBackupSettingsFlow
    private let makeEnrolment: () -> BackupEnrolmentView?

    /// Whether restore is available at all, and separately how to build
    /// it. Split because the row's *presence* is evaluated on every body
    /// pass while the screen itself is needed only when someone taps
    /// through — asking the factory each time built a whole flow, and a
    /// repository with it, to answer a yes/no question.
    private let canRestore: Bool
    private let makeRestore: () -> BackupRestoreView

    public init(
        flow: DeviceBackupSettingsFlow,
        canRestore: Bool = false,
        makeEnrolment: @escaping () -> BackupEnrolmentView?,
        makeRestore: @escaping () -> BackupRestoreView
    ) {
        _flow = State(wrappedValue: flow)
        self.makeEnrolment = makeEnrolment
        self.canRestore = canRestore
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

                if flow.needsEnrolment {
                    if let enrolment = makeEnrolment() {
                        SettingsCard {
                            NavigationLink { enrolment } label: {
                                SettingsRow(
                                    title: enrolmentRowTitle,
                                    subtitle: "Read what it does before turning it on",
                                    last: true
                                ) {
                                    SettingsIconTile(symbol: "externaldrive.badge.plus",
                                                     bg: SettingsTile.green)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("backup.setup_row")
                        }
                    }
                }
                if !flow.needsEnrolment {
                    SettingsCard {
                        Button {
                            Task { await flow.backUpNow() }
                        } label: {
                            SettingsRow(
                                title: "Back Up Now",
                                subtitle: "Uploads your whole history",
                                last: true
                            ) {
                                SettingsIconTile(symbol: "arrow.up.circle", bg: SettingsTile.blue)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(flow.state.status == .running)
                        .accessibilityIdentifier("backup.back_up_now_row")
                    }
                    SettingsFootnote(
                        "Each backup uploads everything, not just what changed — there is no incremental upload yet.")

                    restoreSection
                    snapshotsSection
                }
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

    /// The same screen either way, but not the same sentence: someone
    /// who has backed up before is being asked to re-read terms, not
    /// to discover the feature.
    private var enrolmentRowTitle: LocalizedStringKey {
        switch flow.state.status {
        case .termsChanged: "Review New Terms"
        case .operatorChanged: "Set Up With New Operator"
        default: "Set Up Backup"
        }
    }

    /// Restore is offered whenever backup is set up, not only on a
    /// fresh device.
    ///
    /// It adds history rather than replacing it, and it does not touch
    /// the identity — the wiping kind of restore is identity restore,
    /// which lives in onboarding and is not reachable from here. Someone
    /// who lost a chat, or who set up a second device, has the same
    /// reason to want this as someone with a new phone.
    @ViewBuilder
    private var restoreSection: some View {
        if canRestore {
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
    }

    private var snapshotsSection: some View {
        Group {
            SettingsSectionLabel("SNAPSHOTS")
            SettingsCard {
                if flow.state.snapshots.isEmpty {
                    SettingsRow(
                        title: "None yet",
                        subtitle: "Nothing has been accepted by the operator",
                        last: true
                    ) {
                        SettingsIconTile(symbol: "tray", bg: SettingsTile.gray)
                    }
                } else {
                    ForEach(Array(flow.state.snapshots.enumerated()), id: \.element.snapshotReference) {
                        index, snapshot in
                        // The digest lives in the subtitle rather than
                        // the title: `SettingsRow` takes a localization
                        // key for its title, and runtime data must never
                        // be looked up as one.
                        SettingsRow(
                            title: "Snapshot",
                            subtitle: Self.subtitle(for: snapshot),
                            last: index == flow.state.snapshots.count - 1
                        ) {
                            SettingsIconTile(symbol: "shippingbox", bg: SettingsTile.gray)
                        }
                        .accessibilityIdentifier("backup.snapshot.\(snapshot.snapshotReference.digestHex)")
                    }
                }
            }
            SettingsFootnote(
                "Sizes are rounded into buckets before upload, so what the operator sees does not measure your history.")
        }
    }

    /// `retained` is the only word here that means the operator has the
    /// bytes. Anything else is reported as what it is.
    private static func subtitle(for snapshot: RetainedSnapshot) -> String {
        let date = snapshot.retainedAt.formatted(date: .abbreviated, time: .shortened)
        let digest = snapshot.snapshotReference.shortDigest
        switch snapshot.status {
        case .retained, .alreadyRetained: return "\(digest) · held since \(date)"
        case .erased: return "\(digest) · erased"
        case .unknown, .unreachable: return "\(digest) · result unknown, checking"
        default: return "\(digest) · \(snapshot.status.rawValue)"
        }
    }

    private var statusTitle: LocalizedStringKey {
        switch flow.state.status {
        case .off: "Off"
        case .idle: "On"
        case .running: "Backing up…"
        case .stale: "Out of date"
        case .paymentRequired: "Payment needed"
        case .termsChanged: "Terms changed"
        case .operatorChanged: "Backup operator changed"
        case .checkingEarlierBackup: "Checking an earlier backup"
        case .failed: "Something went wrong"
        }
    }

    private var statusSubtitle: String {
        switch flow.state.status {
        case .off:
            "Your history stays on this phone only"
        case .idle(let last), .stale(let last):
            last.map { "Last backup \($0.formatted(date: .abbreviated, time: .shortened))" }
                ?? "No backup has completed yet"
        case .running:
            "Uploading"
        case .paymentRequired:
            "The operator needs a subscription before it will keep a backup"
        case .termsChanged:
            "Read the new terms to continue backing up"
        case .operatorChanged:
            "Set up backup again with the operator you chose"
        case .checkingEarlierBackup:
            "An earlier backup has not been confirmed yet"
        case .failed(let message):
            message
        }
    }

    private var statusFootnote: String {
        switch flow.state.status {
        case .stale:
            "Backups only run while the app is open. If you have not opened Onym in a while, nothing has been backed up."
        case .checkingEarlierBackup:
            "Nothing new is uploaded until the earlier one is resolved, so you are not charged to store the same history twice."
        default:
            "Only your recovery phrase can open a backup. The operator stores bytes it cannot read."
        }
    }

    private var statusSymbol: String {
        switch flow.state.status {
        case .off: "externaldrive"
        case .idle: "externaldrive.badge.checkmark"
        case .running: "arrow.triangle.2.circlepath"
        case .stale: "exclamationmark.triangle"
        case .paymentRequired: "creditcard"
        case .termsChanged: "doc.badge.ellipsis"
        case .operatorChanged: "arrow.triangle.swap"
        case .checkingEarlierBackup: "questionmark.circle"
        case .failed: "xmark.octagon"
        }
    }
}
