#if canImport(UIKit)
import SwiftUI
import UIKit

struct JustifiedText: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .body
    var color: UIColor = .label

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ text: String, textStyle: UIFont.TextStyle = .body, color: UIColor = .label) {
        self.text = text
        self.textStyle = textStyle
        self.color = color
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .justified
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        _ = dynamicTypeSize
        label.text = text
        label.font = .preferredFont(forTextStyle: textStyle)
        label.textColor = color
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0 > 0 ? $0 : nil } ?? UIView.layoutFittingExpandedSize.width
        label.preferredMaxLayoutWidth = width
        let fitted = label.sizeThatFits(CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
        return CGSize(width: min(fitted.width, width), height: fitted.height)
    }
}
#endif
