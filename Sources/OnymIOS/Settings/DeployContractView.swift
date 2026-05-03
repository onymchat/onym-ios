import SwiftUI

/// Settings → Anchors → ... → Deploy from source. Scaffold screen
/// modeled after the design — animated build/deploy console, source
/// fields (repo + ref + network + module), and a CLI fallback.
/// Currently surfaces a simulated progress run so the UI can be
/// exercised end-to-end; real wasm builds + soroban deploy land in a
/// later PR alongside the deploy-key signer.
struct DeployContractView: View {
    let key: AnchorSelectionKey
    @Environment(\.dismiss) private var dismiss

    @State private var ref: String = "main"
    @State private var stage: Stage = .idle
    @State private var progress: Int = 0
    @State private var logs: [String] = []
    @State private var deployedAddr: String?
    @State private var copiedCmd = false

    enum Stage { case idle, building, deploying, done }

    private static let repoURL = URL(string: "https://github.com/onymchat/onym-contracts")!

    private var networkPassphrase: String {
        key.network == .testnet
            ? "Test SDF Network ; September 2015"
            : "Public Global Stellar Network ; September 2015"
    }

    private var cliCmd: String {
        """
        soroban contract deploy \\
          --network \(key.network == .testnet ? "testnet" : "mainnet") \\
          --source-account onym-deploy \\
          --wasm onym_\(key.type.rawValue).wasm
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroCard

                SettingsSectionLabel("SOURCE")
                SettingsCard {
                    SettingsRow(
                        title: "Repository",
                        subtitle: "github.com/onymchat/onym-contracts",
                        subtitleMono: true,
                        hasChevron: false,
                        onTap: { open(Self.repoURL.absoluteString) }
                    ) {
                        SettingsIconTile(symbol: "chevron.left.forwardslash.chevron.right",
                                         bg: OnymTokens.text)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }

                    HStack(spacing: 12) {
                        SettingsIconTile(symbol: "arrow.triangle.branch",
                                         bg: SettingsTile.indigo)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Ref")
                                .font(.system(size: 13))
                                .foregroundStyle(OnymTokens.text2)
                            TextField("main · v0.0.5 · commit sha", text: $ref)
                                .font(.system(size: 15.5, design: .monospaced))
                                .disabled(stage != .idle)
                                .accessibilityIdentifier("deploy.ref_field")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    SettingsRowDivider(inset: 16)

                    SettingsRow(title: "Network", hasChevron: false) {
                        SettingsContentTile(bg: key.network == .testnet
                                            ? SettingsTile.green : SettingsTile.gray) {
                            Text(key.network == .testnet ? "T" : "M")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    } right: {
                        Text(LocalizedStringKey(key.network.displayName))
                            .foregroundStyle(OnymTokens.text2)
                            .font(.system(size: 14))
                    }

                    SettingsRow(title: "Module", hasChevron: false, last: true) {
                        SettingsContentTile(bg: SettingsTile.purple) {
                            Text(String(key.type.rawValue.prefix(2)).uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    } right: {
                        Text(LocalizedStringKey(key.type.displayName))
                            .foregroundStyle(OnymTokens.text2)
                            .font(.system(size: 14))
                    }
                }

                if stage == .idle {
                    SettingsPrimaryButton(action: startDeploy) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Build & Deploy")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .accessibilityIdentifier("deploy.start_button")
                } else {
                    deployConsole
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                }

                if stage == .done, let addr = deployedAddr {
                    deployedCard(addr)
                    SettingsPrimaryButton("Use this contract") { dismiss() }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .accessibilityIdentifier("deploy.use_button")
                }

                SettingsSectionLabel("OR USE THE CLI")
                cliBlock
                SettingsFootnote("Network passphrase: \(networkPassphrase). After deploying via CLI, come back and choose Use existing address.")
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle(Text(verbatim: "Deploy · \(key.type.displayName)"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 14)).foregroundStyle(.white)
                Text("onymchat/onym-contracts")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Text("Build, deploy, anchor")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.26)
                .foregroundStyle(.white)
            Text("Compile the \(key.type.displayName.lowercased()) contract from source and deploy it to Stellar \(key.network == .testnet ? "Testnet" : "Mainnet"). Onym signs with a one-time deploy key.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(3)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.106, green: 0.122, blue: 0.141),
                                              Color(red: 0.051, green: 0.067, blue: 0.090)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing),
                     in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Console

    private var deployConsole: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(stage == .done ? OnymTokens.green : SettingsTile.amber)
                    .frame(width: 8, height: 8)
                Text(stage == .building ? "Building wasm…" :
                     stage == .deploying ? "Deploying to Stellar…" : "Complete")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(progress)%")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Capsule()
                .fill(.white.opacity(0.08))
                .frame(height: 3)
                .overlay(GeometryReader { geo in
                    Capsule().fill(stage == .done ? OnymTokens.green : OnymAccent.blue.color)
                        .frame(width: geo.size.width * CGFloat(progress) / 100)
                }, alignment: .leading)
                .padding(.bottom, 4)
            ForEach(Array(logs.enumerated()), id: \.offset) { _, l in
                Text(l)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(l.hasPrefix("✓")
                                     ? Color(red: 0.65, green: 1.0, blue: 0.6)
                                     : (l.hasPrefix("↗") ? Color(red: 0.49, green: 0.76, blue: 1.0) : .white))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.051, green: 0.067, blue: 0.090),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Deployed

    private func deployedCard(_ addr: String) -> some View {
        Group {
            SettingsSectionLabel("DEPLOYED CONTRACT")
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(OnymTokens.green).frame(width: 22, height: 22)
                            .overlay(Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white))
                        Text("Contract deployed")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(OnymTokens.text)
                    }
                    Text(addr)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(OnymTokens.text)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OnymTokens.surface3,
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)

                SettingsRowDivider(inset: 16)

                HStack(spacing: 0) {
                    SettingsTextButton(
                        title: "Copy",
                        systemImage: "doc.on.doc",
                        foreground: OnymAccent.blue.color
                    ) {
                        UIPasteboard.general.string = addr
                    }
                    .accessibilityIdentifier("deploy.copy_addr")
                    Rectangle().fill(OnymTokens.hairlineStrong).frame(width: 0.5)
                    Button {
                        let path = key.network == .testnet
                            ? "testnet.stellar.expert/explorer/testnet/contract/\(addr)"
                            : "stellar.expert/explorer/public/contract/\(addr)"
                        open("https://\(path)")
                    } label: {
                        HStack(spacing: 6) {
                            Text("View on Stellar Expert")
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11))
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(OnymAccent.blue.color)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("deploy.view_explorer")
                }
            }
        }
    }

    // MARK: - CLI block

    private var cliBlock: some View {
        ZStack(alignment: .topTrailing) {
            Text(cliCmd)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color(red: 0.65, green: 1.0, blue: 0.6))
                .lineSpacing(3)
                .padding(.horizontal, 12).padding(.vertical, 12)
                .padding(.trailing, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.051, green: 0.067, blue: 0.090),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button {
                UIPasteboard.general.string = cliCmd
                copiedCmd = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedCmd = false }
            } label: {
                Image(systemName: copiedCmd ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityIdentifier("deploy.copy_cli")
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Simulated progress

    private func startDeploy() {
        stage = .building
        progress = 0
        logs = []
        deployedAddr = nil

        let plan: [(t: Double, log: String, p: Int, stage: Stage?, addr: String?)] = [
            (0.6, "✓ Cloned onymchat/onym-contracts @ \(ref)", 12, nil, nil),
            (1.4, "✓ cargo build --release --target wasm32", 38, nil, nil),
            (2.2, "✓ Built onym_\(key.type.rawValue).wasm (47 KB)", 56, .deploying, nil),
            (3.0, "↗ stellar.\(key.network == .testnet ? "testnet" : "mainnet")  · uploading wasm", 72, nil, nil),
            (3.7, "↗ stellar.\(key.network == .testnet ? "testnet" : "mainnet")  · invoking deploy", 88, nil, nil),
            (4.4, "✓ Deployed", 100, .done, randomCAddr()),
        ]
        for ev in plan {
            DispatchQueue.main.asyncAfter(deadline: .now() + ev.t) {
                logs.append(ev.log)
                progress = ev.p
                if let s = ev.stage { stage = s }
                if let a = ev.addr { deployedAddr = a }
            }
        }
    }

    private func randomCAddr() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ234567")
        return "C" + String((0..<55).map { _ in alphabet.randomElement()! })
    }

    private func open(_ s: String) {
        guard let u = URL(string: s) else { return }
        UIApplication.shared.open(u)
    }
}
