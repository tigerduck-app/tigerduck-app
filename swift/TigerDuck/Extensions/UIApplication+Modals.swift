#if canImport(UIKit)
import SwiftUI
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
    /// runs `then` with whether nothing is left up; SwiftUI clears each sheet's state and runs its
    /// `onDismiss` before that. An alert, which waits on a choice, a sheet that refuses the swipe,
    /// such as a mail draft, or one marked `keptOverReminders()` keeps the whole chain up, and
    /// `then(false)` runs at once.
    func closePresentations(then: @escaping (_ closedAll: Bool) -> Void) {
        var next = presentedViewController
        while let shown = next {
            guard !(shown is UIAlertController), !shown.isModalInPresentation, !shown.view.holdsReminderKeep
            else { return then(false) }
            next = shown.presentedViewController
        }
        guard presentedViewController != nil else { return then(true) }
        dismiss(animated: true) { then(true) }
    }
}

extension View {
    /// Keeps this sheet up when a reminder opens a page, though a swipe still closes it: What's
    /// New, which a close would mark as seen unread, and in-app forms a close would wipe
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/673).
    func keptOverReminders(_ kept: Bool = true) -> some View {
        background { if kept { ReminderKeep() } }
    }
}

/// The mark `closePresentations` finds among a sheet's views.
private struct ReminderKeep: UIViewRepresentable {
    final class Mark: UIView {}

    func makeUIView(context: Context) -> Mark { Mark() }
    func updateUIView(_ view: Mark, context: Context) {}
}

private extension UIView {
    var holdsReminderKeep: Bool { self is ReminderKeep.Mark || subviews.contains { $0.holdsReminderKeep } }
}
#endif
