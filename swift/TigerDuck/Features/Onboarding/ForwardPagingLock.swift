import SwiftUI

#if canImport(UIKit)
/// `scrollDisabled` does not reach the page-style `TabView`'s pager, hence the UIKit walk to
/// find it.
struct PagingScrollLock: UIViewRepresentable {
    let isLocked: Bool

    /// A page-style `TabView` reverses under a right-to-left language, so the
    /// same finger movement that advances in English goes back in Arabic.
    static func isForwardDrag(translationX: CGFloat, isRTL: Bool) -> Bool {
        isRTL ? translationX > 0 : translationX < 0
    }

    func makeUIView(context: Context) -> LockView {
        let view = LockView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: LockView, context: Context) {
        view.isLocked = isLocked
    }

    final class LockView: UIView {
        var isLocked = false

        private(set) weak var attachedPager: UIScrollView?
        private var hasJudgedDrag = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachToPager()
        }

        private func attachToPager() {
            guard attachedPager == nil else { return }
            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    attachedPager = scrollView
                    scrollView.panGestureRecognizer.addTarget(
                        self, action: #selector(pagerDidPan)
                    )
                    return
                }
                candidate = view.superview
            }
        }

        @objc private func pagerDidPan(_ recognizer: UIPanGestureRecognizer) {
            guard let pager = attachedPager else { return }
            guard recognizer.state == .changed else {
                hasJudgedDrag = false
                return
            }
            guard isLocked, !hasJudgedDrag else { return }

            let dx = recognizer.translation(in: pager).x
            guard abs(dx) > 4 else { return }
            hasJudgedDrag = true

            let isRTL = pager.effectiveUserInterfaceLayoutDirection == .rightToLeft
            guard PagingScrollLock.isForwardDrag(translationX: dx, isRTL: isRTL) else { return }

            // Turning scrolling off and straight back on cancels the pan in
            // flight; the pager snaps back to the page it started on.
            pager.isScrollEnabled = false
            pager.isScrollEnabled = true
        }
    }
}
#else
struct PagingScrollLock: View {
    let isLocked: Bool
    var body: some View { EmptyView() }
}
#endif
