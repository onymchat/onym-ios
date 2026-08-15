import SwiftUI
import OnymDesign
import OnymDiscovery

/// Add-provider sheet: type the manifest URL, fetch + verify it, then
/// confirm the operator key fingerprint (trust-on-first-use) before
/// anything is pinned. Nothing about the provider is persisted until
/// the Confirm step.
struct AddDiscoveryProviderView: View {
    @Bindable var flow: DiscoverySettingsFlow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch flow.addPhase {
                    case .idle, .fetching:
                        urlEntry
                    case .confirming(let preview):
                        confirm(preview)
                    case .added:
                        done
                    }
                }
                .padding(.bottom, 32)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle("Add Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(dismissLabel) { dismiss() }
                        .accessibilityIdentifier("settings.discovery.add.dismiss")
                }
            }
        }
    }

    private var dismissLabel: LocalizedStringKey {
        if case .added = flow.addPhase { return "Done" }
        return "Cancel"
    }

    // MARK: - Step 1: URL

    @ViewBuilder
    private var urlEntry: some View {
        SettingsLargeTitle("Add Discovery Provider")
        Text("Paste the provider's manifest URL. Its manifest and catalogs are signed — you'll review the operator key fingerprint before this app trusts anything it publishes.")
            .font(.system(size: 14))
            .foregroundStyle(OnymTokens.text2)
            .lineSpacing(3)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

        SettingsCard {
            TextField("https://discovery.example.com/manifest.json",
                      text: $flow.addDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(size: 15, design: .monospaced))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .accessibilityIdentifier("settings.discovery.add.field")
        }

        if let error = flow.addError {
            SettingsFootnote(verbatim: error)
        }

        SettingsPrimaryButton(action: { flow.tappedFetchProvider() }) {
            if case .fetching = flow.addPhase {
                ProgressView().tint(OnymTokens.onAccent)
            } else {
                Text("Fetch Provider")
            }
        }
        .disabled(isFetching)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .accessibilityIdentifier("settings.discovery.add.fetch")
    }

    private var isFetching: Bool {
        if case .fetching = flow.addPhase { return true }
        return false
    }

    // MARK: - Step 2: TOFU confirmation

    @ViewBuilder
    private func confirm(_ preview: DiscoveryProviderPreview) -> some View {
        SettingsLargeTitle("Confirm Operator Key")

        Text("This fingerprint identifies the provider's operator key. Verify it out-of-band — the provider's website, documentation, or the operator directly — before confirming. It's pinned on confirm: a later manifest signed by any other key will be rejected.")
            .font(.system(size: 14))
            .foregroundStyle(OnymTokens.text2)
            .lineSpacing(3)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

        SettingsSectionLabel("OPERATOR KEY FINGERPRINT")
        SettingsCard {
            Text(verbatim: preview.operatorKeyFingerprint)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundStyle(OnymTokens.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .accessibilityIdentifier("settings.discovery.add.fingerprint")
        }
        SettingsFootnote("First 16 characters of the operator's Ed25519 public key.")

        SettingsSectionLabel("PROVIDER")
        SettingsCard {
            summaryRow("Provider", preview.providerId)
            summaryRow("Manifest URL", preview.manifestURL.absoluteString)
            summaryRow(
                "Valid until",
                preview.signed.manifest.validUntil.formatted(date: .abbreviated, time: .omitted)
            )
            catalogsRow(preview, last: true)
        }

        VStack(spacing: 10) {
            SettingsPrimaryButton("Pin Key & Add Provider") {
                flow.tappedConfirmAdd()
            }
            .accessibilityIdentifier("settings.discovery.add.confirm")

            Button("Back") { flow.tappedCancelPreview() }
                .font(.system(size: 14))
                .foregroundStyle(OnymTokens.text2)
                .accessibilityIdentifier("settings.discovery.add.back")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func summaryRow(_ label: LocalizedStringKey, _ value: String, last: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text(verbatim: value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OnymTokens.text2)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if !last { SettingsRowDivider(inset: 16) }
        }
    }

    private func catalogsRow(_ preview: DiscoveryProviderPreview, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Catalogs")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            ForEach(preview.signed.manifest.catalogs, id: \.catalogId) { catalog in
                Text(verbatim: "\(catalog.catalogId) · \(catalog.seatTypes.joined(separator: ", "))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OnymTokens.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Step 3: done

    private var done: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(OnymTokens.green)
            Text("Provider added")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text("Its catalogs are being fetched and verified now.")
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .accessibilityIdentifier("settings.discovery.add.done")
    }
}
