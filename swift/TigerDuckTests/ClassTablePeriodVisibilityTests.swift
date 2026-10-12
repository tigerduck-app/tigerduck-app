import Defaults
import Foundation
import Observation
import Testing
@testable import TigerDuck

/// The "always show all periods" toggle used to leave the grid on its old row
/// set until something else forced a reload, because `activePeriods` read
/// `Defaults` directly and SwiftUI cannot see a raw `Defaults` read.
///
/// Serialized: both tests drive the one global `alwaysShowAllPeriods` key, and
/// `@MainActor` still lets them interleave at their awaits — one test's restore
/// would flip the other's toggle back out from under its polling loop.
@Suite(.serialized)
@MainActor
struct ClassTablePeriodVisibilityTests {
    @Test func flippingTheToggle_widensTheGridWithoutAReload() async throws {
        let saved = Defaults[.alwaysShowAllPeriods]
        defer { Defaults[.alwaysShowAllPeriods] = saved }

        Defaults[.alwaysShowAllPeriods] = false
        let viewModel = ClassTableViewModel()
        #expect(viewModel.activePeriods.map(\.id) == AppConstants.Periods.defaultVisible)

        // Written before the view model's observation task has run at all:
        // the change must still arrive, or the grid keeps the old row set.
        Defaults[.alwaysShowAllPeriods] = true

        try await waitUntil { viewModel.showsAllPeriods }
        #expect(viewModel.activePeriods.map(\.id) == AppConstants.Periods.chronologicalOrder)
    }

    @Test func flippingTheToggle_clearsTheCellRoleCache() async throws {
        let saved = Defaults[.alwaysShowAllPeriods]
        defer { Defaults[.alwaysShowAllPeriods] = saved }

        Defaults[.alwaysShowAllPeriods] = false
        let viewModel = ClassTableViewModel()
        // Cache keys are indexes into `activePeriods`; stale entries would
        // point at the wrong period once the row set grows.
        _ = viewModel.cellRole(weekday: 1, periodIndex: 0)
        #expect(!viewModel.cellRoleCache.isEmpty)

        Defaults[.alwaysShowAllPeriods] = true

        try await waitUntil { viewModel.cellRoleCache.isEmpty }
    }

    /// Set from `withObservationTracking`'s `onChange`, which is `@Sendable`.
    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    @Test func fillingTheCellRoleCache_doesNotRedrawTheGrid() {
        // The grid fills the cache while its body runs. A tracked write there invalidated the
        // cells that had just read it, so every rebuild cost a second grid pass.
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
