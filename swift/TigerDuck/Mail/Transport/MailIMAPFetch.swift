#if os(iOS)
import Foundation
import SwiftMail

/// The multi-command fetches of one mail on a selected folder: its body, an attachment, and the
/// text the search index keeps. `LiveMailClient` runs each inside one serialized command.
nonisolated enum MailIMAPFetch {
    /// The message screen's fetch: the summary attributes plus the full header section.
    ///
    /// ENVELOPE has `In-Reply-To` but not `References`, which SwiftMail reads only from a fetched
    /// header section, so without one every reply loses its thread chain. Ask with `.fullHeader`
    /// (`BODY.PEEK[HEADER]`), never a field list: Mail2000 echoes `HEADER.FIELDS ("References")`
    /// back as `HEADER.FIELDS (""REFERENCES"")`, which NIOIMAP cannot decode. `HEADER` has no list
    /// to mangle. `MailFetchSectionTests` pins the request and replays the echo through NIOIMAP.
    static let detailOptions: FetchMessageInfoOptions = LiveMailClient.summaryOptions.union(.fullHeader)

    static let detailHeaderFields: [String]? = nil

    static func detail(
        folder: String, uid: UInt32, expectedUIDValidity: UInt32?, includeImages: Bool, imap: IMAPServer
    ) async throws -> MailMessageDetail {
        guard let info = try await detailInfo(folder: folder, uid: uid, expectedUIDValidity: expectedUIDValidity, imap: imap),
              let summary = MailIMAPMessages.summary(from: info) else {
            throw MailClientError.protocolError("message \(uid) not found")
        }
        if MailIMAPMessages.recoversByLocalParse(info) {
            let raw = try await imap.fetchRawMessage(identifier: UID(uid))
            if let local = MailIMAPMessages.localDetail(summary: summary, info: info, raw: raw) { return local }
        }
        var textBody: String?
        var htmlBody: String?
        var inlineImages: [String: MailInlineImage] = [:]
        for part in info.parts where !MailIMAPMessages.isAttachment(part) {
            let type = part.contentType.lowercased()
            if type.hasPrefix("text/plain"), textBody == nil {
                let data = try await imap.fetchAndDecodeMessagePartData(messageInfo: info, part: part)
                textBody = MailCharset.decode(data, label: part.declaredCharset)
            } else if type.hasPrefix("text/html"), htmlBody == nil {
                let data = try await imap.fetchAndDecodeMessagePartData(messageInfo: info, part: part)
                htmlBody = MailCharset.decode(data, label: part.declaredCharset)
            } else if includeImages, type.hasPrefix("image/"), let cid = part.contentId,
                      (part.size ?? 0) <= MailConstants.maxInlineImageBytes {
                let data = try await imap.fetchAndDecodeMessagePartData(messageInfo: info, part: part)
                inlineImages[MailIMAPMessages.bareContentID(cid)] = MailInlineImage(mimeType: type, data: data)
            }
        }
        return MailMessageDetail(
            summary: summary,
            messageID: info.messageId.map(MailIMAPMessages.angleBracketed),
            inReplyTo: info.inReplyTo.map(MailIMAPMessages.angleBracketed),
            references: info.references?.map(MailIMAPMessages.angleBracketed),
            returnPath: MailIMAPMessages.returnPath(from: info),
            replyTo: MailIMAPMessages.replyTo(from: info),
            parts: info.parts.map(MailIMAPMessages.bodyPart(from:)),
            textBody: textBody,
            htmlBody: htmlBody,
            inlineImages: inlineImages.isEmpty ? nil : inlineImages
        )
    }

    /// The detail fetch, best-effort about the header section that carries `References`.
    ///
    /// Threading is worth a header section, not the message. If that fetch fails with a protocol
    /// error, an undecodable response included, this retries with the summary attributes the list
    /// already fetches, and the message opens without its thread chain. Other failures are not
    /// retried: a second fetch cannot fix them, and a partial message would hide them. A decode
    /// failure makes SwiftMail recycle the connection, so the retry re-EXAMINEs first.
    private static func detailInfo(
        folder: String, uid: UInt32, expectedUIDValidity: UInt32?, imap: IMAPServer
    ) async throws -> MessageInfo? {
        do {
            return try await imap.fetchMessageInfo(for: UID(uid), options: detailOptions, headerFields: detailHeaderFields)
        } catch {
            guard detailRetriesWithoutHeaderSection(after: error) else { throw error }
            let selection = try await imap.examineMailbox(folder)
            try assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            return try await imap.fetchMessageInfo(for: UID(uid), options: LiveMailClient.summaryOptions)
        }
    }

    static func detailRetriesWithoutHeaderSection(after error: any Error) -> Bool {
        if case .protocolError = MailIMAPErrors.map(error) { return true }
        return false
    }

    static func attachment(uid: UInt32, part: MailBodyPart, imap: IMAPServer) async throws -> Data {
        guard let info = try await imap.fetchMessageInfo(for: UID(uid), options: [.bodyStructure, .size]) else {
            throw MailClientError.protocolError("message \(uid) not found")
        }
        if let found = info.parts.first(where: { $0.section.description == part.section }) {
            return try await imap.fetchAndDecodeMessagePartData(messageInfo: info, part: found)
        }
        guard MailIMAPMessages.recoversByLocalParse(info) else {
            throw MailClientError.protocolError("part \(part.section) not found")
        }
        let raw = try await imap.fetchRawMessage(identifier: UID(uid))
        guard let message = try? EMLParser.parse(raw),
              let found = message.parts.first(where: { $0.section.description == part.section }),
              let data = found.decodedData() else {
            throw MailClientError.protocolError("part \(part.section) not found")
        }
        return data
    }

    /// The mail's first text part, plain before HTML, as the search index reads it.
    static func searchBody(
        of info: MessageInfo, folder: String, expectedUIDValidity: UInt32, imap: IMAPServer
    ) async throws -> String? {
        let parts = info.parts.filter {
            !MailIMAPMessages.isAttachment($0) && ($0.size ?? 0) <= MailConstants.searchTextPartBytes
        }
        let isHTML = { (part: MessagePart) in part.contentType.lowercased().hasPrefix("text/html") }
        guard let part = parts.first(where: { $0.contentType.lowercased().hasPrefix("text/plain") })
            ?? parts.first(where: isHTML) else { return nil }
        do {
            let text = MailCharset.decode(try await imap.fetchAndDecodeMessagePartData(messageInfo: info, part: part),
                                          label: part.declaredCharset)
            return isHTML(part) ? MailHTMLSanitizer.plainText(fromHTML: text) : text
        } catch {
            // A part that will not decode leaves the mail searched by sender and subject. SwiftMail
            // recycles the connection after a decode failure, so the folder is selected again.
            guard case .protocolError = MailIMAPErrors.map(error) else { throw error }
            let selection = try await imap.examineMailbox(folder)
            try assertUIDValidity(expected: expectedUIDValidity, current: selection.uidValidity.value)
            return nil
        }
    }

    static func uidValidityChanged(expected: UInt32?, current: UInt32) -> Bool {
        guard let expected else { return false }
        return expected != current
    }

    static func assertUIDValidity(expected: UInt32?, current: UInt32) throws {
        guard !uidValidityChanged(expected: expected, current: current) else {
            throw MailClientError.folderChanged
        }
    }

    static func uidSet(_ uids: [UInt32]) -> MessageIdentifierSet<UID> {
        MessageIdentifierSet<UID>(uids.map { UID($0) })
    }
}
#endif
