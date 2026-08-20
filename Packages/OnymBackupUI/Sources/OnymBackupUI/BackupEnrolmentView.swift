import OnymBackup
import OnymDesign
import SwiftUI

/// The screen a person reads before their history leaves this device.
///
/// Deliberately not a paragraph of terms with a checkbox. Three things
/// come first, in this order, because they are the three someone would
/// otherwise find out too late:
///
/// 1. what a backup does to everyone else in their conversations;
/// 2. that nobody — including us — can recover it without the phrase;
/// 3. when backups actually happen, which is not "automatically".
///
/// The operator's declared terms follow in full, unsummarised. An
/// operator that keeps access logs or excludes a great deal from
/// erasure has published that, and this screen repeats it.
public struct BackupEnrolmentView: View {
    private let disclosure: BackupDisclosure
    private let onAccept: () -> Void
    private let onCancel: () -> Void

    @State private var scrolledToEnd = false

    public init(
        disclosure: BackupDisclosure,
        onAccept: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.disclosure = disclosure
        self.onAccept = onAccept
        self.onCancel = onCancel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headline(
                    "This copies other people's messages too",
                    disclosure.thirdPartyConsequence,
                    symbol: "person.2.slash",
                    identifier: "backup.enrolment.third_party")

                headline(
                    "Nobody can recover this for you",
                    disclosure.noResetPath,
                    symbol: "key.slash",
                    identifier: "backup.enrolment.no_reset")

                headline(
                    "When backups happen",
                    disclosure.whenBackupsHappen,
                    symbol: "clock.arrow.circlepath",
                    identifier: "backup.enrolment.schedule")

                SettingsSectionLabel("WHAT THE OPERATOR PROMISES")
                SettingsCard {
                    ForEach(Array(disclosure.items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            // `verbatim` throughout: these are the
                            // operator's own published strings, and a
                            // value that happened to match a
                            // localization key would render the
                            // translation instead of what was signed.
                            Text(verbatim: item.label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(verbatim: item.value)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .accessibilityIdentifier("backup.terms.\(item.id)")

                        if index < disclosure.items.count - 1 {
                            SettingsRowDivider()
                        }
                    }
                }

                SettingsFootnote(
                    "These terms are pinned to every backup you make under them. If the operator publishes different terms later, backups stop until you have seen them.")

                // Marks the end of the disclosure. Enabling the accept
                // button only once this has been reached is the cheapest
                // honest way to keep "read the terms" from being a
                // formality — the button is not the consent, the reading
                // is.
                Color.clear
                    .frame(height: 1)
                    .onAppear { scrolledToEnd = true }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: onAccept) {
                    Text("Turn On Backup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!scrolledToEnd)
                .accessibilityIdentifier("backup.enrolment.accept")

                Button("Not Now", action: onCancel)
                    .accessibilityIdentifier("backup.enrolment.cancel")
            }
            .padding(16)
            .background(.bar)
        }
        .navigationTitle("Device Backup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func headline(
        _ title: String,
        _ body: String,
        symbol: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(verbatim: body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }
}
