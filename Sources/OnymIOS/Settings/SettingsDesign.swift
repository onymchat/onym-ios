import SwiftUI

// MARK: - Section / row / card primitives shared by the Settings tree
//
// Reuses `OnymTokens` (theme-adaptive surface + text) and `OnymMark`
// from `Group/OnymBrand.swift`. These atoms render the Apple-Settings
// shape the design calls for: rounded white card, square coloured icon
// tile, label/value rows separated by an inset hairline, big bold large
// title with a `.ultraThinMaterial` condensed bar on scroll.

enum SettingsTile {
    /// Apple-Settings palette used for the icon tiles. Each maps to a
    /// pinned RGB value from the design's `S.tile.*` table.
    static let purple = Color(red: 160/255, green: 76/255,  blue: 224/255) // #A04CE0
    static let blue   = Color(red: 10/255,  green: 132/255, blue: 255/255) // #0A84FF
    static let indigo = Color(red: 91/255,  green: 91/255,  blue: 226/255) // #5B5BE2
    static let orange = Color(red: 255/255, green: 122/255, blue: 45/255)  // #FF7A2D
    static let green  = Color(red: 48/255,  green: 180/255, blue: 90/255)  // #30B45A
    static let gray   = Color(red: 142/255, green: 142/255, blue: 147/255) // #8E8E93
    static let red    = Color(red: 229/255, green: 57/255,  blue: 46/255)  // #E5392E
    static let teal   = Color(red: 43/255,  green: 179/255, blue: 207/255) // #2BB3CF
    static let amber  = Color(red: 255/255, green: 149/255, blue: 0/255)   // #FF9500
}

/// Square-rounded coloured tile. SF symbol over the fill colour.
struct SettingsIconTile: View {
    let symbol: String
    let bg: Color
    var size: CGFloat = 30
    var weight: Font.Weight = .semibold

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(bg)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: weight))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
            )
    }
}

/// Tile that renders arbitrary content (a custom glyph, a 2-letter
/// code, a star button, etc.) over the same coloured fill.
struct SettingsContentTile<Content: View>: View {
    let bg: Color
    var size: CGFloat = 30
    @ViewBuilder var content: () -> Content

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(bg)
            .frame(width: size, height: size)
            .overlay(content().foregroundStyle(.white))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
            )
    }
}

/// Section label above a card. All-caps, mid-grey, small letterspacing.
struct SettingsSectionLabel<Trailing: View>: View {
    let text: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    init(_ text: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .bottom) {
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(OnymTokens.text2)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

extension SettingsSectionLabel where Trailing == EmptyView {
    init(_ text: LocalizedStringKey) {
        self.init(text, trailing: { EmptyView() })
    }
}

/// Footnote text beneath a card — italic-equivalent grey copy used as
/// section explanations.
struct SettingsFootnote: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(OnymTokens.text2)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }
}

/// Settings large title. Renders the same 34pt bold heading the design
/// shows beneath the nav bar on each top-level screen.
struct SettingsLargeTitle: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(OnymTokens.text)
            .tracking(-0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)
    }
}

/// White rounded card surface used for grouped rows. 14pt corner
/// radius, full-bleed inside the page's 16pt horizontal padding.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
    }
}

