import SwiftUI
import UniformTypeIdentifiers
import OnymDesign
import OnymGroup

/// One member's standing on the group's rules, and the file that can
/// carry it off the device.
///
/// The screen exists because the interesting question about an
/// agreement is usually asked somewhere else — to a moderator, to the
/// rest of a committee, to someone deciding whether a person can be
/// held to something. So the whole screen is arranged around the
/// export: what is being claimed, the bytes that back it, and a button
/// that hands both over in a form nobody has to take on trust.
struct MemberRulesProofView: View {
    let proof: GroupRulesProof
    let onClose: () -> Void

    /// Written on appear, not on tap. `ShareLink` wants a `URL` up
    /// front, and a share sheet that has to wait for a file write is a
    /// share sheet that opens empty.
    @State private var file: URL?
    @State private var writeError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    verdict
                    if let rules = proof.rules {
                        signedText(rules)
                    }
                    if proof.standing.isProven {
                        bytes
                    }
                    export
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(OnymTokens.bg.ignoresSafeArea())
            .navigationTitle(proof.memberAlias)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("rules_proof.done")
                }
            }
        }
        .task { writeFile() }
        .reasonAlert("Couldn\u{2019}t prepare the file", reason: $writeError)
    }

    private var verdict: some View {
        VStack(spacing: 8) {
            if let mark = ChatMembersView.mark(for: proof.standing) {
                Image(systemName: mark.symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(mark.color)
                Text(mark.text)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                    .accessibilityIdentifier("rules_proof.standing")
            }
            Text(explanation)
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// Says what the mark means for this member, in the terms someone
    /// asking about them would use.
    private var explanation: String {
        switch proof.standing {
        case .noRules:
            String(localized: "This group has no rules, so nothing was asked of anyone.")
        case .author:
            String(localized: "They set these rules for the group. Founders don\u{2019}t sign their own.")
        case .signed:
            String(localized: "They read these rules and signed them with this identity\u{2019}s key before joining.")
        case .signedEarlierVersion:
            String(localized: "They signed the rules as they were written when they joined. The group has changed them since.")
        case .didNotSign:
            String(localized: "They joined before this group had rules, or from an app version that predates them.")
        case .doesNotVerify:
            String(localized: "A signature is stored for them and it doesn\u{2019}t check out. Nothing here can be shown as their agreement.")
        }
    }

    private func signedText(_ rules: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT THEY SIGNED")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            Text(rules)
                .font(.system(size: 14))
                .foregroundStyle(OnymTokens.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if proof.rules != proof.currentRules {
                // Named on the screen as well as in the file: someone
                // comparing this against the rules section a tap away
                // should not have to work out why they differ.
                Label(
                    String(localized: "The group\u{2019}s rules have changed since. This is the wording they agreed to."),
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.system(size: 12))
                .foregroundStyle(OnymTokens.text2)
            }
        }
        .padding(14)
        .background(OnymTokens.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .accessibilityIdentifier("rules_proof.rules")
    }

    /// The two values a verifier needs, shown rather than described.
    /// Truncated on screen because nobody checks 64 bytes by eye — the
    /// file carries them in full, and this is here so the screen and
    /// the file can be seen to be about the same thing.
    private var bytes: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(String(localized: "signing key"), value: proof.sendingPublicKey.map(short) ?? "")
            row(String(localized: "signature"), value: proof.signature.map(short) ?? "")
        }
        .padding(14)
        .background(OnymTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("rules_proof.bytes")
    }

    private var export: some View {
        VStack(spacing: 8) {
            if let file {
                ShareLink(item: file) {
                    Text("Export proof")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(OnymAccent.blue.color)
                        .foregroundStyle(OnymTokens.onAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("rules_proof.export")
            }
            Text(proof.standing.isProven
                 ? String(localized: "A file anyone can check with any Ed25519 tool \u{2014} it explains how inside.")
                 : String(localized: "The file records what this device knows. There is no signature in it to check."))
                .font(.system(size: 11))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
        }
    }

    private func row(_ key: String, value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(OnymTokens.text2)
        }
    }

    private func short(_ data: Data) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard hex.count > 16 else { return hex }
        return hex.prefix(8) + "\u{2026}" + hex.suffix(8)
    }

    /// Writes the export to a temporary file for `ShareLink`.
    ///
    /// Temporary rather than somewhere durable on purpose: the copy
    /// that matters is the one the person sends, and leaving proofs
    /// about other people lying around this device is a disclosure
    /// nobody asked for.
    private func writeFile() {
        guard file == nil else { return }
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(proof.suggestedFileName)
            try proof.jsonData().write(to: url, options: .atomic)
            file = url
        } catch {
            writeError = String(localized: "This device couldn\u{2019}t write the proof file.")
        }
    }
}
