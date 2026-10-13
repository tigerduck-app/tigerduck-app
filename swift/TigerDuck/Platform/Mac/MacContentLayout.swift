#if os(macOS)
import SwiftUI

/// Layout primitives shared by every Mac feature view.
///
/// Mac windows are resizable and often span the whole display. A view that only pads and
/// fills `maxWidth: .infinity` stretches lines too wide, and an inner `maxWidth:` cap alone
/// pins the content to the leading edge.
///
/// `.macReadableContent()` centres a column up to `maxWidth`, so a small window uses its full
/// width and a maximised one gets a reading column. Grids and calendars use a wider cap.
enum MacContentWidth {
    static let narrow: CGFloat = 720      // forms, settings tabs
    static let standard: CGFloat = 980    // home, bulletins, score
    static let wide: CGFloat = 1280       // class-table grid, calendar
    static let unbounded: CGFloat = .infinity
}

extension View {
    /// Centre this view inside its parent, capped at `maxWidth`, with a
    /// uniform `padding` on all sides. Pair with a parent `ScrollView`
    /// for the typical Mac feature layout.
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
