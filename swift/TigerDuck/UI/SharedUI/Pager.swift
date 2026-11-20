import SwiftUI

/// `settledPage` is the page the pager rests on, or the one `go(to:)` sends it to.
struct PagerPosition {
    var scroll = ScrollPosition(idType: Int.self)
    var settledPage = 0

    mutating func go(to step: Int) {
        settledPage = step
        scroll.scrollTo(id: step)
    }
}

struct Pager<Page: View>: View {
    let count: Int
    @Binding var index: Int
    @Binding var position: PagerPosition
    let lockedPages: Set<Int>
    @ViewBuilder let page: (Int) -> Page

    private struct Spot: Equatable {
        let step: Int
        let restingPage: Int?
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { step in
                        Group {
                            if abs(step - index) <= 1 {
                                page(step)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
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
        }
    }

    /// VoiceOver's three-finger swipe moves the pager without the pan gesture that
    /// `ForwardPagingLock` watches, so a scroll past a locked page is sent back to it.
    private func follow(_ spot: Spot) {
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
        guard width > 0 else { return Spot(step: 0, restingPage: nil) }
        let offset = geometry.visibleRect.minX
        let nearest = (offset / width).rounded()
        return Spot(
            step: Int((geometry.visibleRect.midX / width).rounded(.down)),
            restingPage: abs(offset - nearest * width) < 0.5 ? Int(nearest) : nil
        )
    }
}
