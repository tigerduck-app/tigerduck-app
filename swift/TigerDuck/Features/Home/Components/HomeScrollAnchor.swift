import SwiftUI

/// The Home section the reader has scrolled to. Browsing and editing are two scroll views, so the
/// page that opens scrolls to this section instead of starting at the top. A plain class, so the
/// per-frame geometry it records does not redraw Home.
final class HomeScrollAnchor {
    /// The tops of the rows on screen, by section. A row the List recycled may never report its
    /// last position, so it is dropped when it goes, and a long section counts by any row left.
    private var rowTops: [String: [ObjectIdentifier: CGFloat]] = [:]
    fileprivate var visibleTop: CGFloat = 0
    private var target: String?

    /// The last section, in page order, whose top has reached the top of the visible area; nil
    /// while the page shows its start. Home's List rows start a row inset above their content,
    /// so a section the List scrolled to sits that far down and still counts.
    func section(in order: [String]) -> String? {
        let line = visibleTop + TigerDuckTheme.Spacing.lg + 1
        return order.last { rowTops[$0]?.values.min().map { $0 <= line } ?? false }
    }

    /// Remembers the section shown for the page about to open; the closing page's rows go.
    func keepPlace(in order: [String]) {
        target = section(in: order)
        rowTops = [:]
    }

    /// For a page that is not about to show, which opens at the top.
    func forgetPlace() {
        target = nil
        rowTops = [:]
    }

    /// The section to scroll to, once, if the page still has it; otherwise the page stays at its top.
    func takeTarget(in order: [String]) -> String? {
        defer { target = nil }
        return target.flatMap { order.contains($0) ? $0 : nil }
    }

    fileprivate func record(_ top: CGFloat?, section: String, row: ObjectIdentifier) {
        rowTops[section, default: [:]][row] = top
    }
}

extension View {
    // In a List row both markers go before `homeListRow`. Row settings applied inside them no
    // longer reach the List, which then draws its default insets, background and separators.

    /// Marks the first row of a section, for `HomeScrollAnchor` and `ScrollViewReader.scrollTo`.
    func homeScrollAnchor(_ sectionID: String, in anchor: HomeScrollAnchor) -> some View {
        id(sectionID).homeScrollRow(sectionID, in: anchor)
    }

    /// Marks a later row of a section that spans several List rows.
    func homeScrollRow(_ sectionID: String, in anchor: HomeScrollAnchor?) -> some View {
        modifier(SectionRowTop(sectionID: sectionID, anchor: anchor))
    }

    /// Goes on the page's scroll view. A List reaches under the bars and a ScrollView may not, and
    /// their `.scrollView` spaces differ too, so the window's coordinates keep the pages comparable.
    func homeScrollTop(in anchor: HomeScrollAnchor) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
            anchor.visibleTop = $0
        }
    }
}

private struct SectionRowTop: ViewModifier {
    /// A row's own key and last top. A List row can go and come back where it was, which reports
    /// no new geometry, so it puts its last top back. A class, so a new top does not redraw.
    final class Row {
        var top: CGFloat?
    }

    let sectionID: String
    let anchor: HomeScrollAnchor?
    @State private var row = Row()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                row.top = $0
                anchor?.record($0, section: sectionID, row: ObjectIdentifier(row))
            }
            .onAppear { anchor?.record(row.top, section: sectionID, row: ObjectIdentifier(row)) }
            .onDisappear { anchor?.record(nil, section: sectionID, row: ObjectIdentifier(row)) }
    }
}
