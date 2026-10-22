#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct PullToRevealSearchTests {
    final class Flag {
        var isRevealed = false
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
        try await waitUntil { host.view.descendants(ofType: UIScrollView.self).first.map { $0.contentSize.height > $0.bounds.height } ?? false }
        let scrollView = try #require(host.view.descendants(ofType: UIScrollView.self).first)
        let top = -scrollView.adjustedContentInset.top
        #expect(!flag.isRevealed, "hidden at rest")

        scrollView.contentOffset.y = top - 60
        try await waitUntil { flag.isRevealed }
        #expect(flag.isRevealed, "a pull past the top reveals it")

        scrollView.contentOffset.y = top + 200
        try await waitUntil { flag.reportedOffset > 100 && flag.isRevealed == isActive }
        #expect(flag.isRevealed == isActive, "a scroll folds it, unless the search is active")

        window.isHidden = true
    }
}
#endif
