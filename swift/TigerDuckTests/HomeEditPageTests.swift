#if os(iOS)
import Defaults
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

    /// The time machine's slider and course cards must not take touches while Home is arranged.
    @Test func onlyTheEditControlsRespond() async throws {
        try await withAccessibilityAutomation {
            let viewModel = HomeViewModel()
            viewModel.layout.sections = [
                Self.section(.todayCourses),
                Self.section(.upcomingAssignments),
                Self.section(.quickWidgets, widgets: [WidgetItem(id: "w", feature: .library, size: .small)]),
            ]
            let page = HomeEditPage(viewModel: viewModel, sections: viewModel.layout.sections, scrollAnchor: HomeScrollAnchor()) {
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
                viewModel.layout.sections.map(\.title).map { "\(remove): \($0)" } + ["\(remove): \(AppFeature.library.displayName)"]
            ))
        }
    }

    @Test func eachQuickFunctionMovesUpAndDownAsADragOntoItsNeighbourDoes() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.homeSectionLayoutData]
            defer { Defaults[.homeSectionLayoutData] = saved }
            try await withAccessibilityAutomation {
                let features: [AppFeature] = [.library, .calendar, .gpa]
                let viewModel = HomeViewModel()
                viewModel.layout.sections = [
                    Self.section(.quickWidgets, widgets: features.map { WidgetItem(id: $0.rawValue, feature: $0, size: .small) }),
                ]
                let (window, host) = try Self.show(viewModel)
                defer { window.isHidden = true }
                let card = { (feature: AppFeature) in Self.element(labeled: feature.displayName, in: host.view) }
                let ids = { viewModel.layout.sections[0].widgets.map(\.id) }

                try await waitUntil { card(.library) != nil }
                try await waitUntil(timeout: .seconds(10)) { Self.moveActions(of: card(.library)) == [Self.moveDown] }
                #expect(Self.moveActions(of: card(.library)) == [Self.moveDown])
                #expect(Self.moveActions(of: card(.calendar)) == [Self.moveUp, Self.moveDown])
                #expect(Self.moveActions(of: card(.gpa)) == [Self.moveUp])

                var expected = try Self.dragged(ids(), "calendar", onto: "library")
                try Self.perform(Self.moveUp, on: card(.calendar))
                #expect(ids() == ["calendar", "library", "gpa"])
                #expect(ids() == expected)
                #expect(Self.savedLayout()?.first?.widgets.map(\.id) == expected)

                try await waitUntil { Self.moveActions(of: card(.library)) == [Self.moveUp, Self.moveDown] }
                expected = try Self.dragged(ids(), "library", onto: "gpa")
                try Self.perform(Self.moveDown, on: card(.library))
                #expect(ids() == ["calendar", "gpa", "library"])
                #expect(ids() == expected)
                #expect(Self.savedLayout()?.first?.widgets.map(\.id) == expected)
            }
        }
    }

    @Test func eachSectionMovesUpAndDownAmongTheSectionsShown() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.homeSectionLayoutData]
            defer { Defaults[.homeSectionLayoutData] = saved }
            try await withAccessibilityAutomation {
                let viewModel = HomeViewModel()
                viewModel.layout.sections = [
                    Self.section(.todayCourses),
                    Self.section(.upcomingAssignments),
                    Self.section(.quickWidgets),
                    Self.section(.custom),
                ]
                let (window, host) = try Self.show(viewModel, hiding: .todayCourses)
                defer { window.isHidden = true }
                let handle = { (type: HomeSection.HomeSectionType) in
                    Self.element(labeled: String(localized: "home_section_drag_hint"), value: type.defaultTitle, in: host.view)
                }
                let ids = { viewModel.layout.sections.map(\.id) }

                try await waitUntil { accessibilityElement(labeled: HomeSection.HomeSectionType.custom.defaultTitle, in: host.view) != nil }
                try await waitUntil(timeout: .seconds(10)) { Self.moveActions(of: handle(.upcomingAssignments)) == [Self.moveDown] }
                #expect(Self.moveActions(of: handle(.upcomingAssignments)) == [Self.moveDown])
                #expect(Self.moveActions(of: handle(.quickWidgets)) == [Self.moveUp, Self.moveDown])
                #expect(Self.moveActions(of: handle(.custom)) == [Self.moveUp])

                let expected = try Self.dragged(ids(), "quickWidgets", onto: "upcomingAssignments")
                try Self.perform(Self.moveUp, on: handle(.quickWidgets))
                #expect(ids() == ["todayCourses", "quickWidgets", "upcomingAssignments", "custom"])
                #expect(ids() == expected)
                #expect(Self.savedLayout()?.map(\.id) == expected)
            }
        }
    }

    static let moveUp = String(localized: "a11y_home_edit_move_up")
    static let moveDown = String(localized: "a11y_home_edit_move_down")

    static func show(
        _ viewModel: HomeViewModel,
        hiding hidden: HomeSection.HomeSectionType? = nil
    ) throws -> (UIWindow, UIHostingController<EditingHome>) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: EditingHome(viewModel: viewModel, hidden: hidden))
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (window, host)
    }

    /// The tree lists some elements twice.
    static func element(labeled label: String, value: String? = nil, in view: UIView) -> NSObject? {
        let matches = exposedAccessibilityElements(in: view).filter {
            $0.accessibilityLabel == label && (value == nil || $0.accessibilityValue == value)
        }
        return matches.first { !($0.accessibilityCustomActions ?? []).isEmpty } ?? matches.first
    }

    static func moveActions(of element: NSObject?) -> [String] {
        (element?.accessibilityCustomActions ?? []).map(\.name).filter { [moveUp, moveDown].contains($0) }
    }

    static func perform(_ name: String, on element: NSObject?) throws {
        let action = try #require(element?.accessibilityCustomActions?.first { $0.name == name })
        if let handler = action.actionHandler {
            #expect(handler(action))
        } else {
            _ = (action.target as AnyObject?)?.perform(action.selector, with: action)
        }
    }

    static func dragged(_ ids: [String], _ id: String, onto target: String) throws -> [String] {
        let (offsets, destination) = try #require(ReorderDropSupport.moveDestination(in: ids, draggedID: id, targetID: target))
        var moved = ids
        moved.move(fromOffsets: offsets, toOffset: destination)
        return moved
    }

    static func savedLayout() -> [HomeSection]? {
        Defaults[.homeSectionLayoutData].flatMap { try? JSONDecoder().decode([HomeSection].self, from: $0) }
    }

    struct EditingHome: View {
        let viewModel: HomeViewModel
        let hidden: HomeSection.HomeSectionType?
        @State private var scrollAnchor = HomeScrollAnchor()

        var body: some View {
            HomeEditPage(
                viewModel: viewModel,
                sections: viewModel.layout.sections.filter { $0.type != hidden },
                scrollAnchor: scrollAnchor
            ) {
                EmptyView()
            }
        }
    }
}
#endif
