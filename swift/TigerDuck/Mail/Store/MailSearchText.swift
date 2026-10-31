#if os(iOS)
import Foundation

/// The text a search reads of a mail, folded so both sides of a match compare alike.
nonisolated enum MailSearchText {
    static let maxTextLength = 32_000

    /// What a search of a mail reads: its sender, subject and body text, with runs of white space
    /// as one space, so a phrase broken across lines still matches.
    static func text(of summary: MailSummary, body: String?) -> String {
        let parts = [summary.fromName, summary.fromAddress, summary.subject, body].compactMap { $0 }
        return String(MailTextCleaner.clean(parts.joined(separator: " ")).prefix(maxTextLength))
    }

    /// Both sides of a match fold the same way, in any script.
    static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}
#endif
