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
    case mistypedRecipient
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
    var returnPath: String? = nil
}

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
    static let neverRenderInApp: Set<String> = ["html", "htm", "shtml", "xhtml", "mht", "mhtml", "svg"]

    /// Delimiter-based, like Android's `EMAIL`: the local part, host and TLD each run to the next
    /// delimiter, not over an ASCII allowlist. For Han characters before the `@`, a non-ASCII host
    /// or a one-letter TLD, all of which warn on Android, an ASCII-only pattern matches nothing and
    /// so warns of no display-name or `mailto:` mismatch.
    ///
    /// The ASCII whitespace class is spelled out instead of `\s`: Java's `\s` is ASCII-only but
    /// ICU's, which `NSRegularExpression` uses, is Unicode-wide, so `\s` would end the match where
    /// Android runs on. No `.caseInsensitive`: there are no letter ranges for it to fold.
    private static let emailDelimiters = "\\x{20}\\x{09}\\x{0A}\\x{0B}\\x{0C}\\x{0D}@<>()\",;:"
    private static let emailPattern = try! NSRegularExpression(
        pattern: "[^\(emailDelimiters)]+@[^\(emailDelimiters)]+\\.[^\(emailDelimiters)]+"
    )

    /// The text a link claims to point at, for the link-mismatch warning. Unicode-aware
    /// (`\p{L}`/`\p{N}`), like Android's `HOST_LIKE`, so a homograph host in another script is
    /// still read as a host and checked against the real one. The caller strips `www.` afterwards.
    ///
    /// ICU's `.` (`NSRegularExpression`) excludes more line terminators than Java's, among them
    /// U+000B and U+000C, and ICU's `\d` is Unicode-wide where Java's is ASCII. So this pattern and
    /// `plainHttpLinkPattern` spell out `[^\n\r\u0085\u2028\u2029]` for Java's `.`, as regex
    /// escapes in the pattern string rather than Swift's `\u{...}`, and `[0-9]` for `\d`.
    private static let shownHostPattern = try! NSRegularExpression(
        pattern: "^(?:[a-z][a-z0-9+.-]*://)?((?:[\\p{L}\\p{N}-]+\\.)+[\\p{L}]{2,})(?::[0-9]+)?(?:[/?#][^\\n\\r\\u0085\\u2028\\u2029]*)?$",
        options: [.caseInsensitive]
    )

    private static let schemePattern = try! NSRegularExpression(pattern: "^([a-zA-Z][a-zA-Z0-9+.-]*):")

    private static let urlHostLegacyPattern = try! NSRegularExpression(
        pattern: "^[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^/?#@]*@)?([^/?#:]+)", options: [.caseInsensitive]
    )

    /// An href is a "plain" link, for the password-bait warning, only in the form browsers treat
    /// as unambiguous: `http(s)://`, a host of ASCII letters, digits, `-` and `.`, an optional
    /// `:port`, then the end or `/ ? #`. Anything else (userinfo, backslashes, missing or extra
    /// slashes, percent-escapes or non-ASCII in the authority, whitespace) is an outside link.
    /// No `.caseInsensitive`: its Unicode case folding lets `[A-Za-z]` match lookalikes such as the
    /// Kelvin sign U+212A, dotted and dotless I (U+0130, U+0131) and the long s U+017F, which can
    /// pass inside `https`, letting a non-ASCII host or scheme pass as ASCII. The scheme is spelled
    /// out per letter. The trailing `[/?#]` group spells out Java's `.` as in `shownHostPattern`.
    private static let plainHttpLinkPattern = try! NSRegularExpression(
        pattern: "^[Hh][Tt][Tt][Pp][Ss]?://([A-Za-z0-9.-]+)(?::[0-9]+)?(?:[/?#][^\\n\\r\\u0085\\u2028\\u2029]*)?$"
    )

    static func normalizedDomain(_ raw: String) -> String {
        var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        return domain
    }

    static func isSchoolDomain(_ raw: String) -> Bool {
        isSchoolDomain(raw, config: MailServerConfig.effective)
    }

    static func isSchoolDomain(_ raw: String, config: MailServerConfig) -> Bool {
        config.isOwnDomain(normalizedDomain(raw))
    }

    static func domain(ofAddress address: String) -> String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return normalizedDomain(String(address[address.index(after: at)...]))
    }

    static var schoolMailDomain: String { MailServerConfig.effective.addressDomain }

    private static let maxDomainTypoEdits = 2

    /// RFC 5321 §4.5.5: a delivery status notification is sent with the null reverse-path, which
    /// the receiving server records as `Return-Path: <>`. That header comes from our side of the
    /// delivery, unlike the `From` display name ("Mail Deliver System"), which any sender can
    /// type, so it is the only bounce marker worth trusting. Only the opened message has it, from
    /// the full header `LiveMailClient.detailOptions` fetches; the list's ENVELOPE fetch lacks it,
    /// so the list goes by a sender with no domain. Both call a forged bounce whose `From` names
    /// an outside domain external, since a bounce is exempted only when it has no domain.
    /// See docs/decisions/0013-mail-bounce-detection.md.
    static func isBounce(returnPath: String?) -> Bool {
        guard let returnPath else { return false }
        return returnPath.filter { !$0.isWhitespace } == "<>"
    }

    static func isMistypedSchoolMailDomain(_ domain: String, config: MailServerConfig = .effective) -> Bool {
        let host = toASCII(normalizedDomain(domain))
        let mailDomain = config.addressDomain
        guard !host.isEmpty, !isSchoolDomain(host, config: config) else { return false }
        guard abs(host.count - mailDomain.count) <= maxDomainTypoEdits else { return false }
        return editDistance(host, mailDomain) <= maxDomainTypoEdits
    }

    static func mentionsMistypedSchoolAddress(_ text: String, config: MailServerConfig = .effective) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return emailPattern.matches(in: text, range: range).contains { match in
            guard let matchRange = Range(match.range, in: text) else { return false }
            return isMistypedSchoolMailDomain(domain(ofAddress: String(text[matchRange])), config: config)
        }
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let left = Array(a), right = Array(b)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(current[j - 1] + 1, previous[j] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    private static func sanitizeHref(_ href: String) -> String {
        let dropped = href.unicodeScalars.drop { $0.value <= 0x1F || $0 == " " }
        let filtered = dropped.filter { $0 != "\t" && $0 != "\r" && $0 != "\n" }
        return String(String.UnicodeScalarView(filtered))
    }

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

    private static func isASCIICaseInsensitiveEqual(_ text: some StringProtocol, _ other: String) -> Bool {
        let textScalars = Array(text.unicodeScalars)
        let otherScalars = Array(other.unicodeScalars)
        guard textScalars.count == otherScalars.count else { return false }
        return zip(textScalars, otherScalars).allSatisfy { asciiLowercased($0) == $1 }
    }

    private static func toASCII(_ host: String) -> String {
        guard host.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return host }
        var components = URLComponents()
        components.host = host
        guard let converted = components.url?.host, !converted.isEmpty else { return host }
        return converted.lowercased()
    }

    private static func isPlainSchoolLink(_ href: String, config: MailServerConfig) -> Bool {
        let range = NSRange(href.startIndex..., in: href)
        guard let match = plainHttpLinkPattern.firstMatch(in: href, range: range),
              let hostRange = Range(match.range(at: 1), in: href) else { return false }
        return isSchoolDomain(String(href[hostRange]), config: config)
    }

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

    static func evaluate(_ input: MailWarningInput, config: MailServerConfig = .effective) -> [MailWarning] {
        var warnings: [MailWarning] = []
        let address = MailTextCleaner.clean(input.fromAddress)
        let senderDomain = domain(ofAddress: address)
        // No domain means external unless `Return-Path: <>` marks a bounce, as Mail2000 sends its
        // own failure notices from a bare `<MAILER-DAEMON>`. The password-bait gate still counts a
        // forged bounce's outside links. See docs/decisions/0013-mail-bounce-detection.md.
        let bounce = isBounce(returnPath: input.returnPath)
        let external = senderDomain.isEmpty ? !bounce : !isSchoolDomain(senderDomain, config: config)
        if external, !address.isEmpty {
            warnings.append(.externalSender(address: address))
        }
        if let name = input.fromName.map({ MailTextCleaner.visibleText(MailTextCleaner.clean($0)) }),
           let embedded = firstEmail(in: name),
           embedded.lowercased() != address.lowercased() {
            warnings.append(.displayNameMismatch(address: address))
        }

        let haystack = MailTextCleaner.visibleText(MailTextCleaner.clean(input.subject + "\n" + input.plainText)).lowercased()
        let keywordHit = passwordKeywords.contains { haystack.contains($0.lowercased()) }
        let linksOutside = input.links.contains { link in
            let href = sanitizeHref(link.href).trimmingCharacters(in: .whitespacesAndNewlines)
            return hasASCIICaseInsensitivePrefix(href, "http") && !isPlainSchoolLink(href, config: config)
        }
        if keywordHit && (external || linksOutside) {
            warnings.append(.passwordBait)
        }

        for attachment in input.attachments {
            if let reason = attachmentRisk(filename: attachment.filename, contentType: attachment.contentType, subjectAndBody: haystack) {
                warnings.append(.riskyAttachment(filename: displayFilename(attachment.filename), reason: reason))
            }
        }
        if bounce, mentionsMistypedSchoolAddress(haystack, config: config) {
            warnings.append(.mistypedRecipient)
        }
        return warnings
    }

    static func displayFilename(_ raw: String) -> String {
        var name = MailTextCleaner.clean(raw)
        while let last = name.last, last == "." || last.isWhitespace { name.removeLast() }
        return name
    }

    private static func scannedFilename(_ raw: String) -> String {
        var name = MailTextCleaner.visibleText(MailTextCleaner.clean(raw))
        while let last = name.last, last == "." || last.isWhitespace { name.removeLast() }
        return name
    }

    static func attachmentRisk(filename: String, contentType: String?, subjectAndBody: String) -> MailRiskReason? {
        let pieces = scannedFilename(filename).lowercased().split(separator: ".").map(String.init)
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
        let lowered = MailTextCleaner.visibleText(MailTextCleaner.clean(subjectAndBody)).lowercased()
        if archiveExtensions.contains(ext), archivePasswordHints.contains(where: { lowered.contains($0) }) {
            return .encryptedArchive
        }
        return nil
    }

    static func contentTypeWithoutParameters(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.lowercased().split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func neverRenderedInApp(filename: String) -> Bool {
        let ext = scannedFilename(filename).lowercased().split(separator: ".").last.map(String.init) ?? ""
        return neverRenderInApp.contains(ext)
    }

    static func linkIssues(text rawText: String, href rawHref: String) -> [MailLinkIssue] {
        let href = sanitizeHref(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = MailTextCleaner.visibleText(rawText).trimmingCharacters(in: .whitespacesAndNewlines)

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
        return stripWWW(toASCII(normalizedDomain(String(text[hostRange]))))
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
