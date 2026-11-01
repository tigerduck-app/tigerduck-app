#if os(iOS)
import Foundation

nonisolated enum MailMessageRenderer {
    struct Rendered: Sendable {
        var sanitized: SanitizedHTML?
        var linked: LinkedHTML?
        var plainText: String
        var pages: MailFormattedPages?
    }

    static func detachedCancellably<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(operation: work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func render(html: String?, textBody: String?, allowImages: Bool) async throws -> Rendered {
        try await detachedCancellably { () throws -> Rendered in
            guard let html else { return Rendered(plainText: textBody ?? "") }
            let sanitized = MailHTMLSanitizer.sanitize(html, allowRemoteImages: allowImages)
            try Task.checkCancellation()
            let linked = MailHTMLSanitizer.rewriteLinks(sanitized.html)
            try Task.checkCancellation()
            let readable = MailReadableHTML(linked.html)
            let pages = MailFormattedPages(
                app: readable.html(on: .app),
                light: readable.html(on: .light),
                setsColors: readable.setsColors
            )
            try Task.checkCancellation()
            let plain = textBody ?? MailHTMLSanitizer.plainText(fromHTML: sanitized.html)
            try Task.checkCancellation()
            return Rendered(sanitized: sanitized, linked: linked, plainText: plain, pages: pages)
        }
    }

    static func warnings(for detail: MailMessageDetail, plainText: String, links: [MailLink]) -> [MailWarning] {
        let summary = detail.summary
        return MailWarnings.evaluate(MailWarningInput(
            fromAddress: summary.fromAddress ?? "",
            fromName: summary.fromName,
            subject: summary.subject ?? "",
            plainText: plainText,
            links: links,
            attachments: detail.attachments.map { MailAttachmentInfo(filename: $0.filename ?? "", contentType: $0.contentType) },
            returnPath: detail.returnPath
        ))
    }
}
#endif
