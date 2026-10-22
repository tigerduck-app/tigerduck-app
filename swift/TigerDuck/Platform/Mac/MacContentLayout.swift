#if os(macOS)
import SwiftUI

enum MacContentWidth {
    static let narrow: CGFloat = 720
    static let standard: CGFloat = 980
    static let wide: CGFloat = 1280
    static let unbounded: CGFloat = .infinity
}

extension View {
    func macReadableContent(
        maxWidth: CGFloat = MacContentWidth.standard,
        horizontalPadding: CGFloat = 28,
        verticalPadding: CGFloat = 28
    ) -> some View {
        self
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
    }
}
#endif
