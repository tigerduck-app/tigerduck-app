#if os(iOS)
import Foundation

nonisolated struct MailSearchText: Equatable, Sendable {
    static let maxTextLength = 32_000

    let text: String

    static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}

nonisolated extension MailSearchText {
    init(of summary: MailSummary, body: String?) {
        let parts = [summary.fromName, summary.fromAddress, summary.subject, body].compactMap { $0 }
        self.init(text: String(MailTextCleaner.clean(parts.joined(separator: " ")).prefix(Self.maxTextLength)))
    }
}
#endif
