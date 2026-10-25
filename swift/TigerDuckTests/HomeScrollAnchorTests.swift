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

    /// Sections of a header and a 300 pt row, or with `longFirst` a first section of 20 rows.
    struct Page: View {
        let usesList: Bool
        var longFirst = false
        var rowsReport = false
        let anchor: HomeScrollAnchor
        let probe: Probe

        @ViewBuilder
        private func rows(of id: String) -> some View {
            let count = longFirst && id == HomeScrollAnchorTests.ids[0] ? 20 : 1
            ForEach((0..<count).map { "\(id)-\($0)" }, id: \.self) { _ in
                Color.clear.frame(height: 300)
                    .homeScrollRow(id, in: rowsReport ? anchor : nil)
            }
        }

        var body: some View {
            NavigationStack {
                ScrollViewReader { proxy in
                    Group {
                        if usesList {
                            List {
                                Color.clear.frame(height: 60)
                                ForEach(HomeScrollAnchorTests.ids, id: \.self) { id in
                                    Text(id).homeScrollAnchor(id, in: anchor)
                                    rows(of: id)
                                }
                            }
                        } else {
                            ScrollView {
                                VStack {
                                    Color.clear.frame(height: 60)
                                    ForEach(HomeScrollAnchorTests.ids, id: \.self) { id in
                                        Text(id).homeScrollAnchor(id, in: anchor)
                                        rows(of: id)
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

    private func show(_ page: Page) async throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: page)
        window.makeKeyAndVisible()
        try await waitUntil { page.probe.isShown }
        try await Task.sleep(for: .milliseconds(300))
        return window
    }

    @Test(arguments: [true, false])
    func theSectionScrolledToIsTheAnchor(usesList: Bool) async throws {
        let anchor = HomeScrollAnchor()
        let probe = Probe()
        let window = try await show(Page(usesList: usesList, anchor: anchor, probe: probe))
        defer { window.isHidden = true }
        #expect(anchor.section(in: Self.ids) == nil)

        probe.target = Self.ids[4]
        try await waitUntil { anchor.section(in: Self.ids) == Self.ids[4] }
    }

    /// A recycled header row may never report where it went, so the List forgets it.
    @Test func aHeaderTheListRecycledNoLongerCounts() async throws {
        let anchor = HomeScrollAnchor()
        let probe = Probe()
        let window = try await show(Page(usesList: true, longFirst: true, anchor: anchor, probe: probe))
        defer { window.isHidden = true }

        probe.target = Self.ids[0]
        try await waitUntil { anchor.section(in: Self.ids) == Self.ids[0] }
        probe.target = "\(Self.ids[0])-15"
        try await Task.sleep(for: .milliseconds(800))
        #expect(anchor.section(in: Self.ids) == nil)
    }

    @Test func aLongSectionCountsByAnyOfItsRows() async throws {
        let anchor = HomeScrollAnchor()
        let probe = Probe()
        let window = try await show(Page(usesList: true, longFirst: true, rowsReport: true, anchor: anchor, probe: probe))
        defer { window.isHidden = true }

        probe.target = "\(Self.ids[0])-15"
        try await waitUntil(timeout: .seconds(10)) { anchor.section(in: Self.ids) == Self.ids[0] }
    }

    @Test func thePlaceIsTakenOnceAndOnlyForASectionStillThere() async throws {
        let anchor = HomeScrollAnchor()
        let probe = Probe()
        let window = try await show(Page(usesList: true, anchor: anchor, probe: probe))
        defer { window.isHidden = true }
        probe.target = Self.ids[4]
        try await waitUntil { anchor.section(in: Self.ids) == Self.ids[4] }

        anchor.keepPlace(in: Self.ids)
        #expect(anchor.takeTarget(in: Self.ids) == Self.ids[4])
        #expect(anchor.takeTarget(in: Self.ids) == nil)

        probe.target = Self.ids[5]
        try await waitUntil { anchor.section(in: Self.ids) == Self.ids[5] }
        anchor.keepPlace(in: Self.ids)
        #expect(anchor.takeTarget(in: Self.ids.filter { $0 != Self.ids[5] }) == nil)

        probe.target = Self.ids[6]
        try await waitUntil { anchor.section(in: Self.ids) == Self.ids[6] }
        anchor.forgetPlace()
        #expect(anchor.takeTarget(in: Self.ids) == nil)
    }
}
#endif
