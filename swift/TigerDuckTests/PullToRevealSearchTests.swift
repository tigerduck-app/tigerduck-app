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
    }

    @Test(arguments: [false, true])
    func aPullRevealsAndAScrollFoldsUnlessTheSearchIsActive(isActive: Bool) async throws {
        let flag = Flag()
        let list = List(0..<80, id: \.self) { Text(verbatim: "row \($0)") }
            .pullToRevealSearch(
                isRevealed: Binding(get: { flag.isRevealed }, set: { flag.isRevealed = $0 }),
                isActive: isActive
            )
        let host = UIHostingController(rootView: list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let scrollView = try #require(Self.descendants(of: host.view).compactMap { $0 as? UIScrollView }.first)
        let top = -scrollView.adjustedContentInset.top
        #expect(!flag.isRevealed, "hidden at rest")

        scrollView.contentOffset.y = top - 60
        try await Task.sleep(for: .milliseconds(100))
        #expect(flag.isRevealed, "a pull past the top reveals it")

        scrollView.contentOffset.y = top + 200
        try await Task.sleep(for: .milliseconds(100))
        #expect(flag.isRevealed == isActive, "a scroll folds it, unless the search is active")

        window.isHidden = true
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
#endif
