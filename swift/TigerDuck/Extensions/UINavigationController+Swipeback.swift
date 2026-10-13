import UIKit

/// Re-enables the system swipe-from-left-edge pop gesture app-wide, even on views that use
/// `.navigationBarBackButtonHidden(true)`. `NavigationStack` is backed by `UINavigationController`,
/// whose own delegate refuses `interactivePopGestureRecognizer` while the back button is hidden.
/// That would leave `Features/Bulletins/Components/BulletinDetailView.swift` and every feature
/// page `MoreFeatureDestination` pushes (`Features/More/MoreView.swift`) with no way back. The
/// gesture is allowed whenever the stack has something to pop. Every `UINavigationController`
/// inherits this, so a flow that must not be swiped away, like a mid-submission form, must
/// re-tighten it with a per-VC subclass or a stored property `gestureRecognizerShouldBegin` reads.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
