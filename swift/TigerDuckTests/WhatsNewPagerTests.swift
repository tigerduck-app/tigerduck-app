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
        var position = ScrollPosition(idType: Int.self)
        var pageMinX: [Int: CGFloat] = [:]
    }

    struct Host: View {
        @Bindable var pager: Pager
        var locksForward = false

        var body: some View {
            WhatsNewPager(count: 3, index: $pager.index, position: $pager.position, locksForward: locksForward) { step in
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: {
                    pager.pageMinX[step] = $0
                }
            }
        }
    }

    @Test(arguments: [false, true], [LayoutDirection.leftToRight, .rightToLeft])
    func theStepFollowsTheSwipeAndTheButtons(accessibility: Bool, direction: LayoutDirection) async throws {
        if accessibility {
            try await withAccessibilityAutomation { try await swipeAndPress(direction) }
        } else {
            try await swipeAndPress(direction)
        }
    }

    /// VoiceOver's three-finger swipe and other system scrolls move the pager without a drag.
    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func theStepFollowsAScrollThatIsNotADrag(direction: LayoutDirection) async throws {
        try await withAccessibilityAutomation {
            let pager = Pager()
            let (window, scrollView) = try await host(Host(pager: pager), direction)
            defer { window.isHidden = true }

            let pageTwo = direction == .rightToLeft ? 0 : 2 * scrollView.bounds.width
            scrollView.setContentOffset(CGPoint(x: pageTwo, y: 0), animated: true)
            try await waitUntil { pager.index == 2 }
        }
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft], [false, true])
    func theLockHoldsTheWhatsNewPager(direction: LayoutDirection, locksForward: Bool) async throws {
        let (window, scrollView) = try await host(Host(pager: Pager(), locksForward: locksForward), direction)
        defer { window.isHidden = true }

        try await waitUntil {
            window.descendants(ofType: ForwardPagingLock.LockView.self).first?.attachedPager != nil
        }
        let lock = try #require(window.descendants(ofType: ForwardPagingLock.LockView.self).first)
        #expect(lock.attachedPager === scrollView)
        #expect(lock.isLocked == locksForward)
        let layout: UIUserInterfaceLayoutDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        #expect(scrollView.effectiveUserInterfaceLayoutDirection == layout)
    }

    @Test func onlyACustomPageWithoutNextLocksTheForwardSwipe() {
        #expect(WhatsNewPage.custom(id: "no-next", showsNextButton: false) { _ in EmptyView() }.locksForwardSwipe)
        #expect(!WhatsNewPage.custom(id: "next") { _ in EmptyView() }.locksForwardSwipe)
        #expect(!WhatsNewPage.schoolMail.locksForwardSwipe)
        #expect(!WhatsNewPage.mailInBottomBar.locksForwardSwipe)
    }

    /// A finger's drag reaches the scroll view as a frame-by-frame offset between the delegate
    /// calls that begin and end it.
    private func swipeAndPress(_ direction: LayoutDirection) async throws {
        let pager = Pager()
        let (window, scrollView) = try await host(Host(pager: pager), direction)
        defer { window.isHidden = true }

        let delegate = try #require(scrollView.delegate)
        let offset = { (page: Double) in
            CGPoint(x: (direction == .rightToLeft ? 2 - page : page) * scrollView.bounds.width, y: 0)
        }
        var page = 0.0
        func drag(to end: Double) async throws {
            while abs(end - page) > 0.001 {
                page += max(-0.1, min(0.1, end - page))
                scrollView.setContentOffset(offset(page), animated: false)
                try await Task.sleep(for: .milliseconds(16))
            }
        }

        delegate.scrollViewWillBeginDragging?(scrollView)
        try await drag(to: 0.6)
        try await waitUntil { pager.index == 1 }
        let towardNext = try #require(pager.pageMinX[1]) - (try #require(pager.pageMinX[0]))
        #expect(direction == .rightToLeft ? towardNext < 0 : towardNext > 0)
        try await drag(to: 0.4)
        try await waitUntil { pager.index == 0 }
        try await drag(to: 1)
        try await waitUntil { pager.index == 1 }
        var target = offset(1)
        delegate.scrollViewWillEndDragging?(scrollView, withVelocity: .zero, targetContentOffset: &target)
        delegate.scrollViewDidEndDragging?(scrollView, willDecelerate: false)

        pager.position.scrollTo(id: 0)
        try await waitUntil { abs(scrollView.contentOffset.x - offset(0).x) < 0.5 && pager.index == 0 }
        pager.position.scrollTo(id: 2)
        try await waitUntil { abs(scrollView.contentOffset.x - offset(2).x) < 0.5 && pager.index == 2 }
    }

    /// Without a scene the host builds no `UIScrollView`.
    private func host(_ host: Host, _ direction: LayoutDirection) async throws -> (UIWindow, UIScrollView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: host.environment(\.layoutDirection, direction))
        window.isHidden = false
        try await waitUntil { !window.descendants(ofType: UIScrollView.self).isEmpty }
        return (window, try #require(window.descendants(ofType: UIScrollView.self).first))
    }
}
#endif
