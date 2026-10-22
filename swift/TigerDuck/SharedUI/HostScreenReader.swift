#if os(iOS)
import SwiftUI
import UIKit

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
    func onHostScreenChange(_ action: @escaping (UIScreen?) -> Void) -> some View {
        background(HostScreenReader(onChange: action))
    }
}
#endif
