import Defaults
import Foundation
import Testing
@testable import TigerDuck

/// Home's Add sheet lists the quick features whatever sections Home has
/// (https://github.com/tigerduck-app/tigerduck-app/issues/524).
@MainActor
struct HomeQuickFeatureTests {
    @Test("a quick feature with no section to hold it gets a Quick widgets section")
    func aQuickFeatureWithNoSectionGetsOne() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.homeSectionLayoutData]
            defer { Defaults[.homeSectionLayoutData] = saved }
            let viewModel = HomeViewModel()
            viewModel.sections = []
            viewModel.addQuickFeature(.announcements)
            #expect(viewModel.sections.map(\.type) == [.quickWidgets])
            #expect(viewModel.sections.first?.widgets.map(\.feature) == [.announcements])
            viewModel.addQuickFeature(.gpa)
            #expect(viewModel.sections.count == 1)
            #expect(viewModel.sections.first?.widgets.map(\.feature) == [.announcements, .gpa])
        }
    }
}
