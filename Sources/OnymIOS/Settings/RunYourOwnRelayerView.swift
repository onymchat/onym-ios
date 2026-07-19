import SwiftUI

/// Settings → Relayer → Run your own. 4-step explainer linking to
/// `github.com/onymchat/onym-relayer`. Each step has a copyable
/// shell-command code block. Bottom row links one-click deploys.
struct RunYourOwnRelayerView: View {
    @State private var copied: String?

    private static let repoURL = URL(string: "https://github.com/onymchat/onym-relayer")!

    private struct Step: Identifiable {
        let id = UUID()
        let n: Int
        let title: LocalizedStringKey
        let body: LocalizedStringKey
        let cmd: String?
    }

    private let steps: [Step] = [
        .init(n: 1,
              title: "Clone the repo",
              body: "onym-relayer is open source. Grab it from GitHub.",
              cmd: "git clone https://github.com/onymchat/onym-relayer\ncd onym-relayer"),
        .init(n: 2,
              title: "Configure .env",
              body: "Copy the template, then set your Stellar signing key and bind on 0.0.0.0 so Docker can reach it.",
              cmd: "cp .env.example .env\n# in .env, set:\n#   RELAYER_SECRET_KEY=S…\n#   RELAYER_BIND=0.0.0.0:8080"),
        .init(n: 3,
              title: "Run it with Docker",
              body: "Build the image and start the container on port 8080.",
              cmd: "docker build -t onym-relayer .\ndocker run --env-file .env -p 8080:8080 onym-relayer"),
        .init(n: 4,
              title: "Add it to Onym",
              body: "Back on Relayer, paste your URL (e.g. http://your-host:8080) into “Add Custom URL”.",
              cmd: nil),
    ]

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

                SettingsFootnote("Need help? Open an issue on [GitHub](https://github.com/onymchat/onym-ios/issues).")
            }
            .padding(.bottom, 24)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Run your own relayer")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                Text("onymchat/onym-relayer")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Text("Your relayer, your rules")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.26)
                .foregroundStyle(.white)
            Text("Run a relayer for yourself, your team, or your org. End-to-end encryption stays intact — Onym never sees your messages.")
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(3)

            Button { open(Self.repoURL.absoluteString) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("View on GitHub")
                        .font(.system(size: 13.5, weight: .semibold))
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                // Fixed dark label — button sits on solid white, so an
                // adaptive color (near-white in dark mode) would vanish.
                .foregroundStyle(Color(red: 0.039, green: 0.039, blue: 0.047))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.white,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("run_relayer.github_button")
        }
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

    private func stepRow(_ s: Step) -> some View {
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

    private func open(_ s: String) {
        guard let u = URL(string: s) else { return }
        UIApplication.shared.open(u)
    }
}
