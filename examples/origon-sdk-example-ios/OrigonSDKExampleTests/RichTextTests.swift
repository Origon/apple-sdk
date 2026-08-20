import XCTest
import OrigonSDK
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
        XCTAssertNil(ExampleRichText.safeURL("intent://payload"))
        XCTAssertEqual(ExampleRichText.safeURL("HTTPS://example.invalid/a")?.scheme?.lowercased(), "https")
        XCTAssertEqual(examplePromptURL(buttonType: "url", value: "https://example.invalid")?.host,
                       "example.invalid")
        XCTAssertNil(examplePromptURL(buttonType: "url", value: "javascript:alert(1)"))
        XCTAssertNil(examplePromptURL(buttonType: "postback", value: "https://example.invalid"))
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

    func testAuthorTransitionsAndStableMediaPolicies() {
        let first = Message(role: .user, id: "1", text: "a", userId: "agent", userName: "Pat")
        let repeated = Message(role: .user, id: "2", text: "b", userId: "agent", userName: "Pat")
        let selfRow = Message(role: .external, id: "3", text: "c")
        let lifecycle = Message(role: .system, id: "4", text: "joined", action: "joined")
        XCTAssertTrue(exampleShouldShowAuthor(first, previous: nil))
        XCTAssertFalse(exampleShouldShowAuthor(repeated, previous: first))
        XCTAssertTrue(exampleShouldShowAuthor(selfRow, previous: repeated))
        XCTAssertFalse(exampleShouldShowAuthor(lifecycle, previous: selfRow))
        XCTAssertEqual(exampleMessageAuthor(first).displayName, "Pat")
        XCTAssertEqual(exampleMessageAuthor(selfRow).displayName, "You")
        XCTAssertEqual(Array(["a", "b", "c"].enumerated()).map(\.offset), [0, 1, 2])
    }

    func testComposerRoleLabelAndDisabledMatrix() {
        XCTAssertEqual(
            exampleComposerPresentation(
                hasContent: false, voiceActionAvailable: true,
                transportBlocked: false, sending: false
            ),
            .init(primary: .startCall, label: "Start a call", hint: "Starts a voice session", disabled: false)
        )
        XCTAssertEqual(
            exampleComposerPresentation(
                hasContent: true, voiceActionAvailable: true,
                transportBlocked: false, sending: false
            ).label,
            "Send message"
        )
        XCTAssertTrue(exampleComposerPresentation(
            hasContent: true, voiceActionAvailable: false,
            transportBlocked: true, sending: false
        ).disabled)
        XCTAssertTrue(exampleComposerPresentation(
            hasContent: false, voiceActionAvailable: false,
            transportBlocked: false, sending: false
        ).disabled)
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
