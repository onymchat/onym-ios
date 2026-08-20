import OnymBackup
import OnymDesign
import SwiftUI

/// Settings → Device Backup → Restore.
public struct BackupRestoreView: View {
    @State private var flow: BackupRestoreFlow
    @State private var confirming: RestorableSnapshot?

    public init(flow: BackupRestoreFlow) {
        _flow = State(wrappedValue: flow)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsFootnote(
                    "Restoring adds this backup's messages and groups to what is already on this phone. Nothing is deleted, and your identity is not touched.")

                switch flow.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)

                case .ready(let snapshots):
                    if snapshots.isEmpty {
                        empty
                    } else {
                        list(snapshots)
                    }
                    // Outside both branches on purpose. It used to live
                    // inside `list`, so an outage that left the list
                    // empty rendered "no operator holds anything" with
                    // nothing to say that one of them never answered —
                    // telling someone their history is gone on the
                    // evidence of a network failure.
                    unreachableNote

                case .restoring(let reference):
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(verbatim: "Restoring \(reference.shortDigest)…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)

                case .restored(let summary):
                    restored(summary)

                case .failed(let message, let partial):
                    failed(message, partial: partial)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("Restore")
        .navigationBarTitleDisplayMode(.inline)
        .task { await flow.load() }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore") {
                if let row = confirming {
                    confirming = nil
                    Task { await flow.restore(row) }
                }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Messages and groups from this backup will be added to this phone.")
        }
    }

    /// An empty list is an ordinary answer, not an error — a different
    /// operator or a different identity has a different holder key and
    /// sees nothing. Saying so beats leaving someone to conclude their
    /// history is gone.
    ///
    /// Unless an operator did not answer, in which case the list is not
    /// an answer at all and must not be phrased as one.
    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: flow.unreachableOperators.isEmpty ? "tray" : "wifi.exclamationmark")
                .font(.largeTitle)
            Text(flow.unreachableOperators.isEmpty ? "No backups here" : "Nothing found yet")
                .font(.headline)
            Text(flow.unreachableOperators.isEmpty
                ? "No operator you have set up holds anything for this identity. If you backed up under a different identity, or with an operator this device has not been set up with, that is where it will be."
                : "The operators that answered hold nothing for this identity. That is not the whole picture — one of them could not be reached, and what it holds is unknown.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .accessibilityIdentifier("backup.restore.empty")
    }

    /// Named rather than swallowed: someone deciding whether their
    /// history is recoverable must not read one operator's silence as
    /// another's answer.
    @ViewBuilder
    private var unreachableNote: some View {
        if !flow.unreachableOperators.isEmpty {
            SettingsFootnote(
                verbatim: "Could not reach \(flow.unreachableOperators.joined(separator: ", ")). Anything held there is not in this list.")
                .accessibilityIdentifier("backup.restore.unreachable")
        }
    }

    private func list(_ snapshots: [RestorableSnapshot]) -> some View {
        Group {
            SettingsSectionLabel("BACKUPS")
            SettingsCard {
                ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, row in
                    Button {
                        confirming = row
                    } label: {
                        SettingsRow(
                            title: index == 0 ? "Most recent" : "Earlier backup",
                            subtitle: Self.subtitle(for: row),
                            last: index == snapshots.count - 1
                        ) {
                            SettingsIconTile(symbol: "shippingbox", bg: SettingsTile.blue)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "backup.restore.snapshot.\(row.snapshot.snapshotReference.digestHex)")
                }
            }
            SettingsFootnote(
                "Sizes are rounded into buckets, so they do not tell you how much history a backup holds.")
        }
    }

    private func restored(_ summary: BackupRestoreSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Restored", systemImage: "checkmark.circle")
                .font(.headline)
            Text(verbatim: Self.describe(summary))
                .font(.callout)

            if !summary.skipped.isEmpty {
                // Rows this build could not reconstruct. Reporting a
                // count it did not write would be the same overstatement
                // this seat refuses everywhere else.
                Text(verbatim: "Some entries could not be read by this version of Onym: "
                    + summary.skipped
                        .sorted { $0.key < $1.key }
                        .map { "\($0.value) \($0.key)" }
                        .joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !summary.unresolvedBlobs.isEmpty {
                // Media the snapshot pointed at and did not carry. Said
                // plainly rather than left to be discovered as blank
                // bubbles.
                Text(verbatim: "\(summary.unresolvedBlobs.count) attachments could not be restored — the backup did not include them, and your media provider no longer has them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
        .accessibilityIdentifier("backup.restore.summary")
    }

    private func failed(_ message: String, partial: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text("Restore did not complete")
                .font(.headline)
            // Only claimed when it is true. A failure during the write
            // phase leaves earlier rows in place, and telling someone
            // nothing changed would be the sort of comfortable lie this
            // seat refuses everywhere else.
            if !partial {
                Text("Nothing on this phone was changed.")
                    .font(.callout)
            }
            Text(verbatim: message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .accessibilityIdentifier("backup.restore.failed")
    }

    static func describe(_ summary: BackupRestoreSummary) -> String {
        var parts: [String] = []
        if summary.groups > 0 { parts.append("\(summary.groups) chats") }
        if summary.messages > 0 { parts.append("\(summary.messages) messages") }
        if summary.invitations > 0 { parts.append("\(summary.invitations) invitations") }
        if summary.blobs > 0 { parts.append("\(summary.blobs) attachments") }
        return parts.isEmpty ? "Nothing to add — it was all already here." : parts.joined(separator: ", ")
    }

    /// The operator's name leads, because with more than one set up it
    /// is the first thing that distinguishes two otherwise identical
    /// rows — and because restoring is choosing whose copy to trust.
    static func subtitle(for row: RestorableSnapshot) -> String {
        let date = row.snapshot.retainedAt.formatted(date: .abbreviated, time: .shortened)
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(row.snapshot.snapshotReference.sealedByteSize), countStyle: .file)
        return "\(row.operatorName) · \(date) · about \(size)"
    }
}
