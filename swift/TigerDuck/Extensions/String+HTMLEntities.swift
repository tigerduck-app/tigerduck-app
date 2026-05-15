import Foundation

extension String {
    /// Decode common HTML entities Moodle hands back in assignment titles
    /// and course full-names (e.g. `Assignment 1 &amp; 2`). `&amp;` is
    /// substituted LAST so a doubly-encoded sequence like `&amp;lt;`
    /// resolves to the literal `&lt;` rather than `<`.
    func decodingHTMLEntities() -> String {
        var result = self
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&#x2F;", with: "/")
        result = result.replacingOccurrences(of: "&#x27;", with: "'")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }
}
