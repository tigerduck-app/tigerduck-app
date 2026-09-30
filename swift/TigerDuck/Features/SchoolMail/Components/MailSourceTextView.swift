#if os(iOS)
import SwiftUI
import UIKit

/// Raw mail source, scrolled by `UITextView`.
///
/// SwiftUI's `Text` lays a string out eagerly and in full, on the main thread, with no
/// virtualization — and `.textSelection(.enabled)` on top of that costs more again. Raw
/// source is routinely hundreds of KB and occasionally megabytes, so the old
/// `ScrollView(.horizontal) { Text(source) }` froze the screen for as long as that layout
/// took. The horizontal scroll made it worse in two ways: the `Text` was handed an
/// unbounded width, so every line had to be measured whole and nothing ever wrapped, and
/// there was no vertical scrolling at all — one endless line, broken even for small mail.
///
/// `UITextView` is TextKit-backed and lays out only the visible viewport, which is the
/// standard iOS answer for a multi-megabyte document. It wraps and scrolls vertically, so
/// this matches what Android's message screen already does (chunked `items()` in a
/// `LazyColumn`) — the behaviour, not the mechanism.
///
/// Deliberate settings: `dataDetectorTypes = []` because link detection would walk the
/// whole string (undoing the virtualization, and raw source is full of URL-shaped text
/// nobody should be able to tap); `.byCharWrapping` because source is base64 runs and
/// header lines, not words; `isEditable = false` with `isSelectable = true` so Select and
/// Copy still work.
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
        // Assigning `text` re-runs TextKit's bookkeeping over the whole string, so a
        // multi-megabyte source is written once and not on every unrelated re-render
        // (a Dynamic Type change, a toolbar toggle). Comparing `view.text` instead
        // would itself be an O(n) copy-and-compare of that same string.
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
