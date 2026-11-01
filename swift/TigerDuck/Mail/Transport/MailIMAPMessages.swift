#if os(iOS)
import Foundation
import SwiftMail

/// SwiftMail's `MessageInfo` and `MessagePart` as the app's summaries, parts and details.
nonisolated enum MailIMAPMessages {
    static func recoversByLocalParse(_ info: MessageInfo) -> Bool {
        guard info.bodyStructureUnusable else { return false }
        guard let size = info.size else { return true }
        return size <= MailConstants.maxLocalParseBytes
    }

    static func localDetail(summary: MailSummary, info: MessageInfo, raw: Data) -> MailMessageDetail? {
        guard let message = try? EMLParser.parse(raw) else { return nil }
        var textBody: String?
        var htmlBody: String?
        var inlineImages: [String: MailInlineImage] = [:]
        for part in message.parts where !isAttachment(part) {
            let type = part.contentType.lowercased()
            if type.hasPrefix("text/plain"), textBody == nil {
                textBody = decodedText(of: part)
            } else if type.hasPrefix("text/html"), htmlBody == nil {
                htmlBody = decodedText(of: part)
            } else if type.hasPrefix("image/"), let cid = part.contentId,
                      (part.data?.count ?? 0) <= MailConstants.maxInlineImageBytes,
                      let data = part.decodedData() {
                inlineImages[bareContentID(cid)] = MailInlineImage(mimeType: type, data: data)
            }
        }
        let hasAttachments = message.parts.contains(where: isAttachment)
        guard textBody != nil || htmlBody != nil || hasAttachments else { return nil }
        var summary = summary
        summary.hasAttachments = hasAttachments
        return MailMessageDetail(
            summary: summary,
            messageID: info.messageId.map(angleBracketed),
            inReplyTo: info.inReplyTo.map(angleBracketed),
            references: info.references?.map(angleBracketed),
            returnPath: returnPath(from: info),
            replyTo: replyTo(from: info),
            parts: message.parts.map(bodyPart(from:)),
            textBody: textBody,
            htmlBody: htmlBody,
            inlineImages: inlineImages.isEmpty ? nil : inlineImages
        )
    }

    static func decodedText(of part: MessagePart) -> String? {
        guard let data = part.decodedData() else { return nil }
        return MailCharset.decode(data, label: part.declaredCharset)
    }

    static func summary(from info: MessageInfo) -> MailSummary? {
        guard let uid = info.uid?.value else { return nil }
        // `parseSender`, not `parseList().first`: a From with no domain, like every Mail2000 bounce
        // (`<MAILER-DAEMON>`), keeps its name, with a `nil` address, so `isExternal` stays false.
        // ENVELOPE has no `Return-Path`; the opened message checks it (`MailSchoolDomain.isBounce`).
        let sender = info.from.flatMap { MailAddress.parseSender($0) }
        let fromAddress = sender.flatMap { MailTextCleaner.clean($0.address).mailNonEmpty }
        let clean: (String) -> String = { MailTextCleaner.clean(RFC2047.decode($0)) }
        return MailSummary(
            uid: uid,
            fromName: sender?.name.map(clean),
            fromAddress: fromAddress,
            to: info.to.map(clean),
            cc: info.cc.map(clean),
            subject: info.subject.map(clean),
            date: info.date ?? info.internalDate,
            isSeen: info.flags.contains(.seen),
            isAnswered: info.flags.contains(.answered),
            isDeleted: info.flags.contains(.deleted),
            size: info.size,
            hasAttachments: info.parts.contains(where: isAttachment),
            isExternal: fromAddress.map { !MailSchoolDomain.isSchoolDomain(MailSchoolDomain.domain(ofAddress: $0)) } ?? false,
            arrivedAt: info.internalDate
        )
    }

    /// `Return-Path` off the full header section `detailOptions` already fetches, nil when the
    /// fetch fell back to the summary attributes (`detailInfo`), which carry no headers at all.
    /// The first one, not the last. The final delivery agent prepends its `Return-Path`
    /// above everything the sender wrote, so a message carrying extra copies lower down is one
    /// where the top line is the server's and the rest are the sender's. `additionalFields` is
    /// the same headers as a dictionary and keeps the *last* value for a repeated name, which is
    /// the wrong end; this reads the ordered list instead.
    static func returnPath(from info: MessageInfo) -> String? {
        info.additionalHeaderFields?.first { $0.name.lowercased() == "return-path" }?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replyTo(from info: MessageInfo) -> String? {
        guard let fields = info.additionalHeaderFields else { return nil }
        return fields.first { $0.name.lowercased() == "reply-to" }.map { RFC2047.decode($0.value) } ?? ""
    }

    static func isAttachment(_ part: MessagePart) -> Bool {
        let type = part.contentType.lowercased()
        if part.disposition?.lowercased() == "attachment" { return true }
        if type.hasPrefix("multipart/") { return false }
        if type.hasPrefix("text/plain") || type.hasPrefix("text/html") { return part.filename != nil }
        if type.hasPrefix("image/"), part.contentId != nil { return false }
        return true
    }

    static func bodyPart(from part: MessagePart) -> MailBodyPart {
        MailBodyPart(
            section: part.section.description,
            contentType: part.contentType.lowercased(),
            charset: part.declaredCharset,
            transferEncoding: part.encoding,
            filename: part.filename.map { MailTextCleaner.clean(RFC2047.decode($0)) },
            contentID: part.contentId.map(bareContentID),
            size: part.size ?? part.data?.count,
            isAttachment: isAttachment(part)
        )
    }

    static func bareContentID(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    static func angleBracketed(_ id: MessageID) -> String {
        let text = String(describing: id)
        return text.hasPrefix("<") ? text : "<\(text)>"
    }
}
#endif
