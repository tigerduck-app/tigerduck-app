#if os(iOS)
import Foundation

nonisolated enum MailSearchText {
    static let maxTextLength = 32_000

    static func text(of summary: MailSummary, body: String?) -> String {
        let parts = [summary.fromName, summary.fromAddress, summary.subject, body].compactMap { $0 }
        return String(MailTextCleaner.clean(parts.joined(separator: " ")).prefix(maxTextLength))
    }

    static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}
#endif
