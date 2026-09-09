import Foundation
import Testing
@testable import TigerDuck

/// Pins the one rule that decides whether a protected screen shows content
/// or the login prompt.
///
/// A nil keychain read is ambiguous — the item is absent, or it cannot be
/// read right now — and answering "signed out" on that basis is what put a
/// signed-in user on the login prompt until they pulled to refresh. These
/// tests exist so the rule cannot be quietly simplified back to "just read
/// the keychain".
struct StoredCredentialResolutionTests {
    @Test func keychainAnswerWinsWhenItHasOne() {
        #expect(AuthService.resolveHasCredentials(
            keychainSaysPresent: true, mirrorSaysPresent: false))
    }

    @Test func unreadableKeychainDefersToTheMirrorRatherThanSayingSignedOut() {
        // The reported bug: a launch that could not reach the keychain.
        #expect(AuthService.resolveHasCredentials(
            keychainSaysPresent: false, mirrorSaysPresent: true))
    }

    @Test func genuinelySignedOutStaysSignedOut() {
        // Logout is the one path allowed to lower the mirror, so both are
        // false and the login prompt is correct.
        #expect(!AuthService.resolveHasCredentials(
            keychainSaysPresent: false, mirrorSaysPresent: false))
    }
}
