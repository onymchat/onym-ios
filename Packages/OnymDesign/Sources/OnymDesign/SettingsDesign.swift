import SwiftUI
import OnymDesignTokens

// MARK: - Section / row / card primitives shared by the Settings tree
//
// Reuses `OnymTokens` (theme-adaptive surface + text) and `OnymMark`
// from `Group/OnymBrand.swift`. These atoms render the Apple-Settings
// shape the design calls for: rounded white card, square coloured icon
// tile, label/value rows separated by an inset hairline, big bold large
// title with a `.ultraThinMaterial` condensed bar on scroll.
//
// The tile palette that used to live here is now `OnymTile` in
// OnymDesignTokens — it was a token family sitting in a component file.

/// Square-rounded coloured tile. SF symbol over the fill colour.
public struct IconTile: View {
    let symbol: String
    let bg: Color
    var weight: Font.Weight = .semibold

    /// The tile grows with the reader's text size, but not all the way.
    ///
    /// A tile pinned at 30pt beside 46pt type looks like a bug — the row
    /// stops reading as one thing. Growing it on the full curve is worse
    /// the other way: a 2.8× tile is 85pt of decoration crowding out the
    /// words it decorates. `@ScaledMetric` moves it with the text and
    /// the cap keeps it a tile.
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 30
    private var size: CGFloat { min(scaledSize, 46) }

    // `weight` has no external consumer today, so the public init omits
    // it (it keeps its internal default).
    public init(symbol: String, bg: Color) {
        self.symbol = symbol
        self.bg = bg
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: OnymRadius.tile, style: .continuous)
            .fill(bg)
            .frame(width: size, height: size)
            .overlay(
                // Sized off the tile, so the glyph tracks whatever the
                // tile settled on rather than the reader's setting.
                Image(systemName: symbol)
                    .font(OnymType.fixed(size: size * 0.5, weight: weight))
                    .foregroundStyle(OnymTokens.onTile)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnymRadius.tile, style: .continuous)
                    .stroke(OnymTokens.onTile.opacity(0.18), lineWidth: 0.5)
            )
    }
}

/// Tile that renders arbitrary content (a custom glyph, a 2-letter
/// code, a star button, etc.) over the same coloured fill.
public struct SettingsContentTile<Content: View>: View {
    let bg: Color
    @ViewBuilder var content: () -> Content

    /// Tracks `IconTile` — same tile, arbitrary content inside it.
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 30
    private var size: CGFloat { min(scaledSize, 46) }

    public init(bg: Color, @ViewBuilder content: @escaping () -> Content) {
        self.bg = bg
        self.content = content
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: OnymRadius.tile, style: .continuous)
            .fill(bg)
            .frame(width: size, height: size)
            .overlay(content().foregroundStyle(OnymTokens.onTile))
            .overlay(
                RoundedRectangle(cornerRadius: OnymRadius.tile, style: .continuous)
                    .stroke(OnymTokens.onTile.opacity(0.18), lineWidth: 0.5)
            )
    }
}

/// Section label above a card. All-caps, mid-grey, small letterspacing.
public struct SectionLabel<Trailing: View>: View {
    let text: LocalizedStringKey
    /// Runtime data rather than UI copy — see `Row.verbatimTitle`.
    var verbatimText: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    // The trailing-content variant has no external consumer today, so
    // only the text-only convenience init (below) is public.
    init(_ text: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing
    }

