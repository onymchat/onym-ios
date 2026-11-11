import SwiftUI

/// An SF Symbol standing in for a label on a textless surface. The
/// meaning is never only in the glyph: VoiceOver reads `label`, and a
/// tap shows it in a popover — on the consent screen especially, a
/// term the user agrees to has to be readable on demand, not guessed
/// from a picture.
public struct SymbolHint: View {
    private let symbol: String
    private let label: Text
    private let size: CGFloat
    private let color: Color
    @State private var showsLabel = false

    public init(
        _ symbol: String,
        label: LocalizedStringKey,
        size: CGFloat = 17,
        color: Color = OnymTokens.text2
    ) {
        self.symbol = symbol
        self.label = Text(label)
        self.size = size
        self.color = color
    }

    /// For a label that is runtime data — never looked up as a key.
    public init(
        _ symbol: String,
        verbatimLabel: String,
        size: CGFloat = 17,
        color: Color = OnymTokens.text2
    ) {
        self.symbol = symbol
        self.label = Text(verbatim: verbatimLabel)
        self.size = size
        self.color = color
    }

    public var body: some View {
        Button {
            showsLabel = true
        } label: {
            Image(systemName: symbol)
                .font(OnymType.fixed(size: size, weight: .semibold))
                .foregroundStyle(color)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .popover(isPresented: $showsLabel) {
            label
                .font(OnymType.font(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
                .padding(12)
                .presentationCompactAdaptation(.popover)
        }
    }
}
