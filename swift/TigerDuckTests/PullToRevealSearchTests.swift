#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// `pullToRevealSearch` hangs off a list's real scroll geometry, so it is driven here through the
/// scroll view of a real `List` in a window: a pull past the top reveals the field, and a scroll
/// down folds it again unless a search is active.
@MainActor
struct PullToRevealSearchTests {
    final class Flag {
        var isRevealed = false
        /// How far the list sits below its top, as its last scroll geometry change reported.
        var reportedOffset: CGFloat = 0
    }

    @Test(arguments: [false, true])
    func aPullRevealsAndAScrollFoldsUnlessTheSearchIsActive(isActive: Bool) async throws {
        let flag = Flag()
        let list = List(0..<80, id: \.self) { Text(verbatim: "row \($0)") }
            .pullToRevealSearch(
                isRevealed: Binding(get: { flag.isRevealed }, set: { flag.isRevealed = $0 }),
                isActive: isActive
            )
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                flag.reportedOffset = offset
            }
        let host = UIHostingController(rootView: list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        // The rows may be laid out after this pass, and the list's insets are final once they are.
        try await waitUntil { Self.scrollView(in: host.view).map { $0.contentSize.height > $0.bounds.height } ?? false }
        let scrollView = try #require(Self.scrollView(in: host.view))
        let top = -scrollView.adjustedContentInset.top
        #expect(!flag.isRevealed, "hidden at rest")

        scrollView.contentOffset.y = top - 60
        try await waitUntil { flag.isRevealed }
        #expect(flag.isRevealed, "a pull past the top reveals it")

        scrollView.contentOffset.y = top + 200
        // An active search changes nothing to wait on, so also wait for the list to report the scroll.
        try await waitUntil { flag.reportedOffset > 100 && flag.isRevealed == isActive }
        #expect(flag.isRevealed == isActive, "a scroll folds it, unless the search is active")

        window.isHidden = true
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        descendants(of: view).compactMap { $0 as? UIScrollView }.first
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
#endif
