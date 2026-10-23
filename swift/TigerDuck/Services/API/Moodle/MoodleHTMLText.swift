import Foundation
import SwiftSoup

nonisolated enum MoodleHTMLText {
    static func plainText(fromHTML html: String) -> String {
        guard let body = try? SwiftSoup.parseBodyFragment(html).body() else { return collapsed(html) }
        return collapsed(visibleText(of: body))
    }

    static func markdown(fromHTML html: String, baseURL: URL = AppConstants.moodleBaseURL) -> String {
        guard let body = try? SwiftSoup.parseBodyFragment(html).body() else { return escaped(collapsed(html)) }
        return MarkdownWriter(baseURL: baseURL).blocks(in: body, depth: 0).joined(separator: "\n\n")
    }

    static func resolvingPluginFiles(in html: String, files: [MoodleFile]) -> String {
        let placeholder = "@@PLUGINFILE@@"
        guard html.contains(placeholder), let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body(),
              (try? HTMLParser.flattenPastTheDepthCap(body, skipping: skippedTags, separating: separates)) != nil,
              let elements = try? body.getAllElements() else { return html }
        document.outputSettings().prettyPrint(pretty: false)
        let urls = Dictionary(files.map { (($0.path ?? "/") + $0.name, $0.url) }, uniquingKeysWith: { first, _ in first })
        for element in elements.array() {
            for attribute in ["src", "href"] {
                guard let value = try? element.attr(attribute), value.hasPrefix(placeholder) else { continue }
                let path = String(value.dropFirst(placeholder.count).prefix { $0 != "?" && $0 != "#" })
                if let url = urls[path.removingPercentEncoding ?? path] {
                    _ = try? element.attr(attribute, url)
                } else if element.tagName().lowercased() == "img" {
                    try? element.remove()
                } else {
                    _ = try? element.unwrap()
                }
            }
        }
        return (try? body.html()) ?? html
    }

    fileprivate static func visibleText(of element: Element) -> String {
        HTMLParser.visibleText(of: element.getChildNodes(), skipping: skippedTags, separating: separates)
    }

    private static func separates(_ tag: String) -> Bool {
        tag == "br" || MarkdownWriter.separatesText(tag)
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    fileprivate static let skippedTags: Set<String> = ["script", "style", "head", "title", "noscript", "template"]

    fileprivate static func collapsedKeepingEdges(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace, character != "\u{00A0}" {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result
    }

    fileprivate static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>#|~&".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    fileprivate static func escapedLineStart(_ text: String) -> String {
        if let first = text.first, "-+=".contains(first) { return "\\" + text }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, let next = text.dropFirst(digits.count).first, next == "." || next == ")" {
            return digits + "\\" + text.dropFirst(digits.count)
        }
        return text
    }
}

private nonisolated struct MarkdownWriter {
    let baseURL: URL

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "main", "aside", "header", "footer", "nav", "center", "address",
        "figure", "figcaption", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "dl", "dt", "dd",
        "form", "fieldset", "details", "summary",
    ]

    func blocks(in element: Element, depth: Int) -> [String] {
        guard depth <= AppConstants.maximumHTMLDepth else { return paragraphs(ofTextIn: element) }
        var result: [String] = []
        var paragraph = ""
        func endParagraph() {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(text) }
            paragraph = ""
        }
        for child in element.getChildNodes() {
            if let textNode = child as? TextNode {
                appendText(textNode.getWholeText(), to: &paragraph)
                continue
            }
            guard let child = child as? Element else { continue }
            let tag = child.tagName().lowercased()
            if MoodleHTMLText.skippedTags.contains(tag) { continue }
            if Self.blockTags.contains(tag) {
                endParagraph()
                result += blocks(in: child, depth: depth + 1)
            } else if let level = Self.headingLevel(tag) {
                endParagraph()
                if let heading = Self.heading(level, inline(of: child, depth: depth + 1)) { result.append(heading) }
            } else if tag == "ul" || tag == "ol" {
                endParagraph()
                let list = self.list(child, ordered: tag == "ol", depth: depth + 1)
                if !list.isEmpty { result.append(list) }
            } else if tag == "blockquote" {
                endParagraph()
                if let quote = Self.quote(blocks(in: child, depth: depth + 1)) { result.append(quote) }
            } else if tag == "pre" {
                endParagraph()
                if let code = Self.codeBlock(child) { result.append(code) }
            } else if tag == "hr" {
                endParagraph()
                result.append("---")
            } else if tag == "br" {
                paragraph += "  \n"
            } else {
                paragraph += inline(of: child, depth: depth + 1)
            }
        }
        endParagraph()
        return result
    }

    private static func heading(_ level: Int, _ inline: String) -> String? {
        let text = inline.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(repeating: "#", count: level) + " " + text
    }

    private static func quote(_ blocks: [String]) -> String? {
        let quoted = blocks.joined(separator: "\n\n")
        guard !quoted.isEmpty else { return nil }
        return quoted.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    private static func codeBlock(_ element: Element) -> String? {
        let code = (try? element.text(trimAndNormaliseWhitespace: false)) ?? ""
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "```\n" + code.trimmingCharacters(in: .newlines) + "\n```"
    }

    private static func codeSpan(_ element: Element) -> String {
        let code = MoodleHTMLText.collapsedKeepingEdges((try? element.text()) ?? "")
        return code.trimmingCharacters(in: .whitespaces).isEmpty || code.contains("`") ? MoodleHTMLText.escaped(code) : "`\(code)`"
    }

    private func paragraphs(ofTextIn element: Element) -> [String] {
        var paragraph = ""
        appendText(MoodleHTMLText.visibleText(of: element), to: &paragraph)
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [text]
    }

    private func appendText(_ raw: String, to paragraph: inout String) {
        var text = MoodleHTMLText.collapsedKeepingEdges(raw)
        let opensLine = paragraph.isEmpty || paragraph.hasSuffix("\n")
        if opensLine {
            text = String(text.drop(while: { $0 == " " }))
            guard !text.isEmpty else { return }
            paragraph += MoodleHTMLText.escapedLineStart(MoodleHTMLText.escaped(text))
        } else {
            paragraph += MoodleHTMLText.escaped(text)
        }
    }

    private func inline(of element: Element, depth: Int) -> String {
        guard depth <= AppConstants.maximumHTMLDepth else { return Self.text(of: element) }
        let tag = element.tagName().lowercased()
        switch tag {
        case "br":
            return "  \n"
        case "img":
            return image(element)
        case "code", "kbd", "samp", "tt":
            return Self.codeSpan(element)
        default:
            break
        }
        var content = ""
        for child in element.getChildNodes() {
            if let textNode = child as? TextNode {
                content += MoodleHTMLText.escaped(MoodleHTMLText.collapsedKeepingEdges(textNode.getWholeText()))
            } else if let child = child as? Element, !MoodleHTMLText.skippedTags.contains(child.tagName().lowercased()) {
                content += inline(of: child, depth: depth + 1)
            }
        }
        switch tag {
        case "strong", "b":
            return wrapped(content, in: "**")
        case "em", "i", "cite":
            return wrapped(content, in: "*")
        case "a":
            return link(content, href: (try? element.attr("href")) ?? "")
        default:
            return content
        }
    }

    private static func text(of element: Element) -> String {
        MoodleHTMLText.escaped(MoodleHTMLText.collapsedKeepingEdges(MoodleHTMLText.visibleText(of: element)))
    }

    private func wrapped(_ content: String, in marker: String) -> String {
        let text = content.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return content }
        let leading = content.hasPrefix(" ") ? " " : ""
        let trailing = content.hasSuffix(" ") ? " " : ""
        return leading + marker + text + marker + trailing
    }

    private func link(_ content: String, href: String) -> String {
        guard let url = Self.linkURL(href, baseURL: baseURL) else { return content }
        let text = content.trimmingCharacters(in: .whitespaces)
        let label = text.isEmpty ? MoodleHTMLText.escaped(url.absoluteString) : text
        return "[\(label)](<\(url.absoluteString)>)"
    }

    private func image(_ element: Element) -> String {
        guard let url = Self.linkURL((try? element.attr("src")) ?? "", baseURL: baseURL),
              url.scheme != "mailto" else { return "" }
        let alt = MoodleHTMLText.collapsedKeepingEdges((try? element.attr("alt")) ?? "").trimmingCharacters(in: .whitespaces)
        let name = alt.isEmpty ? (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent) : alt
        return "[\(MoodleHTMLText.escaped(name.isEmpty ? url.absoluteString : name))](<\(url.absoluteString)>)"
    }

    private func list(_ element: Element, ordered: Bool, depth: Int) -> String {
        var lines: [String] = []
        var number = min(max(Int((try? element.attr("start")) ?? "") ?? 1, 0), 999_999_000)
        for item in element.children().array() where item.tagName().lowercased() == "li" {
            let marker = ordered ? "\(number). " : "- "
            let content = blocks(in: item, depth: depth + 1).joined(separator: "\n")
            let pad = String(repeating: " ", count: marker.count)
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if index == 0 {
                    lines.append(marker + line)
                } else {
                    lines.append(line.isEmpty ? "" : pad + line)
                }
            }
            if content.isEmpty { lines.append(marker.trimmingCharacters(in: .whitespaces)) }
            number += 1
        }
        return lines.joined(separator: "\n")
    }

    static func separatesText(_ tag: String) -> Bool {
        blockTags.contains(tag) || headingLevel(tag) != nil
            || ["ul", "ol", "li", "blockquote", "pre", "hr"].contains(tag)
    }

    private static func headingLevel(_ tag: String) -> Int? {
        guard tag.count == 2, tag.hasPrefix("h"), let level = Int(tag.dropFirst()), (1...6).contains(level) else { return nil }
        return level
    }

    static func linkURL(_ href: String, baseURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }
}
