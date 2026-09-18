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

    /// 快取大小 has to account for the whole cache root — folder pages, bodies, sources and a
    /// downloaded attachment alike — because that is what is actually on disk. Driven through
    /// the screen's own measure/clear path, not through `MailCache` directly, so a row wired to
    /// the narrower `bodyBytes()` or to a second clear-all of its own fails here.
    @Test func theCacheRowMeasuresEverythingAndClearingEmptiesIt() async throws {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1,
                                      summaries: [SchoolMailTestDoubles.summary(uid: 1)], oldestLoadedSequence: nil))
        let detail = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: 1), messageID: nil, inReplyTo: nil,
                                       references: nil, parts: [], textBody: String(repeating: "x", count: 500),
                                       htmlBody: nil, inlineImages: nil)
        cache.saveDetail(detail, folder: "INBOX", uidValidity: 1)
        cache.saveSource(String(repeating: "s", count: 400), folder: "INBOX", uidValidity: 1, uid: 1)
        let attachment = try cache.temporaryFileURL(filename: "課程.pdf")
        try Data(repeating: 0, count: 700).write(to: attachment)

        let measured = await MailSettingsView.measureCache(cache)
        // Bigger than the bodies alone: the page and the attachment count too.
        #expect(measured > cache.bodyBytes())
        #expect(measured > 700)

        let afterClear = await MailSettingsView.clearCache(cache)
        #expect(afterClear == 0)
        #expect(cache.loadPage(folder: "INBOX") == nil)
        #expect(!FileManager.default.fileExists(atPath: attachment.path))
    }

    /// The figure is formatted by the platform, so it needs no string of its own — and it is
    /// never the raw byte count.
    @Test func theCacheSizeIsFormattedAsAFileSize() {
        #expect(MailSettingsView.cacheSizeText(bytes: 0) == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
        #expect(MailSettingsView.cacheSizeText(bytes: 5_242_880) != "5242880")
    }

    @Test func eachLoginErrorHasItsOwnCopy() {
        let keys = [MailAccountManager.LoginError.credentials, .network, .certificate, .busy, .generic].map(\.message)
        #expect(Set(keys).count == 5)
    }
}
#endif