    init(verbatimText: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.text = ""
        self.verbatimText = verbatimText
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .bottom) {
            (verbatimText.map { Text(verbatim: $0) } ?? Text(text))
                .font(OnymType.font(size: 12.5, weight: .medium))
                .foregroundStyle(OnymTokens.text2)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

extension SectionLabel where Trailing == EmptyView {
    public init(_ text: LocalizedStringKey) {
        self.init(text, trailing: { EmptyView() })
    }

    /// Label from runtime data (e.g. an authority-supplied class id).
    public init(verbatim text: String) {
        self.init(verbatimText: text, trailing: { EmptyView() })
    }
}

/// Footnote text beneath a card — italic-equivalent grey copy used as
/// section explanations.
public struct Footnote: View {
    let text: LocalizedStringKey
    /// Runtime data rather than UI copy — see `Row.verbatimTitle`.
    var verbatimText: String? = nil
    public init(_ text: LocalizedStringKey) { self.text = text }
    /// Footnote from runtime data (e.g. an already-localized error
    /// message, which must not be re-looked-up as a key).
    public init(verbatim text: String) {
        self.text = ""
        self.verbatimText = text
    }
    public var body: some View {
        (verbatimText.map { Text(verbatim: $0) } ?? Text(text))
            .font(OnymType.font(size: 12.5))
            .foregroundStyle(OnymTokens.text2)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }
}

/// Settings large title. Renders the same 34pt bold heading the design
/// shows beneath the nav bar on each top-level screen.
public struct LargeTitle: View {
    let text: LocalizedStringKey
    /// Runtime data rather than UI copy — see `Row.verbatimTitle`.
    var verbatimText: String? = nil
    public init(_ text: LocalizedStringKey) { self.text = text }
    /// Title from runtime data (e.g. an authority's published name).
    public init(verbatim text: String) {
        self.text = ""
        self.verbatimText = text
    }
    public var body: some View {
        (verbatimText.map { Text(verbatim: $0) } ?? Text(text))
            .font(OnymType.font(size: 34, weight: .bold))
            .foregroundStyle(OnymTokens.text)
            .tracking(-0.75)
            // At the largest sizes 34pt becomes 96pt and a single word
            // like "Settings" is wider than the screen, so it breaks
            // mid-word — "Setting" above a lonely "s". Shrinking a title
            // that is already enormous costs the reader nothing;
            // hyphenating their own app's name costs them a moment of
            // confusion every time they open it.
            //
            // The line limit is what makes the scale factor work at all:
            // given unlimited lines SwiftUI wraps rather than shrinks,
            // and wrapping is the thing being avoided. Two lines leaves
            // room for a longer title to breathe before it scales.
            .lineLimit(2)
            .minimumScaleFactor(0.55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)
    }
}

/// White rounded card surface used for grouped rows. 14pt corner
/// radius, full-bleed inside the page's 16pt horizontal padding.
public struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
    public var body: some View {
        VStack(spacing: 0) { content() }
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: OnymRadius.card, style: .continuous))
            .padding(.horizontal, 16)
    }
}

/// Swipe-to-delete wrapper for one card row (iOS Mail style). Dragging
/// the row left reveals a red Delete action; tapping it confirms — the
/// swipe alone destroys nothing, so there's no accidental single-tap
/// delete. Place inside a rounded, clipped container so the reveal is
/// masked to the card's corners; the row content carries the card's
/// opaque background so the action stays hidden until the row slides.
///
/// Coexists with an enclosing ScrollView: the drag is only tracked once
/// it's clearly horizontal, and it uses default (not high) priority, so
/// vertical drags fall through to the scroll view.
public struct SwipeToDeleteRow<Content: View>: View {
    var deleteLabel: LocalizedStringKey = "Delete"
    var accessibilityID: String? = nil
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    // `deleteLabel` has no external consumer today; the public init
    // omits it (keeps the "Delete" default).
    public init(
        accessibilityID: String? = nil,
        onDelete: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibilityID = accessibilityID
        self.onDelete = onDelete
        self.content = content
    }

    @State private var offset: CGFloat = 0
    @State private var startedHorizontal: Bool?
    private let revealWidth: CGFloat = 96

    public var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: confirmDelete) {
                VStack(spacing: 3) {
                    Image(systemName: "trash.fill").font(OnymType.fixed(size: 16, weight: .semibold))
                    Text(deleteLabel).font(OnymType.fixed(size: 11, weight: .semibold))
                }
                .foregroundStyle(OnymTokens.onTile)
                .frame(width: revealWidth)
                .frame(maxHeight: .infinity)
                .background(OnymTokens.red)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityID.map { "\($0).delete" } ?? "swipe.delete")

            content()
                .background(OnymTokens.surface2)
                .offset(x: offset)
                .gesture(dragGesture)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                if startedHorizontal == nil {
                    startedHorizontal = abs(value.translation.width) > abs(value.translation.height)
                }
                guard startedHorizontal == true else { return }
                let base: CGFloat = offset <= -revealWidth ? -revealWidth : 0
                offset = min(0, max(-revealWidth, base + value.translation.width))
            }
            .onEnded { value in
                defer { startedHorizontal = nil }
                guard startedHorizontal == true else { return }
                let shouldOpen = value.translation.width < -revealWidth / 2
                    || (offset < 0 && value.translation.width < 20)
                withAnimation(.snappy(duration: 0.22)) { offset = shouldOpen ? -revealWidth : 0 }
            }
    }

    private func confirmDelete() {
        withAnimation(.snappy(duration: 0.2)) { offset = 0 }
        onDelete()
    }
}

