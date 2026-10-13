#if os(iOS)
import SwiftUI
import UIKit

/// Raw mail source, scrolled by `UITextView`: source is routinely hundreds of KB and sometimes
/// megabytes. SwiftUI's `Text` lays a string out eagerly and in full on the main thread, with no
/// virtualization (`.textSelection(.enabled)` costs more again), so it freezes the screen. In a
/// horizontal `ScrollView` it also measures every line whole and wraps nothing. TextKit lays out
/// only the visible viewport, and this view wraps and scrolls vertically like Android's message
/// screen. `dataDetectorTypes = []`: link detection would walk the whole string, and URL-shaped
/// text in source must not be tappable. `.byCharWrapping`: source is base64 runs and header
/// lines, not words. Not editable but selectable, so Select and Copy still work.
struct MailSourceTextView: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .caption1
    var color: Color = .textPrimary

    /// Read so a Dynamic Type change re-runs `updateUIView` and re-resolves the font.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.contentInsetAdjustmentBehavior = .never
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        _ = dynamicTypeSize
        // Assigning `text` re-runs TextKit's bookkeeping over the whole string, so the source is
        // written once, not on every unrelated re-render. Comparing against `view.text` would
        // itself be an O(n) copy-and-compare of that string.
        if context.coordinator.appliedText != text {
            context.coordinator.appliedText = text
            view.text = text
        }
        view.font = Self.monospacedFont(for: textStyle)
        view.textColor = UIColor(color)
    }

    /// Deliberately never `uiView.sizeThatFits` — which is what `UIViewRepresentable` would
    /// do by default, and which measures the *whole* document to answer. That is exactly the
    /// full layout this view exists to avoid, and it would put the freeze back by another
    /// route. The view is as flexible as SwiftUI asks it to be and scrolls inside whatever it
    /// is given; only an ideal-size probe (a `nil` dimension) gets a fixed answer.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        CGSize(width: Self.resolve(proposal.width), height: Self.resolve(proposal.height))
    }

    private static let idealSide: CGFloat = 240

    private static func resolve(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed else { return idealSide }
        return proposed.isFinite ? max(proposed, 0) : .infinity
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var appliedText: String?
    }

    /// The `UIFont` equivalent of `.font(.system(textStyle, design: .monospaced))`, kept
    /// scalable so `adjustsFontForContentSizeCategory` still tracks Dynamic Type.
    private static func monospacedFont(for textStyle: UIFont.TextStyle) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: textStyle)
        guard let descriptor = base.fontDescriptor.withDesign(.monospaced) else { return base }
        return UIFont(descriptor: descriptor, size: descriptor.pointSize)
    }
}
#endif
