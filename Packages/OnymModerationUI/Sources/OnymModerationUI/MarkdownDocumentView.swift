import SwiftUI

/// One block of a parsed markdown document. Foundation's markdown
/// parser (`AttributedString(markdown:)` with `.full` syntax) styles
/// inlines but only *annotates* block structure via
/// `PresentationIntent` — `Text` renders it all as one flow. This
/// splits the parse into blocks a view can lay out, using nothing but
/// the system parser.
public struct MarkdownBlock: Identifiable, Equatable {
    public enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        /// `ordinal` is set for ordered lists, nil for bullets.
        case listItem(ordinal: Int?, depth: Int)
        case codeBlock
        case quote
        case divider
    }

    public let id: Int
    public let kind: Kind
    public let text: AttributedString

    public static func blocks(from markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            // Unparseable input is still readable input.
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }
        var blocks: [MarkdownBlock] = []
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let slice = AttributedString(parsed[range])
            var kind = Kind.paragraph
            var ordinal: Int?
            var ordered = false
            var listDepth = 0
            var isDivider = false
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level):
                    kind = .heading(level: level)
                case .codeBlock:
                    kind = .codeBlock
                case .blockQuote:
                    kind = .quote
                case .listItem(let value):
                    ordinal = value
                case .orderedList:
                    ordered = true
                    listDepth += 1
                case .unorderedList:
                    listDepth += 1
                case .thematicBreak:
                    isDivider = true
                default:
                    break
                }
            }
            if isDivider {
                blocks.append(MarkdownBlock(id: blocks.count, kind: .divider, text: AttributedString()))
                continue
            }
            if ordinal != nil || listDepth > 0 {
                kind = .listItem(ordinal: ordered ? ordinal : nil, depth: max(listDepth, 1))
            }
            guard !slice.characters.allSatisfy(\.isWhitespace) else { continue }
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind, text: slice))
        }
        return blocks
    }
}

/// In-app viewer for a fetched markdown document — the system parser
/// only, no rendering dependency. An HTML answer (the address turned
/// out to be a web page, not a document) hands off to the browser
/// instead of pretending to render it.
public struct MarkdownDocumentView: View {
    private enum Phase {
        case loading
        case document([MarkdownBlock])
        case webPage
        case failed
    }

    private let title: String
    private let url: URL

    @State private var phase: Phase = .loading
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .document(let blocks):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(blocks) { block in
                                blockView(block)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                case .webPage:
                    handOff(
                        message: String(localized: "This document is a web page.")
                    )
                case .failed:
                    handOff(
                        message: String(localized: "The document could not be fetched.")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
        .accessibilityIdentifier("moderation.document")
    }

    private func handOff(message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                openURL(url)
            } label: {
                Label("Open in browser", systemImage: "safari")
            }
            .accessibilityIdentifier("moderation.document.open_in_browser")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph:
            Text(block.text)
                .font(.body)
                .lineSpacing(3)
        case .listItem(let ordinal, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ordinal.map { "\($0)." } ?? "•")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(block.text)
                    .font(.body)
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(depth - 1) * 16 + 4)
        case .codeBlock:
            Text(block.text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(block.text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        case .divider:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    private func load() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                phase = .failed
                return
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let text = String(decoding: data, as: UTF8.self)
            let looksLikeHTML = contentType.contains("text/html")
                || text.range(
                    of: #"^\s*<(!doctype|html)"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            if looksLikeHTML {
                phase = .webPage
            } else {
                phase = .document(MarkdownBlock.blocks(from: text))
            }
        } catch {
            phase = .failed
        }
    }
}
