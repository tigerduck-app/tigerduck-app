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

/// The window a tab view is shown in. A link closes the sheets of the window that opens its page, as
/// with two iPad windows the first foreground one may be the other
/// (https://github.com/tigerduck-app/tigerduck-app/issues/676).
final class HostWindow {
    weak var window: UIWindow?

    func closePresentations(then: @escaping (_ closedAll: Bool) -> Void) {
        guard let root = window?.rootViewController ?? UIApplication.shared.foregroundRoot else { return then(true) }
        root.closePresentations(then: then)
    }
}

extension EnvironmentValues {
    @Entry var hostWindow = HostWindow()
}

extension View {
    func readsHostWindow(into host: HostWindow) -> some View {
        background(HostWindowReader(host: host))
    }

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

private struct HostWindowReader: UIViewRepresentable {
    let host: HostWindow

    final class Probe: UIView {
        let host: HostWindow

        init(host: HostWindow) {
            self.host = host
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used; this view is created programmatically") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            host.window = window
        }
    }

    func makeUIView(context: Context) -> Probe { Probe(host: host) }
    func updateUIView(_ view: Probe, context: Context) {}
}

private extension UIView {
    var holdsReminderKeep: Bool { self is ReminderKeep.Mark || subviews.contains { $0.holdsReminderKeep } }
}
#endif
