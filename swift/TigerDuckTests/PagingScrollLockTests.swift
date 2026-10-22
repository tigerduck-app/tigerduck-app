import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct PagingScrollLockTests {
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
        try await waitUntil { host.view.descendants(ofType: PagingScrollLock.LockView.self).first?.attachedPager != nil }

        let lock = try #require(host.view.descendants(ofType: PagingScrollLock.LockView.self).first, "the representable should be in the hierarchy")

        let attached = try #require(
            lock.attachedPager, "the superview walk should reach the pager's scroll view"
        )
        #expect(attached.isScrollEnabled, "backward swipes must stay available")

        window.isHidden = true
    }

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
}
