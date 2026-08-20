import XCTest
@testable import OrigonSDKExample

final class RichTextTests: XCTestCase {
    func testSafeHTMLMarkdownAndUnsafeLinks() async {
        let html = await ExampleRichText.parse(
            html: "<h2>Hello</h2><blockquote><p>quote</p></blockquote><ol><li>one</li></ol>",
            text: "fallback"
        )
        XCTAssertTrue(html.ranOffMain)
        XCTAssertEqual(html.blocks.count, 3)
        let markdown = ExampleRichText.computeForTesting(
            html: nil, text: "## Title\n\n> quote\n\n- item\n\n```\ncode\n```"
        )
        XCTAssertGreaterThanOrEqual(markdown.count, 4)
        XCTAssertNil(ExampleRichText.safeURL("javascript:alert(1)"))
        XCTAssertNil(ExampleRichText.safeURL("file:///etc/passwd"))
        XCTAssertEqual(ExampleRichText.safeURL("HTTPS://example.invalid/a")?.scheme?.lowercased(), "https")
    }

    func testByteNodeDepthListAndOutputCapsFallBackWithoutDroppingAllContent() {
        let oversized = String(repeating: "é", count: ExampleRichText.maximumInputBytes)
        XCTAssertEqual(visible(ExampleRichText.computeForTesting(html: nil, text: oversized)).count,
                       ExampleRichText.maximumOutputCharacters)
        let tooManyNodes = "<p>" + String(repeating: "<b>x</b>", count: 4_200) + "</p>"
        XCTAssertEqual(visible(ExampleRichText.computeForTesting(html: tooManyNodes, text: "fallback")), "fallback")
        let tooDeep = String(repeating: "<b>", count: 80) + "x" + String(repeating: "</b>", count: 80)
        XCTAssertEqual(visible(ExampleRichText.computeForTesting(html: "<p>\(tooDeep)</p>", text: "safe")), "safe")
        let tooManyItems = "<ol>" + String(repeating: "<li>x</li>", count: 1_100) + "</ol>"
        XCTAssertEqual(visible(ExampleRichText.computeForTesting(html: tooManyItems, text: "list fallback")), "list fallback")
    }

    func testMalformedFallbackAndCancellationPublicationFence() {
        XCTAssertEqual(visible(ExampleRichText.computeForTesting(
            html: "<script>alert(1)</script>", text: "plain"
        )), "plain")
        XCTAssertFalse(ExampleRichText.shouldPublish(request: 1, current: 2, cancelled: false))
        XCTAssertFalse(ExampleRichText.shouldPublish(request: 2, current: 2, cancelled: true))
        XCTAssertTrue(ExampleRichText.shouldPublish(request: 2, current: 2, cancelled: false))
    }

    private func visible(_ blocks: [ExampleRichBlock]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let value), .heading(_, let value), .listItem(_, _, let value), .quote(let value):
                return String(value.characters)
            case .code(let value): return value
            case .rule: return ""
            }
        }.joined()
    }
}
