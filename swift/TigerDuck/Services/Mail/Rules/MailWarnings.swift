#if os(iOS)
import Foundation

nonisolated enum MailRiskReason: String, Codable, Sendable {
    case dangerousExtension, doubleExtension, typeMismatch, encryptedArchive
}

nonisolated enum MailWarning: Equatable, Sendable {
    case externalSender(address: String)
    case displayNameMismatch(address: String)
    case passwordBait
    case riskyAttachment(filename: String, reason: MailRiskReason)
}

nonisolated enum MailLinkIssue: Equatable, Sendable {
    case insecure
    case punycode(host: String)
    case mismatch(shownHost: String, realHost: String)
}

nonisolated struct MailAttachmentInfo: Equatable, Sendable {
    var filename: String
    var contentType: String?
}

nonisolated struct MailWarningInput: Sendable {
    var fromAddress: String
    var fromName: String?
    var subject: String
    var plainText: String
    var links: [MailLink]
    var attachments: [MailAttachmentInfo]
}

/// Appendix A.4, word for word. Identical on Android (shared fixture `warnings.json`).
nonisolated enum MailWarnings {
    static let passwordKeywords = [
        "密碼", "帳號驗證", "驗證帳號", "帳號停用", "停用帳號", "帳號異常", "信箱容量", "信箱已滿",
        "重新驗證", "重新登入", "登入驗證", "立即驗證", "解除封鎖", "password", "verify your account",
        "account verification", "mailbox quota", "mailbox full", "revalidate", "re-validate",
        "account suspended", "unusual sign-in",
    ]
    static let dangerousExtensions: Set<String> = [
        "apk", "apks", "xapk", "aab", "exe", "msi", "msix", "appx", "bat", "cmd", "com", "scr", "pif", "cpl",
        "vbs", "vbe", "js", "jse", "wsf", "wsh", "ps1", "psm1", "jar", "lnk", "hta", "chm", "reg", "sh",
        "command", "app", "ipa", "iso", "img", "vhd", "vhdx", "dmg", "pkg", "html", "htm", "shtml", "xhtml",
        "mht", "mhtml", "svg", "docm", "xlsm", "pptm",
    ]
    static let decoyExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "jpg", "jpeg", "png", "gif", "txt", "zip",
    ]
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz"]
    static let archivePasswordHints = ["密碼", "password", "解壓縮"]
    /// Extensions whose attachments are never rendered inside the app (§9.5).
    static let neverRenderInApp: Set<String> = ["html", "htm", "shtml", "xhtml", "mht", "mhtml", "svg"]

    private static let emailPattern = try! NSRegularExpression(
        pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive]
    )

    /// The text a link claims to point at (spec A.4 rule 2, link mismatch). Unicode-aware
    /// (`\p{L}`/`\p{N}`) so a homograph host spelled in another script is still recognized as
    /// host-shaped text and checked against the real host, instead of being silently skipped
    /// (parity fix, mirrors Android's `HOST_LIKE`). `www.` is stripped afterwards by the
    /// caller, not inside this pattern.
    ///
    /// ICU's `.` (used by `NSRegularExpression`) excludes more "line terminator" code points
    /// than Java's `.` does — notably U+000B and U+000C, which Java's `.` matches like any
    /// other character — and ICU's `\d` is Unicode-wide where Java's is ASCII-only. Both
    /// patterns spell these out explicitly instead, so the two platforms agree:
    /// `[^\n\r\u0085\u2028\u2029]` for "any character Java's `.` would match" (written with
    /// ASCII regex escapes in the pattern string, not Swift's `\u{...}`) and `[0-9]` for `\d`.
    private static let shownHostPattern = try! NSRegularExpression(
        pattern: "^(?:[a-z][a-z0-9+.-]*://)?((?:[\\p{L}\\p{N}-]+\\.)+[\\p{L}]{2,})(?::[0-9]+)?(?:[/?#][^\\n\\r\\u0085\\u2028\\u2029]*)?$",
        options: [.caseInsensitive]
    )

    private static let schemePattern = try! NSRegularExpression(pattern: "^([a-zA-Z][a-zA-Z0-9+.-]*):")

    /// Fallback host extraction for schemes other than http/https (mirrors Android's
    /// `URL_HOST_LEGACY`): requires a literal `://`, then takes everything up to the first
    /// `/ ? # :`, skipping one leading `userinfo@` if present.
    private static let urlHostLegacyPattern = try! NSRegularExpression(
        pattern: "^[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^/?#@]*@)?([^/?#:]+)", options: [.caseInsensitive]
    )

    /// A whole href counts as a "plain" link ONLY in the form browsers would treat as
    /// unambiguous: `http(s)://`, a host of ASCII letters/digits/-/. only, an optional
    /// `:port`, then end of string or `/ ? #` (spec A.4 rule 3, password bait). Anything else
    /// (userinfo, backslashes, missing or extra slashes, percent-escapes or non-ASCII in the
    /// authority, whitespace) fails this and counts as an outside link.
    ///
    /// No `.caseInsensitive`: that option also turns on Unicode case folding, which makes
    /// `[A-Za-z]` accept lookalikes such as the Kelvin sign (U+212A, folds to `k`), dotted and
    /// dotless I (U+0130/U+0131), and Latin small letter long s (U+017F, folds to `s`, so it
    /// could pass inside `https`) — letting a non-ASCII host or scheme pass as if it were
    /// ASCII. The scheme is spelled out per letter instead so it stays exactly `http`/`https`.
    /// (Same ICU-`.`-vs-Java-`.` note as `shownHostPattern` above applies to the trailing
    /// `[/?#]...` group here.)
    private static let plainHttpLinkPattern = try! NSRegularExpression(
        pattern: "^[Hh][Tt][Tt][Pp][Ss]?://([A-Za-z0-9.-]+)(?::[0-9]+)?(?:[/?#][^\\n\\r\\u0085\\u2028\\u2029]*)?$"
    )

    // MARK: Domains

    static func normalizedDomain(_ raw: String) -> String {
        var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        return domain
    }

    static func isSchoolDomain(_ raw: String) -> Bool {
        let domain = normalizedDomain(raw)
        return domain == "ntust.edu.tw" || domain.hasSuffix(".ntust.edu.tw")
    }

    static func domain(ofAddress address: String) -> String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return normalizedDomain(String(address[address.index(after: at)...]))
    }

    // MARK: Browser-style host parsing

    /// WHATWG URL pre-processing `MailWarnings` cannot assume a caller already did (spec A.4
    /// rule 1): strip leading C0 controls and space, then remove ASCII tab/CR/LF wherever they
    /// occur (not just at the ends), so a scheme or host split across a control character —
    /// e.g. `ht\ttps://evil.example/` — can't dodge the scheme check or the host parsing below.
    private static func sanitizeHref(_ href: String) -> String {
        let dropped = href.unicodeScalars.drop { $0.value <= 0x1F || $0 == " " }
        let filtered = dropped.filter { $0 != "\t" && $0 != "\r" && $0 != "\n" }
        return String(String.UnicodeScalarView(filtered))
    }

    /// `A`-`Z` folds to `a`-`z`; every other scalar is returned unchanged. Deliberately not
    /// `Unicode.Scalar.properties`-based or full Unicode case mapping: `String.lowercased()`
    /// can expand a single character into several scalars (e.g. U+0130 LATIN CAPITAL LETTER I
    /// WITH DOT ABOVE -> "i" + U+0307), which can shift where a fixed ASCII keyword like
    /// `http` is found. Used instead of `String.lowercased()` for every scheme/prefix check
    /// below.
    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard scalar.value >= 0x41, scalar.value <= 0x5A, let lowered = Unicode.Scalar(scalar.value + 0x20) else {
            return scalar
        }
        return lowered
    }

    /// ASCII case-insensitive prefix check, scalar by scalar. Not `String.hasPrefix`, which
    /// compares `Character`s (extended grapheme clusters): a combining mark attaches to
    /// whatever scalar precedes it — including `/` or another scheme letter — merging it into
    /// one `Character` that no longer equals the plain ASCII character `hasPrefix` is looking
    /// for (spec A.4 rule 1/2/3 parity; this is the same class of bug `browserHostOf` guards
    /// against below). `prefix` must itself be lowercase ASCII.
    private static func hasASCIICaseInsensitivePrefix(_ text: String, _ prefix: String) -> Bool {
        var iterator = text.unicodeScalars.makeIterator()
        for expected in prefix.unicodeScalars {
            guard let next = iterator.next(), asciiLowercased(next) == expected else { return false }
        }
        return true
    }

    /// ASCII case-insensitive whole-string equality, scalar by scalar (see
    /// `hasASCIICaseInsensitivePrefix`). `other` must itself be lowercase ASCII.
    private static func isASCIICaseInsensitiveEqual(_ text: some StringProtocol, _ other: String) -> Bool {
        let textScalars = Array(text.unicodeScalars)
        let otherScalars = Array(other.unicodeScalars)
        guard textScalars.count == otherScalars.count else { return false }
        return zip(textScalars, otherScalars).allSatisfy { asciiLowercased($0) == $1 }
    }

    // Minor, accepted parity differences from Android that never widen what counts as a
    // school link (they never hide an outside link or suppress a real mismatch):
    //  - the surrounding-whitespace trim (`.trimmingCharacters(in: .whitespacesAndNewlines)`,
    //    applied after `sanitizeHref`) strips a broader Unicode whitespace set than WHATWG's
    //    C0-control-and-space-only trim; `sanitizeHref`'s own leading trim already matches
    //    WHATWG exactly, so this only ever trims *more*, never less.
    //  - `toASCII` follows UTS46 (via `URLComponents`); Android's `java.net.IDN` follows the
    //    older IDNA2003 mapping tables, which can disagree on a handful of deprecated
    //    characters (e.g. German sharp s, Greek final sigma).
    //  - a scheme with a combining mark spliced into the letters themselves, e.g.
    //    `http\u{0307}s://...`, is not `http`/`https` per WHATWG either (no real browser
    //    parses it as that scheme), so `schemePattern` failing to match it and `hostOf`
    //    falling through is the same outcome a browser would reach.

    /// IDNA-to-ASCII, a no-op for a host that is already pure ASCII (so an IPv6 literal's
    /// `[...]` brackets, ports already stripped by the caller, etc. pass through unchanged —
    /// mirrors `java.net.IDN.toASCII`, which only transforms labels containing non-ASCII
    /// characters). Falls back to the input unchanged if conversion fails.
    private static func toASCII(_ host: String) -> String {
        guard host.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return host }
        var components = URLComponents()
        components.host = host
        guard let converted = components.url?.host, !converted.isEmpty else { return host }
        return converted.lowercased()
    }

    /// True only when [href] matches [plainHttpLinkPattern] and that host is a school domain
    /// (spec A.4 rule 3, password bait).
    private static func isPlainSchoolLink(_ href: String) -> Bool {
        let range = NSRange(href.startIndex..., in: href)
        guard let match = plainHttpLinkPattern.firstMatch(in: href, range: range),
              let hostRange = Range(match.range(at: 1), in: href) else { return false }
        return isSchoolDomain(String(href[hostRange]))
    }

    /// Browser-style host extraction (spec A.4 rule 2, link mismatch). For `http`/`https`
    /// (scheme matched ASCII case-insensitively): after `scheme:`, skip any run (zero or more)
    /// of `/` and `\`; the authority ends at the first `/`, `\`, `?` or `#`; userinfo ends at
    /// the LAST `@` in the authority; if the host starts with `[`, it runs through the
    /// matching `]` (IPv6), otherwise it ends before `:port`; then the existing normalization
    /// and IDNA-to-ASCII. Other schemes fall back to [urlHostLegacyPattern].
    private static func hostOf(_ href: String) -> String? {
        let range = NSRange(href.startIndex..., in: href)
        if let schemeMatch = schemePattern.firstMatch(in: href, range: range),
           let fullRange = Range(schemeMatch.range, in: href),
           let schemeRange = Range(schemeMatch.range(at: 1), in: href) {
            let scheme = href[schemeRange]
            if isASCIICaseInsensitiveEqual(scheme, "http") || isASCIICaseInsensitiveEqual(scheme, "https") {
                return browserHostOf(href, authorityStart: fullRange.upperBound)
            }
        }
        guard let match = urlHostLegacyPattern.firstMatch(in: href, range: range),
              let hostRange = Range(match.range(at: 1), in: href) else { return nil }
        let host = String(href[hostRange])
        guard !host.isEmpty else { return nil }
        return toASCII(normalizedDomain(host))
    }

    /// All scanning here is on `unicodeScalars`, never on `String`'s default `Character`
    /// (extended grapheme cluster) view: a combining mark attaches to whatever scalar
    /// precedes it, so `Character`-based comparison of `/`, `\`, `?`, `#`, `@`, `[`, `]` or
    /// `:` can silently merge one of those separators into a bogus, non-matching cluster —
    /// e.g. `/` immediately followed by a combining mark stops being `"/"` as a `Character` —
    /// letting the scan run straight past a real terminator or the true last `@` to a
    /// forged one further along (spec A.4 rule 2 parity).
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
        return toASCII(normalizedDomain(String(host)))
    }

    // MARK: Message warnings

    static func evaluate(_ input: MailWarningInput) -> [MailWarning] {
        var warnings: [MailWarning] = []
        let address = MailTextCleaner.clean(input.fromAddress).trimmingCharacters(in: .whitespaces)
        let external = !isSchoolDomain(domain(ofAddress: address))
        if external {
            warnings.append(.externalSender(address: address))
        }
        if let name = input.fromName.map(MailTextCleaner.clean),
           let embedded = firstEmail(in: name),
           embedded.lowercased() != address.lowercased() {
            warnings.append(.displayNameMismatch(address: address))
        }

        // Bidi-stripped subject and body together, so a keyword hidden behind a bidi
        // override in either one still counts (controller ruling, 2026-09-16: the brief
        // only cleaned the subject, leaving the body's bidi controls in place).
        let haystack = MailTextCleaner.clean(input.subject + "\n" + input.plainText).lowercased()
        let keywordHit = passwordKeywords.contains { haystack.contains($0.lowercased()) }
        let linksOutside = input.links.contains { link in
            let href = sanitizeHref(link.href).trimmingCharacters(in: .whitespacesAndNewlines)
            return hasASCIICaseInsensitivePrefix(href, "http") && !isPlainSchoolLink(href)
        }
        if keywordHit && (external || linksOutside) {
            warnings.append(.passwordBait)
        }

        for attachment in input.attachments {
            if let reason = attachmentRisk(filename: attachment.filename, contentType: attachment.contentType, subjectAndBody: haystack) {
                warnings.append(.riskyAttachment(filename: displayFilename(attachment.filename), reason: reason))
            }
        }
        return warnings
    }

    /// A.3-cleaned, trailing whitespace and dots removed, original case kept.
    static func displayFilename(_ raw: String) -> String {
        var name = MailTextCleaner.clean(raw)
        while let last = name.last, last == "." || last.isWhitespace { name.removeLast() }
        return name
    }

    /// Precedence when several apply: double extension, type mismatch, dangerous extension,
    /// then encrypted archive. [subjectAndBody] is bidi-stripped here too (not just by the
    /// caller) so a direct call with raw subject/body text is still checked correctly
    /// (controller ruling, 2026-09-16 — mirrors Android's `riskReason`, which re-strips
    /// defensively rather than trusting its caller).
    static func attachmentRisk(filename: String, contentType: String?, subjectAndBody: String) -> MailRiskReason? {
        let pieces = displayFilename(filename).lowercased().split(separator: ".").map(String.init)
        guard pieces.count >= 2, let ext = pieces.last else { return nil }
        let dangerous = dangerousExtensions.contains(ext)
        if dangerous, pieces.count >= 3, decoyExtensions.contains(pieces[pieces.count - 2]) {
            return .doubleExtension
        }
        if dangerous, let type = contentTypeWithoutParameters(contentType),
           type == "application/pdf" || type.hasPrefix("image/") || type == "text/plain" {
            return .typeMismatch
        }
        if dangerous { return .dangerousExtension }
        let lowered = MailTextCleaner.clean(subjectAndBody).lowercased()
        if archiveExtensions.contains(ext), archivePasswordHints.contains(where: { lowered.contains($0) }) {
            return .encryptedArchive
        }
        return nil
    }

    /// `"Application/PDF; name=x.pdf"` -> `"application/pdf"`. Not `private`: the message
    /// screen's `isNeverRenderedInApp(_:)` compares a content type the same parameter-stripped
    /// way this uses internally for `attachmentRisk` (fix round 2, critical 1 leftover) — a raw
    /// equality check against a real part's `type/subtype; charset=…` value never matches.
    static func contentTypeWithoutParameters(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.lowercased().split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func neverRenderedInApp(filename: String) -> Bool {
        let ext = displayFilename(filename).lowercased().split(separator: ".").last.map(String.init) ?? ""
        return neverRenderInApp.contains(ext)
    }

    // MARK: Links

    static func linkIssues(text rawText: String, href rawHref: String) -> [MailLinkIssue] {
        let href = sanitizeHref(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = MailTextCleaner.clean(rawText).trimmingCharacters(in: .whitespacesAndNewlines)

        if hasASCIICaseInsensitivePrefix(href, "mailto:") {
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
        if hasASCIICaseInsensitivePrefix(href, "http://") {
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

    // MARK: Helpers

    /// The first email-shaped match in `text`, with a sentence-ending `.` trimmed off
    /// (controller ruling, 2026-09-16 — matches Android's `firstEmail`, which does the
    /// same so a display name or mailto link text ending a sentence with the address
    /// doesn't produce a false mismatch).
    static func firstEmail(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = emailPattern.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        var email = String(text[swiftRange])
        while email.hasSuffix(".") { email.removeLast() }
        return email
    }

    private static func hostShown(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = shownHostPattern.firstMatch(in: text, range: range),
              let hostRange = Range(match.range(at: 1), in: text) else { return nil }
        return stripWWW(toASCII(normalizedDomain(String(text[hostRange]))))
    }

    private static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Canonicalization (message-screen dispatch addition 2)

    private struct BrowserURLParts {
        var host: String
        var port: Int?
        var path: String
        var query: String?
        var fragment: String?
    }

    /// Characters a path/query/fragment carries literally after canonicalization —
    /// unreserved (RFC 3986) plus sub-delims and the structural characters `:@/?#`. Mirrors
    /// Android's `PATH_SAFE` constant; anything else (space, control characters, quotes,
    /// brackets, any non-ASCII byte) is percent-encoded the way a browser's own
    /// canonicalization would.
    private static let pathSafeBytes: Set<UInt8> = {
        var set = Set<UInt8>()
        for scalar in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?#".unicodeScalars {
            set.insert(UInt8(scalar.value))
        }
        return set
    }()

    /// The href judged, shown and opened for a tapped link (message-screen dispatch,
    /// 2026-09-16 addition 2). For `http`/`https` (scheme matched ASCII case-insensitively),
    /// canonicalized once the way a browser would, using the same scalar-level authority
    /// parsing `browserHostOf` uses above: a backslash anywhere after the scheme folds to
    /// `/` (WHATWG: `\` is a path/authority separator for a "special" scheme), the authority
    /// ends at the first unescaped `/`, `?` or `#`, userinfo ends at the LAST `@`, a host
    /// starting with `[` runs to the matching `]` (IPv6), the default port for the scheme is
    /// dropped, and any byte in the path/query/fragment outside a safe set is freshly
    /// percent-encoded — an *existing* `%XX` escape is left exactly as it is (its hex digits
    /// uppercased) rather than decoded, since decoding it would change what the href means: a
    /// redirect/safelink URL's own `%2F`/`%23`/percent-encoded nested URL must survive intact.
    /// Any other scheme
    /// (`mailto:`, etc.) is returned trimmed and otherwise unchanged — never canonicalized.
    /// `nil` only when the href claims `http`/`https` but doesn't parse as `scheme://host…`
    /// with a non-empty host; the caller then shows the href as written, without an Open
    /// action, rather than guessing.
    static func canonicalHref(_ rawHref: String) -> String? {
        let href = sanitizeHref(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(href.startIndex..., in: href)
        guard let schemeMatch = schemePattern.firstMatch(in: href, range: range),
              let fullRange = Range(schemeMatch.range, in: href),
              let schemeRange = Range(schemeMatch.range(at: 1), in: href) else { return href }
        let scheme = href[schemeRange]
        let isHTTPS = isASCIICaseInsensitiveEqual(scheme, "https")
        guard isHTTPS || isASCIICaseInsensitiveEqual(scheme, "http") else { return href }
        let lowerScheme = isHTTPS ? "https" : "http"
        let rest = String(href[fullRange.upperBound...]).replacingOccurrences(of: "\\", with: "/")
        guard let parts = browserURLParts(rest) else { return nil }
        var result = "\(lowerScheme)://\(parts.host)"
        let defaultPort = isHTTPS ? 443 : 80
        if let port = parts.port, port != defaultPort { result += ":\(port)" }
        result += canonicalPathComponent(parts.path.isEmpty ? "/" : parts.path)
        if let query = parts.query { result += "?" + canonicalPathComponent(query) }
        if let fragment = parts.fragment { result += "#" + canonicalPathComponent(fragment) }
        return result
    }

    /// Parses `rest` (everything right after `scheme:`, backslashes already folded to `/`)
    /// the same tolerant, scalar-by-scalar way `browserHostOf` reads an authority (so a
    /// combining mark can't hide a separator), then splits whatever follows the authority
    /// into path/query/fragment. `nil` when the host ends up empty or a `:port` suffix isn't
    /// all-decimal.
    private static func browserURLParts(_ rest: String) -> BrowserURLParts? {
        let scalars = rest.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex, scalars[start] == "/" {
            start = scalars.index(after: start)
        }
        var end = scalars.endIndex
        var cursor = start
        while cursor < scalars.endIndex {
            let c = scalars[cursor]
            if c == "/" || c == "?" || c == "#" {
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
        var portString = ""
        var hasPort = false
        if afterUserinfo.first == "[" {
            if let closing = afterUserinfo.firstIndex(of: "]") {
                host = afterUserinfo[afterUserinfo.startIndex...closing]
                let afterBracket = afterUserinfo[afterUserinfo.index(after: closing)...]
                if afterBracket.first == ":" {
                    hasPort = true
                    portString = String(afterBracket[afterBracket.index(after: afterBracket.startIndex)...])
                }
            }
        } else if let colon = afterUserinfo.firstIndex(of: ":") {
            host = afterUserinfo[afterUserinfo.startIndex..<colon]
            hasPort = true
            portString = String(afterUserinfo[afterUserinfo.index(after: colon)...])
        }
        guard !host.isEmpty else { return nil }
        let normalizedHost = toASCII(normalizedDomain(String(host)))
        var port: Int?
        if hasPort {
            guard !portString.isEmpty,
                  portString.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
                  let value = Int(portString) else { return nil }
            port = value
        }
        let tail = String(rest[end...])
        var pathPart = tail
        var fragment: String?
        if let hash = pathPart.firstIndex(of: "#") {
            fragment = String(pathPart[pathPart.index(after: hash)...])
            pathPart = String(pathPart[..<hash])
        }
        var query: String?
        if let question = pathPart.firstIndex(of: "?") {
            query = String(pathPart[pathPart.index(after: question)...])
            pathPart = String(pathPart[..<question])
        }
        return BrowserURLParts(host: normalizedHost, port: port, path: pathPart, query: query, fragment: fragment)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
    }

    private static func hexDigitUppercased(_ byte: UInt8) -> UInt8 {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")) ? byte - 0x20 : byte
    }

    /// Never decodes (fix round 1, important 3: a decode-then-re-encode step here turned
    /// `/a%2Fb` into `/a/b` and `?u=https%3A%2F%2Fx` into a nested URL — exactly the shape of a
    /// redirect/safelink URL in real mail, so decoding changed what the href actually meant).
    /// Walks `raw` byte by byte instead: an existing well-formed `%XX` escape passes through
    /// unchanged except its hex is uppercased, and any other byte outside `pathSafeBytes` is
    /// freshly percent-encoded. Mirrors what Android's own display/open path does (OkHttp's
    /// `HttpUrl` preserves existing escapes) — the scalar-level parsing this type mirrors from
    /// `browserHostOf` is only ever used by Android as a *comparison key*, never as what's shown
    /// or opened.
    private static func canonicalPathComponent(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let bytes = Array(raw.utf8)
        var result = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count, isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2]) {
                result += "%"
                result.unicodeScalars.append(Unicode.Scalar(hexDigitUppercased(bytes[index + 1])))
                result.unicodeScalars.append(Unicode.Scalar(hexDigitUppercased(bytes[index + 2])))
                index += 3
                continue
            }
            if pathSafeBytes.contains(byte) {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
            index += 1
        }
        return result
    }
}
#endif
