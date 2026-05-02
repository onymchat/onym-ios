import SwiftUI

// MARK: - Tokens

/// Dark-theme design tokens for the Create Group flow. Mirrors the
/// tokens in the Claude Designed reference (`THEMES.dark` in
/// `app.jsx`). Light theme will land later — PR-C ships dark only.
enum OnymTokens {
    static let bg = Color(red: 0, green: 0, blue: 0)
    static let surface = Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255)
    static let surface2 = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x1A / 255)
    static let surface3 = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x23 / 255)
    static let text = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255)
    static let text2 = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255).opacity(0.62)
    static let text3 = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255).opacity(0.40)
    static let hairline = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.12)
    static let green = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let red = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
    /// Reads on accent fills.
    static let onAccent = Color.black
}

// MARK: - Accent palette

enum OnymAccent: String, CaseIterable, Identifiable, Sendable {
    case orange, blue, green, purple, pink, yellow

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .orange: Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0x45 / 255)
        case .blue:   Color(red: 0x3F / 255, green: 0xA8 / 255, blue: 0xFF / 255)
        case .green:  Color(red: 0x3D / 255, green: 0xD6 / 255, blue: 0x6E / 255)
        case .purple: Color(red: 0xB2 / 255, green: 0x78 / 255, blue: 0xFF / 255)
        case .pink:   Color(red: 0xFF / 255, green: 0x4D / 255, blue: 0x6D / 255)
        case .yellow: Color(red: 0xFF / 255, green: 0xC9 / 255, blue: 0x3C / 255)
        }
    }
}

// MARK: - OnymMark — broken-ring brand logo

/// The Onym brand mark: a broken/segmented ring with two narrow radial
/// gaps. The gaps suggest privacy/anonymity — the identity is whole
/// but never fully closed.
///
/// Implemented as a `Circle().stroke` with a dash pattern of
/// `[46, 4, 46, 4]` (% of circumference), then a `rotationEffect` to
/// align the gaps near 1:30 and 7:30 o'clock. Matches the SVG
/// reference in `app.jsx` (`OnymMark` component, dasharray `46 4 46 4`,
/// dashoffset `-25`).
struct OnymMark: View {
    var size: CGFloat = 32
    var color: Color = OnymTokens.text
    var strokeRatio: CGFloat = 0.16
    var spinning: Bool = false
    var fillOpacity: Double = 0.92

    @State private var rotation: Double = -90  // -90° lands the dash pattern's first gap near 1:30

    var body: some View {
        let stroke = size * strokeRatio
        let radius = (size - stroke) / 2
        let circumference = 2 * .pi * radius
        let arc = circumference * 0.46
        let gap = circumference * 0.04

        Circle()
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: stroke,
                    lineCap: .butt,
                    dash: [arc, gap, arc, gap]
                )
            )
            .opacity(fillOpacity)
            .frame(width: size - stroke, height: size - stroke)
            .padding(stroke / 2)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                guard spinning else { return }
                withAnimation(.linear(duration: 4.2).repeatForever(autoreverses: false)) {
                    rotation += 360
                }
            }
    }
}

// MARK: - Governance type (UI-side)

/// UI-side mirror of the design's three governance cards. Maps to
/// `SEPGroupType` for the actual chain call. PR-C only enables
/// `.tyranny` — the other two render with a "Soon" label and aren't
/// selectable.
enum OnymUIGovernance: String, CaseIterable, Identifiable, Sendable {
    case tyranny
    case oneOnOne = "dialog"
    case anarchy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tyranny: "Tyranny"
        case .oneOnOne: "1\u{2011}on\u{2011}1"  // non-breaking hyphens
        case .anarchy: "Anarchy"
        }
    }

    var sub: String {
        switch self {
        case .tyranny: "Single admin"
        case .oneOnOne: "Dialog"
        case .anarchy: "Open control"
        }
    }

    var oneLine: String {
        switch self {
        case .tyranny: "You control membership and settings."
        case .oneOnOne: "A private two-person conversation."
        case .anarchy: "Every member has the same control."
        }
    }

    var tooltip: String {
        switch self {
        case .tyranny: "Only the admin can manage this group."
        case .oneOnOne: "Exactly two people. No one else can join."
        case .anarchy: "Anyone can add, remove, or change settings."
        }
    }

    /// Per-PR-C scope: only Tyranny is wired to the chain layer.
    var isAvailable: Bool { self == .tyranny }

    var sepGroupType: SEPGroupType {
        switch self {
        case .tyranny: .tyranny
        case .oneOnOne: .oneOnOne
        case .anarchy: .anarchy
        }
    }
}

