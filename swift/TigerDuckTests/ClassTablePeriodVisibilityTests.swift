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
        #expect(viewModel.activePeriods.map(\.id) == AppConstants.Periods.defaultVisible)

        Defaults[.alwaysShowAllPeriods] = true

        try await waitUntil { viewModel.showsAllPeriods }
        #expect(viewModel.activePeriods.map(\.id) == AppConstants.Periods.chronologicalOrder)
    }

    @Test func flippingTheToggle_clearsTheCellRoleCache() async throws {
        let saved = Defaults[.alwaysShowAllPeriods]
        defer { Defaults[.alwaysShowAllPeriods] = saved }

        Defaults[.alwaysShowAllPeriods] = false
        let viewModel = ClassTableViewModel()
        _ = viewModel.cellRole(weekday: 1, periodIndex: 0)
        #expect(!viewModel.cellRoleCache.isEmpty)

        Defaults[.alwaysShowAllPeriods] = true

        try await waitUntil { viewModel.cellRoleCache.isEmpty }
    }

    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    @Test func fillingTheCellRoleCache_doesNotRedrawTheGrid() {
        let viewModel = ClassTableViewModel()
        let redrawn = Flag()
        withObservationTracking {
            _ = viewModel.cellRole(weekday: 1, periodIndex: 0)
        } onChange: {
            redrawn.raised = true
        }

        _ = viewModel.cellRole(weekday: 2, periodIndex: 0)

        #expect(!redrawn.raised)
    }
}
