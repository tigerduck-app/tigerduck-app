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

    /// Java's `\s`, which is ASCII-only (space, tab, newline, vertical tab, form feed and
    /// carriage return), not Unicode whitespace.
    ///
    /// Spelled out rather than taken from Foundation: `CharacterSet.whitespaces` contains
    /// U+200B ZERO WIDTH SPACE on Darwin, so collapsing with it would turn `ntust.e<U+200B>du.tw`
    /// into `ntust.e du.tw`: two words where Android keeps one host, a different wrong answer to
    /// an invisible-character attack. Removing U+200B is `visibleText`'s job. U+000B and U+000C
    /// never reach this step; `controls` removed them already.
    private static let asciiWhitespace: Set<UInt32> = [0x0020, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D]

    // Android also has a `stripBidi`-only entry point. Every caller here (`LiveMailClient`,
    // `MailNotifier`, `MailHTMLSanitizer`, `MailMessageViewModel`, `MailWarnings`) wants the full
    // clean, so there is none to go stale; add one only when something needs bidi-only behaviour.

    /// Bidi controls out, control characters out, runs of whitespace collapsed to one space,
    /// then trimmed: Android's `TextCleaning.clean`.
    ///
    /// The trim uses Foundation's whitespace-and-newline set and Kotlin's `trim()` uses
    /// `Char.isWhitespace`, which includes `Character.isSpaceChar`; here they differ only on U+0085
    /// and U+200B, which Foundation removes and Kotlin keeps. Trimming more can only expose a file
    /// extension or a host the checks would otherwise miss, never hide one.
    /// See docs/decisions/0018-mail-warnings-android-parity.md.
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

    /// What the reader sees: every character that draws nothing removed, meaning every format
    /// (`Cf`: bidi marks, U+2060, U+00AD, U+FEFF) and control (`Cc`, C0 and C1) character and all
    /// of `Default_Ignorable_Code_Point`. Android's `MailWarnings.INVISIBLE` has only `Cf`/`Cc`, so
    /// the rest is still open there; do not weaken this to match. Not part of `clean`, which makes
    /// display text and keeps word boundaries (`\t`/`\n`/`\r` become a space): a warning must
    /// compare `ntust.e<U+200B>du.tw` as the one host it reads as. Warning rules run this,
    /// displayed text runs `clean`. Without it the check fails open: `ntust.edu.tw` plus a word
    /// joiner matches no host pattern, so a link elsewhere is nothing to compare, not a mismatch.
    static func visibleText(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isInvisible($0) }))
    }

    /// Classified by what a character is, not by attack: listing attacks kept failing open, as
    /// `Cf`/`Cc` alone let the combining grapheme joiner, variation selectors, reserved
    /// default-ignorables and Hangul fillers hide in a host, a file extension or a keyword. All are
    /// `Default_Ignorable_Code_Point` ("renders as nothing"), which excludes `White_Space`, so a
    /// space still separates words. U+200B is listed because its category comes from the run-time
    /// Unicode tables and has moved between versions; Android lists it too. U+2800, a printing
    /// braille cell (`So`), shows nothing: `clean` keeps it for display, and dropping it here can
    /// add a warning but never remove one. `MailTextRulesTests` pins all of it.
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
