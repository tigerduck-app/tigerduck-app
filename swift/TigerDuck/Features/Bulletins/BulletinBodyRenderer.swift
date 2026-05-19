import Foundation

/// Cross-platform helpers for rendering a `BulletinAPI.BulletinDetail` body.
///
/// Both `BulletinDetailView` (iOS) and `MacBulletinsView` (macOS) feed
/// untrusted server Markdown into MarkdownUI. They must agree on:
///   1. Which field wins when the detail row has multiple body shapes —
///      `body_clean` (LLM-cleaned, fact-preserving Markdown) is preferred
///      over `body_md` (raw scrape) so the user reads the curated version.
///   2. The CommonMark preprocessor that fixes flanking-rule misfires
///      around CJK punctuation and `*   ` list markers the LLM emits.
///
/// Centralising both here means a future regex tweak applied for one
/// platform automatically applies to the other.
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

    /// Pre-process the raw Markdown so MarkdownUI's CommonMark parser
    /// reliably picks up inline emphasis inside list items. The LLM
    /// occasionally emits `*   ` (asterisk + multiple spaces) as a list
    /// marker which some CommonMark profiles render as a plain paragraph,
    /// and `**` runs flush against full-width CJK punctuation can fail
    /// CommonMark's flanking rules — both the "punct OUTSIDE the bold"
    /// and "punct INSIDE right before `**`" shapes misfire because the
    /// closing run is neither preceded by whitespace nor followed by a
    /// whitespace/punct. Every observed shape is normalised here so the
    /// theme's `.strong` styling actually fires.
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
