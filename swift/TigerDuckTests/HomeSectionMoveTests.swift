import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct HomeSectionMoveTests {
    private static func section(_ id: String, _ type: HomeSection.HomeSectionType) -> HomeSection {
        HomeSection(id: id, type: type, title: id, sortOrder: 0, isVisible: true, widgets: [])
    }

    @Test("a move among the shown sections leaves a hidden one in its place")
    func aHiddenSectionKeepsItsPlace() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.homeSectionLayoutData]
            defer { Defaults[.homeSectionLayoutData] = saved }
            let viewModel = HomeViewModel()
            viewModel.sections = [
                Self.section("widgets", .quickWidgets),
                Self.section("today", .todayCourses),
                Self.section("assignments", .upcomingAssignments),
                Self.section("custom", .custom),
            ]
            let shown = viewModel.sections.filter { $0.type != .todayCourses }

            viewModel.moveSections(shown: shown, from: IndexSet(integer: 2), to: 0)

            #expect(viewModel.sections.map(\.id) == ["custom", "today", "widgets", "assignments"])
            #expect(viewModel.sections.map(\.sortOrder) == [0, 1, 2, 3])
        }
    }
}
