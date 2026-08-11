import Foundation
import OnymModeration

/// Drives the authority pick → manifest review → sign sequence, used
/// at onboarding (`.onboarding`, blocking gate), from Settings
/// (`.switching`, signs a fresh mandate; the old record stays pinned),
/// and when standing consent has gone stale (`.reconsent`, blocking).
@MainActor
@Observable
public final class ModerationConsentFlow {
    public enum Mode: Equatable {
        case onboarding
        case switching
        /// The user holds a mandate, but not one that matches what its
        /// authority publishes today. Mechanically identical to
        /// switching — consent is always a fresh mandate, never an edit
        /// (spec §12) — and differs only in being unskippable and in
        /// naming what changed.
        case reconsent(ReconsentReason)
    }

    public enum Step: Equatable {
        case loadingDirectory
        case pickingAuthority
        /// Reviewing the fetched, hash-pinned manifest — the consent
        /// surface itself.
        case reviewingManifest
        case signing
        case done
    }

    public struct State: Equatable {
        public var step: Step = .loadingDirectory
        public var authorities: [AuthorityListing] = []
        public var fetchStatus: AuthorityFetchStatus = .idle
        public var selectedListing: AuthorityListing?
        /// The exact manifest on the consent surface. This same value is
        /// handed back to `consent(to:reviewedManifest:)`, so what the
        /// user read is what the mandate pins — and being a
        /// `ReviewedManifest`, it can only have come from the
        /// repository's verified fetch.
        public var reviewingManifest: ReviewedManifest?
        public var errorMessage: String?
        /// The authority the current mandate names, when there is one.
        /// The re-consent picker marks its row: "the terms you already
        /// agreed to, restated" is a different offer from the rest of
        /// the list, and hiding which is which would make re-signing
        /// look like switching.
        public var currentAuthorityId: String?
    }

    public let mode: Mode
    public private(set) var state = State()

    /// Settings can be walked away from; a gate cannot. Re-consent is a
    /// gate — the app is running on consent the authority has withdrawn.
    public var isDismissable: Bool { mode == .switching }

    private let repository: ModerationRepository
    private var snapshotTask: Task<Void, Never>?
    /// Called after a successful consent so the presenter can dismiss
    /// and trigger an immediate gate check.
    private let onConsented: @MainActor () -> Void

    public init(
        mode: Mode,
        repository: ModerationRepository,
        onConsented: @escaping @MainActor () -> Void = {}
    ) {
        self.mode = mode
        self.repository = repository
        self.onConsented = onConsented
    }

    public func start() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.repository.snapshots {
                self.state.authorities = snapshot.authorities
                self.state.fetchStatus = snapshot.fetchStatus
                self.state.currentAuthorityId = snapshot.activeMandate?.mandate.authority
                if self.state.step == .loadingDirectory {
                    switch snapshot.fetchStatus {
                    case .success, .failed:
                        self.state.step = .pickingAuthority
                    case .idle, .fetching:
                        break
                    }
                }
            }
        }
        Task { try? await repository.refresh() }
    }

    public func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    // MARK: - Intents

    /// Row tap in the authority picker: fetch, verify, and validate the
    /// manifest, then move to the review (consent) surface. The value
    /// retained here is the one that gets signed — see `tappedAgree`.
    public func selectedAuthority(_ listing: AuthorityListing) {
        state.selectedListing = listing
        state.errorMessage = nil
        Task {
            do {
                state.reviewingManifest = try await repository.manifestForReview(listing)
                state.step = .reviewingManifest
            } catch {
                state.errorMessage = String(localized: "Couldn't load this authority's terms. Try again.")
            }
        }
    }

    /// "I agree and sign" on the consent surface.
    ///
    /// Hands back the exact `SignedManifest` that was displayed, so the
    /// mandate pins the bytes the user read. The repository never
    /// refetches, which is what closes the window where an authority
    /// could serve different terms between review and agreement — the
    /// footnote on the consent surface promises precisely this.
    public func tappedAgree() {
        guard let listing = state.selectedListing,
              let reviewed = state.reviewingManifest
        else { return }
        state.step = .signing
        state.errorMessage = nil
        Task {
            do {
                try await repository.consent(to: listing, reviewedManifest: reviewed)
                state.step = .done
                onConsented()
            } catch {
                state.step = .reviewingManifest
                state.errorMessage = String(localized: "Signing failed. Try again.")
            }
        }
    }

    /// Back from the review surface to the picker.
    public func tappedBack() {
        state.step = .pickingAuthority
        state.reviewingManifest = nil
        state.selectedListing = nil
        state.errorMessage = nil
    }

    /// Retry button on a failed directory fetch.
    public func tappedRetry() {
        state.errorMessage = nil
        Task { try? await repository.refresh() }
    }
}
