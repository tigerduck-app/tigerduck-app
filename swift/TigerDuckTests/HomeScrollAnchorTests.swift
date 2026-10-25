#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// Home browses in a List and edits in a stack, and each opens at the section the other was
/// scrolled to; both kinds of scroll view have to report and reach that section the same way.
@MainActor
@Suite(.serialized)
struct HomeScrollAnchorTests {
    static let ids = (0..<8).map { "section-\($0)" }

    @Observable final class Probe {
        var target: String?
        var isShown = false
    }

    struct Page: View {
        let usesList: Bool
        let anchor: HomeScrollAnchor
        let probe: Probe

        var body: some View {
            NavigationStack {
                ScrollViewReader { proxy in
                    Group {
                        if usesList {
                            List {
                                Color.clear.frame(height: 60)
                                ForEach(HomeScrollAnchorTests.ids, id: \.self) { id in
                                    Text(id).homeScrollAnchor(id, in: anchor)
                                    Color.clear.frame(height: 300)
                                }
                            }
                        } else {
                            ScrollView {
                                VStack {
                                    Color.clear.frame(height: 60)
                                    ForEach(HomeScrollAnchorTests.ids, id: \.self) { id in
                                        Text(id).homeScrollAnchor(id, in: anchor)
                                        Color.clear.frame(height: 300)
                                    }
                                }
                            }
                        }
                    }
                    .homeScrollTop(in: anchor)
                    .navigationTitle("Home")
                    .onAppear { probe.isShown = true }
                    .onChange(of: probe.target) { _, target in
                        if let target { proxy.scrollTo(target, anchor: .top) }
                    }
                }
            }
        }
    }

    @Test(arguments: [true, false])
    func theSectionScrolledToIsTheAnchor(usesList: Bool) async throws {
        let anchor = HomeScrollAnchor()
        let probe = Probe()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Page(usesList: usesList, anchor: anchor, probe: probe))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await waitUntil { probe.isShown }
        try await Task.sleep(for: .milliseconds(300))
        #expect(anchor.section(in: Self.ids) == nil)

        probe.target = Self.ids[4]
        try await waitUntil { anchor.section(in: Self.ids) == Self.ids[4] }
    }
}
#endif
