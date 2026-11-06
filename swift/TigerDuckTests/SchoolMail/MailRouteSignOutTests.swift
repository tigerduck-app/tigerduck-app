#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MailRouteSignOutTests {
    @Observable
    final class Account {
        let session = AccountSession()
        var isLoggedIn = true
        var opened = SignInBound<MailMessageRoute?>(empty: nil)

        func open(uid: UInt32) {
            opened.set(MailMessageRoute(folder: "INBOX", uid: uid), for: session.currentSignIn)
        }
    }

    struct Screen: View {
        @Bindable var account: Account

        var body: some View {
            NavigationStack {
                Group {
                    if account.isLoggedIn { List { Text("mail list") } } else { Text("signed out") }
                }
                .modifier(MailMessageDestination(session: account.session, opened: $account.opened) { route in
                    Text("message \(route.uid)")
                })
            }
        }
    }

    private static func showOpenMessage() async throws -> (Account, UIWindow) {
        let account = Account()
        let window = try ClubScreensTests.show(Screen(account: account), look: ClubScreensTests.looks[0])
        try await waitUntil { ClubScreensTests.shows("mail list", in: window) }
        account.open(uid: 7)
        try await waitUntil { ClubScreensTests.shows("message 7", in: window) }
        return (account, window)
    }

    @Test("signing in again while a message is open closes it")
    func signingInAgainClosesTheOpenMessage() async throws {
        try await withAccessibilityAutomation {
            let (account, window) = try await Self.showOpenMessage()
            defer { window.isHidden = true }
            account.session.endSignIn()
            try await waitUntil { ClubScreensTests.shows("mail list", in: window) && !ClubScreensTests.shows("message 7", in: window) }
            #expect(account.opened.value == nil)
        }
    }

    @Test("signing out closes the open message, and signing back in does not bring it back")
    func signingOutAndInLeavesTheMessageClosed() async throws {
        try await withAccessibilityAutomation {
            let (account, window) = try await Self.showOpenMessage()
            defer { window.isHidden = true }
            account.session.endSignIn()
            account.isLoggedIn = false
            try await waitUntil { ClubScreensTests.shows("signed out", in: window) && !ClubScreensTests.shows("message 7", in: window) }
            account.isLoggedIn = true
            try await waitUntil { ClubScreensTests.shows("mail list", in: window) }
            #expect(!ClubScreensTests.shows("message 7", in: window))
            #expect(account.opened.value == nil)
        }
    }
}
#endif
