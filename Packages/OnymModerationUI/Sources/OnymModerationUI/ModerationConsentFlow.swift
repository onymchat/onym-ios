import Foundation
import OnymModeration

/// Drives the authority pick → manifest review → sign sequence, used
/// both at onboarding (`.onboarding`, blocking gate) and from Settings
/// (`.switching`, signs a fresh mandate; the old record stays pinned).
@MainActor
@Observable
public final class ModerationConsentFlow {
    public enum Mode: Equatable {
        case onboarding
        case switching
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
        public var reviewingManifest: ReviewedManifest?
        public var errorMessage: String?
    }

    /// The manifest under review plus the hash the mandate will pin —
    /// displayed on the consent surface so what's signed is inspectable.
    public struct ReviewedManifest: Equatable {
        public let manifest: AuthorityManifest
        public let manifestHash: String
    }

    public let mode: Mode
    public private(set) var state = State()

    private let repository: ModerationRepository
    private let manifestFetcher: any AuthorityManifestFetcher
    private var snapshotTask: Task<Void, Never>?
    /// Called after a successful consent so the presenter can dismiss
    /// and trigger an immediate gate check.
    private let onConsented: @MainActor () -> Void

    public init(
        mode: Mode,
        repository: ModerationRepository,
        manifestFetcher: any AuthorityManifestFetcher,
        onConsented: @escaping @MainActor () -> Void = {}
    ) {
        self.mode = mode
        self.repository = repository
        self.manifestFetcher = manifestFetcher
        self.onConsented = onConsented
    }

    public func start() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.repository.snapshots {
                self.state.authorities = snapshot.authorities
                self.state.fetchStatus = snapshot.fetchStatus
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

    /// Row tap in the authority picker: fetch + pin the manifest and
    /// move to the review (consent) surface.
    public func selectedAuthority(_ listing: AuthorityListing) {
        state.selectedListing = listing
        state.errorMessage = nil
        Task {
            do {
                let signed = try await manifestFetcher.fetch(listing)
                state.reviewingManifest = ReviewedManifest(
                    manifest: signed.manifest,
                    manifestHash: signed.manifestHash
                )
                state.step = .reviewingManifest
            } catch {
                state.errorMessage = String(localized: "Couldn't load this authority's terms. Try again.")
            }
        }
    }

    /// "I agree and sign" on the consent surface.
    public func tappedAgree() {
        guard let listing = state.selectedListing else { return }
        state.step = .signing
        state.errorMessage = nil
        Task {
            do {
                try await repository.consent(to: listing)
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
