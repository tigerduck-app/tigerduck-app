#if os(iOS)
import SwiftUI
import UIKit

/// Reports the `UIScreen` hosting this view, and re-reports whenever the view
/// lands on a different one. `CapturedScreenReader` in `PasswordField` does the
/// same for `isCaptured`.
///
/// `UIScreen.main` is deprecated on iOS 16+, and on a foldable it keeps naming
/// the panel the window just left. The library QR pins its screen bright to stay
/// scannable, so the wrong panel leaves the code dim. A fold is just a screen
/// change to the app, so this needs no hinge API and works back to iOS 18.
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
        reportHostScreen()
    }

    /// `didMoveToWindow` alone misses the case this reader exists for.
    ///
    /// A fold, or a Stage Manager window dragged to another display, reassigns
    /// `UIWindowScene.screen` under an unchanged window, so no view is added or
    /// removed and `didMoveToWindow` never fires. The screen is re-read on layout
    /// too, which a geometry change always drives. `CapturedScreenReader` pairs
    /// the same callback with a notification observer for the same reason.
    override func layoutSubviews() {
        super.layoutSubviews()
        reportHostScreen()
    }

    private func reportHostScreen() {
        let screen = window?.windowScene?.screen ?? window?.screen
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
