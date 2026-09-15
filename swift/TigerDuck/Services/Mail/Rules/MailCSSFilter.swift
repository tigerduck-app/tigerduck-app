#if os(iOS)
import Foundation

/// The `style` attribute rules of Appendix A.2.
nonisolated enum MailCSSFilter {
    static let allowedProperties: Set<String> = [
        "color", "background-color", "font", "font-family", "font-size", "font-style", "font-weight",
        "text-align", "text-decoration", "text-indent", "text-transform", "line-height", "letter-spacing",
        "word-spacing", "white-space", "direction", "vertical-align", "margin", "padding", "border",
        "border-radius", "border-collapse", "border-spacing", "width", "min-width", "max-width", "height",
        "min-height", "max-height", "display", "list-style", "list-style-type", "list-style-position",
        "table-layout", "float", "clear", "overflow",
    ]
    /// `margin-*`, `padding-*` and `border-*` longhands.
    static let allowedPrefixes = ["margin-", "padding-", "border-"]
    static let allowedDisplayValues: Set<String> = [
        "block", "inline", "inline-block", "table", "table-row", "table-cell", "list-item", "none",
    ]
    /// Case-insensitive substrings that void a declaration outright. `image-set`,
    /// `-webkit-image-set`, `image(`, `cross-fade` and `element(` are CSS image-loading
    /// functions that can fetch a remote resource just like `url(` (controller ruling,
    /// 2026-09-16, mirrors Android's `CssFilter.FORBIDDEN`).
    static let forbiddenValueFragments = [
        "url(", "expression", "@import", "behavior", "-moz-binding", "javascript:", "\\", "/*",
        "image-set", "-webkit-image-set", "image(", "cross-fade", "element(",
    ]

    /// The surviving declarations joined with `"; "`, or nil when none survive.
    static func filter(_ style: String) -> String? {
        let kept = style.split(separator: ";").compactMap { declaration -> String? in
            guard let colon = declaration.firstIndex(of: ":") else { return nil }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !property.isEmpty, !value.isEmpty, isAllowed(property: property) else { return nil }
            let lowered = value.lowercased()
            guard !forbiddenValueFragments.contains(where: { lowered.contains($0) }) else { return nil }
            if property == "display" {
                let bare = lowered.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
                guard allowedDisplayValues.contains(bare) else { return nil }
            }
            return "\(property): \(value)"
        }
        return kept.isEmpty ? nil : kept.joined(separator: "; ")
    }

    static func isAllowed(property: String) -> Bool {
        allowedProperties.contains(property) || allowedPrefixes.contains(where: { property.hasPrefix($0) })
    }
}
#endif
