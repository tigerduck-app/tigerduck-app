import Defaults
import Foundation
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

        // Let the view model's observation task register before writing, so
        // the change it is waiting for isn't published into a dead stream.
        await Task.yield()
        Defaults[.alwaysShowAllPeriods] = true

        try await Self.waitUntil { viewModel.showsAllPeriods }
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

        await Task.yield()
        Defaults[.alwaysShowAllPeriods] = true

        try await Self.waitUntil { viewModel.cellRoleCache.isEmpty }
    }

    /// Polls `condition` until it holds or the deadline passes — the mirror is
    /// updated from an `AsyncStream`, so the flip lands a hop after the write.
    private static func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition never became true within \(timeout)", sourceLocation: sourceLocation)
    }
}
