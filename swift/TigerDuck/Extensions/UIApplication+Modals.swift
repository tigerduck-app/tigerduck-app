#if canImport(UIKit)
import SwiftUI
import UIKit

extension UIApplication {
    var foregroundRoot: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
        return (scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first)?.rootViewController
    }
}

extension UIViewController {
    func closePresentations(then: @escaping (_ closedAll: Bool) -> Void) {
        var next = presentedViewController
        while let shown = next {
            guard !(shown is UIAlertController), !shown.isModalInPresentation,
                  shown.viewIfLoaded?.holdsReminderKeep != true
            else { return then(false) }
            next = shown.presentedViewController
        }
        guard presentedViewController != nil else { return then(true) }
        dismiss(animated: true) { then(true) }
    }
}

extension View {
    func keptOverReminders(_ kept: Bool = true) -> some View {
        background { if kept { ReminderKeep() } }
    }
}

private struct ReminderKeep: UIViewRepresentable {
    final class Mark: UIView {}

    func makeUIView(context: Context) -> Mark {
        let mark = Mark()
        mark.isUserInteractionEnabled = false
        return mark
    }
    func updateUIView(_ view: Mark, context: Context) {}
}

private extension UIView {
    var holdsReminderKeep: Bool { self is ReminderKeep.Mark || subviews.contains { $0.holdsReminderKeep } }
}
#endif
