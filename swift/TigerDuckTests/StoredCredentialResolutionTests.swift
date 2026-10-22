import Foundation
import Testing
@testable import TigerDuck

struct StoredCredentialResolutionTests {
    @Test func keychainAnswerWinsWhenItHasOne() {
        #expect(AuthService.resolveHasCredentials(
            keychainSaysPresent: true, mirrorSaysPresent: false))
    }

    @Test func unreadableKeychainDefersToTheMirrorRatherThanSayingSignedOut() {
        #expect(AuthService.resolveHasCredentials(
            keychainSaysPresent: false, mirrorSaysPresent: true))
    }

    @Test func genuinelySignedOutStaysSignedOut() {
        #expect(!AuthService.resolveHasCredentials(
            keychainSaysPresent: false, mirrorSaysPresent: false))
    }

    @MainActor
    private final class KeychainReads {
        var count = 0
    }

    @MainActor
    @Test func redrawsReadTheLastKeychainAnswerNotTheKeychain() {
        let reads = KeychainReads()
        let auth = AuthService(keychainHasCredentials: {
            reads.count += 1
            return false
        }, notificationCenter: NotificationCenter())

        for _ in 0..<5 { _ = auth.hasStoredCredentials }

        #expect(reads.count == 1)
    }
}
