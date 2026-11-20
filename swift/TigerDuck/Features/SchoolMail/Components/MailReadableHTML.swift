#if os(iOS)
import Foundation
import SwiftSoup
import os

nonisolated struct MailReadableHTML {
    typealias RGBA = MailCSSColor.RGBA
    static let maximumSearches = 2_000

    let setsColors: Bool
    private let html: String
    /// Held whole: a node finds its output settings through its document, which a node alone
    /// does not keep alive.
    private let document: Document?
    private let nodes: [Node]
    private let targets: [String]

    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.Contrast")

    init(_ html: String) {
        self.html = html
        targets = Self.targets(in: html)
        var setsColors = false
        var nodes: [Node] = []
        var document: Document?
        do {
            let parsed = try SwiftSoup.parseBodyFragment(html)
            parsed.outputSettings().prettyPrint(pretty: false)
            document = parsed
            var stack = (parsed.body()?.children().array() ?? []).reversed()
                .map { Visit(element: $0, depth: 1, backdrop: Backdrop(), parent: nil) }
            while let visit = stack.popLast() {
                guard !Task.isCancelled else {
                    nodes = []
                    break
                }
                let style = Style(try visit.element.attr("style"))
                if try Self.setsColor(visit.element, style: style) { setsColors = true }
                var (backdrop, parent) = (visit.backdrop, visit.parent)
                if visit.depth <= AppConstants.maximumHTMLDepth {
                    let layer = try Self.layer(of: visit.element, style: style)
                    backdrop = visit.backdrop.adding(layer)
                    if let node = try Self.node(visit.element, style: style, layer: layer, backdrop: backdrop, parent: parent) {
                        nodes.append(node)
                        parent = nodes.count - 1
                    }
                }
                // WebKit paints a table's background and border over its grid only, not its caption,
                // while both keep their table display.
                let captionBackdrop = visit.element.tagName() == "table" && Self.keepsDisplay(style, ["table", "inline-table"])
                    ? visit.backdrop : backdrop
                stack += try visit.element.children().array().reversed().map { child in
                    let outside = try child.tagName() == "caption"
                        && Self.keepsDisplay(Style(child.attr("style")), ["table-caption"])
                    return Visit(element: child, depth: visit.depth + 1, backdrop: outside ? captionBackdrop : backdrop, parent: parent)
                }
            }
        } catch {
            Self.logger.error("Mail colour read failed, colours left as sent: \(String(describing: type(of: error)), privacy: .public)")
            nodes = []
        }
        self.setsColors = setsColors
        self.document = document
        self.nodes = nodes
    }

    func html(on theme: MailHTMLTheme) -> String {
        guard let body = document?.body(), !nodes.isEmpty else { return html }
        let page = RGBA(theme.background)
        let (pageText, linkText) = (RGBA(theme.foreground), RGBA(theme.link))
        var shown: [Shown] = []
        shown.reserveCapacity(nodes.count)
        var fixes = Fixes()
        var changed = false
        do {
            for node in nodes {
                guard !Task.isCancelled else { return html }
                let inherited = node.parent.map { shown[$0] } ?? Shown(intended: pageText, displayed: pageText)
                let behind = node.backdrop.over(page)
                var now = inherited
                var fix: RGBA?
                switch node.kind {
                case .own(let sent):
                    if sent.inherits {
                        fix = Self.fix(inherited, on: behind, &fixes)
                    } else {
                        now = Shown(intended: sent.color, displayed: sent.color)
                        if let text = sent.color, text.alpha > 0, let behind { fix = fixes.readable(text.over(behind), on: behind) }
                    }
                    try Self.set(sent.attribute, of: node.element,
                                 to: fix.map { sent.value.replacingCharacters(in: sent.range, with: $0.css) } ?? sent.value)
                case .link:
                    now = Shown(intended: linkText, displayed: linkText)
                    if node.backdrop.alpha > 0, let behind { fix = fixes.readable(linkText, on: behind) }
                    try node.give(fix)
                case .background:
                    fix = Self.fix(inherited, on: behind, &fixes)
                    try node.give(fix)
                }
                if let fix {
                    now.displayed = fix
                    changed = true
                }
                shown.append(now)
            }
            guard changed else { return html }
            let output = try body.html()
            return Self.targets(in: output) == targets ? output : html
        } catch {
            Self.logger.error("Mail colour rewrite failed, colours left as sent: \(String(describing: type(of: error)), privacy: .public)")
            return html
        }
    }

    /// What text in an inherited colour needs on `behind`: nothing while the colour shown reads
    /// there, else the colour the sender meant, made readable.
    private static func fix(_ inherited: Shown, on behind: RGBA?, _ fixes: inout Fixes) -> RGBA? {
        guard let behind, let displayed = inherited.displayed, displayed.alpha > 0, !MailCSSColor.reads(displayed.over(behind), on: behind),
              let intended = inherited.intended, intended.alpha > 0 else { return nil }
        return fixes.readable(intended.over(behind), on: behind) ?? intended.over(behind)
    }

    private nonisolated struct Visit {
        let element: Element
        let depth: Int
        let backdrop: Backdrop
        let parent: Int?
    }

    private nonisolated struct Node {
        nonisolated enum Kind {
            case own(Sent)
            case link
            case background
        }

        let element: Element
        let kind: Kind
        let backdrop: Backdrop
        let parent: Int?
        let style: String?

        func give(_ color: RGBA?) throws {
            let given = color.map { color in style.map { "\($0); color: \(color.css)" } ?? "color: \(color.css)" }
            try MailReadableHTML.set("style", of: element, to: given ?? style)
        }
    }

    private nonisolated struct Sent {
        let color: RGBA?
        var inherits = false
        let attribute: String
        let value: String
        let range: Range<String.Index>
    }

    private nonisolated struct Shown {
        var intended: RGBA?
        var displayed: RGBA?
    }

    private nonisolated enum Layer {
        case none
        case unknown
        case color(RGBA)
    }

    private nonisolated struct Backdrop {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var alpha = 0.0
        var isUnknown = false

        func adding(_ layer: Layer) -> Backdrop {
            switch layer {
            case .none:
                return self
            case .unknown:
                return Backdrop(red: red, green: green, blue: blue, alpha: alpha, isUnknown: true)
            case .color(let top) where top.alpha >= 1:
                return Backdrop(red: top.red, green: top.green, blue: top.blue, alpha: 1)
            case .color(let top):
                let kept = 1 - top.alpha
                return Backdrop(red: top.red * top.alpha + red * kept, green: top.green * top.alpha + green * kept,
                                blue: top.blue * top.alpha + blue * kept, alpha: top.alpha + alpha * kept, isUnknown: isUnknown)
            }
        }

        func over(_ page: RGBA) -> RGBA? {
            guard !isUnknown else { return nil }
            let kept = 1 - alpha
            return RGBA(red: red + page.red * kept, green: green + page.green * kept, blue: blue + page.blue * kept)
        }
    }

    private nonisolated struct Style {
        nonisolated struct Declaration {
            let property: String
            let value: Substring
            let isImportant: Bool
        }

        let text: String
        let declarations: [Declaration]

        init(_ text: String) {
            self.text = text
            declarations = text.split(separator: ";").compactMap { piece in
                guard let colon = piece.firstIndex(of: ":") else { return nil }
                var value = MailCSSColor.trimmed(piece[piece.index(after: colon)...])
                var isImportant = false
                if let bang = value.lastIndex(of: "!"),
                   value[value.index(after: bang)...].trimmingCharacters(in: .whitespaces).lowercased() == "important" {
                    value = MailCSSColor.trimmed(value[..<bang])
                    isImportant = true
                }
                let property = piece[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return Declaration(property: property, value: value, isImportant: isImportant)
            }
        }

        func effective(_ property: String) -> Declaration? {
            let matching = declarations.filter { $0.property == property }
            return matching.last(where: \.isImportant) ?? matching.last
        }

        func declares(_ properties: Set<String>) -> Bool {
            declarations.contains { properties.contains($0.property) && $0.value.lowercased() != "none" }
        }
    }

    private static func legacyValue(_ name: String, of element: Element) throws -> Substring? {
        let value = MailCSSColor.trimmed(try element.attr(name)[...])
        return value.isEmpty || value.lowercased() == "transparent" ? nil : value
    }

    private static func set(_ name: String, of element: Element, to value: String?) throws {
        let current: String? = element.hasAttr(name) ? try element.attr(name) : nil
        guard current != value else { return }
        if let value { try element.attr(name, value) } else { try element.removeAttr(name) }
    }

    private static func keepsDisplay(_ style: Style, _ defaults: Set<String>) -> Bool {
        style.effective("display").map { defaults.contains($0.value.lowercased()) } ?? true
    }

    private static func setsColor(_ element: Element, style: Style) throws -> Bool {
        let text = try style.effective("color").map { shows($0.value) }
            ?? (element.tagName() == "font" && legacyValue("color", of: element) != nil)
        let background = try style.effective("background-color").map { shows($0.value, onBackground: true) }
            ?? (legacyValue("bgcolor", of: element) != nil)
        return text || background
    }

    private static func shows(_ value: Substring, onBackground: Bool = false) -> Bool {
        guard let color = MailCSSColor.parse(value, legacy: false) else {
            let keyword = value.lowercased()
            if onBackground { return keyword == "currentcolor" || !(colorlessKeywords.contains(keyword) || keyword == "initial") }
            return !colorlessKeywords.contains(keyword)
        }
        return color.alpha > 0
    }

    /// Keywords that set no colour of their own. Not `initial`: on `color` it is the initial colour,
    /// which WebKit has drawn black under a dark `color-scheme`
    /// (https://github.com/w3c/csswg-drafts/issues/9274), so it counts as a colour.
    private static let colorlessKeywords: Set<String> = ["currentcolor", "inherit", "unset", "revert", "revert-layer"]

    private static func layer(of element: Element, style: Style) throws -> Layer {
        if style.declares(["border-image", "border-image-source"]) { return .unknown }
        if element.tagName() == "table", try paintsColumns(element) { return .unknown }
        if let declaration = style.effective("background-color") {
            if ["initial", "unset"].contains(declaration.value.lowercased()) { return .none }
            return MailCSSColor.parse(declaration.value, legacy: false).map(Layer.color) ?? .unknown
        }
        guard let value = try legacyValue("bgcolor", of: element) else { return .none }
        return MailCSSColor.parse(value, legacy: true).map(Layer.color) ?? .unknown
    }

    private static func paintsColumns(_ table: Element) throws -> Bool {
        for group in table.children().array() where group.tagName() == "colgroup" {
            for column in [group] + group.children().array() {
                if Style(try column.attr("style")).effective("background-color") != nil { return true }
            }
        }
        return false
    }

    private static func node(_ element: Element, style: Style, layer: Layer, backdrop: Backdrop, parent: Int?) throws -> Node? {
        let kind: Node.Kind
        if let sent = try sentColor(of: element, style: style) {
            kind = .own(sent)
        } else if element.tagName() == "a", element.hasAttr("href") {
            kind = .link
        } else if case .color(let color) = layer, color.alpha > 0, !backdrop.isUnknown {
            kind = .background
        } else if element.tagName() == "caption", !backdrop.isUnknown {
            kind = .background
        } else {
            return nil
        }
        return Node(element: element, kind: kind, backdrop: backdrop, parent: parent,
                    style: element.hasAttr("style") ? style.text : nil)
    }

    private static func sentColor(of element: Element, style: Style) throws -> Sent? {
        if let declaration = style.effective("color") {
            return Sent(color: MailCSSColor.parse(declaration.value, legacy: false),
                        inherits: ["inherit", "currentcolor", "unset"].contains(declaration.value.lowercased()),
                        attribute: "style", value: style.text, range: declaration.value.startIndex..<declaration.value.endIndex)
        }
        guard element.tagName() == "font", let value = try legacyValue("color", of: element) else { return nil }
        return Sent(color: MailCSSColor.parse(value, legacy: true), attribute: "color", value: String(value.base),
                    range: value.startIndex..<value.endIndex)
    }

    private static let targetPattern = try! NSRegularExpression(pattern: #"\s(?:href|src)="[^"]*""#)

    /// Every double-quoted `href` and `src` in `html`, in order. That is all of them: `html` is
    /// SwiftSoup's output, which quotes so, and a page reuses those bytes for what it leaves alone.
    static func targets(in html: String) -> [String] {
        targetPattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
            .compactMap { Range($0.range, in: html).map { String(html[$0]) } }
    }

    private nonisolated struct Fixes {
        private nonisolated struct Pair: Hashable {
            let text: RGBA
            let background: RGBA
        }

        private var known: [Pair: RGBA?] = [:]

        mutating func readable(_ text: RGBA, on background: RGBA) -> RGBA? {
            let pair = Pair(text: text, background: background)
            if let fix = known[pair] { return fix }
            let fix = MailCSSColor.readable(text, on: background, searching: known.count < MailReadableHTML.maximumSearches)
            known[pair] = .some(fix)
            return fix
        }
    }

}
#endif
