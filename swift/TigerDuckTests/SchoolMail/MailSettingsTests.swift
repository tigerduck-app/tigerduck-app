#if os(iOS)
import Foundation
import SwiftUI
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
        #expect(MailNotificationSettingsView.notificationsToggleIsEnabled(isLoggedIn: true, authFailed: false))
        #expect(!MailNotificationSettingsView.notificationsToggleIsEnabled(isLoggedIn: false, authFailed: false))
        #expect(!MailNotificationSettingsView.notificationsToggleIsEnabled(isLoggedIn: true, authFailed: true))

        // And it never disagrees with the scheduler: every state that offers the switch is a
        // state a handled background task would still reschedule from.
        for isLoggedIn in [true, false] {
            for authFailed in [true, false] {
                let offered = MailNotificationSettingsView.notificationsToggleIsEnabled(isLoggedIn: isLoggedIn, authFailed: authFailed)
                let wouldReschedule = MailBackgroundRefresh.shouldRescheduleAfterHandling(
                    featureEnabled: true, signedIn: isLoggedIn, notificationsEnabled: true, authFailed: authFailed)
                #expect(offered == wouldReschedule)
            }
        }
    }

    /// The switch itself, driven through the binding `MailNotificationSettingsView` hands its
    /// `Toggle` — not a direct write to the manager. A toggle wired to the wrong property, or
    /// to a copy of the state, passes the model-level test in `MailAccountManagerTests` and
    /// fails this one.
    @Test func theSwitchOnTheNotificationsPageDrivesTheAccount() async {
        let h = MailAccountManagerTests.harness()
        await h.manager.login(studentID: "B10000000", password: "pw")
        let isOn = MailNotificationSettingsView.notificationsBinding(for: h.manager)

        // Starts reflecting the stored preference rather than a constant.
        #expect(isOn.wrappedValue == h.manager.notificationsEnabled)

        isOn.wrappedValue = false
        #expect(!h.manager.notificationsEnabled)
        #expect(!isOn.wrappedValue)
        // Persisted, and the side effects the move must not drop: cancelling the background
        // refresh and clearing delivered mail notifications.
        #expect(h.prefs.notificationsEnabled == false)
        #expect(h.hooks.disabled == 1)

        isOn.wrappedValue = true
        #expect(h.manager.notificationsEnabled)
        #expect(h.prefs.notificationsEnabled == true)
        // Re-scheduling the background refresh and asking for notification permission.
        #expect(h.hooks.enabled == 1)
    }

    /// The Settings row that opens the page, and the display-name field left behind in
    /// 信箱設定, both follow the real `isLoggedIn` — including demo mode, which is signed in.
    @Test func bothScreensFollowTheSignedInState() async {
        let h = MailAccountManagerTests.harness()
        #expect(!h.manager.isLoggedIn)
        #expect(!MailNotificationSettingsView.settingsRowIsEnabled(isLoggedIn: h.manager.isLoggedIn))
        #expect(!MailSettingsView.displayNameIsEnabled(isLoggedIn: h.manager.isLoggedIn))

        // The demo account is a sign-in like any other, so neither is greyed out for it.
        await h.manager.login(studentID: "B99999999", password: "tigerduck-review")
        #expect(h.manager.isDemo)
        #expect(MailNotificationSettingsView.settingsRowIsEnabled(isLoggedIn: h.manager.isLoggedIn))
        #expect(MailSettingsView.displayNameIsEnabled(isLoggedIn: h.manager.isLoggedIn))

        h.manager.logout()
        #expect(!MailNotificationSettingsView.settingsRowIsEnabled(isLoggedIn: h.manager.isLoggedIn))
        #expect(!MailSettingsView.displayNameIsEnabled(isLoggedIn: h.manager.isLoggedIn))
    }

    /// A signed-out account cannot reach the switch by either route: the Settings row will not
    /// open the page, and the switch on it is dead anyway. The two rules are separate code, so
    /// pin that they never disagree about being signed out.
    @Test func thereIsNoWayToTheSwitchWhileSignedOut() {
        for authFailed in [true, false] {
            #expect(!MailNotificationSettingsView.settingsRowIsEnabled(isLoggedIn: false))
            #expect(!MailNotificationSettingsView.notificationsToggleIsEnabled(
                isLoggedIn: false, authFailed: authFailed))
        }
    }

    @Test func eachLoginErrorHasItsOwnCopy() {
        let keys = [MailAccountManager.LoginError.credentials, .network, .certificate, .busy, .generic].map(\.message)
        #expect(Set(keys).count == 5)
    }
}
#endif
