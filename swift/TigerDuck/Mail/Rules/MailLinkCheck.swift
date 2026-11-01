#if os(iOS)
import Foundation

nonisolated enum MailLinkCheck {
    /// The ASCII whitespace class is spelled out instead of `\s`: Java's `\s` is ASCII-only but
    /// ICU's, which `NSRegularExpression` uses, is Unicode-wide, so `\s` would end the match where
    /// Android runs on.
    private static let emailDelimiters = "\\x{20}\\x{09}\\x{0A}\\x{0B}\\x{0C}\\x{0D}@<>()\",;:"
    static let emailPattern = try! NSRegularExpression(
        pattern: "[^\(emailDelimiters)]+@[^\(emailDelimiters)]+\\.[^\(emailDelimiters)]+"
    )

    /// ICU's `.` (`NSRegularExpression`) excludes more line terminators than Java's, among them
    /// U+000B and U+000C, and ICU's `\d` is Unicode-wide where Java's is ASCII. So this pattern and
    /// `plainHttpLinkPattern` spell out `[^\n\r\u0085\u2028\u2029]` for Java's `.`, as regex
    /// escapes in the pattern string rather than Swift's `\u{...}`, and `[0-9]` for `\d`.
    private static let shownHostPattern = try! NSRegularExpression(
        pattern: "^(?:[a-z][a-z0-9+.-]*://)?((?:[\\p{L}\\p{N}-]+\\.)+[\\p{L}]{2,})(?::[0-9]+)?(?:[/?#][^\\n\\r\\u0085\\u2028\\u2029]*)?$",
        options: [.caseInsensitive]
    )

    private static let urlHostLegacyPattern = try! NSRegularExpression(
        pattern: "^[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^/?#@]*@)?([^/?#:]+)", options: [.caseInsensitive]
    )

    /// No `.caseInsensitive`: its Unicode case folding lets `[A-Za-z]` match lookalikes such as the
    /// Kelvin sign U+212A and the long s U+017F, which can pass inside `https`, letting a non-ASCII
    /// host or scheme pass as ASCII.
    private static let plainHttpLinkPattern = try! NSRegularExpression(
        pattern: "^[Hh][Tt][Tt][Pp][Ss]?://([A-Za-z0-9.-]+)(?::[0-9]+)?(?:[/?#][^\\n\\r\\u0085\\u2028\\u2029]*)?$"
    )

    static func isPlainSchoolLink(_ href: String, config: MailServerConfig) -> Bool {
        let range = NSRange(href.startIndex..., in: href)
        guard let match = plainHttpLinkPattern.firstMatch(in: href, range: range),
              let hostRange = Range(match.range(at: 1), in: href) else { return false }
        return MailSchoolDomain.isSchoolDomain(String(href[hostRange]), config: config)
    }

    private static func hostOf(_ href: String) -> String? {
        let range = NSRange(href.startIndex..., in: href)
        if let schemeMatch = MailHref.schemePattern.firstMatch(in: href, range: range),
           let fullRange = Range(schemeMatch.range, in: href),
           let schemeRange = Range(schemeMatch.range(at: 1), in: href) {
            let scheme = href[schemeRange]
            if ASCIIText.isASCIICaseInsensitiveEqual(scheme, "http") || ASCIIText.isASCIICaseInsensitiveEqual(scheme, "https") {
                return browserHostOf(href, authorityStart: fullRange.upperBound)
            }
        }
        guard let match = urlHostLegacyPattern.firstMatch(in: href, range: range),
              let hostRange = Range(match.range(at: 1), in: href) else { return nil }
        let host = String(href[hostRange])
        guard !host.isEmpty else { return nil }
        return MailHref.toASCII(MailSchoolDomain.normalizedDomain(host))
    }

    /// All scanning here is on `unicodeScalars`, never on `String`'s default `Character`
    /// (extended grapheme cluster) view: a combining mark attaches to whatever scalar
    /// precedes it, so `Character`-based comparison of `/`, `\`, `?`, `#`, `@`, `[`, `]` or
    /// `:` can silently merge one of those separators into a bogus, non-matching cluster.
    private static func browserHostOf(_ href: String, authorityStart: String.Index) -> String? {
        let scalars = href.unicodeScalars
        var start = authorityStart
        while start < scalars.endIndex, scalars[start] == "/" || scalars[start] == "\\" {
            start = scalars.index(after: start)
        }
        var end = scalars.endIndex
        var cursor = start
        while cursor < scalars.endIndex {
            let c = scalars[cursor]
            if c == "/" || c == "\\" || c == "?" || c == "#" {
                end = cursor
                break
            }
            cursor = scalars.index(after: cursor)
        }
        let authority = scalars[start..<end]
        var afterUserinfo = authority
        if let lastAt = authority.lastIndex(of: "@") {
            afterUserinfo = authority[authority.index(after: lastAt)...]
        }
        var host = afterUserinfo
        if afterUserinfo.first == "[" {
            if let closing = afterUserinfo.firstIndex(of: "]") {
                host = afterUserinfo[afterUserinfo.startIndex...closing]
            }
        } else if let colon = afterUserinfo.firstIndex(of: ":") {
            host = afterUserinfo[afterUserinfo.startIndex..<colon]
        }
        guard !host.isEmpty else { return nil }
        return MailHref.toASCII(MailSchoolDomain.normalizedDomain(String(host)))
    }

    static func linkIssues(text rawText: String, href rawHref: String) -> [MailLinkIssue] {
        let href = MailHref.sanitizeHref(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = MailTextCleaner.visibleText(rawText).trimmingCharacters(in: .whitespacesAndNewlines)

        if ASCIIText.hasASCIICaseInsensitivePrefix(href, "mailto:") {
            let target = href.dropFirst("mailto:".count).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
            let real = (target.removingPercentEncoding ?? target).lowercased()
            if let shown = firstEmail(in: text), shown.lowercased() != real {
                return [.mismatch(shownHost: shown.lowercased(), realHost: real)]
            }
            return []
        }

        guard let rawHost = hostOf(href) else { return [] }
        let realHost = stripWWW(rawHost)
        var issues: [MailLinkIssue] = []
        if ASCIIText.hasASCIICaseInsensitivePrefix(href, "http://") {
            issues.append(.insecure)
        }
        if realHost.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
            issues.append(.punycode(host: realHost))
        }
        if let shownHost = hostShown(in: text), shownHost != realHost, !realHost.hasSuffix("." + shownHost) {
            issues.append(.mismatch(shownHost: shownHost, realHost: realHost))
        }
        return issues
    }

    static func firstEmail(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = emailPattern.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        var email = String(text[swiftRange])
        while email.hasSuffix(".") { email.removeLast() }
        return email
    }

    private static func hostShown(in text: String) -> String? {
        if let host = matchedHost(in: text) { return host }
        let rejoined = joiningWhitespaceTouchingADot(text)
        guard rejoined != text else { return nil }
        return matchedHost(in: rejoined)
    }

    private static func matchedHost(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = shownHostPattern.firstMatch(in: text, range: range),
              let hostRange = Range(match.range(at: 1), in: text) else { return nil }
        return stripWWW(MailHref.toASCII(MailSchoolDomain.normalizedDomain(String(text[hostRange]))))
    }

    private static func joiningWhitespaceTouchingADot(_ text: String) -> String {
        let dot = Unicode.Scalar(".")
        let scalars = Array(text.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index].properties.isWhitespace else {
                kept.append(scalars[index])
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, scalars[end].properties.isWhitespace { end += 1 }
            let touchesADot = (index > 0 && scalars[index - 1] == dot) || (end < scalars.count && scalars[end] == dot)
            if !touchesADot { kept.append(contentsOf: scalars[index..<end]) }
            index = end
        }
        return String(kept)
    }

    private static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
#endif
