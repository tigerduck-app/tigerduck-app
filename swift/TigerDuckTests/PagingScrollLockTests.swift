import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// `PagingScrollLock` relies on the page-style `TabView` being backed by a
/// `UIScrollView` ancestor it can reach from a page's background. Host a
/// real pager in a window and check the walk still lands on it.
@MainActor
struct PagingScrollLockTests {
    /// The lock used to set `isScrollEnabled = false`, which froze the page
    /// in *both* directions — a user who had not ticked the onboarding
    /// checkboxes could not swipe back to the previous page either. Only
    /// forward motion is gated now, so the pager must stay scrollable
    /// whether or not the lock is engaged; forward drags are refused
    /// individually, in the pan handler.
    @Test(arguments: [true, false])
    func pagerStaysScrollableWhileLocked(isLocked: Bool) async throws {
        let pager = TabView {
            Color.red.background(PagingScrollLock(isLocked: isLocked)).tag(0)
            Color.blue.tag(1)
        }
        .tabViewStyle(.page)

        let host = UIHostingController(rootView: pager)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let locks = Self.descendants(of: host.view)
            .compactMap { $0 as? PagingScrollLock.LockView }
        let lock = try #require(locks.first, "the representable should be in the hierarchy")

        // Without this the rest of the test passes vacuously: a lock that
        // never found the pager also never disables anything.
        let attached = try #require(
            lock.attachedPager, "the superview walk should reach the pager's scroll view"
        )
        #expect(attached.isScrollEnabled, "backward swipes must stay available")

        window.isHidden = true
    }

    /// A page-style `TabView` reverses under a right-to-left language, so
    /// the same finger movement that advances in English goes back in
    /// Arabic — and the app ships ar, fa, he and ur.
    @Test(arguments: [
        (dx: -40.0, isRTL: false, isForward: true),
        (dx: 40.0, isRTL: false, isForward: false),
        (dx: 40.0, isRTL: true, isForward: true),
        (dx: -40.0, isRTL: true, isForward: false),
    ])
    func forwardDragMirrorsUnderRTL(dx: Double, isRTL: Bool, isForward: Bool) {
        #expect(
            PagingScrollLock.isForwardDrag(translationX: CGFloat(dx), isRTL: isRTL) == isForward
        )
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
