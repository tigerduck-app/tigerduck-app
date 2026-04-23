import UIKit

/// Re-enable the iOS system swipe-from-left-edge pop gesture across the
/// whole app, even on views that use `.navigationBarBackButtonHidden(true)`.
///
/// Why: SwiftUI's `NavigationStack` is backed by `UINavigationController`
/// under the hood. UIKit automatically disables the
/// `interactivePopGestureRecognizer` whenever the back button is hidden
/// (its own delegate returns `false`). The bulletin detail page
/// deliberately hides the back chevron for full-screen reading, so
/// without this override users are stranded with no dismissal path.
///
/// What: replace the nav controller's gesture delegate with the
/// controller itself, and allow the gesture as long as the stack has
/// something to pop to (i.e. we're not on the root).
///
/// Scope caveat: this is a global UIKit extension, so every
/// `UINavigationController` the app instantiates inherits this
/// behaviour. TigerDuck currently has no flow that intentionally
/// suppresses swipe-back (like a mid-submission form that must not be
/// dismissed). If such a flow is ever added, that view's own delegate
/// will need to re-tighten the check — either per-VC subclass or a
/// stored property the `gestureRecognizerShouldBegin` implementation
/// below consults.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
