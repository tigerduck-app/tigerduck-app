#if os(iOS)
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct LibraryViewModelAccountTests {
    @MainActor
    private final class SignInCalls {
        var count = 0
        var isOpen = false
    }

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

            LibraryService.schoolAccountDidSignOut()

            #expect(model.libUsername.isEmpty)
        }
    }

    @Test func anAccountChangeDuringATypedSignInRefusesASecondSignIn() async throws {
        let calls = SignInCalls()
        let signIn: @MainActor @Sendable (String, String) async throws -> Void = { _, _ in
            calls.count += 1
            try await waitUntil { calls.isOpen }
            throw LibraryServiceError.loginFailed("wrong password")
        }
        try await SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
            let model = LibraryViewModel()
            model.load()
            model.libUsername = "B1LIBTYPED"
            model.libPassword = "typed"
            model.loginAndStart(signIn: signIn)
            try await waitUntil { calls.count == 1 }

            NotificationCenter.default.post(name: LibraryAccount.didChange, object: nil)
            #expect(model.isLoggingIn)
            model.libPassword = "typed again"
            model.loginAndStart(signIn: signIn)
            calls.isOpen = true
            try await waitUntil { !model.isLoggingIn }

            #expect(calls.count == 1)
            #expect(model.access == .signedOut)
            #expect(model.errorMessage != nil)
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
