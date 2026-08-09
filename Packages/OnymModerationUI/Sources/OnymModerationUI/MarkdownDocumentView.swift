import SwiftUI
import UIKit

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
        /// Rows of cells; the first row is the header (dropped when
        /// its cells are all empty — `| | |` header syntax).
        case table(rows: [[AttributedString]])
    }

    public let id: Int
    public let kind: Kind
    public let text: AttributedString

    /// `baseURL` resolves relative links (`./evidence-rules`,
    /// `#anchor`) against the document's own address — policy
    /// documents cross-reference each other relatively, and a link
    /// with no base is parsed but dead: rendered tappable-looking,
    /// going nowhere.
    public static func blocks(from markdown: String, baseURL: URL? = nil) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var parsed = try? AttributedString(markdown: markdown, options: options) else {
            // Unparseable input is still readable input.
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }
        if let baseURL {
            let relative = parsed.runs.compactMap { run -> (Range<AttributedString.Index>, URL)? in
                guard let link = run.link, link.scheme == nil,
                      let resolved = URL(string: link.relativeString, relativeTo: baseURL)
                else { return nil }
                return (run.range, resolved.absoluteURL)
            }
            for (range, resolved) in relative {
                parsed[range].link = resolved
            }
        }

        var blocks: [MarkdownBlock] = []
        var table = TableAccumulator()

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let slice = AttributedString(parsed[range])
            var kind = Kind.paragraph
            var ordinal: Int?
            var ordered = false
            var listDepth = 0
            var isDivider = false
            var cell: TableAccumulator.Cell?
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
                case .table:
                    cell = (cell ?? TableAccumulator.Cell()).with(tableIdentity: component.identity)
                case .tableHeaderRow:
                    cell = (cell ?? TableAccumulator.Cell()).with(row: -1)
                case .tableRow(let rowIndex):
                    cell = (cell ?? TableAccumulator.Cell()).with(row: rowIndex)
                case .tableCell(let columnIndex):
                    cell = (cell ?? TableAccumulator.Cell()).with(column: columnIndex)
                default:
                    break
                }
            }
            if let cell {
                // Flush a finished table when a different one starts
                // back to back.
                if let rows = table.addIfNewTable(cell: cell, text: slice) {
                    blocks.append(MarkdownBlock(id: blocks.count, kind: .table(rows: rows), text: AttributedString()))
                }
                continue
            }
            if let rows = table.flush() {
                blocks.append(MarkdownBlock(id: blocks.count, kind: .table(rows: rows), text: AttributedString()))
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
        if let rows = table.flush() {
            blocks.append(MarkdownBlock(id: blocks.count, kind: .table(rows: rows), text: AttributedString()))
        }
        return blocks
    }

    /// Collects table cells (which arrive as one run per cell) back
    /// into rows. Header row is index -1; a header of empty cells —
    /// the `| | |` key-value-table idiom — is dropped.
    private struct TableAccumulator {
        struct Cell {
            var tableIdentity: Int?
            var row: Int?
            var column: Int?

            func with(tableIdentity: Int? = nil, row: Int? = nil, column: Int? = nil) -> Cell {
                var copy = self
                if let tableIdentity { copy.tableIdentity = tableIdentity }
                if let row { copy.row = row }
                if let column { copy.column = column }
                return copy
            }
        }

        private var identity: Int?
        private var cells: [(row: Int, column: Int, text: AttributedString)] = []

        /// Adds the cell; returns finished rows when the cell opens a
        /// *different* table than the one being collected.
        mutating func addIfNewTable(cell: Cell, text: AttributedString) -> [[AttributedString]]? {
            var flushed: [[AttributedString]]?
            if let identity, identity != cell.tableIdentity {
                flushed = flush()
            }
            identity = cell.tableIdentity
            cells.append((row: cell.row ?? 0, column: cell.column ?? 0, text: text))
            return flushed
        }

        mutating func flush() -> [[AttributedString]]? {
            guard !cells.isEmpty else { return nil }
            defer {
                identity = nil
                cells = []
            }
            let byRow = Dictionary(grouping: cells, by: \.row)
            let rows = byRow.keys.sorted().map { rowIndex -> [AttributedString] in
                byRow[rowIndex]!.sorted { $0.column < $1.column }.map(\.text)
            }
            // Tradeoff, accepted: this also drops a legitimate row
            // whose cells are ALL blank, not just the `| | |` header.
            // A fully blank data row carries nothing a policy reader
            // loses; rows with any content survive intact.
            return rows.filter { row in
                !row.allSatisfy { $0.characters.allSatisfy(\.isWhitespace) }
            }
        }
    }
}

