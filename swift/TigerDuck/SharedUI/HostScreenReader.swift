#if os(iOS)
import SwiftUI
import UIKit

/// Reports the `UIScreen` currently hosting this view, and re-reports
/// whenever the view lands on a different one.
///
/// `UIScreen.main` is deprecated on iOS 16+ and on a foldable it is
/// actively wrong: folding the device moves the window from the inner
/// display to the outer one, so anything keyed on `.main` goes on
/// addressing a screen the user is no longer looking at. Brightness is the
/// sharp case — the library QR pins its screen bright to stay scannable,
/// and pinning the wrong panel leaves the code dim at the reader.
///
/// From the app's point of view a fold simply *is* the window changing
/// screens, so `didMoveToWindow` is the notification for it; no hinge API
/// is involved and this works back to iOS 18.
///
/// Mirrors `CapturedScreenReader` in `PasswordField`, which solves the same
/// problem for `isCaptured`.
struct HostScreenReader: UIViewRepresentable {
    let onChange: (UIScreen?) -> Void

    func makeUIView(context: Context) -> HostScreenReaderView {
        let view = HostScreenReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: HostScreenReaderView, context: Context) {
        uiView.onChange = onChange
    }
}

final class HostScreenReaderView: UIView {
    var onChange: ((UIScreen?) -> Void)?
    private weak var reportedScreen: UIScreen?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        // Carries no visual weight — shrink to zero rather than influencing
        // the layout of whatever it backs.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this view is created programmatically")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let screen = window?.screen
        guard screen !== reportedScreen else { return }
        reportedScreen = screen
        onChange?(screen)
    }
}

extension View {
    /// Observe the `UIScreen` hosting this view. Fires on attach and again
    /// whenever the view moves to a different screen — which, on a
    /// foldable, is what a fold looks like from here.
    func onHostScreenChange(_ action: @escaping (UIScreen?) -> Void) -> some View {
        background(HostScreenReader(onChange: action))
    }
}
#endif
