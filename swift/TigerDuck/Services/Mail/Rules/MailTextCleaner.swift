#if os(iOS)
import Foundation

/// Appendix A.3: sender names, subjects, attachment names and notification text lose every
/// Unicode bidi control and every control character, and have their whitespace collapsed, which
/// defeats invoice-then-hidden-RTL-override-style disguises and stops a control character
/// spliced into a file extension from hiding what a file is.
///
/// `clean` mirrors Android's `mail/mime/TextCleaning.kt` step for step; `visibleText` mirrors
/// `MailWarnings.visibleText` there. They are separate on purpose — see `visibleText`.
nonisolated enum MailTextCleaner {
    /// Android's `BIDI`.
    private static let bidiControls: Set<UInt32> = Set<UInt32>(0x202A...0x202E)
        .union(0x2066...0x2069)
        .union([0x200E, 0x200F, 0x061C])

    /// Android's `CONTROLS` — `[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]` — scalar for
    /// scalar. `\t` (0x09), `\n` (0x0A) and `\r` (0x0D) are deliberately NOT in here: they are
    /// left for the whitespace collapse below, which turns a run of them into a single space.
    /// Deleting them outright instead would join two words that Android keeps apart.
    private static let controls: Set<UInt32> = Set<UInt32>(0x0000...0x0008)
        .union([0x000B, 0x000C])
        .union(0x000E...0x001F)
        .union([0x007F])

    /// Java's `\s`, which is ASCII-only (space, tab, newline, vertical tab, form feed
    /// and carriage return), not Unicode whitespace.
    ///
    /// Spelled out rather than taken from Foundation: `CharacterSet.whitespaces` contains
    /// U+200B ZERO WIDTH SPACE on Darwin, so collapsing with it would rewrite
    /// `ntust.e<U+200B>du.tw` as `ntust.e du.tw` — breaking one host into two words where
    /// Android leaves it whole, and turning an invisible-character attack into a *different*
    /// wrong answer instead of the right one. Removing U+200B is `visibleText`'s job.
    /// (U+000B and U+000C never actually reach this step; `controls` removed them already.)
    private static let asciiWhitespace: Set<UInt32> = [0x0020, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D]

    // Android also exposes a `stripBidi`-only entry point. Every iOS caller of this type —
    // `LiveMailClient`, `MailNotifier`, `MailHTMLSanitizer`, `MailMessageViewModel` and
    // `MailWarnings` — wants the full clean, so there is no second entry point here to go
    // stale; add one only when something actually needs bidi-only behaviour.

    /// Bidi controls out, control characters out, runs of whitespace collapsed to one space,
    /// then trimmed — Android's `TextCleaning.clean`.
    ///
    /// The trim uses Foundation's whitespace-and-newline set where Kotlin's `trim()` uses
    /// `Character.isWhitespace`; the difference is a handful of code points (U+00A0, U+2007,
    /// U+202F, U+0085, U+200B) that Foundation trims and Kotlin does not. Every one of them is
    /// in the direction of trimming *more*, which can only expose a file extension or a host
    /// the checks would otherwise have missed — never hide one.
    static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if controls.contains(scalar.value) || bidiControls.contains(scalar.value) { continue }
            if asciiWhitespace.contains(scalar.value) {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the reader actually sees: every character that draws nothing removed outright —
    /// every Unicode format character (`Cf` — the bidi marks, word joiner U+2060, soft hyphen
    /// U+00AD, BOM U+FEFF), every control character (`Cc`, C0 and C1), and everything Unicode
    /// itself marks `Default_Ignorable_Code_Point`. Android's `MailWarnings.INVISIBLE` is the
    /// `Cf`/`Cc` half only, so the wider class is still open there — a cross-platform
    /// follow-up, not something this side should match by weakening.
    ///
    /// This is deliberately *not* folded into `clean`. `clean` produces text that is shown to
    /// the user, so it keeps word boundaries: `\t`/`\n`/`\r` become a space. The warning rules
    /// need the opposite — the characters joined back up, because `ntust.e<U+200B>du.tw` reads
    /// as one host and must be compared as one. Every rule that decides whether to warn runs
    /// `visibleText`; every string that is merely displayed runs `clean`.
    ///
    /// The comparison fails *open* without this: `ntust.edu.tw` with a trailing word joiner
    /// matches no host pattern at all, so a link pointing somewhere else is reported as having
    /// nothing to compare rather than as a mismatch, and a crafted mail ends up with fewer
    /// banners than an ordinary one.
    static func visibleText(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isInvisible($0) }))
    }

    /// Named character by character rather than by attack, because enumerating attacks is how
    /// this check kept failing open: `Cf`/`Cc` alone left the combining grapheme joiner
    /// (U+034F), every variation selector (U+FE00–FE0F, U+E0100–), the reserved
    /// default-ignorables (U+2065) and the Hangul fillers (U+115F, U+1160, U+3164, U+FFA0)
    /// able to hide inside a host, a file extension or a keyword. They are all
    /// `Default_Ignorable_Code_Point`, which is Unicode's own name for "renders as nothing",
    /// and which excludes `White_Space`, so an ordinary space still separates two words here.
    ///
    /// Two are spelled out because the property does not cover them:
    ///
    /// - **U+200B** reports `.format` on this toolchain, but the property is answered from the
    ///   platform's Unicode tables at run time and this character's category has moved between
    ///   Unicode versions — which is exactly why Android spells it out too.
    /// - **U+2800 BRAILLE PATTERN BLANK** is not default-ignorable and is not meant to be: it
    ///   is a printing character (`So`), a real braille cell that happens to have no raised
    ///   dots. Unicode is right and it is still invisible to someone reading a filename or a
    ///   host, which is the only question this function answers, so it is removed here and
    ///   nowhere else. `clean` — the display path — leaves it alone, so braille text still
    ///   renders with its blank cells intact; it is dropped only when deciding whether to warn,
    ///   where removing a cell can add a warning but never take one away.
    ///
    /// `MailTextRulesTests` pins all of it.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x200B || scalar.value == 0x2800 { return true }
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        switch scalar.properties.generalCategory {
        case .format, .control: return true
        default: return false
        }
    }
}
#endif
