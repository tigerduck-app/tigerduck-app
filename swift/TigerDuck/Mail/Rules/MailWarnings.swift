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

    static func evaluate(_ input: MailWarningInput, config: MailServerConfig = .effective) -> [MailWarning] {
        var warnings: [MailWarning] = []
        let address = MailTextCleaner.clean(input.fromAddress)
        let senderDomain = MailSchoolDomain.domain(ofAddress: address)
        // No domain means external unless `Return-Path: <>` marks a bounce, as Mail2000 sends its
        // own failure notices from a bare `<MAILER-DAEMON>`.
        let bounce = MailSchoolDomain.isBounce(returnPath: input.returnPath)
        let external = senderDomain.isEmpty ? !bounce : !MailSchoolDomain.isSchoolDomain(senderDomain, config: config)
        if external, !address.isEmpty {
            warnings.append(.externalSender(address: address))
        }
        if let name = input.fromName.map({ MailTextCleaner.visibleText(MailTextCleaner.clean($0)) }),
           let embedded = MailLinkCheck.firstEmail(in: name),
           embedded.lowercased() != address.lowercased() {
            warnings.append(.displayNameMismatch(address: address))
        }

        let haystack = MailTextCleaner.visibleText(MailTextCleaner.clean(input.subject + "\n" + input.plainText)).lowercased()
        let keywordHit = passwordKeywords.contains { haystack.contains($0.lowercased()) }
        let linksOutside = input.links.contains { link in
            let href = MailHref.sanitizeHref(link.href).trimmingCharacters(in: .whitespacesAndNewlines)
            return ASCIIText.hasASCIICaseInsensitivePrefix(href, "http") && !MailLinkCheck.isPlainSchoolLink(href, config: config)
        }
        if keywordHit && (external || linksOutside) {
            warnings.append(.passwordBait)
        }

        for attachment in input.attachments {
            if let reason = MailAttachmentRisk.attachmentRisk(filename: attachment.filename, contentType: attachment.contentType, subjectAndBody: haystack) {
                warnings.append(.riskyAttachment(filename: MailAttachmentRisk.displayFilename(attachment.filename), reason: reason))
            }
        }
        if bounce, MailSchoolDomain.mentionsMistypedSchoolAddress(haystack, config: config) {
            warnings.append(.mistypedRecipient)
        }
        return warnings
    }
}
#endif
