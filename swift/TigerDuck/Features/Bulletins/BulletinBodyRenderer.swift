import Foundation
import MarkdownUI
import SwiftUI

nonisolated enum BulletinBodyRenderer {
    static func bodyMarkdown(
        for detail: BulletinAPI.BulletinDetail,
        fallbackSummary: String? = nil
    ) -> String {
        detail.bodyClean?.trimmedNilIfEmpty
            ?? detail.bodyMd?.trimmedNilIfEmpty
            ?? detail.summary?.trimmedNilIfEmpty
            ?? fallbackSummary?.trimmedNilIfEmpty
            ?? ""
    }

    /// Pre-processes the raw Markdown so MarkdownUI's CommonMark parser picks up inline emphasis
    /// inside list items. The LLM sometimes emits `*   ` (an asterisk and several spaces) as a
    /// list marker, which some CommonMark profiles render as a plain paragraph. A `**` run flush
    /// against full-width CJK punctuation can also fail the flanking rules, with the punctuation
    /// just outside the bold or just inside before the closing `**`, because the closing run is
    /// neither preceded by whitespace nor followed by whitespace or punctuation. Every observed
    /// shape is normalised here so the theme's `.strong` styling fires.
    static func normalize(_ source: String) -> String {
        var text = source
        text = text.replacingOccurrences(
            of: #"(?m)^(\s*)[*+]\s+"#,
            with: "$1- ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\*\*([^*\n]+)\*\*([、。，．：；！？」』）])"#,
            with: "**$1** $2",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\*\*([^*\n]*?[、。，．：；！？])\*\*(\S)"#,
            with: "**$1** $2",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"([「『（])\*\*([^*\n]+)\*\*"#,
            with: "$1 **$2**",
            options: .regularExpression
        )
        return text
    }
}

private nonisolated extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Theme {
    static func bulletin(accent: Color) -> Theme {
        Theme()
            .text {
                ForegroundColor(Color.textPrimary)
            }
            .link {
                ForegroundColor(accent)
                UnderlineStyle(.single)
            }
            .strong {
                FontWeight(.bold)
            }
            .emphasis {
                FontStyle(.italic)
            }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.25))
                    .markdownMargin(top: .em(0.6))
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.3))
            }
    }
}