/// Inset hairline used between rows inside a card.
public struct SettingsRowDivider: View {
    var inset: CGFloat = 60
    public init(inset: CGFloat = 60) { self.inset = inset }
    public var body: some View {
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
public struct Row<Tile: View, Right: View>: View {
    let title: LocalizedStringKey
    /// Set instead of `title` when the text is runtime data (a name
    /// fetched from the network, an identifier) rather than UI copy.
    /// Such a string must not be looked up as a localization key — a
    /// remote value that happens to match one would render the
    /// translation instead of itself.
    var verbatimTitle: String? = nil
    var titleColor: Color = OnymTokens.text
    var titleMono: Bool = false
    var subtitle: String? = nil
    var subtitleMono: Bool = false
    /// Subtitle line cap. `1` (default) middle-truncates on overflow;
    /// pass `nil` to let a longer subtitle wrap freely.
    var subtitleLineLimit: Int? = 1
    var hasChevron: Bool = true
    var inset: CGFloat = 60
    var last: Bool = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder var tile: () -> Tile
    @ViewBuilder var right: () -> Right

    public init(
        title: LocalizedStringKey,
        titleColor: Color = OnymTokens.text,
        titleMono: Bool = false,
        subtitle: String? = nil,
        subtitleMono: Bool = false,
        subtitleLineLimit: Int? = 1,
        hasChevron: Bool = true,
        inset: CGFloat = 60,
        last: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder tile: @escaping () -> Tile,
        @ViewBuilder right: @escaping () -> Right
    ) {
        self.title = title
        self.titleColor = titleColor
        self.titleMono = titleMono
        self.subtitle = subtitle
        self.subtitleMono = subtitleMono
        self.subtitleLineLimit = subtitleLineLimit
        self.hasChevron = hasChevron
        self.inset = inset
        self.last = last
        self.onTap = onTap
        self.tile = tile
        self.right = right
    }

    /// Row whose title is runtime data rather than UI copy — rendered
    /// verbatim, never looked up as a localization key. Distinct
    /// argument label (not an overload on `title:`) so a string literal
    /// can't silently resolve to the wrong initializer.
    public init(
        titleText: String,
        titleColor: Color = OnymTokens.text,
        titleMono: Bool = false,
        subtitle: String? = nil,
        subtitleMono: Bool = false,
        subtitleLineLimit: Int? = 1,
        hasChevron: Bool = true,
        inset: CGFloat = 60,
        last: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder tile: @escaping () -> Tile,
        @ViewBuilder right: @escaping () -> Right
    ) {
        self.title = ""
        self.verbatimTitle = titleText
        self.titleColor = titleColor
        self.titleMono = titleMono
        self.subtitle = subtitle
        self.subtitleMono = subtitleMono
        self.subtitleLineLimit = subtitleLineLimit
        self.hasChevron = hasChevron
        self.inset = inset
        self.last = last
        self.onTap = onTap
        self.tile = tile
        self.right = right
    }

    public var body: some View {
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
                    (verbatimTitle.map { Text(verbatim: $0) } ?? Text(title))
                        .font(titleMono
                              ? OnymType.mono(size: 16.5)
                              : OnymType.font(size: 16.5))
                        .foregroundStyle(titleColor)
                        // A mono title is a key or a URL and truncates
                        // on purpose. A prose one is a label the reader
                        // came for, and gives way at accessibility sizes.
                        .onymLineLimit(1, relaxing: !titleMono)
                    if let subtitle {
                        Text(subtitle)
                            .font(subtitleMono
                                  ? OnymType.mono(size: 12.5)
                                  : OnymType.font(size: 12.5))
                            .foregroundStyle(OnymTokens.text2)
                            .lineLimit(subtitleLineLimit)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                right()
                if hasChevron {
                    Image(systemName: "chevron.right")
                        .font(OnymType.font(size: 12, weight: .semibold))
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

extension Row where Right == EmptyView {
    public init(
        title: LocalizedStringKey,
        titleColor: Color = OnymTokens.text,
        titleMono: Bool = false,
        subtitle: String? = nil,
        subtitleMono: Bool = false,
        subtitleLineLimit: Int? = 1,
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
        self.subtitleLineLimit = subtitleLineLimit
        self.hasChevron = hasChevron
        self.inset = inset
        self.last = last
        self.onTap = onTap
        self.tile = tile
        self.right = { EmptyView() }
    }

    /// Tile-only row whose title is runtime data — see the
    /// `titleText:` initializer on `Row`.
    public init(
        titleText: String,
        titleColor: Color = OnymTokens.text,
        titleMono: Bool = false,
        subtitle: String? = nil,
        subtitleMono: Bool = false,
        subtitleLineLimit: Int? = 1,
        hasChevron: Bool = true,
        inset: CGFloat = 60,
        last: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder tile: @escaping () -> Tile
    ) {
        self.title = ""
        self.verbatimTitle = titleText
        self.titleColor = titleColor
        self.titleMono = titleMono
        self.subtitle = subtitle
        self.subtitleMono = subtitleMono
        self.subtitleLineLimit = subtitleLineLimit
        self.hasChevron = hasChevron
        self.inset = inset
        self.last = last
        self.onTap = onTap
        self.tile = tile
        self.right = { EmptyView() }
    }
}

/// Small uppercase chip used for TESTNET / PUBLIC etc. on relayer rows.
public struct Chip: View {
    let text: String
    let fg: Color
    let bg: Color

    public init(text: String, fg: Color, bg: Color) {
        self.text = text
        self.fg = fg
        self.bg = bg
    }

    public var body: some View {
        Text(text)
            .font(OnymType.font(size: 9.5, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: OnymRadius.chip))
            .foregroundStyle(fg)
    }
}

/// Pill button used for the in-card Copy/Share split actions.
public struct TextButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var foreground: Color = OnymTokens.text
    let action: () -> Void

    public init(
        title: LocalizedStringKey,
        systemImage: String,
        foreground: Color = OnymTokens.text,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.foreground = foreground
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title).font(OnymType.font(size: 15, weight: .medium))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

/// Primary CTA used for Continue / Build & Deploy / Verify etc. Same
/// dimensions as the design's `PrimaryButton`.
public struct PrimaryButton<Label: View>: View {
    var disabled: Bool = false
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    public init(
        disabled: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.disabled = disabled
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            label()
                .font(OnymType.font(size: 16, weight: .semibold))
                .foregroundStyle(OnymTokens.onAccent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(disabled
                            ? OnymAccent.blue.color.opacity(0.45)
                            : OnymAccent.blue.color,
                            in: RoundedRectangle(cornerRadius: OnymRadius.card, style: .continuous))
        }
        .disabled(disabled)
    }
}

extension PrimaryButton where Label == Text {
    public init(_ text: LocalizedStringKey, disabled: Bool = false, action: @escaping () -> Void) {
        self.disabled = disabled
        self.action = action
        self.label = { Text(text) }
    }
}

/// Step indicator for multi-step flows (backup, onboarding). Active
/// dot expands into a 22pt capsule; visited dots stay filled at 6pt.
public struct StepIndicator: View {
    let step: Int
    var count: Int = 3

    public init(step: Int, count: Int = 3) {
        self.step = step
        self.count = count
    }

    public var body: some View {
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
public struct IdentityRingTile: View {
    var active: Bool = false
    var size: CGFloat = 36

    public init(active: Bool = false, size: CGFloat = 36) {
        self.active = active
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(active ? OnymTint.stepActive : OnymTokens.surface3)
            .frame(width: size, height: size)
            .overlay(OnymMark(size: size * 0.55,
                               color: active ? OnymAccent.blue.color : OnymTile.gray,
                               strokeRatio: 0.18))
            .overlay(Circle().stroke(active ? OnymAccent.blue.color : .clear, lineWidth: 1.5))
    }
}
