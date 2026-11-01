import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// `ForwardPagingLock` relies on the page-style `TabView` being backed by a
/// `UIScrollView` ancestor it can reach from a page's background. Host a
/// real pager in a window and check the walk still lands on it.
@MainActor
struct ForwardPagingLockTests {
    @Test(arguments: [true, false])
    func pagerStaysScrollableWhileLocked(isLocked: Bool) async throws {
        let pager = TabView {
            Color.red.background(ForwardPagingLock(isLocked: isLocked)).tag(0)
            Color.blue.tag(1)
        }
        .tabViewStyle(.page)

        let host = UIHostingController(rootView: pager)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await waitUntil { host.view.descendants(ofType: ForwardPagingLock.LockView.self).first?.attachedPager != nil }

        let lock = try #require(host.view.descendants(ofType: ForwardPagingLock.LockView.self).first, "the representable should be in the hierarchy")

        let attached = try #require(
            lock.attachedPager, "the superview walk should reach the pager's scroll view"
        )
        #expect(attached.isScrollEnabled, "backward swipes must stay available")

        window.isHidden = true
    }
}
