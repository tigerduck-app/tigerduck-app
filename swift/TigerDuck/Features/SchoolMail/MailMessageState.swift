#if os(iOS)
import Foundation

nonisolated struct MailLinkTarget: Equatable, Sendable, Identifiable {
    var href: String
    var issues: [MailLinkIssue]
    var canOpen: Bool
    var id: String { href }

    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    static func isOpenable(_ href: String) -> Bool {
        guard let scheme = scheme(of: href) else { return false }
        return openableSchemes.contains(scheme)
    }

    /// The scheme, lower-cased, per RFC 3986 §3.1 (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`),
    /// or nil when there is none. The character rule is also what keeps a colon *inside* a path
    /// or a userinfo from being read as a scheme separator.
    private static func scheme(of href: String) -> String? {
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = href.firstIndex(of: ":") else { return nil }
        let scheme = href[href.startIndex..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return nil }
        let isSchemeCharacter = { (character: Character) in
            character.isASCII && (character.isLetter || character.isNumber || "+-.".contains(character))
        }
        guard scheme.allSatisfy(isSchemeCharacter) else { return nil }
        return scheme.lowercased()
    }

    static func target(text: String, href rawHref: String) -> MailLinkTarget {
        let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonical = MailHref.canonicalHref(trimmed) else {
            return MailLinkTarget(href: MailTextCleaner.clean(trimmed), issues: [], canOpen: false)
        }
        return MailLinkTarget(
            href: MailTextCleaner.clean(canonical),
            issues: MailLinkCheck.linkIssues(text: text, href: canonical),
            canOpen: isOpenable(canonical)
        )
    }
}

nonisolated struct MailFormattedPages: Equatable, Sendable {
    var app: String
    var light: String
    var setsColors: Bool
}

struct MailMessageContent {
    var loadState: MailMessageViewModel.LoadState = .loading
    var detail: MailMessageDetail?
    var cachedSummary: MailSummary?
    var sanitized: SanitizedHTML?
    var linkedDocument: LinkedHTML?
    var pages: MailFormattedPages?
    var plainText = ""
    var linkedPlainText = AttributedString()
    var warnings: [MailWarning] = []
    var hasNothingRenderable = false
}

struct MailMessageDisplay {
    var mode: MailMessageViewModel.ViewMode = .formatted
    var viewsInLightMode = false
    var appearsLight = false
    var allowRemoteImages = false
    var hasPickedPage = false
}

struct MailMessageActivity {
    var source: String?
    var sourceLoadFailed = false
    var actionError: String?
    var isMoving = false
    var downloading: Set<String> = []
}

struct MailMessageStores {
    let cache: MailCache
    let prefs: any MailPreferences
    let notifier: MailNotifier
    let signIn: SignIn
}
#endif
