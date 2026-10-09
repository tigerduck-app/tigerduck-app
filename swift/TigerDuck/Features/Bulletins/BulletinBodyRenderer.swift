import Foundation

/// Cross-platform helpers for rendering a `BulletinAPI.BulletinDetail` body.
///
/// `BulletinDetailView` (iOS) and `MacBulletinsView` (macOS) both feed untrusted server Markdown
/// into MarkdownUI and must agree on two things, kept here so a fix for one platform reaches the
/// other: which body field wins (`body_clean`, the LLM-cleaned, fact-preserving Markdown, over the
/// raw scrape in `body_md`), and the CommonMark preprocessing that fixes flanking-rule misfires
/// around CJK punctuation and the `*   ` list markers the LLM emits.
nonisolated enum BulletinBodyRenderer {
    /// Fallback chain that picks the best non-empty body string for a
    /// loaded `BulletinDetail`, optionally falling back to a list-row
    /// `summary` when the detail itself is empty.
    ///
    /// Order: `body_clean` → `body_md` → `detail.summary` →
    /// `fallbackSummary` → `""`. Each candidate is trimmed before the
    /// empty check so a row of only whitespace doesn't short-circuit the
    /// chain.
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
