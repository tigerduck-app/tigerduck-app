#if os(iOS)
import Foundation

/// Server values (design doc §1.1) and the fixed values of Appendix A.6.
///
/// `host`, `imapPort`, `smtpPort` and `addressDomain` are the school's own values and stay
/// exactly what §1.1 says. Nothing reads them directly to open a connection or build an
/// address any more — they are the inputs to `MailServerConfig.school`, and every read site
/// goes through `MailServerConfig.effective` so that a DEBUG-only override has one place to
/// take effect rather than several.
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
    /// The largest message `LiveMailClient` will download whole in order to parse its MIME
    /// locally, when the server's own `BODYSTRUCTURE` came back unreadable and the normal
    /// part-by-part fetch therefore has nothing to work from.
    ///
    /// Not an Appendix A.6 value — a bound on an added recovery.
    ///
    /// It was `bodyCacheLimitBytes / 2` (10 MB), borrowed from `MailCache`'s per-entry ceiling on
    /// the reasoning that a mail too big to *keep* is too big to fetch whole. That was wrong, and
    /// wrong in a way that excluded the one real message this recovery was written for: a 28 MB
    /// Mail2000 bounce, which went on showing "Couldn't read this mail's format" on a device
    /// after the recovery shipped, because the guard turned it away.
    ///
    /// The cache's ceiling answers "how much may one entry evict?", which is a question about
    /// *storage*. This is a question about *transfer*, and the two have opposite answers here,
    /// because refusing to parse saves no bytes at all: `parseFailed` forces the source view,
    /// and `MailMessageView.onChange(of: mode)` starts `loadSource()` the moment it does — so
    /// the whole message is downloaded either way. Below the old ceiling that bought a readable
    /// mail; above it, the user paid the full download *and* got the unreadable dump. The bound
    /// now matches `maxEncodedMessageBytes`, the size this app already treats as the largest
    /// single message it deals with, so it stops a pathological message being held in memory
    /// twice while no longer refusing ordinary mail with a large attachment.
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
    /// A username that already carries a domain is returned as it stands rather than having a
    /// second one appended. A school student ID never contains `@`, so this changes nothing on
    /// the real path; it is what lets the override sign in to a server whose username *is* an
    /// email address without producing `user@example.com@example.com`.
    static func address(forStudentID studentID: String) -> String {
        let identifier = studentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !identifier.contains("@") else { return identifier }
        return "\(identifier)@\(MailServerConfig.effective.addressDomain)"
    }
}
#endif
