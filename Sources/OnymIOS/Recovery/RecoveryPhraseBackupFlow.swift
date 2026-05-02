import Foundation
import UIKit

/// Single source of truth for the "Back up keys" flow.
///
/// State flows down (`step`); intents flow up (the `tapped*` / `picked` /
/// `dismissed*` methods). The view never mutates state directly — it reads
/// `step`, renders the matching screen, and calls intents on user actions.
/// All side effects (Keychain via `IdentityRepository`, biometric prompt,
/// pasteboard, randomness, `Task.sleep`) live here.
@MainActor
@Observable
final class RecoveryPhraseBackupFlow {
    enum Step: Equatable {
        case intro
        case authFailed(reason: String)
        case reveal(phrase: String, revealed: Bool)
        case verify(phrase: String, rounds: [VerifyRound], index: Int, state: VerifyState)
        case done
    }

    enum VerifyState: Equatable {
        case idle
        case correct
        case wrong(String)
    }

    struct VerifyRound: Equatable, Sendable {
        let wordPosition: Int   // 1-based
        let correct: String
        let options: [String]
    }

    // MARK: - Public state

    private(set) var step: Step = .intro

    /// True once `IdentityRepository.bootstrap()` has resolved and produced
    /// a snapshot. The view disables the Continue button until this flips
    /// so a too-eager tap on first launch can't race the bootstrap write.
    var isReady: Bool { currentIdentity != nil }

    // MARK: - Dependencies

    private let repository: IdentityRepository
    private let authenticator: BiometricAuthenticator
    private let pasteboard: PasteboardWriter
    private let clipboardClearDelay: Duration
    private let verifyAdvanceDelay: Duration

    // MARK: - Internal

    private var snapshotTask: Task<Void, Never>?
    private var verifyAdvanceTask: Task<Void, Never>?
    private var clipboardClearTask: Task<Void, Never>?
    private var currentIdentity: Identity?

    // MARK: - Init

    init(
        repository: IdentityRepository,
        authenticator: BiometricAuthenticator,
        pasteboard: PasteboardWriter = UIPasteboardWriter(),
        clipboardClearDelay: Duration = .seconds(60),
        verifyAdvanceDelay: Duration = .milliseconds(450)
    ) {
        self.repository = repository
        self.authenticator = authenticator
        self.pasteboard = pasteboard
        self.clipboardClearDelay = clipboardClearDelay
        self.verifyAdvanceDelay = verifyAdvanceDelay
    }

    /// Begin draining the repository's snapshots into our local cache.
    /// Idempotent — safe to call from `.task` on every appear.
    func start() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            _ = try? await self.repository.bootstrap()
            for await snapshot in self.repository.snapshots {
                self.currentIdentity = snapshot
            }
        }
    }

    /// Cancel any in-flight tasks. Call on view disappear if the flow's
    /// lifetime exceeds the view's; for the first-cut single-screen app,
    /// the flow lives for the App's lifetime so this is mostly a hook for
    /// future composition.
    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        verifyAdvanceTask?.cancel()
        verifyAdvanceTask = nil
        clipboardClearTask?.cancel()
        clipboardClearTask = nil
    }

    // MARK: - Intents (called from the view)

    func tappedContinueFromIntro() {
        Task { await self.authenticate() }
    }

    func dismissedAuthError() {
        if case .authFailed = step { step = .intro }
    }

    func tappedReveal() {
        if case let .reveal(phrase, _) = step {
            step = .reveal(phrase: phrase, revealed: true)
        }
    }

    func tappedCopyPhrase() {
        guard case let .reveal(phrase, true) = step else { return }
        // onym:allow-secret-read: copy is the explicit user intent on the
        // reveal screen; auto-clears after `clipboardClearDelay` so the
        // value doesn't sit on the system pasteboard indefinitely.
        pasteboard.write(phrase)
        clipboardClearTask?.cancel()
        clipboardClearTask = Task { [pasteboard, clipboardClearDelay] in
            try? await Task.sleep(for: clipboardClearDelay)
            pasteboard.clearIfStill(phrase)
        }
    }

    func tappedContinueFromReveal() {
        if case let .reveal(phrase, true) = step {
            step = .verify(
                phrase: phrase,
                rounds: Self.makeRounds(for: phrase),
                index: 0,
                state: .idle
            )
        }
    }

    func picked(word: String) {
        guard case let .verify(phrase, rounds, index, currentState) = step,
              currentState != .correct else { return }
        let round = rounds[index]
        if word == round.correct {
            step = .verify(phrase: phrase, rounds: rounds, index: index, state: .correct)
            verifyAdvanceTask?.cancel()
            verifyAdvanceTask = Task { [weak self, verifyAdvanceDelay] in
                try? await Task.sleep(for: verifyAdvanceDelay)
                guard let self else { return }
                guard case let .verify(p, r, i, .correct) = self.step, i == index else { return }
                if i + 1 >= r.count {
                    self.step = .done
                } else {
                    self.step = .verify(phrase: p, rounds: r, index: i + 1, state: .idle)
                }
            }
        } else {
            step = .verify(phrase: phrase, rounds: rounds, index: index, state: .wrong(word))
        }
    }

    func tappedDoneFromCompletion() {
        // Single-screen app: loop back to intro so the user can re-verify.
        // Once a settings/home screen exists, this becomes a navigation pop.
        step = .intro
    }

    // MARK: - Internal (also reachable from tests)

    func authenticate() async {
        do {
            try await authenticator.authenticate(
                reason: "Authenticate to reveal your recovery phrase"
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            step = .authFailed(reason: message)
            return
        }
        // onym:allow-secret-read: revealing the recovery phrase to the user
        // is the entire purpose of this flow. The reveal screen gates the
        // text behind a tap-to-reveal, scene-phase obscure overlay, and the
        // (Face ID / passcode)-gated authenticator above.
        guard let phrase = currentIdentity?.recoveryPhrase else {
            step = .authFailed(
                reason: "Recovery phrase unavailable. Your identity may not be BIP39-backed."
            )
            return
        }
        step = .reveal(phrase: phrase, revealed: false)
    }

    // MARK: - Private

    /// Pick three random word positions (1-based displayed), present each
    /// as a 4-way multiple choice with one correct + three random distractors
    /// from the same phrase. Matches the reference impl's verification UX.
    private static func makeRounds(for phrase: String) -> [VerifyRound] {
        let words = phrase.split(separator: " ").map(String.init)
        let positions = Array(0..<words.count).shuffled().prefix(3).sorted()
        return positions.map { pos in
            var opts = Set<String>([words[pos]])
            while opts.count < 4 {
                if let candidate = words.randomElement(), candidate != words[pos] {
                    opts.insert(candidate)
                }
            }
            return VerifyRound(
                wordPosition: pos + 1,
                correct: words[pos],
                options: Array(opts).shuffled()
            )
        }
    }
}

// MARK: - Pasteboard seam

/// Minimal seam over `UIPasteboard` so the flow's clipboard side effect can
/// be observed in tests without writing to the actual system pasteboard.
protocol PasteboardWriter: Sendable {
    func write(_ value: String)
    func clearIfStill(_ value: String)
}

struct UIPasteboardWriter: PasteboardWriter {
    func write(_ value: String) {
        UIPasteboard.general.string = value
    }
    func clearIfStill(_ value: String) {
        if UIPasteboard.general.string == value {
            UIPasteboard.general.string = ""
        }
    }
}
