#if os(iOS)
import Foundation

/// Server values (design doc §1.1) and the fixed values of Appendix A.6.
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
    static let sourceConfirmBytes = 5 * 1024 * 1024
    static let maxEncodedMessageBytes = 50 * 1024 * 1024
    static let maxInlineImageBytes = 5 * 1024 * 1024
    static let notificationCollapseThreshold = 5
    static let connectionIdleClose: TimeInterval = 30
    static let sentCopyDedupeDelay: Duration = .seconds(3)
    static let diagnosticsLimit = 10

    static let backgroundTaskIdentifier = "org.ntust.app.TigerDuck.mailRefresh"
    static let backgroundEarliestBegin: TimeInterval = 15 * 60
    static let valetIdentifier = "org.ntust.app.TigerDuck.mail"
    static let notificationThread = "schoolMail"
    static let notificationKind = "school_mail"

    /// `B10000000` → `b10000000@mail.ntust.edu.tw` (Mail2000 writes the address lowercase).
    static func address(forStudentID studentID: String) -> String {
        "\(studentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())@\(addressDomain)"
    }
}
#endif
