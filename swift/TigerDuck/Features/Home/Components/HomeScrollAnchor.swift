import SwiftUI

/// The Home section the reader has scrolled to. Browsing and editing are two scroll views, so the
/// page that opens scrolls to this section instead of starting at the top. A plain class, so the
/// per-frame geometry it records does not redraw Home.
final class HomeScrollAnchor {
    fileprivate var sectionTops: [String: CGFloat] = [:]
    fileprivate var visibleTop: CGFloat = 0

    /// The last section, in page order, whose top has reached the top of the visible area; nil
    /// while the page shows its start. Home's List rows start a row inset above their content,
    /// so a section the List scrolled to sits that far down and still counts.
    func section(in order: [String]) -> String? {
        let line = visibleTop + TigerDuckTheme.Spacing.lg + 1
        return order.last { sectionTops[$0].map { $0 <= line } ?? false }
    }

    /// Rows of the page that closed keep their last tops, which would mislead the next reading.
    func reset() {
        sectionTops = [:]
    }
}

extension View {
    /// Marks the first row of a section, for `HomeScrollAnchor` and `ScrollViewReader.scrollTo`.
    func homeScrollAnchor(_ sectionID: String, in anchor: HomeScrollAnchor) -> some View {
        id(sectionID)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                anchor.sectionTops[sectionID] = $0
            }
    }

    /// Goes on the page's scroll view. A List reaches under the bars and a ScrollView may not, and
    /// their `.scrollView` spaces differ too, so the window's coordinates keep the pages comparable.
    func homeScrollTop(in anchor: HomeScrollAnchor) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
            anchor.visibleTop = $0
        }
    }
}
