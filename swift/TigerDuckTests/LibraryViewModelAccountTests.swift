#if os(iOS)
import Testing
import UIKit
@testable import TigerDuck

/// A library code already on screen belongs to whoever was signed in when it
/// was fetched. The in-flight guards stop a late one landing; this is the one
/// that had already landed.
@MainActor
struct LibraryViewModelAccountTests {
    @Test func anAccountChangeTakesTheCodeOffTheScreenAtOnce() {
        let model = LibraryViewModel()
        model.qrCodeImage = UIImage()
        model.qrPayload = "previous-account-code"
        model.isLoadingQR = true

        NotificationCenter.default.post(name: LibraryService.accountDidChange, object: nil)

        #expect(model.qrCodeImage == nil)
        #expect(model.qrPayload == nil)
        #expect(model.isLoadingQR == false)
    }

    /// After a school sign-out takes the library account with it, the sign-in form keeps neither
    /// the departing student ID nor a typed password (#440).
    @Test func anAccountChangeEmptiesTheSignInForm() {
        SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
            let model = LibraryViewModel()
            model.libUsername = "B1DEPARTING"
            model.libPassword = "typed"

            NotificationCenter.default.post(name: LibraryService.accountDidChange, object: nil)

            #expect(model.libUsername.isEmpty)
            #expect(model.libPassword.isEmpty)
        }
    }

    /// With no library account stored, the sign-in form offers the school account's student ID,
    /// so a school sign-out takes it out of the form as well
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/499).
    @Test func aSchoolSignOutWithNoLibraryAccountEmptiesTheSignInForm() {
        let keychain = MemoryKeychain.signedIn()
        SecureStore.$sharedForTesting.withValue(keychain) {
            let model = LibraryViewModel()
            model.load()
            #expect(model.libUsername == "B11000000")
            // `AuthService.logout()` has deleted the school account by the time the library hears of it.
            try? keychain.removeObject(forKey: AppConstants.KeychainKeys.studentId)
            try? keychain.removeObject(forKey: AppConstants.KeychainKeys.password)

            #expect(!LibraryService.clearCredentials(ifSchoolAccount: "B11000000"))

            #expect(model.libUsername.isEmpty)
        }
    }

    @Test func otherNotificationsLeaveTheCodeAlone() {
        let model = LibraryViewModel()
        model.qrPayload = "code"
        NotificationCenter.default.post(name: Notification.Name("TigerDuck.somethingElse"), object: nil)
        #expect(model.qrPayload == "code")
    }
}
#endif
