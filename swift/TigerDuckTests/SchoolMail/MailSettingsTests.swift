#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailSettingsTests {
    @Test func linksPointWhereTheSpecSays() {
        #expect(MailConstants.webmailURL.absoluteString == "https://mail.ntust.edu.tw")
        #expect(MailConstants.mail2000AppStoreURL.absoluteString == "https://apps.apple.com/tw/app/mail2000/id509471262")
    }

    /// The sheet's own footer, not a `FooterLink` the test built itself: this fails if
    /// `MailLoginSheet` ever points 忘記密碼 somewhere else or drops the footer.
    @Test func theLoginSheetCarriesTheResetLink() {
        let link = MailLoginSheet.resetPasswordLink
        #expect(link.url == MailConstants.webmailURL)
        #expect(link.title == String(localized: "school_mail_forgot_password"))
        #expect(!link.title.isEmpty)
    }

    /// §7.4: after a rejected password nothing may re-arm a background check. The toggle used to
    /// be gated on `isLoggedIn` alone, so a locked-out account could still switch notifications
    /// on and schedule a task `MailBackgroundRefresh` then immediately refuses to reschedule.
    @Test func theNotificationsToggleIsOfferedOnlyWhenABackgroundCheckCouldRun() {
        #expect(MailSettingsView.notificationsToggleIsEnabled(isLoggedIn: true, authFailed: false))
        #expect(!MailSettingsView.notificationsToggleIsEnabled(isLoggedIn: false, authFailed: false))
        #expect(!MailSettingsView.notificationsToggleIsEnabled(isLoggedIn: true, authFailed: true))

        // And it never disagrees with the scheduler: every state that offers the switch is a
        // state a handled background task would still reschedule from.
        for isLoggedIn in [true, false] {
            for authFailed in [true, false] {
                let offered = MailSettingsView.notificationsToggleIsEnabled(isLoggedIn: isLoggedIn, authFailed: authFailed)
                let wouldReschedule = MailBackgroundRefresh.shouldRescheduleAfterHandling(
                    featureEnabled: true, signedIn: isLoggedIn, notificationsEnabled: true, authFailed: authFailed)
                #expect(offered == wouldReschedule)
            }
        }
    }

    @Test func eachLoginErrorHasItsOwnCopy() {
        let keys = [MailAccountManager.LoginError.credentials, .network, .certificate, .busy, .generic].map(\.message)
        #expect(Set(keys).count == 5)
    }
}
#endif
