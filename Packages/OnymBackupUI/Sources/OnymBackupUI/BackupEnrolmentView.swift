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
    private let flow: BackupEnrolmentFlow
    private let onEnrolled: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var scrolledToEnd = false

    public init(flow: BackupEnrolmentFlow, onEnrolled: @escaping () -> Void = {}) {
        self.flow = flow
        self.onEnrolled = onEnrolled
    }

    public var body: some View {
        Group {
            switch flow.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let message):
                unavailable(message)
            case .ready(let disclosure):
                disclosureBody(disclosure)
            case .enrolled:
                // Nothing is uploaded by enrolling. The screen closes
                // and the settings surface takes over.
                Color.clear.onAppear {
                    onEnrolled()
                    dismiss()
                }
            }
        }
        .navigationTitle("Device Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await flow.load() }
    }

    /// Terms are a precondition for enrolment, so a failure to fetch or
    /// verify them ends here rather than offering to continue without.
    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("The operator's terms could not be verified")
                .font(.headline)
            Text(verbatim: message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Backup cannot be turned on without them.")
                .font(.callout)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("backup.enrolment.unavailable")
    }

    private func disclosureBody(_ disclosure: BackupDisclosure) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Backing up to")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(verbatim: disclosure.operatorName)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("backup.enrolment.operator")

                if let additionalCopies = disclosure.additionalCopies {
                    // Above the rest, because it changes what the whole
                    // screen is: not "choose an operator" but "add one".
                    headline(
                        "This adds a second copy — it does not move the first",
                        additionalCopies,
                        symbol: "square.on.square",
                        identifier: "backup.enrolment.additional_copies")
                }

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

            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        // Scroll geometry, not an `onAppear` sentinel.
        //
        // The first version put a `Color.clear` marker at the bottom of
        // a plain `VStack` and set the flag in its `onAppear` — which
        // fires at initial layout for offscreen children too, so the
        // gate opened immediately and the button was enabled without
        // anyone reading anything. The claim that "the button is not the
        // consent, the reading is" was false in the exact way §18.10
        // warns about: it still compiled, still rendered, and still
        // looked like a consent screen.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            Self.hasReachedEnd(
                contentOffsetY: geometry.contentOffset.y,
                containerHeight: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height)
        } action: { _, reachedEnd in
            if reachedEnd { scrolledToEnd = true }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button { flow.accept() } label: {
                    Text("Turn On Backup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!scrolledToEnd)
                .accessibilityIdentifier("backup.enrolment.accept")

                Button("Not Now") { dismiss() }
                    .accessibilityIdentifier("backup.enrolment.cancel")
            }
            .padding(16)
            .background(.bar)
        }
    }

    /// Whether the disclosure has been scrolled to its end.
    ///
    /// Pure, so it can be tested — including the case that matters most
    /// and is easiest to get wrong: content shorter than the container
    /// has *already* been read in full, and gating on a scroll that can
    /// never happen would lock the button forever.
    static func hasReachedEnd(
        contentOffsetY: CGFloat,
        containerHeight: CGFloat,
        contentHeight: CGFloat,
        tolerance: CGFloat = 24
    ) -> Bool {
        guard contentHeight > containerHeight else { return true }
        return contentOffsetY + containerHeight >= contentHeight - tolerance
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
