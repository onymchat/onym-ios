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
                    bytes
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
        .task(id: proof) { await writeFile() }
        // Deliberately *not* deleted on dismiss. `ShareLink` hands out
        // a URL, not a copy, and an AirDrop target or a share extension
        // that reads it lazily loses the file if this sheet tidies up
        // first — the export failing at the moment it is used. What is
        // left behind is one small file per member opened, each
        // overwritten on the next open, in a directory the OS sweeps.
        .reasonAlert("Couldn\u{2019}t prepare the file", reason: $writeError)
    }

    private var verdict: some View {
        VStack(spacing: 8) {
            if let mark = GroupRulesMark(proof.standing) {
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

    /// Says what the mark means for this member.
    ///
    /// Written without a subject pronoun, rather than in the third
    /// person it started in. These strings are read on your *own* row
    /// as often as on anyone else's — the joiner checking their own
    /// agreement is the case this screen exists for, and it sits next
    /// to a `(you)` badge — so "they read these rules" and "their
    /// signature doesn't check out" were about the reader. The
    /// alternative was a second-person variant of every line behind an
    /// `isSelf` flag: twice the strings for translators, and a branch
    /// to get wrong. Subjectless phrasing reads correctly either way.
    private var explanation: String {
        switch proof.standing {
        case .noRules:
            String(localized: "This group has no rules, so nothing was asked of anyone.")
        case .notCollected:
            String(localized: "This kind of group has no join approval, so nobody is asked to sign its rules.")
        case .author:
            String(localized: "These rules were set for the group by this member. Founders don\u{2019}t sign their own.")
        case .signed:
            String(localized: "These rules were read and signed with this identity\u{2019}s key before joining.")
        case .signedEarlierVersion:
            String(localized: "Signed as the rules were written at the time of joining. The group has changed them since.")
        case .didNotSign:
            String(localized: "Joined before this group had rules, or from an app version that predates them.")
        case .unknownRules:
            String(localized: "A signature is stored, but the wording it covers isn\u{2019}t on this device, so nothing here can check it.")
        case .doesNotVerify:
            String(localized: "A signature is stored and it doesn\u{2019}t check out. Nothing here can be shown as an agreement.")
        }
    }

    private func signedText(_ rules: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // "WHAT THEY SIGNED" sat directly under "Founders don't
            // sign their own" for the author, where the same text is
            // shown because the rules are theirs. The file avoids the
            // contradiction by routing the author through `note`; the
            // screen has to vary the heading.
            Text(proof.standing == .author ? "THE RULES THEY SET" : "WHAT THEY SIGNED")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            Text(rules)
                .font(.system(size: 14))
                .foregroundStyle(OnymTokens.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            // From the standing, not a string compare of the two
            // copies: `GroupRulesProof` single-sources this exact fact
            // for the file, and two derivations agree only until
            // normalization changes.
            if proof.standing == .signedEarlierVersion {
                // Named on the screen as well as in the file: someone
                // comparing this against the rules section a tap away
                // should not have to work out why they differ.
                Label(
                    String(localized: "The group\u{2019}s rules have changed since. This is the wording that was agreed to."),
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
            // Always, even where there is no signature: the title of
            // this sheet is an alias the member chose for themselves,
            // and two people can choose the same one. The fingerprint
            // is what says which member this is about.
            row(String(localized: "member"), value: shortHex(proof.memberBlsHex))
            if proof.standing.isProven {
                row(String(localized: "signing key"), value: proof.sendingPublicKey.map(short) ?? "")
                row(String(localized: "signature"), value: proof.signature.map(short) ?? "")
            }
        }
        .padding(14)
        .background(OnymTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("rules_proof.bytes")
    }

    private var export: some View {
        VStack(spacing: 8) {
            // The button holds its place while the file is being
            // written rather than appearing a frame or two later: it is
            // the primary action, and a thumb is already moving toward
            // it when the layout would otherwise jump.
            if let file {
                ShareLink(item: file) {
                    exportLabel(enabled: true)
                }
                .accessibilityIdentifier("rules_proof.export")
            } else {
                exportLabel(enabled: false)
                    .accessibilityIdentifier("rules_proof.export_preparing")
            }
            Text(proof.standing.isProven
                 ? String(localized: "A file anyone can check with any Ed25519 tool \u{2014} it explains how inside.")
                 : String(localized: "The file records what this device knows. There is no signature in it to check."))
                .font(.system(size: 11))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
        }
    }

    private func exportLabel(enabled: Bool) -> some View {
        Text("Export proof")
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(OnymAccent.blue.color.opacity(enabled ? 1.0 : 0.5))
            .foregroundStyle(OnymTokens.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
        shortHex(data.map { String(format: "%02x", $0) }.joined())
    }

    private func shortHex(_ hex: String) -> String {
        guard hex.count > 16 else { return hex }
        return hex.prefix(8) + "\u{2026}" + hex.suffix(8)
    }

    /// Writes the export to a temporary file for `ShareLink`.
    ///
    /// Temporary rather than somewhere durable on purpose: the copy
    /// that matters is the one the person sends, and leaving proofs
    /// about other people lying around this device is a disclosure
    /// nobody asked for.
    /// Re-runs when the proof does — `.task(id: proof)`.
    ///
    /// The sheet re-renders from the live group, so a roster or rules
    /// update while it is open changed what the screen said and left
    /// the file holding the bytes it was written with. Whoever tapped
    /// Export would have sent the old ones.
    private func writeFile() async {
        let proof = proof
        let previous = file
        // Off the main actor: encode-and-write is small today, but it
        // runs on the sheet's first frame, and "small today" is how a
        // hitch gets built in.
        let written: URL? = await Task.detached {
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(proof.suggestedFileName)
                try proof.jsonData().write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }.value
        // A superseded write must not land. `.task(id:)` cancels this
        // task, but cancellation doesn't reach `Task.detached` and
        // awaiting a non-throwing task doesn't throw on cancel — so an
        // earlier write finishing last would assign its URL and delete
        // the newer one as `previous`, leaving Export on the old
        // proof's bytes. Which is what `.task(id:)` was added to stop.
        guard !Task.isCancelled else {
            if let written { try? FileManager.default.removeItem(at: written) }
            return
        }
        if let written {
            // Replaces the previous write from *this* sheet — the proof
            // changed under it. A proof for a different member was
            // written by a different presentation and is not reachable
            // from here; it keeps its own name, is overwritten the next
            // time that member is opened, and is `tmp`'s to sweep.
            if let previous, previous != written {
                try? FileManager.default.removeItem(at: previous)
            }
            file = written
        } else {
            // Cleared, not left pointing at the last successful write.
            // Otherwise a failed re-write leaves Export live and
            // sharing the *previous* proof's bytes — which is the exact
            // thing `.task(id: proof)` was added to prevent.
            file = nil
            writeError = String(localized: "This device couldn\u{2019}t write the proof file.")
        }
    }
}


/// Shown where a member's proof was asked for and the group (or the
/// member) is no longer there — a roster change while the sheet was
/// opening, or a group deleted underneath it. A sheet that renders
/// nothing at all reads as a bug; this reads as what happened.
struct MemberGoneView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 34))
                    .foregroundStyle(OnymTokens.text3)
                Text("This member is no longer in the group.")
                    .font(.system(size: 15))
                    .foregroundStyle(OnymTokens.text)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OnymTokens.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("rules_proof.member_gone_done")
                }
            }
        }
        .accessibilityIdentifier("rules_proof.member_gone")
    }
}
