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
        var position = WhatsNewPagerPosition()
        var farthest: CGFloat = 0
    }

    struct Host: View {
        @Bindable var pager: Pager
        var lockedPages: Set<Int> = []

        var body: some View {
            WhatsNewPager(count: 3, index: $pager.index, position: $pager.position, lockedPages: lockedPages) { _ in
                Color.clear
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.visibleRect.minX } action: { _, minX in
                pager.farthest = max(pager.farthest, minX)
            }
        }
    }

    /// A finger's drag reaches the scroll view as a frame-by-frame offset between the delegate
    /// calls that begin and end it.
    @MainActor final class Finger {
        let scrollView: UIScrollView
        private(set) var page: Double

        init(_ scrollView: UIScrollView, on page: Double = 0) {
            self.scrollView = scrollView
            self.page = page
        }

        func offset(_ page: Double) -> CGPoint {
            CGPoint(x: page * scrollView.bounds.width, y: 0)
        }

        func isResting(on page: Double) -> Bool {
            abs(scrollView.contentOffset.x - offset(page).x) < 0.5
        }

        func touchDown() {
            scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
        }

        func move(to end: Double) async throws {
            while abs(end - page) > 0.001 {
                page += max(-0.1, min(0.1, end - page))
                scrollView.setContentOffset(offset(page), animated: false)
                try await Task.sleep(for: .milliseconds(16))
            }
        }

        func lift() {
            var target = scrollView.contentOffset
            scrollView.delegate?.scrollViewWillEndDragging?(scrollView, withVelocity: .zero, targetContentOffset: &target)
            scrollView.delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: false)
        }
    }

    @Test(arguments: [false, true])
    func theStepFollowsTheSwipeAndTheButtons(accessibility: Bool) async throws {
        if accessibility {
            try await withAccessibilityAutomation { try await swipeAndPress() }
        } else {
            try await swipeAndPress()
        }
    }

    /// VoiceOver's three-finger swipe and other system scrolls move the pager without a drag.
    @Test func theStepFollowsAScrollThatIsNotADrag() async throws {
        try await withAccessibilityAutomation {
            let pager = Pager()
            let (window, scrollView) = try await host(Host(pager: pager))
            defer { window.isHidden = true }

            scrollView.setContentOffset(CGPoint(x: 2 * scrollView.bounds.width, y: 0), animated: true)
            try await waitUntil { pager.index == 2 }
        }
    }

    @Test func aSwipeIntoALockedPageLandsThereAndGoesNoFurther() async throws {
        let pager = Pager()
        let (window, scrollView) = try await host(Host(pager: pager, lockedPages: [1]))
        defer { window.isHidden = true }
        let lock = try await forwardLock(in: window)
        let finger = Finger(scrollView)

        finger.touchDown()
        try await finger.move(to: 0.6)
        try await waitUntil { pager.index == 1 }
        try await finger.move(to: 0.9)
        #expect(!lock.isLocked, "a drag that started on an open page is not cut off")
        try await finger.move(to: 1)
        finger.lift()
        try await waitUntil { lock.isLocked }

        finger.touchDown()
        try await finger.move(to: 1.6)
        finger.lift()
        try await waitUntil { finger.isResting(on: 1) && pager.index == 1 }
    }

    @Test func aScrollThatIsNotADragStopsAtALockedPage() async throws {
        try await withAccessibilityAutomation {
            let pager = Pager()
            let (window, scrollView) = try await host(Host(pager: pager, lockedPages: [1]))
            defer { window.isHidden = true }
            let finger = Finger(scrollView)

            pager.position.go(to: 1)
            try await waitUntil { finger.isResting(on: 1) && pager.index == 1 }

            let width = scrollView.bounds.width
            scrollView.setContentOffset(finger.offset(2), animated: true)
            try await waitUntil { pager.farthest > 1.1 * width }
            try await waitUntil { finger.isResting(on: 1) && pager.index == 1 }

            pager.position.go(to: 2)
            try await waitUntil { finger.isResting(on: 2) && pager.index == 2 }
        }
    }

    @Test(arguments: [false, true])
    func theLockHoldsTheWhatsNewPager(locksForward: Bool) async throws {
        let (window, scrollView) = try await host(Host(pager: Pager(), lockedPages: locksForward ? [0] : []))
        defer { window.isHidden = true }

        let lock = try await forwardLock(in: window)
        #expect(lock.attachedPager === scrollView)
        #expect(lock.isLocked == locksForward)
    }

    @Test func onlyACustomPageWithoutNextLocksTheForwardSwipe() {
        #expect(WhatsNewPage.custom(id: "no-next", showsNextButton: false) { _ in EmptyView() }.locksForwardSwipe)
        #expect(!WhatsNewPage.custom(id: "next") { _ in EmptyView() }.locksForwardSwipe)
        #expect(!WhatsNewPage.schoolMail.locksForwardSwipe)
        #expect(!WhatsNewPage.mailInBottomBar.locksForwardSwipe)
    }

    private func swipeAndPress() async throws {
        let pager = Pager()
        let (window, scrollView) = try await host(Host(pager: pager))
        defer { window.isHidden = true }
        let finger = Finger(scrollView)

        finger.touchDown()
        try await finger.move(to: 0.6)
        try await waitUntil { pager.index == 1 }
        try await finger.move(to: 0.4)
        try await waitUntil { pager.index == 0 }
        try await finger.move(to: 1)
        try await waitUntil { pager.index == 1 }
        finger.lift()

        pager.position.go(to: 0)
        try await waitUntil { finger.isResting(on: 0) && pager.index == 0 }
        pager.position.go(to: 2)
        try await waitUntil { finger.isResting(on: 2) && pager.index == 2 }
    }

    private func forwardLock(in window: UIWindow) async throws -> ForwardPagingLock.LockView {
        try await waitUntil {
            window.descendants(ofType: ForwardPagingLock.LockView.self).first?.attachedPager != nil
        }
        return try #require(window.descendants(ofType: ForwardPagingLock.LockView.self).first)
    }

    /// Without a scene the host builds no `UIScrollView`.
    private func host(_ host: Host) async throws -> (UIWindow, UIScrollView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: host)
        window.isHidden = false
        try await waitUntil { !window.descendants(ofType: UIScrollView.self).isEmpty }
        return (window, try #require(window.descendants(ofType: UIScrollView.self).first))
    }
}
#endif
