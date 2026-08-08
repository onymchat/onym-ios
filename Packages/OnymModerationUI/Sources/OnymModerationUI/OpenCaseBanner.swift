import SwiftUI
import OnymDesign
import OnymModeration

/// Non-blocking banner shown while a case is open against this
/// device. The case-open mark is procedural state: the spec forbids
/// degrading service on it beyond displaying the case's existence
/// (Moderation.md §5.5), so this overlays the normal UI and taps
/// through to the notice detail.
public struct OpenCaseBanner: View {
    let notices: [CaseNotice]
    @State private var presented: CaseNotice?

    public init(notices: [CaseNotice]) {
        self.notices = notices
    }

    public var body: some View {
        if let first = notices.first {
            Button { presented = first } label: {
                HStack(spacing: 10) {
                    Circle().fill(SettingsTile.amber).frame(width: 22, height: 22)
                        .overlay(Image(systemName: "exclamationmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white))
                    Text(notices.count == 1
                         ? "A moderation case is open against this device."
                         : "\(notices.count) moderation cases are open against this device.")
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.text)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OnymTokens.text2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(OnymTokens.surface2,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(OnymTokens.hairlineStrong, lineWidth: 0.5))
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("moderation.case_banner")
            .sheet(item: $presented) { notice in
                NavigationStack {
                    CaseNoticeDetailView(notice: notice)
                }
            }
        }
    }
}

extension CaseNotice: @retroactive Identifiable {
    public var id: String { caseId }
}

/// The served notice, presented faithfully: class, deadlines,
/// evidence reference, and the response path (stubbed — the client
/// operation throws `.notImplemented` until an authority service
/// exists; the screen says so instead of pretending).
public struct CaseNoticeDetailView: View {
    let notice: CaseNotice

    public init(notice: CaseNotice) {
        self.notice = notice
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Moderation case")

                SettingsSectionLabel("NOTICE")
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Case", notice.caseId, monospaced: true)
                        row("Authority", notice.authority)
                        row("Violation class", notice.classId)
                        row("Evidence", notice.evidenceSummary, monospaced: true)
                        row("Respond by", notice.responseDeadline.formatted(date: .abbreviated, time: .shortened))
                        row("Decision due", notice.decisionDeadline.formatted(date: .abbreviated, time: .shortened))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                SettingsFootnote("If the authority doesn't decide by the deadline, the case is dismissed automatically — silence never bans anyone. Not responding doesn't concede the case; it proceeds on the record.")

                SettingsSectionLabel("RESPONSE")
                SettingsCard {
                    Text("Responding from the app isn't available yet. Use the authority's contact channel to respond before the deadline.")
                        .font(.system(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Case")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("moderation.case_detail")
    }

    private func row(_ label: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .textSelection(.enabled)
        }
    }
}
