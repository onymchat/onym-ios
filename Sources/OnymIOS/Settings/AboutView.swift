import SwiftUI

/// Settings → About Onym. Hero (5-tap mark spins as a small easter
/// egg), version metadata, and Resources/Help/Legal cards linking to
/// `github.com/onymchat`.
struct AboutView: View {
    @State private var taps = 0

    private static let sourceURL  = URL(string: "https://github.com/onymchat/onym-ios")!
    private static let docsURL    = URL(string: "https://docs.onym.app")!
    private static let supportURL = URL(string: "mailto:hello@onym.app")!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero

                SettingsSectionLabel("VERSION")
                SettingsCard {
                    SettingsRow(title: "Version", hasChevron: false, inset: 16) {
                        EmptyView()
                    } right: {
                        Text(version).foregroundStyle(OnymTokens.text2)
                    }
                    SettingsRow(title: "Build", hasChevron: false, inset: 16) {
                        EmptyView()
                    } right: {
                        Text(build)
                            .font(.system(size: 13.5, design: .monospaced))
                            .foregroundStyle(OnymTokens.text2)
                    }
                    SettingsRow(
                        title: "Check for updates",
                        last: true,
                        onTap: { open(Self.sourceURL.absoluteString + "/releases") }
                    ) {
                        SettingsIconTile(symbol: "arrow.up.circle.fill", bg: SettingsTile.blue)
                    }
                }

                SettingsSectionLabel("RESOURCES")
                SettingsCard {
                    SettingsRow(
                        title: "Source code",
                        subtitle: "github.com/onymchat/onym-ios",
                        subtitleMono: true,
                        hasChevron: false,
                        onTap: { open(Self.sourceURL.absoluteString) }
                    ) {
                        SettingsIconTile(symbol: "chevron.left.forwardslash.chevron.right",
                                         bg: OnymTokens.text)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                    .accessibilityIdentifier("about.source_row")

                    SettingsRow(
                        title: "Documentation",
                        subtitle: "docs.onym.app",
                        hasChevron: false,
                        onTap: { open(Self.docsURL.absoluteString) }
                    ) {
                        SettingsIconTile(symbol: "doc.text.fill", bg: SettingsTile.indigo)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }

                    SettingsRow(
                        title: "Whitepaper",
                        subtitle: "The Onym protocol",
                        hasChevron: false,
                        onTap: { open("https://onym.app/whitepaper") }
                    ) {
                        SettingsIconTile(symbol: "sparkles", bg: SettingsTile.green)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }

                    SettingsRow(
                        title: "Changelog",
                        subtitle: "What’s new",
                        last: true,
                        onTap: { open(Self.sourceURL.absoluteString + "/releases") }
                    ) {
                        SettingsIconTile(symbol: "list.star", bg: SettingsTile.purple)
                    }
                }

                SettingsSectionLabel("HELP")
                SettingsCard {
                    SettingsRow(
                        title: "FAQ",
                        hasChevron: false,
                        onTap: { open(Self.docsURL.absoluteString + "/faq") }
                    ) {
                        SettingsIconTile(symbol: "questionmark.circle.fill",
                                         bg: SettingsTile.blue)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                    SettingsRow(
                        title: "Community chat",
                        subtitle: "Join the dev group on Onym",
                        hasChevron: false,
                        onTap: { open("https://onym.app/community") }
                    ) {
                        SettingsIconTile(symbol: "bubble.left.fill", bg: SettingsTile.green)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                    SettingsRow(
                        title: "Contact support",
                        subtitle: "hello@onym.app",
                        hasChevron: false,
                        last: true,
                        onTap: { open(Self.supportURL.absoluteString) }
                    ) {
                        SettingsIconTile(symbol: "envelope.fill", bg: SettingsTile.orange)
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                }

                SettingsSectionLabel("LEGAL")
                SettingsCard {
                    SettingsRow(title: "Privacy policy",
                                hasChevron: false, inset: 16,
                                onTap: { open("https://onym.app/privacy") }) {
                        EmptyView()
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                    SettingsRow(title: "Terms of service",
                                hasChevron: false, inset: 16,
                                onTap: { open("https://onym.app/terms") }) {
                        EmptyView()
                    } right: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(OnymTokens.text3)
                    }
                    SettingsRow(title: "Open source licenses",
                                inset: 16, last: true,
                                onTap: { open(Self.sourceURL.absoluteString + "/blob/main/LICENSE") }) {
                        EmptyView()
                    }
                }

                VStack(spacing: 12) {
                    OnymMark(size: 22, color: OnymTokens.text3)
                    Text("Built by people who think privacy is a right.\nReleased under the MIT license.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnymTokens.text3)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                    Text("© 2026 · Onym Foundation")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OnymTokens.text3.opacity(0.6))
                    if taps >= 5 {
                        Text("🎉 Hello, builder. Want to contribute?")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(LinearGradient(colors: [OnymAccent.purple.color,
                                                                  OnymAccent.blue.color],
                                                        startPoint: .leading, endPoint: .trailing),
                                         in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
                .padding(.bottom, 16)
            }
            .padding(.bottom, 24)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(spacing: 4) {
            Button { taps += 1 } label: {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.106, green: 0.122, blue: 0.141),
                                                    Color(red: 0.051, green: 0.067, blue: 0.090)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 104, height: 104)
                    .overlay(OnymMark(size: 64, color: .white, spinning: taps >= 5))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .accessibilityIdentifier("about.mark")

            Text("Onym")
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(OnymTokens.text)
                .padding(.top, 18)
            Text("open · anonymous · onchain")
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .tracking(0.26)
                .padding(.top, 4)
            HStack(spacing: 6) {
                Text("Up to date")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(OnymTokens.green.opacity(0.14), in: Capsule())
                    .foregroundStyle(OnymTokens.green)
                Text("·").font(.system(size: 12)).foregroundStyle(OnymTokens.text3)
                Text("\(version) (\(build))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OnymTokens.text2)
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 28)
    }

    private func open(_ s: String) {
        guard let u = URL(string: s) else { return }
        UIApplication.shared.open(u)
    }
}
