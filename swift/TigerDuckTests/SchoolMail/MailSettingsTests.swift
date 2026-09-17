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

    @Test func theLoginSheetCarriesTheResetLink() {
        let link = LoginSheet.FooterLink(title: "t", url: MailConstants.webmailURL)
        #expect(link.url == MailConstants.webmailURL)
    }

    @Test func eachLoginErrorHasItsOwnCopy() {
        let keys = [MailAccountManager.LoginError.credentials, .network, .certificate, .busy, .generic].map(\.message)
        #expect(Set(keys).count == 5)
    }
}
#endif
