import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// `PagingScrollLock` relies on the page-style `TabView` being backed by a
/// `UIScrollView` ancestor it can reach from a page's background. Host a
/// real pager in a window and check the flag actually lands.
@MainActor
struct PagingScrollLockTests {
    @Test(arguments: [true, false])
    func pagerScrollFollowsTheLock(isLocked: Bool) async throws {
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

        let scrollViews = Self.descendants(of: host.view).compactMap { $0 as? UIScrollView }
        #expect(!scrollViews.isEmpty, "page-style TabView should be backed by a UIScrollView")
        #expect(scrollViews.contains { $0.isScrollEnabled == !isLocked })
        window.isHidden = true
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
