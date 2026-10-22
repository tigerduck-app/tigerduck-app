#if os(iOS)
import Testing
import UIKit
@testable import TigerDuck

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

    @Test func aSchoolSignOutWithNoLibraryAccountEmptiesTheSignInForm() {
        let keychain = MemoryKeychain.signedIn()
        SecureStore.$sharedForTesting.withValue(keychain) {
            let model = LibraryViewModel()
            model.load()
            #expect(model.libUsername == "B11000000")
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
