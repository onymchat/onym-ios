import OnymBackup
import OnymDesign
import SwiftUI

/// Settings → Device Backup → Restore.
public struct BackupRestoreView: View {
    @State private var flow: BackupRestoreFlow
    @State private var confirming: RetainedSnapshot?

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

                case .failed(let message):
                    failed(message)
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
                if let snapshot = confirming {
                    confirming = nil
                    Task { await flow.restore(snapshot) }
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
    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.largeTitle)
            Text("No backups here")
                .font(.headline)
            Text("This operator holds nothing for this identity. If you backed up with a different operator, or under a different identity, choose that one instead.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .accessibilityIdentifier("backup.restore.empty")
    }

    private func list(_ snapshots: [RetainedSnapshot]) -> some View {
        Group {
            SettingsSectionLabel("BACKUPS")
            SettingsCard {
                ForEach(Array(snapshots.enumerated()), id: \.element.snapshotReference) {
                    index, snapshot in
                    Button {
                        confirming = snapshot
                    } label: {
                        SettingsRow(
                            title: index == 0 ? "Most recent" : "Earlier backup",
                            subtitle: Self.subtitle(for: snapshot),
                            last: index == snapshots.count - 1
                        ) {
                            SettingsIconTile(symbol: "shippingbox", bg: SettingsTile.blue)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "backup.restore.snapshot.\(snapshot.snapshotReference.digestHex)")
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

    private func failed(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text("Restore did not complete")
                .font(.headline)
            Text("Nothing on this phone was changed.")
                .font(.callout)
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

    static func subtitle(for snapshot: RetainedSnapshot) -> String {
        let date = snapshot.retainedAt.formatted(date: .abbreviated, time: .shortened)
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(snapshot.snapshotReference.sealedByteSize), countStyle: .file)
        return "\(date) · about \(size)"
    }
}
