#if os(iOS)
import SwiftUI
import UIKit

struct MailSourceTextView: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .caption1
    var color: Color = .textPrimary

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
        if context.coordinator.appliedText != text {
            context.coordinator.appliedText = text
            view.text = text
        }
        view.font = Self.monospacedFont(for: textStyle)
        view.textColor = UIColor(color)
    }

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

    private static func monospacedFont(for textStyle: UIFont.TextStyle) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: textStyle)
        guard let descriptor = base.fontDescriptor.withDesign(.monospaced) else { return base }
        return UIFont(descriptor: descriptor, size: descriptor.pointSize)
    }
}
#endif
