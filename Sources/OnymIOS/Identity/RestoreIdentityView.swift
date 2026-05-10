import SwiftUI

/// Settings → Identities → "Restore from recovery phrase".
///
/// Pushed onto the Settings nav stack as the destination of the green
/// "Restore" card on `IdentitiesView`. Mirrors Android's
/// `RestoreIdentityScreen` (onym-android #94): multi-line phrase input,
/// optional alias, live BIP39 validation, primary "Restore" CTA that
/// stays disabled until the phrase parses cleanly. The cryptographic
/// path under the hood is the same as the legacy `Add Identity` mnemonic
/// field — `IdentityRepository.add(name:mnemonic:)` — but here the new
/// identity is added **alongside** existing ones and made active so the
/// user can keep their original install + restore-from-backup in one
/// keychain.
struct RestoreIdentityView: View {
    @Bindable var flow: IdentitiesFlow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Restore from recovery phrase")
                SettingsFootnote("Import an existing identity using your 12 or 24-word recovery phrase. The restored identity is added alongside your current ones.")

                SettingsSectionLabel("RECOVERY PHRASE")
                SettingsCard {
                    TextEditor(text: $flow.restorePhrase)
                        .frame(minHeight: 110)
                        .font(.system(size: 15, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("restore_identity.phrase_field")
                }
                phraseHint

                SettingsSectionLabel("ALIAS (OPTIONAL)")
                SettingsCard {
                    TextField("Alias (optional)", text: $flow.restoreAlias)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .font(.system(size: 16.5))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("restore_identity.alias_field")
                }
                SettingsFootnote("Defaults to “Identity N” if left blank.")

                if let error = flow.restoreError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .accessibilityIdentifier("restore_identity.error")
                }

                SettingsPrimaryButton("Restore", disabled: !flow.restoreIsValid) {
                    Task {
                        if await flow.submitRestore() {
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .accessibilityIdentifier("restore_identity.submit_button")
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Restore identity")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // System-back / programmatic pop — clear the buffer so a
            // second visit doesn't surface a stale phrase.
            flow.cancelRestore()
        }
    }

    /// Live phrase-validity hint. Hidden while the field is empty so a
    /// fresh visit isn't immediately red; otherwise green when the
    /// BIP39 checksum + wordlist parse, red when not.
    @ViewBuilder
    private var phraseHint: some View {
        let trimmed = flow.restorePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            SettingsFootnote("Enter your 12 or 24-word recovery phrase.")
        } else if flow.restoreIsValid {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Valid phrase")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(OnymTokens.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .accessibilityIdentifier("restore_identity.hint_valid")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                Text("Invalid phrase")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(OnymTokens.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .accessibilityIdentifier("restore_identity.hint_invalid")
        }
    }
}
