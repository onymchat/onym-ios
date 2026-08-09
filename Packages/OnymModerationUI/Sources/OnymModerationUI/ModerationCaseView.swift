import SwiftUI
import OnymDesign
import OnymModeration

/// The accused-side case screen: authenticated status (or the labeled
/// offline snapshot), the event log, the response composer while the
/// case is open, and the appeal / new-holder filings for a ban. Every
/// filing surfaces the Authority's actual answer — copy never promises
/// reversal or suspension the returned terms don't state.
public struct ModerationCaseView: View {
    @State private var flow: ModerationCaseFlow
    @State private var responseText = ""
    @State private var appealText = ""
    @State private var newHolderText = ""
    /// Scrolls to the new-holder section on first appearance — the ban
    /// screen's "I'm this device's new owner" must land the user on
    /// the affordance they tapped, not on the status card.
    private let focusNewHolder: Bool

    public init(flow: ModerationCaseFlow, focusNewHolder: Bool = false) {
        _flow = State(initialValue: flow)
        self.focusNewHolder = focusNewHolder
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsLargeTitle("Moderation case")

                    statusSection
                    if let events = flow.state.status?.events, !events.isEmpty {
                        eventsSection(events)
                    }
                    if flow.canRespond {
                        responseSection
                    }
                    if flow.showsAppealSection {
                        appealSection
                    }
                    if flow.banContext {
                        newHolderSection
                            .id("newHolder")
                    }
                }
                .padding(.bottom, 32)
            }
            .onAppear {
                if focusNewHolder { proxy.scrollTo("newHolder", anchor: .top) }
            }
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Case")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("moderation.case")
        .task { await flow.start() }
        .refreshable { await flow.refresh() }
    }

    // MARK: - Status

    private var statusSection: some View {
        Group {
            SettingsSectionLabel("STATUS")
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    if let status = flow.state.status {
                        row("Case", status.caseId, monospaced: true)
                        row("Stage", stageLine(status))
                        if let classId = status.classId {
                            row("Violation class", classId)
                        }
                        if let opened = status.openedAt {
                            row("Opened", opened.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let deadline = status.responseDeadline {
                            row("Respond by", deadline.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let deadline = status.decisionDeadline {
                            row("Decision due", deadline.formatted(date: .abbreviated, time: .shortened))
                        }
                        row("Response on file", responsesLine(status))
                        if let appealState = status.appealState, appealState != "none" {
                            row("Appeal", appealState)
                        }
                        if let deadline = status.appealDeadline {
                            row("Appeal deadline", deadline.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let newHolderState = status.newHolderState, newHolderState != "none" {
                            row("New-holder claim", newHolderState)
                        }
                    } else if flow.state.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Fetching the case from your authority…")
                                .font(.system(size: 13))
                                .foregroundStyle(OnymTokens.text2)
                        }
                    } else {
                        Text("No case status is available yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(OnymTokens.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            if let fetchedAt = flow.state.snapshotFetchedAt {
                SettingsFootnote("Shown as of \(fetchedAt.formatted(date: .abbreviated, time: .shortened)) — the authority couldn't be reached for a newer status.")
            }
            if let message = flow.state.statusErrorMessage {
                errorText(message, id: "moderation.case.status_error")
            }
            if flow.state.status == nil, !flow.state.isLoading {
                retryButton
            }
        }
    }

    private var retryButton: some View {
        Button {
            Task { await flow.refresh() }
        } label: {
            Text("Try again")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OnymTokens.text)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(OnymTokens.surface2,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .accessibilityIdentifier("moderation.case.retry")
    }

    // MARK: - Events

    private func eventsSection(_ events: [CaseEvent]) -> some View {
        Group {
            SettingsSectionLabel("HISTORY")
            SettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(event.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(OnymTokens.text3)
                            Text(eventLabel(event.kind))
                                .font(.system(size: 13))
                                .foregroundStyle(OnymTokens.text2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    // MARK: - Response

    private var responseSection: some View {
        Group {
            SettingsSectionLabel("YOUR RESPONSE")
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    if let receipt = flow.state.responseReceipt {
                        Label(
                            receipt.late
                                ? "Your response is on file. It arrived after the response deadline and is marked late."
                                : "Your response is on file.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.text)
                        .accessibilityIdentifier("moderation.case.response_receipt")
                        Text("You can file additional statements while the case is open; they attach to the same case.")
                            .font(.system(size: 12))
                            .foregroundStyle(OnymTokens.text3)
                    }
                    TextEditor(text: $responseText)
                        .frame(minHeight: 100)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(OnymTokens.surface,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityIdentifier("moderation.case.response_editor")
                    if let passed = flow.responseDeadlinePassed {
                        Text("The response deadline (\(passed.formatted(date: .abbreviated, time: .shortened))) has passed by this device's clock. A filing is still accepted — it will be marked late.")
                            .font(.system(size: 12))
                            .foregroundStyle(OnymTokens.text3)
                    }
                    if let message = flow.state.responseErrorMessage {
                        inlineError(message, id: "moderation.case.response_error")
                    }
                    SettingsPrimaryButton(action: {
                        let statement = responseText
                        Task {
                            await flow.submitResponse(statement)
                            if flow.state.responseErrorMessage == nil { responseText = "" }
                        }
                    }) {
                        HStack {
                            if flow.state.isSubmittingResponse { ProgressView().tint(.white) }
                            Text(flow.state.isSubmittingResponse ? "Filing…" : "File response")
                        }
                    }
                    .disabled(trimmed(responseText).isEmpty || flow.state.isSubmittingResponse)
                    .accessibilityIdentifier("moderation.case.submit_response")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            SettingsFootnote("Your statement is signed with your identity key and disclosed to your authority in full. Not responding doesn't concede the case; it proceeds on the record.")
        }
    }

    // MARK: - Appeal

    private var appealSection: some View {
        Group {
            SettingsSectionLabel("APPEAL")
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    if flow.state.appealReceipt != nil {
                        Label("Your appeal is filed. The authority reviews it; a successful appeal issues a reversal.", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(OnymTokens.text)
                            .accessibilityIdentifier("moderation.case.appeal_receipt")
                    }
                    TextEditor(text: $appealText)
                        .frame(minHeight: 80)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(OnymTokens.surface,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityIdentifier("moderation.case.appeal_editor")
                    if let passed = flow.appealDeadlinePassed {
                        Text("The appeal window closed \(passed.formatted(date: .abbreviated, time: .shortened)) by this device's clock. The authority decides whether a filing is still accepted.")
                            .font(.system(size: 12))
                            .foregroundStyle(OnymTokens.text3)
                    }
                    if let message = flow.state.appealErrorMessage {
                        inlineError(message, id: "moderation.case.appeal_error")
                    }
                    SettingsPrimaryButton(action: {
                        let statement = appealText
                        Task {
                            await flow.submitAppeal(kind: .appeal, statement: statement)
                            if flow.state.appealErrorMessage == nil { appealText = "" }
                        }
                    }) {
                        HStack {
                            if flow.state.isSubmittingAppeal { ProgressView().tint(.white) }
                            Text(flow.state.isSubmittingAppeal ? "Filing…" : "File appeal")
                        }
                    }
                    .disabled(trimmed(appealText).isEmpty || flow.state.isSubmittingAppeal)
                    .accessibilityIdentifier("moderation.case.submit_appeal")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            SettingsFootnote("Filing an appeal does not suspend the ban unless the consented terms say so.")
        }
    }

    // MARK: - New holder

    private var newHolderSection: some View {
        Group {
            SettingsSectionLabel("DEVICE CHANGED HANDS?")
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("If you acquired this device after the ban, you can file a new-holder claim. A human reviews it on an expedited basis — a device is not a person.")
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.text2)
                    if flow.state.newHolderReceipt != nil {
                        Label("Your claim is submitted for expedited human review.", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(OnymTokens.text)
                            .accessibilityIdentifier("moderation.case.new_holder_receipt")
                    } else {
                        TextEditor(text: $newHolderText)
                            .frame(minHeight: 60)
                            .font(.system(size: 14))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(OnymTokens.surface,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityIdentifier("moderation.case.new_holder_editor")
                        if let message = flow.state.newHolderErrorMessage {
                            inlineError(message, id: "moderation.case.new_holder_error")
                        }
                        Button {
                            let statement = newHolderText
                            Task {
                                await flow.submitAppeal(kind: .newHolderClaim, statement: statement)
                                if flow.state.newHolderErrorMessage == nil { newHolderText = "" }
                            }
                        } label: {
                            Text("File new-holder claim")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(OnymTokens.text)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(OnymTokens.surface2,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(trimmed(newHolderText).isEmpty || flow.state.isSubmittingAppeal)
                        .accessibilityIdentifier("moderation.case.submit_new_holder")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    // MARK: - Helpers

    private func stageLine(_ status: CaseStatus) -> String {
        switch (status.stage, status.disposition) {
        case ("open", _):
            return String(localized: "Open — awaiting decision")
        case ("decided", "dismiss"):
            return String(localized: "Decided — dismissed")
        case ("decided", "ban"):
            return String(localized: "Decided — ban")
        case ("decided", "reversed"):
            return String(localized: "Decided — reversed on appeal")
        default:
            return status.stage
        }
    }

    private func responsesLine(_ status: CaseStatus) -> String {
        if let count = status.responsesOnFile, count > 0 {
            return String(localized: "Yes (\(count) filed)")
        }
        return status.responded == true ? String(localized: "Yes") : String(localized: "No")
    }

    /// Event kinds are the reference's identifiers; translate the
    /// known vocabulary and show unknown kinds verbatim rather than
    /// inventing meaning for them.
    private func eventLabel(_ kind: String) -> String {
        switch kind {
        case "case_opened": return String(localized: "Case opened")
        case "notice_evidence": return String(localized: "Evidence noticed")
        case "report_joined": return String(localized: "Another report joined")
        case "response": return String(localized: "Response filed")
        case "response_late": return String(localized: "Response filed (late)")
        case "appeal_filed": return String(localized: "Appeal filed")
        case "new_holder_claim": return String(localized: "New-holder claim filed")
        case "decided": return String(localized: "Decided")
        case "decision_overdue": return String(localized: "Decision overdue")
        case "appeal_reversed": return String(localized: "Reversed on appeal")
        default: return kind
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inlineError(_ message: String, id: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(OnymTokens.red)
            .accessibilityIdentifier(id)
    }

    private func errorText(_ message: String, id: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(OnymTokens.red)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityIdentifier(id)
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