/// Inset hairline used between rows inside a card.
struct SettingsRowDivider: View {
    var inset: CGFloat = 60
    var body: some View {
        Rectangle()
            .fill(OnymTokens.hairlineStrong)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

/// Single Apple-Settings row. `tile` is the leading icon. `right` is
/// the trailing content (chips, value text, switches). The row is
/// pure layout — wrap it in a `NavigationLink` (push) or a `Button`
/// (in-place action) externally, or pass `onTap` for a built-in
/// Button. The chevron renders whenever `hasChevron` is true,
/// independent of `onTap`, because the wrapping `NavigationLink`
/// itself owns the tap.
struct SettingsRow<Tile: View, Right: View>: View {
    let title: LocalizedStringKey
    var titleColor: Color = OnymTokens.text
    var titleMono: Bool = false
    var subtitle: String? = nil
    var subtitleMono: Bool = false
    var hasChevron: Bool = true
    var inset: CGFloat = 60
    var last: Bool = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder var tile: () -> Tile
    @ViewBuilder var right: () -> Right

    var body: some View {
        if let onTap {
            // Tappable variant — used for in-place actions (Copy
            // public key, Set as active, …). Wrap in `NavigationLink`
            // or external `Button` for push navigation instead.
            Button(action: onTap) { rowBody }
                .buttonStyle(.plain)
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                tile()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(titleMono
                              ? .system(size: 16.5, design: .monospaced)
                              : .system(size: 16.5))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(subtitleMono
                                  ? .system(size: 12.5, design: .monospaced)
                                  : .system(size: 12.5))
                            .foregroundStyle(OnymTokens.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                right()
                if hasChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OnymTokens.text3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())

            if !last {
                SettingsRowDivider(inset: inset)
            }
        }
    }
}

extension SettingsRow where Right == EmptyView {
    init(
        title: LocalizedStringKey,
        titleColor: Color = OnymTokens.text,
        titleMono: Bool = false,
        subtitle: String? = nil,
        subtitleMono: Bool = false,
        hasChevron: Bool = true,
        inset: CGFloat = 60,
        last: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder tile: @escaping () -> Tile
    ) {
        self.title = title
        self.titleColor = titleColor
        self.titleMono = titleMono
        self.subtitle = subtitle
        self.subtitleMono = subtitleMono
        self.hasChevron = hasChevron
        self.inset = inset
        self.last = last
        self.onTap = onTap
        self.tile = tile
        self.right = { EmptyView() }
    }
}

/// Small uppercase chip used for TESTNET / PUBLIC etc. on relayer rows.
struct SettingsChip: View {
    let text: String
    let fg: Color
    let bg: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(fg)
    }
}

/// Pill button used for the in-card Copy/Share split actions.
struct SettingsTextButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var foreground: Color = OnymTokens.text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title).font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

/// Primary CTA used for Continue / Build & Deploy / Verify etc. Same
/// dimensions as the design's `PrimaryButton`.
struct SettingsPrimaryButton<Label: View>: View {
    var disabled: Bool = false
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnymTokens.onAccent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(disabled
                            ? OnymAccent.blue.color.opacity(0.45)
                            : OnymAccent.blue.color,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(disabled)
    }
}

extension SettingsPrimaryButton where Label == Text {
    init(_ text: LocalizedStringKey, disabled: Bool = false, action: @escaping () -> Void) {
        self.disabled = disabled
        self.action = action
        self.label = { Text(text) }
    }
}

/// Step indicator for the multi-step backup flow. Active dot expands
/// into a 22pt capsule; visited dots stay filled at 6pt.
struct SettingsStepIndicator: View {
    let step: Int
    var count: Int = 3
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? OnymAccent.blue.color : OnymTokens.text3.opacity(0.4))
                    .frame(width: i == step ? 22 : 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// Round identity tile with the broken-ring mark inside. Renders the
/// active highlight ring when `active` is true.
struct IdentityRingTile: View {
    var active: Bool = false
    var size: CGFloat = 36

    var body: some View {
        Circle()
            .fill(active
                  ? Color.dynamic(light: Color(red: 0.878, green: 0.933, blue: 0.996),
                                   dark: Color(red: 10/255, green: 132/255, blue: 255/255).opacity(0.18))
                  : OnymTokens.surface3)
            .frame(width: size, height: size)
            .overlay(OnymMark(size: size * 0.55,
                               color: active ? OnymAccent.blue.color : SettingsTile.gray,
                               strokeRatio: 0.18))
            .overlay(Circle().stroke(active ? OnymAccent.blue.color : .clear, lineWidth: 1.5))
    }
}
