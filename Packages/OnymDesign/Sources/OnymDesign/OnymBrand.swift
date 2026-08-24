import SwiftUI
import UIKit

@_exported import OnymDesignTokens

// MARK: - Sender → accent

extension OnymAccent {
    /// Deterministic accent for a chat sender, keyed off their BLS
    /// pubkey hex.
    ///
    /// Color keys on the *load-bearing* identity (the pubkey), never the
    /// self-asserted `MemberProfile.alias` — so two members who both
    /// claim "Alice" still get different colors, and an impostor can't
    /// steal the original's color by copying their name. The mapping is
    /// a pure function of the hex bytes (FNV-1a, not the per-process-
    /// seeded `Hashable`), so the same person resolves to the same color
    /// on every device, in every group, across launches.
    ///
    /// Lives here rather than in `OnymDesignTokens` because it is
    /// mapping policy, not a token value — adopters swapping the token
    /// module inherit this behaviour unchanged.
    public static func forSender(blsPubkeyHex: String) -> OnymAccent {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a offset basis
        for byte in blsPubkeyHex.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3  // FNV-1a prime
        }
        let all = allCases
        return all[Int(hash % UInt64(all.count))]
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
public struct OnymMark: View {
    var size: CGFloat = 32
    var color: Color = OnymTokens.text
    var strokeRatio: CGFloat = 0.16
    var spinning: Bool = false
    var fillOpacity: Double = 0.92

    @State private var rotation: Double = -45  // -45° lands the dash pattern's gaps at 1:00 and 7:00

    public init(
        size: CGFloat = 32,
        color: Color = OnymTokens.text,
        strokeRatio: CGFloat = 0.16,
        spinning: Bool = false,
        fillOpacity: Double = 0.92
    ) {
        self.size = size
        self.color = color
        self.strokeRatio = strokeRatio
        self.spinning = spinning
        self.fillOpacity = fillOpacity
    }

    public var body: some View {
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

/// UI-side mirror of the design's three governance cards. The app
/// target maps it to `SEPGroupType` for the actual chain call (see
/// `OnymBrandSEPBridge.swift` — this package stays Chain-free). PR-C
/// only enables `.tyranny` — the other two render with a "Soon" label
/// and aren't selectable.
public enum OnymUIGovernance: String, CaseIterable, Identifiable, Sendable {
    case tyranny
    case oneOnOne = "dialog"
    case anarchy

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tyranny: "Founder"
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

    /// True when this governance type is selectable in the Create
    /// Group flow. Only Tyranny ships today — 1-on-1 and Anarchy
    /// render with a "Soon" label and aren't selectable.
    public var isAvailable: Bool {
        switch self {
        case .tyranny: true
        case .oneOnOne, .anarchy: false
        }
    }
}

// MARK: - Governance icons

/// Small badge icons that go on each governance card. Three distinct
/// silhouettes: crown (admin), facing bubbles (dialog), nodes-in-ring
/// (anarchy). Implemented with SwiftUI `Path`/`Shape` rather than
/// SF symbols because the design uses custom artwork.
public struct OnymGovIcon: View {
    let type: OnymUIGovernance
    let accent: Color
    var size: CGFloat = 44
    var dimmed: Bool = false

    public init(type: OnymUIGovernance, accent: Color, size: CGFloat = 44, dimmed: Bool = false) {
        self.type = type
        self.accent = accent
        self.size = size
        self.dimmed = dimmed
    }

    public var body: some View {
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
                .fill(dimmed ? OnymTokens.text3 : OnymTokens.onAccent)
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

// MARK: - Group avatar (image-or-mark)

/// Avatar slot. Renders the group photo (`imageData`, a square JPEG —
/// see `GroupAvatarImage`) clipped to a circle when one is set, else
/// falls back to the Onym brand mark — the same fallback the design's
/// `GroupAvatar` used before uploads shipped.
public struct OnymGroupAvatar: View {
    var size: CGFloat = 96
    var accent: Color = OnymAccent.blue.color
    var ringPulse: Bool = false
    var spinning: Bool = false
    /// When `true` the mark renders in the accent colour rather than
    /// the neutral text colour — used on the Creating screen.
    var brand: Bool = false
    /// Square JPEG to show instead of the brand mark. `nil` → mark.
    var imageData: Data? = nil

    public init(
        size: CGFloat = 96,
        accent: Color = OnymAccent.blue.color,
        ringPulse: Bool = false,
        spinning: Bool = false,
        brand: Bool = false,
        imageData: Data? = nil
    ) {
        self.size = size
        self.accent = accent
        self.ringPulse = ringPulse
        self.spinning = spinning
        self.brand = brand
        self.imageData = imageData
    }

    public var body: some View {
        ZStack {
            if ringPulse {
                Circle()
                    .stroke(accent, lineWidth: 1.5)
                    .padding(-8)
                    .modifier(PulseModifier())
            }
            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                OnymMark(
                    size: size,
                    color: brand ? accent : OnymTokens.text,
                    spinning: spinning,
                    fillOpacity: brand ? 1.0 : 0.92
                )
            }
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
