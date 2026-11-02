import Defaults
import Foundation
import Observation
import Testing
@testable import TigerDuck

@Suite(.serialized)
@MainActor
struct ClassTablePeriodVisibilityTests {
    @Test func flippingTheToggle_widensTheGridWithoutAReload() async throws {
        let saved = Defaults[.alwaysShowAllPeriods]
        defer { Defaults[.alwaysShowAllPeriods] = saved }

        Defaults[.alwaysShowAllPeriods] = false
        let viewModel = ClassTableViewModel()
        #expect(viewModel.grid.activePeriods(withClubs: false).map(\.id) == AppConstants.Periods.defaultVisible)

        Defaults[.alwaysShowAllPeriods] = true

        try await waitUntil { viewModel.grid.showsAllPeriods }
        #expect(viewModel.grid.activePeriods(withClubs: false).map(\.id) == AppConstants.Periods.chronologicalOrder)
    }

    @Test func flippingTheToggle_clearsTheCellRoleCache() async throws {
        let saved = Defaults[.alwaysShowAllPeriods]
        defer { Defaults[.alwaysShowAllPeriods] = saved }

        Defaults[.alwaysShowAllPeriods] = false
        let viewModel = ClassTableViewModel()
        _ = viewModel.grid.cellRole(weekday: 1, periodIndex: 0, withClubs: false)
        #expect(!viewModel.grid.cellRoleCache.isEmpty)

        Defaults[.alwaysShowAllPeriods] = true

        try await waitUntil { viewModel.grid.cellRoleCache.isEmpty }
    }

    /// Set from `withObservationTracking`'s `onChange`, which is `@Sendable`.
    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    @Test func fillingTheCellRoleCache_doesNotRedrawTheGrid() {
        let viewModel = ClassTableViewModel()
        let redrawn = Flag()
        withObservationTracking {
            _ = viewModel.grid.cellRole(weekday: 1, periodIndex: 0, withClubs: false)
        } onChange: {
            redrawn.raised = true
        }

        _ = viewModel.grid.cellRole(weekday: 2, periodIndex: 0, withClubs: false)

        #expect(!redrawn.raised)
    }
}
