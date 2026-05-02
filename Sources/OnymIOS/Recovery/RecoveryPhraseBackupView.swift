import SwiftUI

/// Top-level view for the "Back up keys" flow. Stateless w.r.t. domain
/// data — reads `flow.step` and renders the matching subview, wires
/// button taps to flow intents. The only local UI state is `obscured`
/// (scene-phase background dim) and `copyConfirmShown` (transient alert
/// after Copy tap).
struct RecoveryPhraseBackupView: View {
    @State private var flow: RecoveryPhraseBackupFlow
    @Environment(\.scenePhase) private var scenePhase
    @State private var obscured = false

    init(flow: RecoveryPhraseBackupFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        NavigationStack {
            stepContent
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .alert("Authentication Failed", isPresented: errorBinding) {
                    Button("Try Again") { flow.tappedContinueFromIntro() }
                    Button("Cancel", role: .cancel) { flow.dismissedAuthError() }
                } message: {
                    Text(errorMessage)
                }
                .overlay {
                    if obscured {
                        Color(UIColor.systemBackground)
                            .ignoresSafeArea()
                            .overlay {
                                Image(systemName: "lock.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    obscured = phase != .active
                }
                .task { flow.start() }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .intro, .authFailed:
            IntroScreen(
                isReady: flow.isReady,
                onContinue: { flow.tappedContinueFromIntro() }
            )
        case let .reveal(phrase, revealed):
            RevealScreen(
                phrase: phrase,
                revealed: revealed,
                onReveal: { flow.tappedReveal() },
                onCopy: { flow.tappedCopyPhrase() },
                onContinue: { flow.tappedContinueFromReveal() }
            )
        case let .verify(_, rounds, index, state):
            VerifyScreen(
                round: rounds[index],
                progressIndex: index,
                progressTotal: rounds.count,
                state: state,
                onPick: { flow.picked(word: $0) }
            )
        case .done:
            DoneScreen(onDone: { flow.tappedDoneFromCompletion() })
        }
    }

    private var navigationTitle: LocalizedStringKey {
        switch flow.step {
        case .intro, .authFailed: return "Back up keys"
        case .reveal: return "Recovery phrase"
        case .verify: return "Verify"
        case .done: return ""
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { if case .authFailed = flow.step { return true } else { return false } },
            set: { if !$0 { flow.dismissedAuthError() } }
        )
    }

    private var errorMessage: String {
        if case let .authFailed(reason) = flow.step { return reason }
        return ""
    }
}

// MARK: - Intro

private struct IntroScreen: View {
    let isReady: Bool
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroCard
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 18)

                sectionHeader("Before you start")
                VStack(spacing: 0) {
                    row(
                        icon: RoundedIcon(systemImage: "exclamationmark.triangle.fill", background: .orange),
                        title: "Never share or photograph",
                        separator: true
                    )
                    row(
                        icon: RoundedIcon(systemImage: "checkmark.shield.fill", background: .green),
                        title: "Store offline (paper or metal)",
                        separator: true
                    )
                    row(
                        icon: RoundedIcon(systemImage: "lock.fill", background: Color(UIColor.systemGray)),
                        title: "Anyone with it can read your chats",
                        separator: false
                    )
                }
                .background(
                    Color(UIColor.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .padding(.horizontal, 16)

                Button(action: onContinue) {
                    HStack(spacing: 8) {
                        Image(systemName: "faceid")
                        Text("Continue with Face ID")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(Color.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!isReady)
                .opacity(isReady ? 1 : 0.5)
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .accessibilityIdentifier("intro.continue_button")
            }
            .padding(.bottom, 28)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    private var heroCard: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 10, x: 0, y: 8)
                Image(systemName: "key.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Your identity, in 12 words")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Write them down. Keep them offline. This phrase restores your Nostr, Stellar, and BLS keys on any device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            Color(UIColor.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.bottom, 6)
    }

    private func row(icon: RoundedIcon, title: String, separator: Bool) -> some View {
        HStack(spacing: 12) {
            icon
            Text(title)
                .font(.body)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if separator {
                Rectangle()
                    .fill(Color(UIColor.separator).opacity(0.5))
                    .frame(height: 0.5)
                    .padding(.leading, 58)
            }
        }
    }
}

// MARK: - Reveal

private struct RevealScreen: View {
    let phrase: String
    let revealed: Bool
    let onReveal: () -> Void
    let onCopy: () -> Void
    let onContinue: () -> Void

    @State private var copyConfirmShown = false

    private var words: [String] {
        phrase.split(separator: " ").map(String.init)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Write down these \(words.count) words in order. You'll confirm three of them on the next screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                phraseCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                HStack(spacing: 8) {
                    Button(action: {
                        onCopy()
                        copyConfirmShown = true
                    }) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                    }
                    .disabled(!revealed)
                    .opacity(revealed ? 1 : 0.4)
                    .accessibilityIdentifier("reveal.copy_button")
                }
                .padding(.horizontal, 16)

                Button(action: onContinue) {
                    Text("I've written it down")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Color.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!revealed)
                .opacity(revealed ? 1 : 0.5)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .accessibilityIdentifier("reveal.continue_button")

                Text("The phrase is generated on-device and never sent off the device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 18)
            }
            .padding(.bottom, 28)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .alert("Copied", isPresented: $copyConfirmShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Recovery phrase copied. It will be cleared from clipboard in 60 seconds. Store it securely now.")
        }
    }

    private var phraseCard: some View {
        ZStack {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())],
                spacing: 10
            ) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(width: 18, alignment: .trailing)
                            .monospacedDigit()
                        Text(word)
                            .font(.callout.weight(.medium))
                            .accessibilityIdentifier("reveal.word.\(index + 1)")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
            }
            .padding(16)
            .blur(radius: revealed ? 0 : 10)
            .allowsHitTesting(revealed)

            if !revealed {
                Button(action: onReveal) {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 44, height: 44)
                            Image(systemName: "eye.slash")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.primary)
                        }
                        Text("Tap to reveal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityIdentifier("reveal.tap_button")
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            Color(UIColor.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

// MARK: - Verify

private struct VerifyScreen: View {
    let round: RecoveryPhraseBackupFlow.VerifyRound
    let progressIndex: Int
    let progressTotal: Int
    let state: RecoveryPhraseBackupFlow.VerifyState
    let onPick: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ProgressDots(current: progressIndex, total: progressTotal)
                    .padding(.top, 6)
                    .padding(.bottom, 22)

                VStack(spacing: 6) {
                    Text("Select word number")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(round.wordPosition)")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                        .accessibilityIdentifier("verify.position")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .padding(.horizontal, 16)
                .background(
                    Color(UIColor.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

                VStack(spacing: 10) {
                    ForEach(round.options, id: \.self) { option in
                        VerifyOption(
                            word: option,
                            isCorrect: state == .correct && option == round.correct,
                            isWrong: state == .wrong(option),
                            onTap: { onPick(option) }
                        )
                    }
                }
                .padding(.horizontal, 16)

                if case .wrong = state {
                    Text("Not the right word. Check your phrase and try again.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 32)
                        .padding(.top, 18)
                        .accessibilityIdentifier("verify.error_message")
                }
            }
            .padding(.bottom, 28)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }
}

private struct VerifyOption: View {
    let word: String
    let isCorrect: Bool
    let isWrong: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(word)
                    .font(.body.weight(.medium))
                Spacer()
                if isCorrect {
                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(border, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("verify.option.\(word)")
    }

    private var background: Color {
        if isCorrect { return Color.green.opacity(0.14) }
        if isWrong { return Color.red.opacity(0.12) }
        return Color(UIColor.secondarySystemGroupedBackground)
    }

    private var border: Color {
        if isCorrect { return Color.green }
        if isWrong { return Color.red }
        return Color.clear
    }

    private var foreground: Color {
        if isCorrect { return Color.green }
        if isWrong { return Color.red }
        return Color.primary
    }
}

private struct ProgressDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color(UIColor.systemGray4))
                    .frame(width: i == current ? 24 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: current)
            }
        }
    }
}

// MARK: - Done

private struct DoneScreen: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.green, Color(red: 0.2, green: 0.78, blue: 0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 96, height: 96)
                    .shadow(color: Color.green.opacity(0.4), radius: 16, x: 0, y: 12)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 24)

            Text("Backup verified")
                .font(.title.weight(.bold))
                .padding(.bottom, 10)
                .accessibilityIdentifier("done.title")
            Text("Your recovery phrase is confirmed. Store it somewhere safe — you'll only need it if you lose this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.bottom, 36)

            Button(action: onDone) {
                Text("Done")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 16)
            .accessibilityIdentifier("done.button")

            Spacer()

            Text(footer)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground))
    }

    private var footer: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        let date = df.string(from: Date())
        return String(localized: "Backed up \(date) · BIP-39 English")
    }
}

// MARK: - Shared atoms

private struct RoundedIcon: View {
    let systemImage: String
    let background: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
                .frame(width: 30, height: 30)
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
