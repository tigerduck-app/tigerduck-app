import Foundation
import SwiftSoup

/// Moodle's HTML, such as an announcement's message, as the app shows it: CommonMark for the
/// body, which MarkdownUI draws with the school bulletins' theme, and one line of plain text for
/// a preview.
nonisolated enum MoodleHTMLText {
    /// The text of `html` with every run of whitespace, line breaks included, as one space.
    static func plainText(fromHTML html: String) -> String {
        guard let body = try? SwiftSoup.parseBodyFragment(html).body() else { return collapsed(html) }
        var text = ""
        appendPlainText(of: body, to: &text)
        return collapsed(text)
    }

    /// CommonMark for `html`: paragraphs, line breaks, headings, lists, quotes, emphasis and
    /// links, with the text escaped so it never reads as Markdown. An image becomes a link to it.
    /// Links resolve against `baseURL`, and only http, https and mailto ones stay links.
    static func markdown(fromHTML html: String, baseURL: URL = AppConstants.moodleBaseURL) -> String {
        guard let body = try? SwiftSoup.parseBodyFragment(html).body() else { return escaped(collapsed(html)) }
        return MarkdownWriter(baseURL: baseURL).blocks(in: body).joined(separator: "\n\n")
    }

    // MARK: Plain text

    private static func appendPlainText(of node: Node, to text: inout String) {
        for child in node.getChildNodes() {
            if let textNode = child as? TextNode {
                text += textNode.getWholeText()
            } else if let element = child as? Element {
                let tag = element.tagName().lowercased()
                if skippedTags.contains(tag) { continue }
                // A block or a break ends a word even where the HTML has no space around it.
                let separates = tag == "br" || MarkdownWriter.separatesText(tag)
                if separates { text += " " }
                appendPlainText(of: element, to: &text)
                if separates { text += " " }
            }
        }
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    fileprivate static let skippedTags: Set<String> = ["script", "style", "head", "title", "noscript", "template"]

    // MARK: Markdown

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

    /// Backslash-escapes the ASCII punctuation Markdown would read as syntax anywhere in a line.
    fileprivate static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>#|~&".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Escapes what reads as a list item, a heading underline or a thematic break only at the
    /// start of a line.
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

    /// The Markdown blocks of `element`'s children; inline runs between blocks become paragraphs.
    func blocks(in element: Element) -> [String] {
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
                result += blocks(in: child)
            } else if let level = Self.headingLevel(tag) {
                endParagraph()
                let text = inline(of: child).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result.append(String(repeating: "#", count: level) + " " + text) }
            } else if tag == "ul" || tag == "ol" {
                endParagraph()
                let list = self.list(child, ordered: tag == "ol")
                if !list.isEmpty { result.append(list) }
            } else if tag == "blockquote" {
                endParagraph()
                let quoted = blocks(in: child).joined(separator: "\n\n")
                if !quoted.isEmpty {
                    result.append(quoted.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
                }
            } else if tag == "pre" {
                endParagraph()
                let code = (try? child.text(trimAndNormaliseWhitespace: false)) ?? ""
                if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append("```\n" + code.trimmingCharacters(in: .newlines) + "\n```")
                }
            } else if tag == "hr" {
                endParagraph()
                result.append("---")
            } else if tag == "br" {
                paragraph += "  \n"
            } else {
                paragraph += inline(of: child)
            }
        }
        endParagraph()
        return result
    }

    /// Text in a paragraph: collapsed, escaped, and escaped again where it opens a line.
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

    private func inline(of element: Element) -> String {
        let tag = element.tagName().lowercased()
        switch tag {
        case "br":
            return "  \n"
        case "img":
            return image(element)
        case "code", "kbd", "samp", "tt":
            let code = MoodleHTMLText.collapsedKeepingEdges((try? element.text()) ?? "")
            return code.trimmingCharacters(in: .whitespaces).isEmpty || code.contains("`") ? MoodleHTMLText.escaped(code) : "`\(code)`"
        default:
            break
        }
        var content = ""
        for child in element.getChildNodes() {
            if let textNode = child as? TextNode {
                content += MoodleHTMLText.escaped(MoodleHTMLText.collapsedKeepingEdges(textNode.getWholeText()))
            } else if let child = child as? Element, !MoodleHTMLText.skippedTags.contains(child.tagName().lowercased()) {
                content += inline(of: child)
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

    /// `**text**` with the spaces at its edges moved outside, which emphasis needs to open and close.
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

    private func list(_ element: Element, ordered: Bool) -> String {
        var lines: [String] = []
        var number = Int((try? element.attr("start")) ?? "") ?? 1
        for item in element.children().array() where item.tagName().lowercased() == "li" {
            let marker = ordered ? "\(number). " : "- "
            let content = blocks(in: item).joined(separator: "\n")
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

    /// Whether `tag` sets its content apart from the text around it.
    static func separatesText(_ tag: String) -> Bool {
        blockTags.contains(tag) || headingLevel(tag) != nil
            || ["ul", "ol", "li", "blockquote", "pre", "hr"].contains(tag)
    }

    private static func headingLevel(_ tag: String) -> Int? {
        guard tag.count == 2, tag.hasPrefix("h"), let level = Int(tag.dropFirst()), (1...6).contains(level) else { return nil }
        return level
    }

    /// The link `href` names, made absolute against `baseURL`, when it is http, https or mailto.
    static func linkURL(_ href: String, baseURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }
}
