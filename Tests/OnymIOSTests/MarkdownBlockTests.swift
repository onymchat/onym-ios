import XCTest
import OnymModerationUI

/// The block splitter over Foundation's markdown parse: block
/// structure recovered from PresentationIntent, inline styling left
/// to AttributedString.
final class MarkdownBlockTests: XCTestCase {

    func testSplitsHeadingsParagraphsAndLists() {
        let blocks = MarkdownBlock.blocks(from: """
        # Policy

        What this class prohibits.

        - first
        - second

        1. step one
        """)

        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(String(blocks[0].text.characters), "Policy")
        XCTAssertEqual(blocks[1].kind, .paragraph)
        XCTAssertEqual(blocks[2].kind, .listItem(ordinal: nil, depth: 1))
        XCTAssertEqual(String(blocks[2].text.characters), "first")
        XCTAssertEqual(blocks[3].kind, .listItem(ordinal: nil, depth: 1))
        XCTAssertEqual(blocks[4].kind, .listItem(ordinal: 1, depth: 1))
        XCTAssertEqual(String(blocks[4].text.characters), "step one")
    }

    func testRecognizesCodeQuoteAndDivider() {
        let blocks = MarkdownBlock.blocks(from: """
        > quoted term

        ```
        exact bytes
        ```

        ---
        """)

        XCTAssertEqual(blocks[0].kind, .quote)
        XCTAssertEqual(blocks[1].kind, .codeBlock)
        XCTAssertTrue(String(blocks[1].text.characters).contains("exact bytes"))
        XCTAssertEqual(blocks[2].kind, .divider)
    }

    func testInlineStylingSurvivesTheSplit() throws {
        let blocks = MarkdownBlock.blocks(from: "A **bold** claim with a [link](https://example.org).")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph)
        let text = blocks[0].text
        XCTAssertEqual(String(text.characters), "A bold claim with a link.")
        let linked = text.runs.compactMap(\.link)
        XCTAssertEqual(linked, [URL(string: "https://example.org")!])
        XCTAssertTrue(
            text.runs.contains { run in
                run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            },
            "bold must survive as inline presentation"
        )
    }

    /// The live policy documents cross-reference each other with
    /// relative links (`./evidence-rules#anchor`); unresolved they
    /// render tappable-looking but dead.
    func testRelativeLinksResolveAgainstTheDocumentURL() throws {
        let blocks = MarkdownBlock.blocks(
            from: "[What these windows mean](./evidence-rules#what-the-windows-mean).",
            baseURL: URL(string: "https://authority.example/policy/csam")!
        )
        let link = try XCTUnwrap(blocks[0].text.runs.compactMap(\.link).first)
        XCTAssertEqual(
            link.absoluteString,
            "https://authority.example/policy/evidence-rules#what-the-windows-mean"
        )

        // Absolute links stay untouched.
        let absolute = MarkdownBlock.blocks(
            from: "[elsewhere](https://other.example/doc)",
            baseURL: URL(string: "https://authority.example/policy/csam")!
        )
        XCTAssertEqual(
            absolute[0].text.runs.compactMap(\.link).first?.absoluteString,
            "https://other.example/doc"
        )
    }

    /// The policy docs' "Terms" table uses the empty-header key-value
    /// idiom (`| | |`); the empty header row must not render.
    func testTablesBecomeRowsAndEmptyHeadersAreDropped() {
        let blocks = MarkdownBlock.blocks(from: """
        | | |
        |---|---|
        | Response window | 3 days |
        | Ban term | 365 days |
        """)

        XCTAssertEqual(blocks.count, 1)
        guard case .table(let rows) = blocks[0].kind else {
            return XCTFail("expected a table, got \(blocks[0].kind)")
        }
        XCTAssertEqual(
            rows.map { $0.map { String($0.characters) } },
            [["Response window", "3 days"], ["Ban term", "365 days"]]
        )
    }

    func testUnparseableInputFallsBackToPlainParagraph() {
        // Nothing markdown can't represent as *something*; the
        // guarantee is no crash and no dropped content.
        let blocks = MarkdownBlock.blocks(from: "just text")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(String(blocks[0].text.characters), "just text")
    }
}
