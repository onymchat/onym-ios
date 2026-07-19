import SwiftUI

/// One numbered step in a `SelfHostGuideView`.
struct SelfHostGuideStep: Identifiable {
    let id = UUID()
    let n: Int
    let title: LocalizedStringKey
    let body: LocalizedStringKey
    /// Optional copyable shell snippet.
    let cmd: String?
}

/// Reusable "run your own <server>" tutorial: a dark hero with a
/// prominent **generic / not-Onym-software** note, numbered copyable
/// Docker/CLI steps, and a footnote. Backs the Nostr-relay and
/// Blossom-server self-host guides — the servers are standard,
/// interoperable open-source software; nothing here is Onym-specific.
struct SelfHostGuideView: View {
    let navTitle: String
    let heroTitle: String
    let heroBody: String
    /// The "this is generic, standard software — not Onym" highlight.
    let genericNote: String
    let steps: [SelfHostGuideStep]
    let footnote: LocalizedStringKey

    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroCard
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    stepRow(step)
                    if idx < steps.count - 1 {
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [OnymAccent.blue.color.opacity(0.4),
                                         OnymAccent.blue.color.opacity(0.1)],
                                startPoint: .top, endPoint: .bottom))
                            .frame(width: 2, height: 24)
                            .padding(.leading, 30)
                    }
                }
                SettingsFootnote(footnote)
            }
            .padding(.bottom, 24)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Prominent "generic, not Onym" badge.
            HStack(spacing: 6) {
                Image(systemName: "cube.box")
                    .font(.system(size: 11, weight: .bold))
                Text(genericNote)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.14),
                        in: Capsule())

            Text(heroTitle)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.26)
                .foregroundStyle(.white)
            Text(heroBody)
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(LinearGradient(colors: [Color(red: 0.106, green: 0.122, blue: 0.141),
                                            Color(red: 0.051, green: 0.067, blue: 0.090)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // MARK: - Steps

    private func stepRow(_ s: SelfHostGuideStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(OnymAccent.blue.color)
                .frame(width: 28, height: 28)
                .overlay(Text("\(s.n)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 4) {
                Text(s.title)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text(s.body)
                    .font(.system(size: 13.5))
                    .foregroundStyle(OnymTokens.text2)
                    .lineSpacing(2)
                if let cmd = s.cmd {
                    codeBlock(cmd, label: "step.\(s.n)")
                        .padding(.top, 8)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func codeBlock(_ text: String, label: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(red: 0.65, green: 1.0, blue: 0.6))
                .lineSpacing(3)
                .padding(.horizontal, 12).padding(.vertical, 12)
                .padding(.trailing, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.051, green: 0.067, blue: 0.090),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button {
                UIPasteboard.general.string = text
                copied = label
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if copied == label { copied = nil }
                }
            } label: {
                Image(systemName: copied == label ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied == label
                                     ? Color(red: 0.65, green: 1.0, blue: 0.6)
                                     : .white)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }
}

// MARK: - Content

extension SelfHostGuideView {
    /// Generic Nostr-relay self-host guide (uses strfry as the example;
    /// any spec-compliant relay works).
    static var nostr: SelfHostGuideView {
        SelfHostGuideView(
            navTitle: "Run your own Nostr relay",
            heroTitle: "Run your own Nostr relay",
            heroBody: "A Nostr relay is standard open-source software that speaks the Nostr protocol — nothing Onym-specific. The steps below use strfry, a popular relay; nostr-rs-relay is another good option.",
            genericNote: "Generic Nostr software — not Onym",
            steps: [
                .init(n: 1,
                      title: "Run a relay with Docker",
                      body: "strfry listens on port 7777. Data persists in a named volume.",
                      cmd: "docker run -d --name strfry \\\n  -p 7777:7777 \\\n  -v strfry-db:/app/strfry-db \\\n  dockurr/strfry"),
                .init(n: 2,
                      title: "Put it behind TLS",
                      body: "Clients connect over wss://, so terminate TLS with a reverse proxy on your domain (Caddy auto-issues a certificate).",
                      cmd: "caddy reverse-proxy \\\n  --from relay.example.com \\\n  --to localhost:7777"),
                .init(n: 3,
                      title: "Add it to Onym",
                      body: "Back on Nostr Relays, paste wss://relay.example.com into “Add Custom URL”.",
                      cmd: nil),
            ],
            footnote: "Any spec-compliant Nostr relay works (strfry, nostr-rs-relay, and others). These are independent open-source projects, not Onym software."
        )
    }

    /// Generic Blossom-server self-host guide (uses blossom-server as the
    /// example; any Blossom-compliant server works).
    static var blossom: SelfHostGuideView {
        SelfHostGuideView(
            navTitle: "Run your own Blossom server",
            heroTitle: "Run your own Blossom server",
            heroBody: "Blossom is an open spec for storing media blobs addressed by hash — nothing Onym-specific. The steps below use blossom-server (hzrd149), a common implementation.",
            genericNote: "Generic Blossom software — not Onym",
            steps: [
                .init(n: 1,
                      title: "Run a server with Docker",
                      body: "blossom-server listens on port 3000. Blobs + config persist in a mounted folder.",
                      cmd: "docker run -d --name blossom \\\n  -p 3000:3000 \\\n  -v ./blossom-data:/app/data \\\n  ghcr.io/hzrd149/blossom-server:master"),
                .init(n: 2,
                      title: "Put it behind TLS",
                      body: "Onym uploads/downloads over https://, so front it with a reverse proxy on your domain (Caddy auto-issues a certificate).",
                      cmd: "caddy reverse-proxy \\\n  --from blossom.example.com \\\n  --to localhost:3000"),
                .init(n: 3,
                      title: "Add it to Onym",
                      body: "Back on Blossom Relays, paste https://blossom.example.com into “Add Custom URL”.",
                      cmd: nil),
            ],
            footnote: "Any Blossom-compliant server works. These are independent open-source projects, not Onym software."
        )
    }
}
