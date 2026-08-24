import SwiftUI
import OnymDesign
import OnymChain

/// Settings → Anchors → … → Deploy from source.
///
/// Contracts can't be deployed from the phone — building the wasm needs
/// the Rust + Stellar CLI toolchain, and deploy is a privileged on-chain
/// op the app has no direct RPC path for. So this is an honest, copyable
/// guide to deploying `onymchat/onym-contracts` from a computer with the
/// `stellar` CLI, then pasting the resulting address back via "Use
/// existing address". (Previously this screen faked a build/deploy run.)
struct DeployContractView: View {
    let key: AnchorSelectionKey
    @State private var copied: String?

    private static let repoURL = URL(string: "https://github.com/onymchat/onym-contracts")!

    /// Stellar CLI network alias (testnet / mainnet).
    private var cliNetwork: String { key.network == .testnet ? "testnet" : "mainnet" }

    private struct Step: Identifiable {
        let id = UUID()
        let n: Int
        let title: LocalizedStringKey
        let body: LocalizedStringKey
        let cmd: String?
    }

    private var steps: [Step] {
        [
            .init(n: 1,
                  title: "Clone the contracts repo",
                  body: "The Onym contracts are open source.",
                  cmd: "git clone https://github.com/onymchat/onym-contracts"),
            .init(n: 2,
                  title: "Install the Stellar CLI",
                  body: "Needs the Rust toolchain + the wasm32 target.",
                  cmd: "cargo install --locked stellar-cli"),
            .init(n: 3,
                  title: "Build the wasm",
                  body: "Compiles the contracts to a wasm artifact.",
                  cmd: "cd onym-contracts\nstellar contract build"),
            .init(n: 4,
                  title: "Deploy to \(cliNetwork)",
                  body: "Sign with your own funded account; prints a C… contract address.",
                  cmd: """
                  stellar contract deploy \\
                    --network \(cliNetwork) \\
                    --source-account onym-deploy \\
                    --wasm target/wasm32-unknown-unknown/release/onym_\(key.type.rawValue).wasm
                  """),
            .init(n: 5,
                  title: "Add it to Onym",
                  body: "Copy the C… address it prints, then go back and tap “Use existing address” to paste it in.",
                  cmd: nil),
        ]
    }

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

                Footnote("Deployment runs on your computer, not on the phone — the app can't build wasm or submit a deploy transaction directly.")
            }
            .padding(.bottom, 24)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Deploy from source")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(OnymType.font(size: 14))
                    .foregroundStyle(.white)
                Text("onymchat/onym-contracts")
                    .font(OnymType.mono(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Text("Deploy your own contract")
                .font(OnymType.font(size: 22, weight: .bold))
                .tracking(-0.26)
                .foregroundStyle(.white)
            Text("Build and deploy the Onym contracts from your computer with the Stellar CLI, then point Onym at the deployed address.")
                .font(OnymType.font(size: 13.5))
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(3)

            Button { open(Self.repoURL.absoluteString) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("View on GitHub")
                        .font(OnymType.font(size: 13.5, weight: .semibold))
                    Image(systemName: "arrow.up.right.square")
                        .font(OnymType.font(size: 11))
                }
                // Fixed dark label — the button sits on a solid white
                // background, so an adaptive color (near-white in dark
                // mode) would be unreadable.
                .foregroundStyle(OnymTerminal.ink)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.white,
                            in: RoundedRectangle(cornerRadius: OnymRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("deploy.github_button")
        }
        .padding(20)
        .background(LinearGradient(colors: [OnymTerminal.surface,
                                            OnymTerminal.surfaceDeep],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: OnymRadius.panel, style: .continuous))
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
                .overlay(Text("\(s.n)").font(OnymType.font(size: 14, weight: .bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 4) {
                Text(s.title)
                    .font(OnymType.font(size: 16.5, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text(s.body)
                    .font(OnymType.font(size: 13.5))
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
                .font(OnymType.mono(size: 12))
                .foregroundStyle(OnymTerminal.text)
                .lineSpacing(3)
                .padding(.horizontal, 12).padding(.vertical, 12)
                .padding(.trailing, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OnymTerminal.surfaceDeep,
                            in: RoundedRectangle(cornerRadius: OnymRadius.control, style: .continuous))
            Button {
                UIPasteboard.general.string = text
                copied = label
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if copied == label { copied = nil }
                }
            } label: {
                Image(systemName: copied == label ? "checkmark" : "doc.on.doc")
                    .font(OnymType.fixed(size: 12, weight: .semibold))
                    .foregroundStyle(copied == label
                                     ? OnymTerminal.text
                                     : .white)
                    .frame(width: 26, height: 26)
                    .background(OnymTerminal.overlay,
                                in: RoundedRectangle(cornerRadius: OnymRadius.tile))
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityIdentifier("deploy.copy.\(label)")
        }
    }

    private func open(_ s: String) {
        guard let u = URL(string: s) else { return }
        UIApplication.shared.open(u)
    }
}
