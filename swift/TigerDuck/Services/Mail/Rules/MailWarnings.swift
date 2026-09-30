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
    /// A delivery failure naming an address one or two keystrokes away from the school's own
    /// mail domain — see `isMistypedSchoolMailDomain`.
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
    /// The mail's `Return-Path` header where one was fetched, otherwise nil — see
    /// `MailWarnings.isBounce`. Defaulted, because only the opened-message path has it: the
    /// folder list fetches ENVELOPE alone and has no headers to read it from.
    var returnPath: String? = nil
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

    /// Delimiter-based, mirroring Android's `EMAIL` (parity fix): the local part, the host and
    /// the TLD are "everything up to the next delimiter", not an ASCII allowlist. The old
    /// ASCII-only pattern silently matched nothing — and so produced no display-name or
    /// `mailto:` mismatch warning at all — for a display name with Han characters before the
    /// `@`, for a non-ASCII host, and for a single-letter TLD, all of which warn on Android.
    ///
    /// The ASCII whitespace class is spelled out instead of written `\s`: Java's `\s` is
    /// ASCII-only where ICU's, which `NSRegularExpression` uses, is Unicode-wide, so a bare
    /// `\s` here would end the match at characters Android runs straight through. No
    /// `.caseInsensitive` — there are no letter ranges left for it to fold.
    private static let emailDelimiters = "\\x{20}\\x{09}\\x{0A}\\x{0B}\\x{0C}\\x{0D}@<>()\",;:"
    private static let emailPattern = try! NSRegularExpression(
        pattern: "[^\(emailDelimiters)]+@[^\(emailDelimiters)]+\\.[^\(emailDelimiters)]+"
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

    /// Whether `raw` is inside the organization whose mail this is — `ntust.edu.tw` and its
    /// subdomains on the real path, and the overridden address domain (and its subdomains)
    /// under the DEBUG developer override.
    ///
    /// The rule has to follow the override or the whole warning layer reads as noise on a test
    /// mailbox: left hard-coded, every single message in a Gmail account is badged External,
    /// including the ones the developer sent themselves. `MailServerConfig.school`'s
    /// `organizationDomain` is `ntust.edu.tw`, so with no override in force this is exactly the
    /// comparison it has always been, character for character — which is what keeps the shared
    /// `warnings.json` fixture agreeing with Android.
    ///
    /// The `config:` overload is the real rule; the no-argument form is the effective
    /// configuration applied to it. Callers that already know which configuration they mean
    /// (tests, and `evaluate` below, which resolves it once per message) pass it explicitly
    /// rather than each rule re-reading the global.
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

    // MARK: Delivery failures (Mail2000 bounces)

    /// The one mailbox domain every student address lives on, and the yardstick
    /// `isMistypedSchoolMailDomain` measures against. Android keeps its own copy of this in its
    /// `MailWarnings`; here it is the value the rest of the app already agrees on — which under
    /// the DEBUG developer override is the overridden domain, so the bounce rule measures
    /// near-misses of the mailbox the developer is actually using.
    static var schoolMailDomain: String { MailServerConfig.effective.addressDomain }

    /// Two, not one, so a transposition (`ntsut`) counts — plain Levenshtein scores that as two.
    private static let maxDomainTypoEdits = 2

    /// RFC 5321 §4.5.5: a delivery status notification is sent with the null reverse-path, and
    /// the **receiving** server writes that down as `Return-Path: <>`. The header therefore comes
    /// from our own side of the delivery, unlike the `From` display name ("Mail Deliver System"),
    /// which any sender can type — so it is the only signal here worth treating as a bounce
    /// marker.
    ///
    /// What can read it, per site, and why the two differ:
    ///
    /// - The **opened message** can. `LiveMailClient.detailOptions` already fetches the whole
    ///   header section (`BODY.PEEK[HEADER]`), so `Return-Path` is already on the wire; it costs
    ///   nothing to read and rides into the cached body on `MailMessageDetail`.
    /// - The **folder list** cannot, and is deliberately left as it is. Its fetch is ENVELOPE
    ///   only, which carries no `Return-Path`, and the one way to ask for just that field —
    ///   `BODY.PEEK[HEADER.FIELDS (…)]` — is exactly the request Mail2000 mangles (it echoes the
    ///   section back with the field name double-quoted, which no IMAP parser can read; see
    ///   `detailOptions`). The remaining option, a full header for all 50 rows of every page, is
    ///   a real download for a badge that is already right: `LiveMailClient.summary` sets
    ///   `MailSummary.isExternal` from the parsed address, and a Mail2000 bounce has no address
    ///   at all, so it is already false. The list therefore decides on the weaker signal — a
    ///   sender with no domain — and the opened message on this one. They agree on the mail that
    ///   prompted this; where they could differ is a *forged* bounce whose `From` names a real
    ///   outside domain, and both call that external, because the exemption below only ever
    ///   applies when there is no domain at all.
    static func isBounce(returnPath: String?) -> Bool {
        guard let returnPath else { return false }
        return returnPath.filter { !$0.isWhitespace } == "<>"
    }

    /// True for a domain that reads as a mistyped `schoolMailDomain`: within
    /// `maxDomainTypoEdits` single-character edits of it, but neither it nor any other real
    /// school domain.
    ///
    /// The length check is not only a shortcut — it keeps a sender-supplied token out of the
    /// quadratic distance loop entirely.
    static func isMistypedSchoolMailDomain(_ domain: String, config: MailServerConfig = .effective) -> Bool {
        let host = toASCII(normalizedDomain(domain))
        let mailDomain = config.addressDomain
        guard !host.isEmpty, !isSchoolDomain(host, config: config) else { return false }
        guard abs(host.count - mailDomain.count) <= maxDomainTypoEdits else { return false }
        return editDistance(host, mailDomain) <= maxDomainTypoEdits
    }

    /// Whether `text` names an email address whose domain is a near miss of the school's. This
    /// is what turns a delivery failure into "Did you mistype an address in the mail you just
    /// sent?": a bounce from `gmail.com` says nothing about a typo, so it earns no such claim.
    static func mentionsMistypedSchoolAddress(_ text: String, config: MailServerConfig = .effective) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return emailPattern.matches(in: text, range: range).contains { match in
            guard let matchRange = Range(match.range, in: text) else { return false }
            return isMistypedSchoolMailDomain(domain(ofAddress: String(text[matchRange])), config: config)
        }
    }

    /// Levenshtein, two rows at a time.
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
    private static func isPlainSchoolLink(_ href: String, config: MailServerConfig) -> Bool {
        let range = NSRange(href.startIndex..., in: href)
        guard let match = plainHttpLinkPattern.firstMatch(in: href, range: range),
              let hostRange = Range(match.range(at: 1), in: href) else { return false }
        return isSchoolDomain(String(href[hostRange]), config: config)
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

    /// `config` is resolved once here and threaded through every domain-sensitive rule below,
    /// so one message is always judged against one configuration even if the developer changes
    /// the override while it is being evaluated.
    static func evaluate(_ input: MailWarningInput, config: MailServerConfig = .effective) -> [MailWarning] {
        var warnings: [MailWarning] = []
        // The real sender address is deliberately NOT run through `visibleText`: removing an
        // invisible character here could turn `x@mail.ntust.e<U+200B>du.tw` into a school
        // domain and suppress the external-sender banner. `clean` alone leaves it external,
        // which is the safe direction.
        let address = MailTextCleaner.clean(input.fromAddress)
        let senderDomain = domain(ofAddress: address)
        // A sender with no domain at all is the one case a confirmed bounce is exempted from,
        // and that exemption deliberately reverses what this used to assume. A Mail2000
        // delivery failure arrives as `From: "Mail Deliver System" <MAILER-DAEMON>` — a bare
        // local part — so "no domain, therefore outside" called the school's own mail system an
        // outside sender, which is wrong on its face and teaches people to ignore the warning.
        // The exemption is read from `Return-Path: <>`, which the receiving server writes, never
        // from the display name, which anyone can set.
        //
        // It stays safe. `external` feeds the banner below and the password-bait gate, and that
        // gate fires on `keywordHit && (external || linksOutside)` — so a forged "bounce"
        // carrying a phishing link to a non-school host is still caught through the link. What
        // is left is a forged, link-free bounce (anyone may send `MAIL FROM:<>`, so this is not
        // proof of origin), which has nothing to click. And the exemption is narrow: a bounce
        // whose `From` does name a real outside domain stays external exactly as before.
        let bounce = isBounce(returnPath: input.returnPath)
        let external = senderDomain.isEmpty ? !bounce : !isSchoolDomain(senderDomain, config: config)
        // An empty address means the From header gave none this app will route to
        // (`MailAddress.parseSender`) — a Mail2000 bounce's `<MAILER-DAEMON>`, say. It still
        // counts as "outside" for the password-bait gate below, because it is certainly not
        // a school address, but it gets no external-sender banner of its own: that banner
        // names the address, and naming nothing on every delivery-failure notice is how a
        // warning stops being read. The case that matters — a display name that *claims* an
        // address the header cannot back up — is caught by the mismatch check just below,
        // which compares against this same empty string and so still fires.
        if external, !address.isEmpty {
            warnings.append(.externalSender(address: address))
        }
        // The display name is the opposite case: it is the *claim*, so it is read the way the
        // reader reads it. `From: "no-reply@ntust.e<U+200B>du.tw" <b10123456@mail.ntust.edu.tw>`
        // renders as a school no-reply address; without `visibleText` no address-shaped
        // substring is found, no mismatch is reported, and — the sender being a real school
        // account — no external-sender banner fires either, so the mail passes silently while
        // the message screen prints the fake address as the sender headline.
        if let name = input.fromName.map({ MailTextCleaner.visibleText(MailTextCleaner.clean($0)) }),
           let embedded = firstEmail(in: name),
           embedded.lowercased() != address.lowercased() {
            warnings.append(.displayNameMismatch(address: address))
        }

        // Subject and body together, so a keyword hidden behind a bidi override in either one
        // still counts (controller ruling, 2026-09-16: the brief only cleaned the subject,
        // leaving the body's bidi controls in place), and `visibleText` on top so that
        // `pass<U+200B>word` or `密<U+200B>碼` — which read exactly like the keyword — are
        // matched as the keyword. A.4 rule 3 says to apply A.3 cleaning, and A.3 as written is
        // bidi-only, so this is deliberately stricter than the spec: the rule is worth nothing
        // if one character nobody can see turns it off.
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
        // Only when the failure really looks like a mistyped school address. A bounce from
        // somewhere unrelated gives us no basis for claiming the sender typed one wrong.
        if bounce, mentionsMistypedSchoolAddress(haystack, config: config) {
            warnings.append(.mistypedRecipient)
        }
        return warnings
    }

    /// A.3-cleaned, trailing whitespace and dots removed, original case kept. What the user is
    /// shown — Android's `cleanFileName`, same steps in the same order.
    static func displayFilename(_ raw: String) -> String {
        var name = MailTextCleaner.clean(raw)
        while let last = name.last, last == "." || last.isWhitespace { name.removeLast() }
        return name
    }

    /// The name the extension checks read, which is `displayFilename` with every invisible
    /// character taken out as well.
    ///
    /// `payload.ex<U+200B>e` and `report.ht<U+200B>ml` display and open exactly like
    /// `payload.exe` and `report.html`, but their last dot-separated piece is `ex\u{200B}e`,
    /// which is in no extension set — so `attachmentRisk` returned nil, `neverRenderedInApp`
    /// returned false, and the message screen skipped the confirmation dialog and handed the
    /// file straight to Quick Look or the share sheet, with only the attacker's own
    /// Content-Type left between the mail and an in-process render (§9.5).
    ///
    /// Invisible characters go before the trailing-dot-and-space trim, so `payload.exe.<U+200B>`
    /// trims down to `payload.exe` rather than stopping at the character it cannot see.
    /// This is stricter than Android, whose `cleanFileName` removes control characters but not
    /// format characters, so the zero-width cases above are still open there — a cross-platform
    /// follow-up, not something this side should match by weakening.
    private static func scannedFilename(_ raw: String) -> String {
        var name = MailTextCleaner.visibleText(MailTextCleaner.clean(raw))
        while let last = name.last, last == "." || last.isWhitespace { name.removeLast() }
        return name
    }

    /// Precedence when several apply: double extension, type mismatch, dangerous extension,
    /// then encrypted archive. [subjectAndBody] is cleaned here too (not just by the
    /// caller) so a direct call with raw subject/body text is still checked correctly
    /// (controller ruling, 2026-09-16 — mirrors Android's `riskReason`, which re-strips
    /// defensively rather than trusting its caller).
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
        let ext = scannedFilename(filename).lowercased().split(separator: ".").last.map(String.init) ?? ""
        return neverRenderInApp.contains(ext)
    }

    // MARK: Links

    static func linkIssues(text rawText: String, href rawHref: String) -> [MailLinkIssue] {
        let href = sanitizeHref(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
        // `visibleText`, not `clean`, and before BOTH branches below — Android's `checkLink`
        // does the same. What is compared has to be what the reader sees, joined back up:
        // `<a href="https://evil.example/login">ntust.edu.tw&#8288;</a>` renders as plain
        // `ntust.edu.tw`, but the word joiner breaks `shownHostPattern`'s `^…$` anchor, so
        // `hostShown` returns nil, the mismatch branch never runs, and the link is shown with
        // no banner at all while `insecure`/`punycode` stay silent on an https host. The
        // `mailto:` branch fails the same way through `firstEmail`. `clean` would not do: it
        // collapses `\t`/`\n`/`\r` into a space to keep words apart for display, which is the
        // opposite of what a host split across a line break needs.
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

    /// `visibleText` joins a host back up when what split it is invisible, but it cannot join
    /// one that a *space* splits — and by the time link text reaches here a line break has
    /// already become a space twice over: SwiftSoup's `Element.text()` normalizes an anchor's
    /// whitespace, and `MailTextCleaner.clean` collapses what is left, both on purpose, so that
    /// displayed text keeps its word boundaries. A host wrapped across a line in the source
    /// therefore arrives as `ntust. edu.tw`, matches no host pattern, and a link pointing
    /// somewhere else was reported as having nothing to compare rather than as a mismatch.
    ///
    /// So the host pattern is tried a second time with the whitespace that touches a dot taken
    /// out. Only whitespace touching a dot: `請見 ntust.edu.tw 公告` is prose with a host in it,
    /// not a claim that the whole line is one host, and joining it wholesale would invent a
    /// shown host out of the words around the link.
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

    /// `"ntust. edu.tw"` -> `"ntust.edu.tw"`; `"請見 ntust.edu.tw 公告"` unchanged. Every
    /// Unicode whitespace character counts, so a no-break space or an ideographic space splits
    /// a host no more successfully than a plain one does.
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
