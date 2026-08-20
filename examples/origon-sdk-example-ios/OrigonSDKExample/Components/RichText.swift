import Foundation
import Darwin
import SwiftSoup
import SwiftUI

enum ExampleRichBlock: Sendable {
    case paragraph(AttributedString)
    case heading(Int, AttributedString)
    case listItem(Int?, Int, AttributedString)
    case quote(AttributedString)
    case code(String)
    case rule
}

struct ExampleRichParseResult: Sendable {
    let blocks: [ExampleRichBlock]
    let ranOffMain: Bool
}

enum ExampleRichText {
    static let maximumInputBytes = 262_144
    static let maximumNodes = 4_096
    static let maximumDepth = 64
    static let maximumListItems = 1_024
    static let maximumOutputCharacters = 131_072

    static func parse(html: String?, text: String?) async -> ExampleRichParseResult {
        await Task.detached(priority: .userInitiated) {
            let offMain = pthread_main_np() == 0
            return ExampleRichParseResult(
                blocks: compute(html: html, text: text),
                ranOffMain: offMain
            )
        }.value
    }

    static func computeForTesting(html: String?, text: String?) -> [ExampleRichBlock] {
        compute(html: html, text: text)
    }

    private static func compute(html: String?, text: String?) -> [ExampleRichBlock] {
        if let html, !html.isEmpty, html.utf8.count <= maximumInputBytes,
           let mapped = htmlBlocks(html) {
            return mapped
        }
        if let text, !text.isEmpty {
            guard text.utf8.count <= maximumInputBytes else { return plain(text) }
            if let mapped = markdownBlocks(text) { return mapped }
            return plain(text)
        }
        if let html, !html.isEmpty {
            let stripped = html.utf8.count <= maximumInputBytes
                ? ((try? SwiftSoup.parseBodyFragment(html).text()) ?? html)
                : html
            return plain(stripped)
        }
        return []
    }

    private struct Budget {
        var nodes = 0
        var listItems = 0
        var output = 0

        mutating func consume(depth: Int, output count: Int = 0, listItem: Bool = false) -> Bool {
            nodes += 1
            output += count
            if listItem { listItems += 1 }
            return depth <= maximumDepth && nodes <= maximumNodes &&
                listItems <= maximumListItems && output <= maximumOutputCharacters
        }
    }

    private static let blockTags: Set<String> = [
        "p", "ul", "ol", "blockquote", "pre", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]
    private static let inlineTags: Set<String> = [
        "strong", "b", "em", "i", "s", "del", "strike", "u", "code", "a", "br",
    ]

    private static func htmlBlocks(_ html: String) -> [ExampleRichBlock]? {
        guard let body = (try? SwiftSoup.parseBodyFragment(html))?.body(),
              !body.children().isEmpty() else { return nil }
        var budget = Budget()
        var output: [ExampleRichBlock] = []
        for node in body.getChildNodes() {
            guard let element = node as? Element else {
                guard let text = node as? TextNode, text.isBlank() else { return nil }
                continue
            }
            guard blockTags.contains(element.tagName()),
                  mapHTMLBlock(element, depth: 0, budget: &budget, output: &output)
            else { return nil }
        }
        return output.isEmpty ? nil : output
    }

    private static func mapHTMLBlock(
        _ element: Element,
        depth: Int,
        budget: inout Budget,
        output: inout [ExampleRichBlock]
    ) -> Bool {
        guard budget.consume(depth: depth) else { return false }
        switch element.tagName() {
        case "p":
            guard let value = htmlInline(element.getChildNodes(), depth: depth + 1, budget: &budget)
            else { return false }
            if !value.characters.isEmpty { output.append(.paragraph(value)) }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            guard let value = htmlInline(element.getChildNodes(), depth: depth + 1, budget: &budget)
            else { return false }
            output.append(.heading(Int(element.tagName().dropFirst()) ?? 3, value))
        case "ul", "ol":
            return mapHTMLList(element, depth: depth, budget: &budget, output: &output)
        case "blockquote":
            let value = collapsed((try? element.text()) ?? "")
            guard budget.consume(depth: depth + 1, output: value.count) else { return false }
            output.append(.quote(AttributedString(value)))
        case "pre":
            let value = verbatimText(element).trimmingCharacters(in: CharacterSet.newlines)
            guard budget.consume(depth: depth + 1, output: value.count) else { return false }
            output.append(.code(value))
        case "hr": output.append(.rule)
        default: return false
        }
        return true
    }

