import SwiftUI
import OnymDesign
import OnymModeration

/// Settings → Moderation. Shows the consented authority and its
/// pinned terms, any open cases, the mandate history, and the
/// "Switch authority" path (a fresh consent — the old mandate stays
/// exactly as signed).
public struct ModerationSettingsView: View {
    @State private var flow: ModerationSettingsFlow
    private let makeConsentFlow: @MainActor (ModerationConsentFlow.Mode) -> ModerationConsentFlow
    private let makeCaseFlow: (@MainActor (CaseNotice) -> ModerationCaseFlow)?

    @State private var showSwitchConsent = false

    public init(
        flow: ModerationSettingsFlow,
        makeConsentFlow: @escaping @MainActor (ModerationConsentFlow.Mode) -> ModerationConsentFlow,
        makeCaseFlow: (@MainActor (CaseNotice) -> ModerationCaseFlow)? = nil
    ) {
        _flow = State(initialValue: flow)
        self.makeConsentFlow = makeConsentFlow
        self.makeCaseFlow = makeCaseFlow
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Moderation")

                if !flow.state.openCases.isEmpty {
                    OpenCaseBanner(notices: flow.state.openCases, makeCaseFlow: makeCaseFlow)
                        .padding(.bottom, 8)
                }

                if let record = flow.activeMandate {
                    activeCard(record)
                } else {
                    noMandateCard
                }

                if !flow.pendingRegistrations.isEmpty {
                    SettingsSectionLabel("PENDING REGISTRATION")
                    SettingsCard {
                        ForEach(
                            Array(flow.pendingRegistrations.enumerated()),
                            id: \.element.historyRowID
                        ) { idx, record in
                            Button {
                                Task { await flow.retryRegistration(record) }
                            } label: {
                                SettingsRow(
                                    titleText: record.authorityName,
                                    subtitle: pendingRegistrationSubtitle(record),
                                    last: idx == flow.pendingRegistrations.count - 1
                                ) {
                                    SettingsIconTile(
                                        symbol: "clock.arrow.circlepath",
                                        bg: SettingsTile.indigo
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(flow.state.retryingRegistration != nil)
                            .accessibilityIdentifier("moderation.settings.retry-registration")
                        }
                    }
                    if let message = flow.state.registrationErrorMessage {
                        SettingsFootnote(verbatim: message)
                    } else {
                        SettingsFootnote(
                            "These signed mandates are not active. Tap one to retry delivery of the exact persisted artifact; no new consent is created."
                        )
                    }
                }

                if !flow.previousMandates.isEmpty {
                    SettingsSectionLabel("PREVIOUS MANDATES")
                    SettingsCard {
                        ForEach(Array(flow.previousMandates.enumerated()), id: \.element.historyRowID) { idx, record in
                            SettingsRow(
                                titleText: record.authorityName,
                                subtitle: "Consented \(record.mandate.acceptedAt.formatted(date: .abbreviated, time: .omitted)) · \(String(record.mandate.manifestHash.prefix(16)))…",
                                hasChevron: false,
                                last: idx == flow.previousMandates.count - 1
                            ) {
                                SettingsIconTile(symbol: "doc.text", bg: SettingsTile.gray)
                            }
                        }
                    }
                    SettingsFootnote("Old mandates stay bound to the exact terms they consented to. Switching authorities never rewrites them.")
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Moderation")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
        .onDisappear { flow.stop() }
        .sheet(isPresented: $showSwitchConsent) {
            ModerationConsentView(flow: makeConsentFlow(.switching))
        }
    }

    // MARK: - Cards

    private func activeCard(_ record: MandateRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionLabel("CURRENT AUTHORITY")
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    row("Authority", record.authorityName)
                    row("Component", record.mandate.authority, monospaced: true)
                    row("Consented", record.mandate.acceptedAt.formatted(date: .abbreviated, time: .shortened))
                    row("Manifest hash", record.mandate.manifestHash, monospaced: true)
                    if let manifest = record.consentedManifest() {
                        row("Terms valid until", manifest.manifest.validUntil.formatted(date: .abbreviated, time: .omitted))
                        row("Violation classes", manifest.manifest.violationClasses.map(\.classId).joined(separator: ", "))
                    }
                    if !record.countersigned {
                        row("Countersignature", String(localized: "Pending — no enforcement backend is deployed yet"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

                SettingsRowDivider()

                Button { showSwitchConsent = true } label: {
                    SettingsRow(
                        title: "Switch authority",
                        subtitle: "Signs a fresh mandate under the new authority's terms",
                        last: true
                    ) {
                        SettingsIconTile(symbol: "arrow.triangle.2.circlepath", bg: SettingsTile.indigo)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("moderation.settings.switch")
            }
            SettingsFootnote("Your consent is the authority's entire jurisdiction: it can only decide cases against you under the classes and terms you signed, and its verdicts must be reasoned, expiring, and appealable.")
        }
    }

    private var noMandateCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionLabel("CURRENT AUTHORITY")
            SettingsCard {
                Button { showSwitchConsent = true } label: {
                    SettingsRow(
                        title: "Choose a moderation authority",
                        subtitle: "No mandate signed on this device yet",
                        last: true
                    ) {
                        SettingsIconTile(symbol: "checkmark.shield", bg: SettingsTile.indigo)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("moderation.settings.choose")
            }
        }
    }

    private func pendingRegistrationSubtitle(_ record: MandateRecord) -> String {
        if flow.state.retryingRegistration == record.historyRowID {
            return String(localized: "Confirming with authority…")
        }
        return String(localized: "Not active · Tap to retry")
    }

    private func row(_ label: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .textSelection(.enabled)
        }
    }
}

private extension MandateRecord {
    /// Stable list identity for the read-only history. `acceptedAt`
    /// alone isn't enough: the repository stamps it from an injectable
    /// clock, so two records can share an instant (trivially so under
    /// a fixed test clock) and collide as `ForEach` ids.
    var historyRowID: String {
        "\(mandate.authority)|\(mandate.manifestHash)|\(mandate.acceptedAt.timeIntervalSince1970)"
    }
}
