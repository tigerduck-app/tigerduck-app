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
            // The tree lists some elements twice, so a set tells them apart.
            let buttons = {
                Set(exposedAccessibilityElements(in: host.view)
                    .filter { $0.accessibilityTraits.contains(.button) }
                    .map { "\($0.accessibilityLabel ?? ""): \($0.accessibilityValue ?? "")" })
            }
            try await waitUntil(timeout: .seconds(10)) { buttons().count >= 4 }
            try await Task.sleep(for: .milliseconds(300))
            #expect(!exposedAccessibilityElements(in: host.view).contains { $0.accessibilityTraits.contains(.adjustable) })
            // Only the remove buttons of the three sections and the one widget, each naming what it removes.
            let remove = String(localized: "action_remove")
            #expect(buttons() == Set(
                viewModel.sections.map(\.title).map { "\(remove): \($0)" } + ["\(remove): \(AppFeature.library.displayName)"]
            ))
        }
    }
}
#endif
