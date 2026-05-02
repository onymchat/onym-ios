import SwiftUI

/// Second-chunk scaffold: subscribe to `IdentityRepository.snapshots` and
/// render whatever the repo publishes. Drives `bootstrap()` from `.task`
/// so first launch generates a fresh BIP39 identity and persists it; later
/// launches load the same identity from the Keychain.
///
/// This view exists to make the repo wiring exercisable end-to-end. Real
/// onboarding / recovery / settings UI lands in subsequent chunks.
struct IdentityBootstrapView: View {
    let repository: IdentityRepository

    @State private var identity: Identity?
    @State private var bootstrapError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Identity repository", systemImage: "person.badge.key.fill")
                .font(.title2.weight(.semibold))

            if let bootstrapError {
                Text(bootstrapError)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let identity {
                identitySection(identity)
            } else {
                ProgressView("Loading identity…")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await drainSnapshots()
        }
    }

    @ViewBuilder
    private func identitySection(_ identity: Identity) -> some View {
        labelled("Nostr public key (hex, 32 bytes)") {
            Text(identity.nostrPublicKey.hexEncoded)
        }
        labelled("BLS12-381 public key (hex, 48 bytes)") {
            Text(identity.blsPublicKey.hexEncoded)
        }
        labelled("Stellar account ID (StrKey)") {
            Text(identity.stellarAccountID)
        }
        labelled("Inbox public key — X25519 (hex, 32 bytes)") {
            Text(identity.inboxPublicKey.hexEncoded)
        }
        labelled("Inbox tag (Nostr filter)") {
            Text(identity.inboxTag)
        }
        // onym:allow-secret-read: dev bootstrap screen displays the freshly
        // generated mnemonic so chunk-2 wiring is verifiable end-to-end.
        // Production recovery-reveal UI lands in a later chunk and will own
        // its own gated suppression (biometric + screenshot block).
        if let phrase = identity.recoveryPhrase {
            labelled("Recovery phrase (BIP39)") {
                Text(phrase)
            }
        }
    }

    @ViewBuilder
    private func labelled<Content: View>(
        _ caption: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private func drainSnapshots() async {
        async let _: Void = bootstrap()
        for await snap in repository.snapshots {
            identity = snap
        }
    }

    private func bootstrap() async {
        do {
            _ = try await repository.bootstrap()
        } catch {
            bootstrapError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

private extension Data {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