/// In-app viewer for a fetched markdown document — the system parser
/// only, no rendering dependency. Links between documents stay
/// in-app: policy documents cross-reference each other, and bouncing
/// to Safari per hop would defeat the viewer. An HTML answer (the
/// address turned out to be a web page, not a document) hands off to
/// the browser instead of pretending to render it.
public struct MarkdownDocumentView: View {
    private let title: String
    private let url: URL

    @State private var path: [URL] = []
    @Environment(\.dismiss) private var dismiss

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    public var body: some View {
        NavigationStack(path: $path) {
            MarkdownDocumentContent(title: title, url: url, onDone: { dismiss() })
                .navigationDestination(for: URL.self) { destination in
                    // Pushed pages carry their own Done: the sheet
                    // must close in one tap from any depth, not by
                    // popping back through each followed document.
                    MarkdownDocumentContent(
                        title: Self.impliedTitle(of: destination),
                        url: destination,
                        onDone: { dismiss() }
                    )
                }
        }
        .environment(\.openURL, OpenURLAction { destination in
            // In-app follow is a same-host privilege. The viewer's
            // chrome says "this is the authority's document" and shows
            // no address, so rendering another domain inside it would
            // borrow the authority's trust for arbitrary content. The
            // authority's own cross-references (./evidence-rules) stay
            // in-app; everything else goes to the system, where the
            // address is visible.
            guard Self.followsInApp(destination, from: url) else {
                return .systemAction
            }
            path.append(destination)
            return .handled
        })
        .accessibilityIdentifier("moderation.document")
    }

    /// Whether a tapped link is the root document's own authority
    /// speaking — a web URL on the same host — and may render inside
    /// the viewer's chrome.
    public static func followsInApp(_ destination: URL, from root: URL) -> Bool {
        guard destination.scheme == "https" || destination.scheme == "http" else {
            return false
        }
        guard let destinationHost = destination.host?.lowercased(),
              let rootHost = root.host?.lowercased() else {
            return false
        }
        return destinationHost == rootHost
    }

    /// A followed link has no display title of its own; the last path
    /// component's words are the best available.
    private static func impliedTitle(of url: URL) -> String {
        let slug = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
        guard let first = slug.first else { return slug }
        return first.uppercased() + slug.dropFirst()
    }
}

/// One document: fetch, parse, lay out. No navigation chrome of its
/// own so the stack can push it for links followed within a document.
struct MarkdownDocumentContent: View {
    private enum Phase {
        case loading
        case document([MarkdownBlock])
        case webPage
        case failed
    }

    let title: String
    let url: URL
    let onDone: () -> Void

    @State private var phase: Phase = .loading

    var body: some View {
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
                Button("Done", action: onDone)
            }
        }
        .task { await load() }
    }

    private func handOff(message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                // Deliberately around the viewer's own link handling:
                // this is the one place a web destination must reach
                // the browser.
                UIApplication.shared.open(url)
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
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(rows[rowIndex].indices, id: \.self) { columnIndex in
                            Text(rows[rowIndex][columnIndex])
                                .font(.callout)
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
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
                phase = .document(MarkdownBlock.blocks(from: text, baseURL: url))
            }
        } catch {
            phase = .failed
        }
    }
}
