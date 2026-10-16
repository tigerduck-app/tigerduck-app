#if canImport(UIKit)
import UIKit

extension UIApplication {
    /// The foreground window's root, which every sheet, cover and alert is presented over. Sheets
    /// are not tracked centrally, so whether one is up is asked of UIKit's presentation chain. A
    /// notification tap can arrive while its scene is still becoming active.
    var foregroundRoot: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
        return (scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first)?.rootViewController
    }
}

extension UIViewController {
    /// Closes everything presented over this controller, as a swipe down closes a sheet, and then
    /// runs `then`; SwiftUI clears each sheet's state and runs its `onDismiss`. An alert, which
    /// waits on a choice, or a sheet that refuses the swipe, such as a mail draft, keeps the whole
    /// chain up, and `then` runs at once.
    func closePresentations(then: @escaping () -> Void) {
        var next = presentedViewController
        while let shown = next {
            guard !(shown is UIAlertController), !shown.isModalInPresentation else { return then() }
            next = shown.presentedViewController
        }
        guard presentedViewController != nil else { return then() }
        dismiss(animated: true, completion: then)
    }
}
#endif