    private static func mapHTMLList(
        _ list: Element,
        depth: Int,
        budget: inout Budget,
        output: inout [ExampleRichBlock]
    ) -> Bool {
        let ordered = list.tagName() == "ol"
        var ordinal = min(max(Int((try? list.attr("start")) ?? "") ?? 1, 0), 999_999)
        for node in list.getChildNodes() {
            if let text = node as? TextNode, text.isBlank() { continue }
            guard let item = node as? Element, item.tagName() == "li",
                  budget.consume(depth: depth + 1, listItem: true) else { return false }
            var value = AttributedString()
            var nested: [ExampleRichBlock] = []
            for child in item.getChildNodes() {
                if let nestedList = child as? Element,
                   nestedList.tagName() == "ul" || nestedList.tagName() == "ol" {
                    guard mapHTMLList(
                        nestedList, depth: depth + 1, budget: &budget, output: &nested
                    ) else { return false }
                } else {
                    guard let inline = htmlInline([child], depth: depth + 2, budget: &budget)
                    else { return false }
                    value += inline
                }
            }
            output.append(.listItem(ordered ? ordinal : nil, depth, value))
            output.append(contentsOf: nested)
            ordinal += 1
        }
        return true
    }

    private struct InlineStyle {
        var intent: InlinePresentationIntent = []
        var underline = false
        var link: URL?
    }

    private static func htmlInline(
        _ nodes: [Node], depth: Int, budget: inout Budget, style: InlineStyle = .init()
    ) -> AttributedString? {
        guard depth <= maximumDepth else { return nil }
        var output = AttributedString()
        for node in nodes {
            if let text = node as? TextNode {
                let value = collapsed(text.getWholeText())
                guard budget.consume(depth: depth, output: value.count) else { return nil }
                output += styled(value, style: style)
                continue
            }
            guard let element = node as? Element, inlineTags.contains(element.tagName())
            else { return nil }
            if element.tagName() == "br" {
                guard budget.consume(depth: depth, output: 1) else { return nil }
                output += AttributedString("\n")
                continue
            }
            var next = style
            switch element.tagName() {
            case "strong", "b": next.intent.insert(.stronglyEmphasized)
            case "em", "i": next.intent.insert(.emphasized)
            case "s", "del", "strike": next.intent.insert(.strikethrough)
            case "code": next.intent.insert(.code)
            case "u": next.underline = true
            case "a":
                if let href = try? element.attr("href"), let url = safeURL(href) {
                    next.link = url
                    next.underline = true
                }
            default: break
            }
            guard let value = htmlInline(
                element.getChildNodes(), depth: depth + 1, budget: &budget, style: next
            ) else { return nil }
            output += value
        }
        return output
    }

