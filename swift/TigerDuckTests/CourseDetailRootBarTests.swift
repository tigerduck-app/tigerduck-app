#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// A Moodle screen pushed in the course detail sheet keeps its bar where it lands. With the root's
/// bar hidden, the pushed bar sat at the sheet's top edge until the push ended, then dropped 16 pt
/// below the grabber with everything under it.
@MainActor
struct CourseDetailRootBarTests {
    @Observable
    final class Probe {
        var path: [Int] = []
        var detent: PresentationDetent = .medium
        var isShown = false
        var pushedTops: [CGFloat] = []
    }

    /// The course detail's navigation as `CourseDetailSheet` builds it.
    struct Detail: View {
        @Bindable var probe: Probe

        var body: some View {
            NavigationStack(path: $probe.path) {
                ScrollView {
                    Text("Course").onAppear { probe.isShown = true }
                }
                .courseDetailRootBar()
                .navigationDestination(for: Int.self) { _ in
                    List { Text("Announcement") }
                        .background {
                            Color.clear.onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { _, top in
                                if top > 0 { probe.pushedTops.append(top) }
                            }
                        }
                        .moodleListChrome(title: "Announcements", page: nil, refresh: {})
                }
            }
            .presentationDetents([.medium, .large], selection: $probe.detent)
            .onChange(of: probe.path) { _, path in
                if !path.isEmpty { probe.detent = .large }
            }
        }
    }

    @Test func aPushedScreenKeepsItsBarWhereItLands() async throws {
        let probe = Probe()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(
            rootView: Color.clear.sheet(isPresented: .constant(true)) { Detail(probe: probe) }
        )
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        try await waitUntil { probe.isShown }
        try await Task.sleep(for: .milliseconds(600))

        probe.path.append(1)
        try await waitUntil { !probe.pushedTops.isEmpty }
        // Past the end of the push, when the bar used to drop.
        try await Task.sleep(for: .seconds(1))
        #expect(Set(probe.pushedTops).count == 1, "the pushed screen's top inset went \(probe.pushedTops)")
    }
}
#endif
