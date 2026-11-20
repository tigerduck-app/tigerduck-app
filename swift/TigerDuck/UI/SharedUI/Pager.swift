import SwiftUI

/// `settledPage` is the page the pager rests on, or the one `go(to:)` sends it to.
struct PagerPosition {
    var scroll: ScrollPosition
    var settledPage: Int
    var visiblePages: ClosedRange<Int>

    init(page: Int = 0) {
        scroll = ScrollPosition(idType: Int.self)
        settledPage = page
        visiblePages = page...page
    }

    mutating func go(to page: Int) {
        settledPage = page
        scroll.scrollTo(id: page)
    }
}

/// Builds only the pages beside `index` and the settled one, so a jump lands on a built page.
struct Pager<Page: View>: View {
    let count: Int
    @Binding var index: Int
    @Binding var position: PagerPosition
    var lockedPages: Set<Int> = []
    @ViewBuilder let page: (Int) -> Page

    @Environment(\.displayScale) private var displayScale

    private struct Spot: Equatable {
        let step: Int
        let restingPage: Int?
        let visiblePages: ClosedRange<Int>
    }

    var body: some View {
        GeometryReader { proxy in
            // UIKit lays the scroll view out in whole pixels, and pages of any other width drift off
            // its paging.
            let width = (proxy.size.width * displayScale).rounded() / displayScale
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { step in
                        Group {
                            if abs(step - index) <= 1 || step == position.settledPage {
                                page(step)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: width, height: proxy.size.height)
                        .accessibilityHidden(step != index)
                    }
                }
                .scrollTargetLayout()
                .background(ForwardPagingLock(isLocked: lockedPages.contains(position.settledPage)))
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition($position.scroll)
            // The scroll position's view identity follows only a drag, not VoiceOver's
            // three-finger swipe; the visible rect follows every scroll.
            .onScrollGeometryChange(for: Spot.self, of: Self.spot(in:)) { _, spot in
                follow(spot)
            }
            .scrollIndicators(.hidden)
            // A lazy stack scrolled to a far page on appear passes the first page on its way there.
            .defaultScrollAnchor(UnitPoint(x: Double(position.settledPage) / Double(max(count - 1, 1)), y: 0), for: .initialOffset)
        }
    }

    /// VoiceOver's three-finger swipe moves the pager without the pan gesture that
    /// `ForwardPagingLock` watches, so a scroll past a locked page is sent back to it.
    private func follow(_ spot: Spot) {
        guard count > 0 else { return }
        position.visiblePages = spot.visiblePages.clamped(to: 0...(count - 1))
        let settled = position.settledPage
        let step = min(max(spot.step, 0), count - 1)
        if lockedPages.contains(settled), step > settled {
            index = settled
            position.scroll.scrollTo(id: settled)
            return
        }
        index = step
        if let page = spot.restingPage, page != settled {
            position.settledPage = page
        }
    }

    private static func spot(in geometry: ScrollGeometry) -> Spot {
        let width = geometry.containerSize.width
        guard width > 0 else { return Spot(step: 0, restingPage: nil, visiblePages: 0...0) }
        let offset = geometry.visibleRect.minX
        let nearest = (offset / width).rounded()
        let tolerance = 0.5
        let first = Int(((offset + tolerance) / width).rounded(.down))
        let last = Int(((geometry.visibleRect.maxX - tolerance) / width).rounded(.down))
        return Spot(
            step: Int((geometry.visibleRect.midX / width).rounded(.down)),
            restingPage: abs(offset - nearest * width) < tolerance ? Int(nearest) : nil,
            visiblePages: first...max(first, last)
        )
    }
}
