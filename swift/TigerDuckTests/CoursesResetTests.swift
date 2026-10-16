import Foundation
import Testing
@testable import TigerDuck

/// A full course reset made on another device reaches this one as `courses_reset_at` in the full
/// sync, and drops this device's hidden and manual courses once.
@MainActor
struct CoursesResetTests {

    /// The backend sends Python `isoformat()`, which has microseconds unless they are zero, so
    /// both forms must parse.
    @Test func parsesTheBackendsTimestampWithMicroseconds() throws {
        let parsed = try #require(AppState.backendDate("2026-10-10T16:42:49.666640+00:00"))
        let whole = try #require(AppState.backendDate("2026-10-10T16:42:49+00:00"))
        #expect(parsed.timeIntervalSince(whole) > 0.66)
        #expect(parsed.timeIntervalSince(whole) < 0.67)
    }

    @Test func readsNoDateFromAMissingOrMalformedValue() {
        #expect(AppState.backendDate(nil) == nil)
        #expect(AppState.backendDate(NSNull()) == nil)
        #expect(AppState.backendDate("yesterday") == nil)
    }

    @Test func aLaterResetThanTheLastSeenIsAppliedAndKept() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        let reset = AppState.coursesReset(server: lastSeen.addingTimeInterval(1), lastSeen: lastSeen, takesCourses: true)
        #expect(reset.apply)
        #expect(reset.remember == lastSeen.addingTimeInterval(1))
    }

    /// Only server times are compared, never this device's clock, which can run behind the
    /// server's: the same reset would then read as new on every sync and drop the hidden and
    /// manual courses each time.
    @Test func theResetLastSeenIsNotAppliedAgain() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        #expect(!AppState.coursesReset(server: lastSeen, lastSeen: lastSeen, takesCourses: true).apply)
        #expect(!AppState.coursesReset(server: lastSeen.addingTimeInterval(-60), lastSeen: lastSeen, takesCourses: true).apply)
    }

    /// An account's first sync on this device has no hidden or manual courses from before the
    /// reset to drop; it keeps the reset so the next one is told apart.
    @Test func theFirstSyncOnlyKeepsTheReset() {
        let reset = Date(timeIntervalSince1970: 1_000)
        let first = AppState.coursesReset(server: reset, lastSeen: nil, takesCourses: true)
        #expect(!first.apply)
        #expect(first.remember == reset)
    }

    /// A sync that finds no reset still counts as this device's first, so the account's first
    /// full reset, made on another device later, is applied.
    @Test func theFirstResetAfterASyncWithoutOneIsApplied() {
        let first = AppState.coursesReset(server: nil, lastSeen: nil, takesCourses: true)
        #expect(!first.apply)

        let reset = Date(timeIntervalSince1970: 1_000)
        let second = AppState.coursesReset(server: reset, lastSeen: first.remember, takesCourses: true)
        #expect(second.apply)
        #expect(!AppState.coursesReset(server: reset, lastSeen: second.remember, takesCourses: true).apply)
    }

    /// With the Courses switch off, or a courses re-enable check waiting for its answer, the user
    /// keeps this device's courses, and a reset made elsewhere used to drop the added and hidden
    /// ones anyway (https://github.com/tigerduck-app/tigerduck-app/issues/648).
    @Test("A sync that does not take courses keeps them through a new reset, and records the reset")
    func aSyncNotTakingCoursesRecordsTheResetWithoutApplyingIt() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        let reset = lastSeen.addingTimeInterval(1)

        let skipped = AppState.coursesReset(server: reset, lastSeen: lastSeen, takesCourses: false)
        #expect(!skipped.apply)
        #expect(skipped.remember == reset)

        // Recorded, so the first sync that takes courses again leaves the decision to the check.
        #expect(!AppState.coursesReset(server: reset, lastSeen: skipped.remember, takesCourses: true).apply)
    }

    /// A sync that finds no reset keeps the last one it saw.
    @Test func aSyncWithoutAResetKeepsTheLastSeen() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        let reset = AppState.coursesReset(server: nil, lastSeen: lastSeen, takesCourses: true)
        #expect(!reset.apply)
        #expect(reset.remember == lastSeen)
    }
}
