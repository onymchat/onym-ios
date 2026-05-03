import SwiftUI

/// Settings → Appearance. Theme cards, accent dots, font picker,
/// text-size slider, bubble previews, reduce-motion. Persists choices
/// to `@AppStorage` — wiring them into the rest of the app's
/// view-model layer (root tint, message bubble shape) lands in a
/// follow-up PR; this scaffold lets the design surfaces breathe.
struct AppearanceView: View {
    @AppStorage("settings.appearance.theme")        private var theme = "system"
    @AppStorage("settings.appearance.accent")       private var accent = OnymAccent.blue.rawValue
    @AppStorage("settings.appearance.font")         private var font = "system"
    @AppStorage("settings.appearance.textSize")     private var textSize = 2
    @AppStorage("settings.appearance.bubble")       private var bubble = "rounded"
    @AppStorage("settings.appearance.reduceMotion") private var reduceMotion = false

    private let themes = ["light", "dark", "system"]
    private let bubbleStyles = ["rounded", "square"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Appearance")

                SettingsSectionLabel("THEME")
                themeRow.padding(.horizontal, 16)

                SettingsSectionLabel("ACCENT COLOR")
                SettingsCard {
                    HStack(spacing: 12) {
                        ForEach(OnymAccent.allCases) { a in
                            Button { accent = a.rawValue } label: {
                                ZStack {
                                    Circle().fill(a.color).frame(width: 36, height: 36)
                                    if accent == a.rawValue {
                                        Circle().stroke(OnymTokens.surface2, lineWidth: 2)
                                            .frame(width: 36, height: 36)
                                        Circle().stroke(a.color, lineWidth: 2)
                                            .frame(width: 42, height: 42)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("appearance.accent.\(a.rawValue)")
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                SettingsFootnote("Used for buttons, links, and active states throughout the app.")

                SettingsSectionLabel("TEXT")
                SettingsCard {
                    SettingsRow(
                        title: "Font",
                        inset: 16,
                        onTap: { font = nextFont(font) }
                    ) {
                        EmptyView()
                    } right: {
                        Text(fontLabel(font))
                            .foregroundStyle(OnymTokens.text2)
                            .font(.system(size: 14))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text size")
                                .font(.system(size: 16.5))
                                .foregroundStyle(OnymTokens.text)
                            Spacer()
                            Text(["Smallest","Small","Default","Large","Largest"][textSize])
                                .font(.system(size: 13))
                                .foregroundStyle(OnymTokens.text2)
                        }
                        textSizeSlider
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)

                    SettingsRowDivider(inset: 0)

                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(fontPreview)
                        .foregroundStyle(OnymTokens.text2)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OnymTokens.surface3)
                }

                SettingsSectionLabel("CHATS")
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bubble style")
                            .font(.system(size: 16.5))
                            .foregroundStyle(OnymTokens.text)
                        HStack(spacing: 10) {
                            ForEach(bubbleStyles, id: \.self) { b in
                                Button { bubble = b } label: { bubblePreview(b) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("appearance.bubble.\(b)")
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }

                SettingsSectionLabel("ACCESSIBILITY")
                SettingsCard {
                    SettingsRow(
                        title: "Reduce motion",
                        subtitle: "Disable transitions and animated avatars",
                        hasChevron: false,
                        last: true
                    ) {
                        SettingsIconTile(symbol: "tortoise.fill", bg: SettingsTile.gray)
                    } right: {
                        Toggle("", isOn: $reduceMotion)
                            .labelsHidden()
                            .tint(OnymTokens.green)
                            .accessibilityIdentifier("appearance.reduce_motion")
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Theme cards

    private var themeRow: some View {
        HStack(spacing: 10) {
            ForEach(themes, id: \.self) { t in
                Button { theme = t } label: { themeCard(t) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("appearance.theme.\(t)")
            }
        }
    }

    private func themeCard(_ t: String) -> some View {
        let sel = theme == t
        let bg: AnyShapeStyle = {
            switch t {
            case "light":  return AnyShapeStyle(Color.white)
            case "dark":   return AnyShapeStyle(Color(red: 0.110, green: 0.110, blue: 0.118))
            default:       return AnyShapeStyle(LinearGradient(
                colors: [.white, Color(red: 0.110, green: 0.110, blue: 0.118)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }()
        let fg: Color = t == "dark" ? .white : OnymTokens.text
        return VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(bg)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(sel ? OnymAccent.blue.color : OnymTokens.hairlineStrong,
                                lineWidth: sel ? 2.5 : 1))
                    .frame(height: 110)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        OnymMark(size: 14, color: fg)
                        Capsule().fill(fg.opacity(0.18)).frame(height: 4)
                    }
                    VStack(spacing: 4) {
                        Capsule().fill(fg.opacity(0.5)).frame(width: 60, height: 3)
                        Capsule().fill(fg.opacity(0.25))
                            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 3)
                        Capsule().fill(fg.opacity(0.25)).frame(width: 40, height: 3)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(t == "dark"
                                ? Color(red: 0.173, green: 0.173, blue: 0.180)
                                : (t == "system"
                                   ? Color.gray.opacity(0.18)
                                   : Color(red: 0.949, green: 0.949, blue: 0.957)),
                                in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(10)
            }
            Text(t.capitalized)
                .font(.system(size: 13, weight: sel ? .semibold : .medium))
                .foregroundStyle(sel ? OnymAccent.blue.color : OnymTokens.text)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Text-size slider

    private var textSizeSlider: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(OnymTokens.surface3).frame(height: 2)
                Capsule().fill(OnymAccent.blue.color)
                    .frame(width: max(0, CGFloat(textSize) * geo.size.width / 4), height: 2)
                HStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { i in
                        Button { textSize = i } label: {
                            Circle()
                                .fill(i == textSize ? OnymTokens.surface2 : Color.clear)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().fill(i <= textSize
                                                       ? OnymAccent.blue.color
                                                       : OnymTokens.text3.opacity(0.4))
                                    .frame(width: 8, height: 8))
                                .shadow(color: i == textSize ? .black.opacity(0.18) : .clear,
                                        radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        if i < 4 { Spacer() }
                    }
                }
            }
        }
        .frame(height: 28)
    }

    private var fontPreview: Font {
        let pt: CGFloat = 12 + CGFloat(textSize) * 1.5
        switch font {
        case "mono":  return .system(size: pt, design: .monospaced)
        case "serif": return .system(size: pt, design: .serif)
        default:      return .system(size: pt)
        }
    }

    private func fontLabel(_ id: String) -> String {
        switch id {
        case "mono":  return "Mono everywhere"
        case "serif": return "New York"
        default:      return "San Francisco"
        }
    }

    private func nextFont(_ id: String) -> String {
        switch id {
        case "system": return "mono"
        case "mono":   return "serif"
        default:       return "system"
        }
    }

    // MARK: - Bubble preview

    private func bubblePreview(_ b: String) -> some View {
        let sel = bubble == b
        let radius: CGFloat = b == "rounded" ? 18 : 6
        return VStack(alignment: .leading, spacing: 6) {
            Text("Hi there")
                .font(.system(size: 11))
                .foregroundStyle(OnymTokens.text)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(OnymTokens.surface3,
                            in: RoundedRectangle(cornerRadius: radius))
            Text("Hey!")
                .font(.system(size: 11))
                .foregroundStyle(OnymTokens.onAccent)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(OnymAccent.blue.color,
                            in: RoundedRectangle(cornerRadius: radius))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(b.capitalized)
                .font(.system(size: 12.5, weight: sel ? .semibold : .medium))
                .foregroundStyle(sel ? OnymAccent.blue.color : OnymTokens.text2)
        }
        .padding(12)
        .background(OnymTokens.surface3, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(sel ? OnymAccent.blue.color : OnymTokens.hairlineStrong,
                    lineWidth: sel ? 1.5 : 1))
        .frame(maxWidth: .infinity)
    }
}
