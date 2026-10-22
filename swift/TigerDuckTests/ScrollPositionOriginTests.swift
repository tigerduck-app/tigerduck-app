import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct ScrollPositionOriginTests {
    struct Reading: Equatable {
        var offset: CGFloat
        var topInset: CGFloat
    }

    @Observable final class Scroll {
        var position = ScrollPosition(edge: .top)
        var reading: Reading?
    }

    struct Scroller: View {
        @Bindable var scroll: Scroll

        var body: some View {
            ScrollView { Color.clear.frame(height: 3000) }
                .scrollPosition($scroll.position)
                .onScrollGeometryChange(for: Reading.self) {
                    Reading(offset: $0.contentOffset.y, topInset: $0.contentInsets.top)
                } action: { _, reading in
                    scroll.reading = reading
                }
        }
    }

    @Test func scrollToCountsFromTheTopInset() async throws {
        let scroll = Scroll()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Scroller(scroll: scroll))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        try await waitUntil { (scroll.reading?.topInset ?? 0) > 0 }

        scroll.position.scrollTo(y: 400)
        try await waitUntil { scroll.reading.map { abs($0.offset + $0.topInset - 400) < 0.5 } ?? false }
    }
}
