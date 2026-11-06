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
                let calendarUp = try Self.action(Self.moveUp, of: card(.calendar))
                #expect(try Self.perform(calendarUp))
                #expect(ids() == ["calendar", "library", "gpa"])
                #expect(ids() == expected)
                #expect(Self.savedLayout()?.first?.widgets.map(\.id) == expected)
                try Self.perform(calendarUp)
                #expect(ids() == expected, "an action the card no longer offers moves nothing")

                try await waitUntil { Self.moveActions(of: card(.library)) == [Self.moveUp, Self.moveDown] }
                expected = try Self.dragged(ids(), "library", onto: "gpa")
                #expect(try Self.perform(Self.action(Self.moveDown, of: card(.library))))
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
                let handle = { (type: HomeSection.HomeSectionType) in Self.element(labeled: type.defaultTitle, in: host.view) }
                let ids = { viewModel.layout.sections.map(\.id) }

                try await waitUntil { accessibilityElement(labeled: HomeSection.HomeSectionType.custom.defaultTitle, in: host.view) != nil }
                try await waitUntil(timeout: .seconds(10)) { Self.moveActions(of: handle(.upcomingAssignments)) == [Self.moveDown] }
                #expect(Self.moveActions(of: handle(.upcomingAssignments)) == [Self.moveDown])
                #expect(Self.moveActions(of: handle(.quickWidgets)) == [Self.moveUp, Self.moveDown])
                #expect(Self.moveActions(of: handle(.custom)) == [Self.moveUp])

                let exposed = exposedAccessibilityElements(in: host.view)
                let titles = [HomeSection.HomeSectionType.upcomingAssignments, .quickWidgets, .custom].map(\.defaultTitle)
                #expect(!exposed.contains { $0.accessibilityLabel == String(localized: "home_section_drag_hint") })
                for title in titles {
                    let named = exposed.filter { $0.accessibilityLabel == title }
                    #expect(!named.isEmpty && named.allSatisfy { !Self.moveActions(of: $0).isEmpty }, "\(title) is read only on its handle")
                }
                let removed = exposed.filter { $0.accessibilityLabel == String(localized: "action_remove") }.compactMap(\.accessibilityValue)
                #expect(Set(titles).isSubset(of: Set(removed)))

                let expected = try Self.dragged(ids(), "quickWidgets", onto: "upcomingAssignments")
                #expect(try Self.perform(Self.action(Self.moveUp, of: handle(.quickWidgets))))
                #expect(ids() == ["todayCourses", "quickWidgets", "upcomingAssignments", "custom"])
                #expect(ids() == expected)
                #expect(Self.savedLayout()?.map(\.id) == expected)
            }
        }
    }

    @Test func aMoveOfAnIDTheLayoutDoesNotHoldMovesNothing() {
        var ids = ["stale", "upcomingAssignments", "quickWidgets"]
        let shown = ["upcomingAssignments", "gone", "quickWidgets"]
        let move = { (offsets: IndexSet, destination: Int) in ids.move(fromOffsets: offsets, toOffset: destination) }

        #expect(ReorderDropSupport.step("gone", by: 1, among: shown, in: ids, moveAction: move)?.position == nil)
        #expect(ReorderDropSupport.step("gone", by: -1, among: shown, in: ids, moveAction: move)?.position == nil)
        #expect(ReorderDropSupport.step("upcomingAssignments", by: -1, among: shown, in: ids, moveAction: move)?.position == nil)
        #expect(ids == ["stale", "upcomingAssignments", "quickWidgets"])

        let landed = ReorderDropSupport.step("quickWidgets", by: -1, among: shown, in: ids, moveAction: move)
        #expect(landed?.position == 1 && landed?.count == 2)
        #expect(ids == ["stale", "quickWidgets", "upcomingAssignments"])
    }

    @Test func twoQuickMovesDownGoTwoPlacesAndStopAtTheEnd() {
        var ids = ["library", "calendar", "gpa"]
        let drawn = ids
        let move = { (offsets: IndexSet, destination: Int) in ids.move(fromOffsets: offsets, toOffset: destination) }

        let first = ReorderDropSupport.step("library", by: 1, among: drawn, in: ids, moveAction: move)
        let second = ReorderDropSupport.step("library", by: 1, among: drawn, in: ids, moveAction: move)
        let third = ReorderDropSupport.step("library", by: 1, among: drawn, in: ids, moveAction: move)

        #expect(first?.position == 2 && second?.position == 3 && third?.position == nil)
        #expect(ids == ["calendar", "gpa", "library"])
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
    static func element(labeled label: String, in view: UIView) -> NSObject? {
        let matches = exposedAccessibilityElements(in: view).filter { $0.accessibilityLabel == label }
        return matches.first { !($0.accessibilityCustomActions ?? []).isEmpty } ?? matches.first
    }

    static func moveActions(of element: NSObject?) -> [String] {
        (element?.accessibilityCustomActions ?? []).map(\.name).filter { [moveUp, moveDown].contains($0) }
    }

    static func action(_ name: String, of element: NSObject?) throws -> UIAccessibilityCustomAction {
        try #require(element?.accessibilityCustomActions?.first { $0.name == name })
    }

    @discardableResult
    static func perform(_ action: UIAccessibilityCustomAction) throws -> Bool {
        let handler = try #require(action.actionHandler)
        return handler(action)
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
