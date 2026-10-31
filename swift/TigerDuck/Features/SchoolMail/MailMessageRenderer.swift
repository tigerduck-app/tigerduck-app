#if os(iOS)
import Foundation

/// Turns a mail's body into what the message screen shows, off the main actor: the sanitized and
/// link-rewritten HTML, its pages on the app's colours and on light, and the plain text.
nonisolated enum MailMessageRenderer {
    struct Rendered: Sendable {
        var sanitized: SanitizedHTML?
        var linked: LinkedHTML?
        var plainText: String
        var pages: MailFormattedPages?
    }

    static func detachedCancellably<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Nil when the task was cancelled part way.
    static func render(html: String?, textBody: String?, allowImages: Bool) async -> Rendered? {
        await detachedCancellably { () -> Rendered? in
            guard let html else { return Rendered(plainText: textBody ?? "") }
            let sanitized = MailHTMLSanitizer.sanitize(html, allowRemoteImages: allowImages)
            guard !Task.isCancelled else { return nil }
            let linked = MailHTMLSanitizer.rewriteLinks(sanitized.html)
            guard !Task.isCancelled else { return nil }
            let readable = MailReadableHTML(linked.html)
            let pages = MailFormattedPages(
                app: readable.html(on: .app),
                light: readable.html(on: .light),
                setsColors: readable.setsColors
            )
            guard !Task.isCancelled else { return nil }
            let plain = textBody ?? MailHTMLSanitizer.plainText(fromHTML: sanitized.html)
            return Task.isCancelled ? nil : Rendered(sanitized: sanitized, linked: linked, plainText: plain, pages: pages)
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
