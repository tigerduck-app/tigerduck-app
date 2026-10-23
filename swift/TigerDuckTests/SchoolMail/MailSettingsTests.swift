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

    @Test func theLoginSheetCarriesTheResetLink() {
        let link = MailLoginSheet.resetPasswordLink
        #expect(link.url == MailConstants.webmailURL)
        #expect(link.title == String(localized: "school_mail_forgot_password"))
        #expect(!link.title.isEmpty)
    }

    @Test func theNotificationsToggleIsOfferedOnlyWhenABackgroundCheckCouldRun() {
        #expect(MailNotificationSettingsView.notificationsToggleIsEnabled(isLoggedIn: true, authFailed: false))
        #expect(!MailNotificationSettingsView.notificationsToggleIsEnabled(isLoggedIn: false, authFailed: false))
        #expect(!MailNotificationSettingsView.notificationsToggleIsEnabled(isLoggedIn: true, authFailed: true))

        for isLoggedIn in [true, false] {
            for authFailed in [true, false] {
                let offered = MailNotificationSettingsView.notificationsToggleIsEnabled(isLoggedIn: isLoggedIn, authFailed: authFailed)
                let wouldReschedule = MailBackgroundRefresh.shouldRescheduleAfterHandling(
                    featureEnabled: true, signedIn: isLoggedIn, notificationsEnabled: true, authFailed: authFailed,
                    notificationsDenied: false)
                #expect(offered == wouldReschedule)
            }
        }
    }

    @Test func theSwitchOnTheNotificationsPageDrivesTheAccount() async {
        let h = MailAccountManagerTests.harness()
        await h.manager.login(studentID: "B10000000", password: "pw")
        let isOn = MailNotificationSettingsView.notificationsBinding(for: h.manager)

        #expect(isOn.wrappedValue == h.manager.notificationsEnabled)

        isOn.wrappedValue = false
        #expect(!h.manager.notificationsEnabled)
        #expect(!isOn.wrappedValue)
        #expect(h.prefs.notificationsEnabled == false)
        #expect(h.hooks.disabled == 1)

        isOn.wrappedValue = true
        #expect(h.manager.notificationsEnabled)
        #expect(h.prefs.notificationsEnabled == true)
        #expect(h.hooks.enabled == 1)
    }

    @Test func bothScreensFollowTheSignedInState() async {
        let h = MailAccountManagerTests.harness()
        #expect(!h.manager.isLoggedIn)
        #expect(!MailNotificationSettingsView.settingsRowIsEnabled(isLoggedIn: h.manager.isLoggedIn))
        #expect(!MailSettingsView.displayNameIsEnabled(isLoggedIn: h.manager.isLoggedIn))

        await h.manager.login(studentID: "B99999999", password: "tigerduck-review")
        #expect(h.manager.isDemo)
        #expect(MailNotificationSettingsView.settingsRowIsEnabled(isLoggedIn: h.manager.isLoggedIn))
        #expect(MailSettingsView.displayNameIsEnabled(isLoggedIn: h.manager.isLoggedIn))

        h.manager.logout()
        #expect(!MailNotificationSettingsView.settingsRowIsEnabled(isLoggedIn: h.manager.isLoggedIn))
        #expect(!MailSettingsView.displayNameIsEnabled(isLoggedIn: h.manager.isLoggedIn))
    }

    @Test func thereIsNoWayToTheSwitchWhileSignedOut() {
        for authFailed in [true, false] {
            #expect(!MailNotificationSettingsView.settingsRowIsEnabled(isLoggedIn: false))
            #expect(!MailNotificationSettingsView.notificationsToggleIsEnabled(
                isLoggedIn: false, authFailed: authFailed))
        }
    }

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
        #expect(measured > cache.bodyBytes())
        #expect(measured > 700)

        let afterClear = await MailSettingsView.clearCache(cache)
        #expect(afterClear == 0)
        #expect(cache.loadPage(folder: "INBOX") == nil)
        #expect(!FileManager.default.fileExists(atPath: attachment.path))
    }

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
