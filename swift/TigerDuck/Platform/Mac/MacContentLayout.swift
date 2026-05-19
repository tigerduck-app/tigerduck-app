#if os(macOS)
import SwiftUI

/// Layout primitives shared by every Mac feature view.
///
/// Mac windows are resizable and routinely span the full display width,
/// so views that just `.padding()` and `.frame(maxWidth: .infinity)` end
/// up either stretching long lines uncomfortably wide or — when an
/// inner `maxWidth:` cap is applied — pinning content to the leading
/// edge (the original "squeezes to the left" complaint).
///
/// `.macReadableContent()` centres a column up to `maxWidth` so a small
/// window uses the full width while a maximised window gets a sensible
/// reading column flanked by background space. `kind` lets feature views
/// pick a wider cap when their content naturally needs more horizontal
/// room (grids, calendars).
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
