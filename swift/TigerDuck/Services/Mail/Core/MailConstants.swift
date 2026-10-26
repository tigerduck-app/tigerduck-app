#if os(iOS)
import Foundation

///
nonisolated enum MailConstants {
    static let host = "mail.ntust.edu.tw"
    static let imapPort = 993
    static let smtpPort = 465
    static let addressDomain = "mail.ntust.edu.tw"
    static let inbox = "INBOX"
    static let webmailURL = URL(string: "https://mail.ntust.edu.tw")!

    static let pagePollInterval: TimeInterval = 60
    static let foregroundCheckThrottle: TimeInterval = 60
    static let pageSize = 50
    static let cachedPageRows = 200
    static let bodyCacheLimitBytes = 20 * 1024 * 1024
    static let openedAttachmentLifetime: TimeInterval = 24 * 60 * 60
    static let maxEncodedMessageBytes = 50 * 1024 * 1024
    static let maxInlineImageBytes = 5 * 1024 * 1024
    static let maxLocalParseBytes = maxEncodedMessageBytes
    static let notificationCollapseThreshold = 5
    static let connectionIdleClose: TimeInterval = 30
    static let sentCopyDedupeDelay: Duration = .seconds(3)
    static let diagnosticsLimit = 10
    static let emptyWindowWalkbackPages = 4
    static let warmPageSize = 20
    static let warmStartDelay: Duration = .milliseconds(500)
    static let bodyPrefetchLimit = 5
    static let indexBatchSize = 20
    static let indexResyncInterval: TimeInterval = 15 * 60
    static let indexRetryDelay: TimeInterval = 60
    static let searchTextPartBytes = 256 * 1024

    static let backgroundTaskIdentifier = "org.ntust.app.TigerDuck.mailRefresh"
    static let backgroundEarliestBegin: TimeInterval = 15 * 60
    static let valetIdentifier = "org.ntust.app.TigerDuck.mail"
    static let notificationThread = "schoolMail"
    static let notificationKind = "school_mail"

    /// `B10000000` → `b10000000@mail.ntust.edu.tw` (Mail2000 writes the address lowercase).
    ///
    /// The domain is the effective one, so a DEBUG override reaches the `From` address the
    /// compose screen sends with and the address `MailAccountManager` shows in Settings.
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
