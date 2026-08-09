import SwiftUI
import OnymDesign
import OnymModeration

public struct ModerationReportView: View {
    @State private var flow: ModerationReportFlow
    @Environment(\.dismiss) private var dismiss

    public init(flow: ModerationReportFlow) {
        _flow = State(initialValue: flow)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let receipt = flow.state.receipt {
                        success(receipt)
                    } else if flow.state.alreadyFiled {
                        alreadyFiled
                    } else {
                        reportForm
                    }
                }
                .padding(20)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle(isTerminal ? "Report filed" : "Report message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isTerminal ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        .task { await flow.start() }
    }

    /// Both terminal outcomes: accepted with a receipt, or confirmed
    /// already on file (409, no receipt to show).
    private var isTerminal: Bool {
        flow.state.receipt != nil || flow.state.alreadyFiled
    }

    private var alreadyFiled: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Your authority already has this report on file.")
                .font(.title3.weight(.semibold))
            Text("Nothing further is needed. The reported user receives notice through their interface and can respond before a decision.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("moderation.report.alreadyFiled")
    }

    private var reportForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MESSAGE TO DISCLOSE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(flow.message.displayBody)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("WHAT DOES IT VIOLATE?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                // All classes visible at once, none preselected: the
                // class IS the report, so the reporter should compare
                // the options and choose — not discover them one menu
                // tap at a time, or inherit a default.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(flow.state.classes.enumerated()),
                        id: \.element.classId
                    ) { index, item in
                        classRow(item)
                        if index < flow.state.classes.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("moderation.report.class")
            }

            Label(
                "Submitting discloses this exact message — its text, identifiers, and timestamp — and its sender proof to your moderation authority. No surrounding conversation is included.",
                systemImage: "lock.shield"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let error = flow.state.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("moderation.report.error")
            }

            Button {
                Task { await flow.submit() }
            } label: {
                HStack {
                    if flow.state.isSubmitting { ProgressView() }
                    Text(flow.state.isSubmitting ? "Submitting…" : "Submit report")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                flow.state.selectedClassId == nil
                    || flow.state.isSubmitting
                    || flow.state.isLoading
            )
            .accessibilityIdentifier("moderation.report.submit")
        }
    }

    /// One selectable class. The name shown is the consented
    /// `classId` with typography only — hyphens to spaces, known
    /// acronyms uppercased — never a renaming: the id is the exact
    /// vocabulary the mandate consented to. The selected row expands
    /// with what choosing it means: the consented definition, and the
    /// statutory-reporting notice for classes that declare one.
    private func classRow(_ item: ViolationClass) -> some View {
        let isSelected = item.classId == flow.state.selectedClassId
        // The expanded details live BELOW the Button, not inside its
        // label: SwiftUI renders controls nested in a button label
        // inert, so a `Link` in there would never receive the tap —
        // the row would swallow it as a re-select.
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                flow.selectClass(item.classId)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .padding(.top, 1)
                    Text(Self.displayName(for: item.classId))
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(flow.state.isSubmitting)
            .accessibilityIdentifier("moderation.report.class.\(item.classId)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected {
                VStack(alignment: .leading, spacing: 6) {
                    definitionLine(for: item)
                    if item.lawfulReporting != nil {
                        Label(
                            "The authority files legally required reports for this class.",
                            systemImage: "building.columns"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("moderation.report.lawful")
                    }
                }
                .padding(.leading, 48)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
    }

    /// The consented definition of the class. `definition` is a
    /// content address (hash-or-url, AuthorityManifest): a URL opens
    /// the consented prohibited-content definition; a bare hash can
    /// only be shown as the address the user consented to.
    @ViewBuilder
    private func definitionLine(for item: ViolationClass) -> some View {
        if let url = URL(string: item.definition),
           url.scheme == "https" || url.scheme == "http" {
            Link(destination: url) {
                Label("What counts as this?", systemImage: "arrow.up.right.square")
                    .font(.footnote)
            }
            .accessibilityIdentifier("moderation.report.definition")
        } else {
            Text("Definition pinned to content address \(item.definition)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("moderation.report.definition")
        }
    }

    /// Typography-only rendering of a consented class id: hyphens
    /// become spaces, the leading word is capitalized, and short ids
    /// known to be acronyms are uppercased. No translation, no
    /// paraphrase — the words stay the manifest's words.
    static func displayName(for classId: String) -> String {
        let acronyms: Set<Substring> = ["csam", "ncii"]
        let words = classId.split(separator: "-")
        return words.enumerated().map { index, word in
            if acronyms.contains(word) {
                return word.uppercased()
            }
            return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : String(word)
        }.joined(separator: " ")
    }

    private func success(_ receipt: ReportReceipt) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Your authority accepted the report.")
                .font(.title3.weight(.semibold))
            LabeledContent("Case", value: receipt.caseId)
            LabeledContent("Report", value: receipt.reportId)
            Text("The reported user will receive notice through their interface and can respond before a decision.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("moderation.report.success")
    }
}
