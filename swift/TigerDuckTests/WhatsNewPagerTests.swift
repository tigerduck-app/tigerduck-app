#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct WhatsNewPagerTests {
    @Observable final class Pager {
        var index = 0
        var pageMinX: [Int: CGFloat] = [:]
    }

    struct Host: View {
        @Bindable var pager: Pager

        var body: some View {
            WhatsNewPager(count: 3, index: $pager.index) { step in
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: {
                    pager.pageMinX[step] = $0
                }
            }
        }
    }

    /// SwiftUI reports a scroll position only while the scroll view is dragged, so the swipe
    /// goes through the delegate calls a finger makes. Without a scene the host builds no
    /// `UIScrollView`.
    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func theStepFollowsTheSwipeAndTheButtons(direction: LayoutDirection) async throws {
        let pager = Pager()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: Host(pager: pager).environment(\.layoutDirection, direction)
        )
        window.isHidden = false
        defer { window.isHidden = true }

        try await waitUntil {
            pager.pageMinX[1] != nil && !window.descendants(ofType: UIScrollView.self).isEmpty
        }
        let towardNext = try #require(pager.pageMinX[1]) - (try #require(pager.pageMinX[0]))
        #expect(direction == .rightToLeft ? towardNext < 0 : towardNext > 0)

        let scrollView = try #require(window.descendants(ofType: UIScrollView.self).first)
        let delegate = try #require(scrollView.delegate)
        let offset = { (page: Double) in
            CGPoint(x: (direction == .rightToLeft ? 2 - page : page) * scrollView.bounds.width, y: 0)
        }

        delegate.scrollViewWillBeginDragging?(scrollView)
        scrollView.setContentOffset(offset(0.6), animated: false)
        try await waitUntil { pager.index == 1 }
        scrollView.setContentOffset(offset(0.4), animated: false)
        try await waitUntil { pager.index == 0 }
        scrollView.setContentOffset(offset(1), animated: false)
        try await waitUntil { pager.index == 1 }
        var target = offset(1)
        delegate.scrollViewWillEndDragging?(scrollView, withVelocity: .zero, targetContentOffset: &target)
        delegate.scrollViewDidEndDragging?(scrollView, willDecelerate: false)

        pager.index = 2
        try await waitUntil { abs(scrollView.contentOffset.x - offset(2).x) < 0.5 }
    }
}
#endif
