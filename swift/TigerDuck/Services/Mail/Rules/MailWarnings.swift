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
    private static let shownHostPattern = try! NSRegularExpression(
        pattern: "^(?:[a-z][a-z0-9+.-]*://)?(?:www\\.)?((?:[a-z0-9-]+\\.)+[a-z]{2,})(?:[:/?#].*)?$",
        options: [.caseInsensitive]
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
            guard let url = URL(string: link.href),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host else { return false }
            return !isSchoolDomain(host)
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

    /// `"Application/PDF; name=x.pdf"` -> `"application/pdf"`.
    private static func contentTypeWithoutParameters(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.lowercased().split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func neverRenderedInApp(filename: String) -> Bool {
        let ext = displayFilename(filename).lowercased().split(separator: ".").last.map(String.init) ?? ""
        return neverRenderInApp.contains(ext)
    }

    // MARK: Links

    static func linkIssues(text rawText: String, href: String) -> [MailLinkIssue] {
        guard let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)) else { return [] }
        let text = MailTextCleaner.clean(rawText).trimmingCharacters(in: .whitespacesAndNewlines)

        if url.scheme?.lowercased() == "mailto" {
            let target = href.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
            let real = (target.removingPercentEncoding ?? target).lowercased()
            if let shown = firstEmail(in: text), shown.lowercased() != real {
                return [.mismatch(shownHost: shown.lowercased(), realHost: real)]
            }
            return []
        }

        guard let rawHost = url.host else { return [] }
        let realHost = stripWWW(normalizedDomain(rawHost))
        var issues: [MailLinkIssue] = []
        if url.scheme?.lowercased() == "http" {
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
        return stripWWW(normalizedDomain(String(text[hostRange])))
    }

    private static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
#endif
