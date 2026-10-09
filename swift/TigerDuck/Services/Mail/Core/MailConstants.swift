#if os(iOS)
import Foundation

/// Server values and the fixed limits and intervals School Mail uses.
///
/// `host`, `imapPort`, `smtpPort` and `addressDomain` are the school's own values and stay that
/// way. Nothing reads them directly to open a connection or build an address: they are the
/// inputs to `MailServerConfig.school`, and every read site goes through
/// `MailServerConfig.effective`, so a DEBUG-only override has one place to take effect rather
/// than several.
nonisolated enum MailConstants {
    static let host = "mail.ntust.edu.tw"
    static let imapPort = 993
    static let smtpPort = 465
    static let addressDomain = "mail.ntust.edu.tw"
    static let inbox = "INBOX"
    static let webmailURL = URL(string: "https://mail.ntust.edu.tw")!
    static let mail2000AppStoreURL = URL(string: "https://apps.apple.com/tw/app/mail2000/id509471262")!

    static let pagePollInterval: TimeInterval = 60
    static let foregroundCheckThrottle: TimeInterval = 60
    static let pageSize = 50
    static let bodyCacheLimitBytes = 20 * 1024 * 1024
    static let maxEncodedMessageBytes = 50 * 1024 * 1024
    static let maxInlineImageBytes = 5 * 1024 * 1024
    /// The largest message `LiveMailClient` downloads whole to parse its MIME locally, when the
    /// server's `BODYSTRUCTURE` came back unreadable and the part-by-part fetch has nothing to
    /// work from. It matches `maxEncodedMessageBytes`, the largest single message the app deals
    /// with, not `MailCache`'s per-entry ceiling: that one is about storage, this about transfer.
    /// Refusing to parse saves no bytes, because `parseFailed` forces the source view and
    /// `MailMessageView.onChange(of: mode)` then starts `loadSource()`, downloading the whole
    /// message anyway, so a lower bound only turns larger mail (a 28 MB Mail2000 bounce) into an
    /// unreadable dump. The bound still stops a pathological message being held in memory twice.
    static let maxLocalParseBytes = maxEncodedMessageBytes
    static let notificationCollapseThreshold = 5
    static let connectionIdleClose: TimeInterval = 30
    static let sentCopyDedupeDelay: Duration = .seconds(3)
    static let diagnosticsLimit = 10
    /// How many further pages the list walks back when a first page comes back with every row
    /// `\Deleted` (`MailListViewModel.walkBackToVisibleMail`). Not an Appendix A.6 value — a
    /// bound on an added recovery, so a folder with thousands of flagged messages costs a few
    /// round trips rather than an unbounded scan.
    static let emptyWindowWalkbackPages = 4
    /// Rows per folder a background warm fetches (`MailListViewModel.startWarm`): enough to fill
    /// a screen, and the real load that follows a chip tap replaces it.
    static let warmPageSize = 20
    /// How long a warm holds off before it takes the connection, so that a refresh in the first
    /// moments after the list paints cancels it rather than queueing behind it.
    static let warmStartDelay: Duration = .milliseconds(500)
    /// Newest arrivals whose bodies one check or one page poll fetches ahead of a tap.
    static let bodyPrefetchLimit = 5

    static let backgroundTaskIdentifier = "org.ntust.app.TigerDuck.mailRefresh"
    static let backgroundEarliestBegin: TimeInterval = 15 * 60
    static let valetIdentifier = "org.ntust.app.TigerDuck.mail"
    static let notificationThread = "schoolMail"
    static let notificationKind = "school_mail"

    /// `B10000000` → `b10000000@mail.ntust.edu.tw` (Mail2000 writes the address lowercase).
    ///
    /// The domain is the effective one, so a DEBUG override reaches the `From` address the
    /// compose screen sends with and the address `MailAccountManager` shows in Settings.
    ///
    /// A username that already carries a domain gets no second one. A school student ID never
    /// contains `@`, so the real path is unchanged; this lets the override sign in to a server
    /// whose username is an email address without producing `user@example.com@example.com`.
    static func address(forStudentID studentID: String) -> String {
        let identifier = studentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !identifier.contains("@") else { return identifier }
        return "\(identifier)@\(MailServerConfig.effective.addressDomain)"
    }
}
#endif
