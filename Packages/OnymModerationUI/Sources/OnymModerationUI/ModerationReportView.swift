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
                    } else {
                        reportForm
                    }
                }
                .padding(20)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle(flow.state.receipt == nil ? "Report message" : "Report filed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(flow.state.receipt == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
        .task { await flow.start() }
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
                Text("VIOLATION CLASS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(
                    "Violation class",
                    selection: Binding(
                        get: { flow.state.selectedClassId ?? "" },
                        set: { flow.selectClass($0) }
                    )
                ) {
                    ForEach(flow.state.classes, id: \.classId) { item in
                        Text(item.classId).tag(item.classId)
                    }
                }
                .pickerStyle(.menu)
                .disabled(flow.state.classes.isEmpty || flow.state.isSubmitting)
                .accessibilityIdentifier("moderation.report.class")

                // The consented definition of the selected class — the
                // reporter must see what they are alleging, not just a
                // raw class id.
                if let selected = flow.state.classes.first(where: {
                    $0.classId == flow.state.selectedClassId
                }) {
                    Text("Definition: \(selected.definition)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("moderation.report.definition")
                }
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
