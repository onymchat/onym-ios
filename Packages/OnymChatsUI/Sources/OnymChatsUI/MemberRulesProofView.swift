import SwiftUI
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
                    // A standing can lose its mark *after* presentation
                    // — a refresh reply that clears the group's rules
                    // turns an open `.didNotSign` sheet into
                    // `.noRules`. The chevron gating can only stop the
                    // ones that start that way, and what was left was a
                    // blank card over a live Export button.
                    if !proof.standing.hasSomethingToShow {
                        nothingToShow
                    } else {
                        verdict
                        if let rules = proof.rules {
                            signedText(rules)
                        }
                        bytes
                        export
                    }
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
        .task { await Self.sweepStaleExports() }
        // One rule for the exported file, because the two this had
        // grown contradicted each other: **nothing written during this
        // sheet's life is ever deleted while it lives; everything left
        // by an earlier sheet is swept when the next one opens.**
        //
        // Not on dismiss, and not on replacement: `ShareLink` hands out
        // a URL, not a copy, so an AirDrop target or a share extension
        // reading it lazily loses the file if we tidy up underneath it
        // — the export failing at the moment it is used. Deleting the
        // *previous* write had the same hazard, since the user may have
        // handed that one out a second earlier.
        //
        // Sweeping *stale* exports is what keeps that from
        // accumulating. Each directory holds another member's rules
        // text and signature in plaintext, outside the encrypted store,
        // and `tmp` is only purged under pressure — a pile of those is
        // the disclosure this screen is careful about everywhere else.
        // An hour old is the test, because it is the one thing that
        // needs no coordination with whoever might still be reading.
        .reasonAlert("Couldn\u{2019}t prepare the file", reason: $writeError)
    }

    /// For a member whose standing stopped having anything to report
    /// while this sheet was open.
    private var nothingToShow: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(OnymTokens.text3)
            Text("There\u{2019}s nothing to show about this member\u{2019}s agreement any more.")
                .font(.system(size: 15))
                .foregroundStyle(OnymTokens.text)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .accessibilityIdentifier("rules_proof.nothing_to_show")
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
        case .noRules, .notCollected:
            // Unreachable, and left unwritten rather than translated:
            // `GroupRulesMark` is nil for both, so those rows get no
            // chevron and this sheet has no way to open on them. Two
            // strings nothing can display would be two strings a
            // translator has to render.
            ""
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
                // A `Button`, disabled, rather than a dimmed label: a
                // tap during the write is inert either way, but only
                // one of them tells VoiceOver that it is.
                Button(action: {}) { exportLabel(enabled: false) }
                    .disabled(true)
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
        // Nothing to export, nothing to write. The `nothingToShow`
        // branch has no Export button to feed, and every write leaves
        // another member's rules text, sending key and signature in
        // plaintext outside the encrypted store until a later sheet
        // sweeps it — twenty members tapped through is twenty of those.
        guard proof.standing.hasSomethingToShow else {
            file = nil
            return
        }
        let proof = proof
        // Cleared first. The screen has already re-rendered from the
        // live group, so between a proof change and its write landing
        // `ShareLink` was still holding the previous proof's URL — a
        // tap in that window exported the old bytes, which is what
        // `.task(id: proof)` exists to prevent. The disabled label
        // covers the gap.
        file = nil
        let written: URL? = await Task.detached {
            do {
                // Its own directory per write, and the readable name
                // inside it.
                //
                // The filename is stable for one member — group, alias,
                // key prefix — so two writes for the same sheet used to
                // contend for one path. Nothing there was safe: the
                // detached writes race on disk whatever the guard below
                // decides, so a superseded write could leave stale
                // bytes under a URL the fresh one had published; and
                // deleting "the previous file" deleted the live one,
                // handing the share sheet a dead link. A directory per
                // write makes each one addressable, so cleaning up
                // after yourself can't take somebody else's file with
                // it.
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "\(Self.exportDirectoryPrefix)\(UUID().uuidString)",
                        isDirectory: true
                    )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let url = directory.appendingPathComponent(proof.suggestedFileName)
                try proof.jsonData().write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }.value

        // A superseded write must not land. `.task(id:)` cancels this
        // task, but cancellation doesn't reach `Task.detached` and
        // awaiting a non-throwing task doesn't throw on cancel — so an
        // earlier write finishing last would otherwise publish itself
        // over the newer one.
        guard !Task.isCancelled else {
            // Only what this write created, which no one has been
            // handed: it never reached `file`.
            if let written { try? remove(written) }
            return
        }
        if let written {
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

    /// Removes a written export and the directory minted for it.
    private func remove(_ export: URL) throws {
        try FileManager.default.removeItem(at: export.deletingLastPathComponent())
    }

    /// Deletes export directories old enough that nothing can still be
    /// reading them.
    ///
    /// Age, not "everything that was here when I appeared" — which is
    /// what this was, and it was wrong twice over. The sweep and the
    /// write are separate `.task` modifiers that both hop to
    /// `Task.detached`, so nothing ordered the listing against this
    /// sheet's own `createDirectory`: catch it and the sweep deletes
    /// the export it is about to publish, handing `ShareLink` a dead
    /// URL. And on iPad a second window's sheet is a live directory
    /// that was present before this one appeared, so a snapshot at
    /// appear would delete a file whose share sheet is open.
    ///
    /// An hour is far longer than any share sheet lives and far shorter
    /// than "until the OS feels pressure", which is the alternative.
    /// The directory this sheet is about to write is seconds old, so it
    /// cannot be caught by any ordering.
    static func sweepStaleExports() async {
        await Task.detached {
            let fileManager = FileManager.default
            let cutoff = Date().addingTimeInterval(-Self.staleExportAge)
            let contents = try? fileManager.contentsOfDirectory(
                at: fileManager.temporaryDirectory,
                includingPropertiesForKeys: [.creationDateKey]
            )
            for url in contents ?? []
            where url.lastPathComponent.hasPrefix(Self.exportDirectoryPrefix) {
                let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                // No creation date means no evidence it is stale, and
                // leaving a file is the recoverable mistake here.
                guard let created, created < cutoff else { continue }
                try? fileManager.removeItem(at: url)
            }
        }.value
    }

    /// How long an export is left alone before the next sheet may
    /// remove it.
    static let staleExportAge: TimeInterval = 60 * 60

    static let exportDirectoryPrefix = "rules-proof-"
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
