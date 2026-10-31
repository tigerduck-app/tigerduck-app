#if os(iOS)
import Foundation

/// What compose starts from when it answers, forwards or reopens a mail: the fields, the
/// attachments to carry over and, for a reopened draft, what removing it after a send needs.
struct MailComposePrefill {
    enum Outcome {
        case prefill(MailComposePrefill)
        /// A draft to reopen that the context does not name.
        case missingDraft
        case nothing
    }

    var to: String?
    var cc: String?
    var subject: String
    var body: String
    var showCcBcc: Bool
    var attachments: [MailComposeViewModel.Attachment]
    var draft: (pageUIDValidity: UInt32?, wasAlreadyDeleted: Bool)?

    static func fetch(
        _ context: MailComposeContext, sender: MailAddress, session: MailPageSession, cache: MailCache
    ) async throws -> Outcome {
        if context.mode == .draft {
            guard let message = context.message else { return .missingDraft }
            return .prefill(try await reopenedDraft(folder: message.folder, uid: message.uid, session: session, cache: cache))
        }
        guard let original = context.original else { return .nothing }
        let dateText = original.date.map(MailDateFormatter.detailString(for:)) ?? ""
        switch context.mode {
        case .reply, .replyAll:
            var replyTo = original.replyTo
            if replyTo == nil, let message = context.message {
                let pin = await cachedPageUIDValidity(of: message.folder, cache: cache)
                let raw = try? await session.use { client in
                    try await client.rawSource(folder: message.folder, uid: message.uid, expectedUIDValidity: pin)
                }
                replyTo = raw.map { MailRawHeaders.value(named: "Reply-To", in: $0).map(MailAddress.parseList) ?? [] }
            }
            let recipients = MailReplyComposer.replyRecipients(to: original, replyTo: replyTo ?? [],
                                                               me: sender.address, replyAll: context.mode == .replyAll)
            return .prefill(MailComposePrefill(
                to: MailRecipients.format(recipients.to), cc: MailRecipients.format(recipients.cc),
                subject: MailReplyComposer.replySubject(original.subject),
                body: MailReplyComposer.quotedBody(of: original, dateText: dateText),
                showCcBcc: !recipients.cc.isEmpty, attachments: []
            ))
        case .forward:
            var pin: UInt32?
            if let folder = context.folder { pin = await cachedPageUIDValidity(of: folder, cache: cache) }
            let parts = context.attachments
            let downloaded: [MailComposeViewModel.Attachment] = try await session.use { client in
                guard let message = context.message else { return [] }
                return try await download(parts, folder: message.folder, uid: message.uid, pin: pin, client: client)
            }
            return .prefill(MailComposePrefill(
                to: nil, cc: nil,
                subject: MailReplyComposer.forwardSubject(original.subject),
                body: MailReplyComposer.forwardBody(of: original, dateText: dateText),
                showCcBcc: false, attachments: downloaded
            ))
        case .new, .draft:
            return .nothing
        }
    }

    private static func reopenedDraft(
        folder: String, uid: UInt32, session: MailPageSession, cache: MailCache
    ) async throws -> MailComposePrefill {
        let pin = await cachedPageUIDValidity(of: folder, cache: cache)
        let (draft, downloaded) = try await session.use { client -> (MailMessageDetail, [MailComposeViewModel.Attachment]) in
            let draft = try await client.detail(folder: folder, uid: uid, expectedUIDValidity: pin)
            return (draft, try await download(draft.attachments, folder: folder, uid: uid, pin: pin, client: client))
        }
        return MailComposePrefill(
            to: (draft.summary.to ?? []).joined(separator: ", "),
            cc: (draft.summary.cc ?? []).joined(separator: ", "),
            subject: draft.summary.subject ?? "",
            body: draft.textBody ?? "",
            showCcBcc: !(draft.summary.cc ?? []).isEmpty,
            attachments: downloaded,
            draft: (pin, draft.summary.isDeleted)
        )
    }

    private static func download(
        _ parts: [MailBodyPart], folder: String, uid: UInt32, pin: UInt32?, client: any MailClient
    ) async throws -> [MailComposeViewModel.Attachment] {
        var files: [MailComposeViewModel.Attachment] = []
        for part in parts {
            let data = try await client.attachment(folder: folder, uid: uid, part: part, expectedUIDValidity: pin)
            files.append(MailComposeViewModel.Attachment(filename: part.filename ?? "attachment", mimeType: part.contentType, data: data))
        }
        return files
    }

    private static func cachedPageUIDValidity(of folder: String, cache: MailCache) async -> UInt32? {
        await Task.detached { cache.loadPage(folder: folder)?.uidValidity }.value
    }
}
#endif
