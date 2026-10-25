#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct HomeEditPageTests {
    static func section(_ type: HomeSection.HomeSectionType, widgets: [WidgetItem] = []) -> HomeSection {
        HomeSection(id: type.rawValue, type: type, title: type.defaultTitle, sortOrder: 0, isVisible: true, widgets: widgets)
    }

    /// The time machine's slider and course cards used to take touches while Home was arranged.
    @Test func onlyTheEditControlsRespond() async throws {
        try await withAccessibilityAutomation {
            let viewModel = HomeViewModel()
            viewModel.sections = [
                Self.section(.todayCourses),
                Self.section(.upcomingAssignments),
                Self.section(.quickWidgets, widgets: [WidgetItem(id: "w", feature: .library, size: .small)]),
            ]
            let page = HomeEditPage(viewModel: viewModel, sections: viewModel.sections, scrollAnchor: HomeScrollAnchor()) {
                EmptyView()
            }
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: page)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            let title = HomeSection.HomeSectionType.todayCourses.defaultTitle
            try await waitUntil { accessibilityElement(labeled: title, in: host.view) != nil }
            // The tree lists some elements twice, so they are told apart by where they are.
            let buttonFrames = {
                Set(exposedAccessibilityElements(in: host.view)
                    .filter { $0.accessibilityTraits.contains(.button) }
                    .map { NSCoder.string(for: $0.accessibilityFrame) })
            }
            try await waitUntil(timeout: .seconds(10)) { buttonFrames().count >= 4 }
            try await Task.sleep(for: .milliseconds(300))
            #expect(!exposedAccessibilityElements(in: host.view).contains { $0.accessibilityTraits.contains(.adjustable) })
            // A remove button for each of the three sections and for the one widget.
            #expect(buttonFrames().count == 4)
        }
    }
}
#endif