// MARK: - Governance icons

/// Small badge icons that go on each governance card. Three distinct
/// silhouettes: crown (admin), facing bubbles (dialog), nodes-in-ring
/// (anarchy). Implemented with SwiftUI `Path`/`Shape` rather than
/// SF symbols because the design uses custom artwork.
struct OnymGovIcon: View {
    let type: OnymUIGovernance
    let accent: Color
    var size: CGFloat = 44
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(strokeColor, lineWidth: 1.4 * size / 44)
                .opacity(0.5)
            Circle()
                .fill(strokeColor.opacity(0.14))
                .padding(size * 6 / 44)

            switch type {
            case .tyranny: tyrannyMark
            case .oneOnOne: dialogMark
            case .anarchy: anarchyMark
            }
        }
        .frame(width: size, height: size)
    }

    private var strokeColor: Color { dimmed ? OnymTokens.text3 : accent }

    private var tyrannyMark: some View {
        // Crown: filled chevron-y polygon + bar + dot, all in `accent`.
        ZStack {
            Path { path in
                let s = size
                path.move(to: CGPoint(x: s * 13/44, y: s * 24/44))
                path.addLine(to: CGPoint(x: s * 15/44, y: s * 17/44))
                path.addLine(to: CGPoint(x: s * 19/44, y: s * 21/44))
                path.addLine(to: CGPoint(x: s * 22/44, y: s * 15/44))
                path.addLine(to: CGPoint(x: s * 25/44, y: s * 21/44))
                path.addLine(to: CGPoint(x: s * 29/44, y: s * 17/44))
                path.addLine(to: CGPoint(x: s * 31/44, y: s * 24/44))
                path.closeSubpath()
            }
            .fill(strokeColor)

            RoundedRectangle(cornerRadius: 0.8 * size / 44)
                .fill(strokeColor)
                .frame(width: 18 * size / 44, height: 3 * size / 44)
                .position(x: 22 * size / 44, y: 27 * size / 44)

            Circle()
                .fill(dimmed ? OnymTokens.text3 : Color.white)
                .frame(width: 2.4 * size / 44, height: 2.4 * size / 44)
                .position(x: 22 * size / 44, y: 20 * size / 44)
        }
    }

    private var dialogMark: some View {
        ZStack {
            // Left bubble (filled accent)
            Path { path in
                let s = size
                path.move(to: CGPoint(x: s * 9/44, y: s * 17/44))
                path.addQuadCurve(to: CGPoint(x: s * 12/44, y: s * 14/44), control: CGPoint(x: s * 9/44, y: s * 14/44))
                path.addLine(to: CGPoint(x: s * 19/44, y: s * 14/44))
                path.addQuadCurve(to: CGPoint(x: s * 22/44, y: s * 17/44), control: CGPoint(x: s * 22/44, y: s * 14/44))
                path.addLine(to: CGPoint(x: s * 22/44, y: s * 20/44))
                path.addQuadCurve(to: CGPoint(x: s * 19/44, y: s * 23/44), control: CGPoint(x: s * 22/44, y: s * 23/44))
                path.addLine(to: CGPoint(x: s * 16/44, y: s * 23/44))
                path.addLine(to: CGPoint(x: s * 13/44, y: s * 26/44))
                path.addLine(to: CGPoint(x: s * 13/44, y: s * 23/44))
                path.addLine(to: CGPoint(x: s * 12/44, y: s * 23/44))
                path.addQuadCurve(to: CGPoint(x: s * 9/44, y: s * 20/44), control: CGPoint(x: s * 9/44, y: s * 23/44))
                path.closeSubpath()
            }
            .fill(strokeColor)

            // Right bubble (translucent accent)
            Path { path in
                let s = size
                path.move(to: CGPoint(x: s * 35/44, y: s * 22/44))
                path.addQuadCurve(to: CGPoint(x: s * 32/44, y: s * 19/44), control: CGPoint(x: s * 35/44, y: s * 19/44))
                path.addLine(to: CGPoint(x: s * 25/44, y: s * 19/44))
                path.addQuadCurve(to: CGPoint(x: s * 22/44, y: s * 22/44), control: CGPoint(x: s * 22/44, y: s * 19/44))
                path.addLine(to: CGPoint(x: s * 22/44, y: s * 25/44))
                path.addQuadCurve(to: CGPoint(x: s * 25/44, y: s * 28/44), control: CGPoint(x: s * 22/44, y: s * 28/44))
                path.addLine(to: CGPoint(x: s * 28/44, y: s * 28/44))
                path.addLine(to: CGPoint(x: s * 31/44, y: s * 31/44))
                path.addLine(to: CGPoint(x: s * 31/44, y: s * 28/44))
                path.addLine(to: CGPoint(x: s * 32/44, y: s * 28/44))
                path.addQuadCurve(to: CGPoint(x: s * 35/44, y: s * 25/44), control: CGPoint(x: s * 35/44, y: s * 28/44))
                path.closeSubpath()
            }
            .fill(strokeColor.opacity(0.55))
        }
    }

    private var anarchyMark: some View {
        // Five nodes in a ring with light edges between every pair.
        let count = 5
        let nodes: [CGPoint] = (0..<count).map { i in
            let a = (Double(i) / Double(count)) * .pi * 2 - .pi / 2
            return CGPoint(
                x: 22 * size / 44 + cos(a) * 10 * size / 44,
                y: 22 * size / 44 + sin(a) * 10 * size / 44
            )
        }
        return ZStack {
            // Edges
            Path { path in
                for i in 0..<count {
                    for j in (i + 1)..<count {
                        path.move(to: nodes[i])
                        path.addLine(to: nodes[j])
                    }
                }
            }
            .stroke(strokeColor.opacity(0.45), lineWidth: 0.9 * size / 44)

            // Nodes
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(strokeColor)
                    .frame(width: 5.2 * size / 44, height: 5.2 * size / 44)
                    .position(nodes[i])
            }
        }
    }
}

// MARK: - Group avatar (Onym mark as upload placeholder)

/// Avatar slot. In this prototype the user never uploads an image, so
/// the slot always shows the brand mark — same behaviour as the
/// design's `GroupAvatar` after the `forceInitials` refactor.
struct OnymGroupAvatar: View {
    var size: CGFloat = 96
    var accent: Color = OnymAccent.blue.color
    var ringPulse: Bool = false
    var spinning: Bool = false
    /// When `true` the mark renders in the accent colour rather than
    /// the neutral text colour — used on the Creating screen.
    var brand: Bool = false

    var body: some View {
        ZStack {
            if ringPulse {
                Circle()
                    .stroke(accent, lineWidth: 1.5)
                    .padding(-8)
                    .modifier(PulseModifier())
            }
            OnymMark(
                size: size,
                color: brand ? accent : OnymTokens.text,
                spinning: spinning,
                fillOpacity: brand ? 1.0 : 0.92
            )
        }
        .frame(width: size, height: size)
    }
}

private struct PulseModifier: ViewModifier {
    @State private var animating = false

    func body(content: Content) -> some View {
        content
            .opacity(animating ? 0.55 : 0.35)
            .scaleEffect(animating ? 1.06 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
    }
}