    private static func styled(_ text: String, style: InlineStyle) -> AttributedString {
        var value = AttributedString(text)
        if !style.intent.isEmpty { value.inlinePresentationIntent = style.intent }
        if style.underline {
            value[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
        }
        value.link = style.link
        return value
    }

    private static func verbatimText(_ element: Element) -> String {
        var output = ""
        var stack: [Node] = element.getChildNodes().reversed()
        while let node = stack.popLast() {
            if let text = node as? TextNode {
                output += text.getWholeText()
            } else if let child = node as? Element {
                if child.tagName() == "br" { output += "\n" }
                else { stack.append(contentsOf: child.getChildNodes().reversed()) }
            }
        }
        return output
    }

    private static func markdownBlocks(_ text: String) -> [ExampleRichBlock]? {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard var parsed = try? AttributedString(markdown: text, options: options) else { return nil }
        parsed = parsed.transformingAttributes(\.link) { link in
            if let value = link.value, safeURL(value.absoluteString) == nil { link.value = nil }
        }
        guard parsed.characters.count <= maximumOutputCharacters else { return nil }
        return splitMarkdown(parsed)
    }

    private static func splitMarkdown(_ parsed: AttributedString) -> [ExampleRichBlock]? {
        var blocks: [ExampleRichBlock] = []
        var pieces = 0
        for run in parsed.runs {
            pieces += 1
            guard pieces <= maximumNodes else { return nil }
            var value = AttributedString(parsed[run.range])
            value.presentationIntent = nil
            guard !value.characters.isEmpty else { continue }
            let components = run.presentationIntent?.components ?? []
            if let heading = components.compactMap({ component -> Int? in
                if case .header(let level) = component.kind { return level }
                return nil
            }).first {
                blocks.append(.heading(heading, value))
            } else if components.contains(where: {
                if case .codeBlock = $0.kind { return true }; return false
            }) {
                blocks.append(.code(String(value.characters)))
            } else if let item = components.first(where: {
                if case .listItem = $0.kind { return true }; return false
            }) {
                guard blocks.count < maximumListItems else { return nil }
                let ordinal: Int?
                if case .listItem(let number) = item.kind { ordinal = number } else { ordinal = nil }
                let depth = max(0, components.filter {
                    if case .orderedList = $0.kind { return true }
                    if case .unorderedList = $0.kind { return true }
                    return false
                }.count - 1)
                guard depth <= maximumDepth else { return nil }
                blocks.append(.listItem(ordinal, depth, value))
            } else if components.contains(where: {
                if case .blockQuote = $0.kind { return true }; return false
            }) {
                blocks.append(.quote(value))
            } else {
                blocks.append(.paragraph(value))
            }
        }
        return blocks.isEmpty ? nil : blocks
    }

    private static func plain(_ text: String) -> [ExampleRichBlock] {
        let bounded = String(text.prefix(maximumOutputCharacters))
        return bounded.isEmpty ? [] : [.paragraph(linkified(bounded))]
    }

    private static func linkified(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return value }
        for match in detector.matches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length)
        ) {
            guard let url = match.url, safeURL(url.absoluteString) != nil,
                  let stringRange = Range(match.range, in: text) else { continue }
            let lower = value.index(value.startIndex, offsetByCharacters: text.distance(
                from: text.startIndex, to: stringRange.lowerBound
            ))
            let upper = value.index(lower, offsetByCharacters: text.distance(
                from: stringRange.lowerBound, to: stringRange.upperBound
            ))
            value[lower..<upper].link = url
        }
        return value
    }

    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    static func shouldPublish(request: UInt64, current: UInt64, cancelled: Bool) -> Bool {
        !cancelled && request == current
    }

    private static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

struct ExampleRichMessageView: View {
    let blocks: [ExampleRichBlock]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let value): Text(value)
                case .heading(let level, let value):
                    Text(value).font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                case .listItem(let ordinal, let depth, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordinal.map { "\($0)." } ?? "•")
                        Text(value)
                    }.padding(.leading, CGFloat(depth) * 12)
                case .quote(let value):
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle().fill(color.opacity(0.35)).frame(width: 3)
                        Text(value)
                    }
                case .code(let value):
                    Text(value).font(.system(.body, design: .monospaced))
                        .padding(8).background(color.opacity(0.08)).cornerRadius(6)
                case .rule: Rectangle().fill(color.opacity(0.2)).frame(height: 1)
                }
            }
        }
    }
}

struct ExampleRichMessageBody: View {
    let html: String?
    let text: String?
    let color: Color
    @State private var blocks: [ExampleRichBlock] = []

    var body: some View {
        ExampleRichMessageView(blocks: blocks, color: color)
            .task(id: "\(html ?? "")\u{0}\(text ?? "")") {
                let result = await ExampleRichText.parse(html: html, text: text)
                guard !Task.isCancelled else { return }
                blocks = result.blocks
            }
    }
}
