import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct HomeQuickFeatureTests {
    @Test("a quick feature with no section to hold it gets a Quick widgets section")
    func aQuickFeatureWithNoSectionGetsOne() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.homeSectionLayoutData]
            defer { Defaults[.homeSectionLayoutData] = saved }
            let viewModel = HomeViewModel()
            viewModel.layout.sections = []
            viewModel.layout.addQuickFeature(.announcements)
            #expect(viewModel.layout.sections.map(\.type) == [.quickWidgets])
            #expect(viewModel.layout.sections.first?.widgets.map(\.feature) == [.announcements])
            viewModel.layout.addQuickFeature(.gpa)
            #expect(viewModel.layout.sections.count == 1)
            #expect(viewModel.layout.sections.first?.widgets.map(\.feature) == [.announcements, .gpa])
        }
    }
}
