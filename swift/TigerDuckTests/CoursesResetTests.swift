import Foundation
import Testing
@testable import TigerDuck

/// A full course reset made on another device reaches this one as `courses_reset_at` in the full
/// sync, and drops this device's hidden and manual courses once.
@MainActor
struct CoursesResetTests {

    /// The backend sends Python `isoformat()`. A parser without fractional seconds read every
    /// reset as nil, so no reset made elsewhere was ever applied.
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

    @Test func aLaterResetThanTheLastSeenIsApplied() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        #expect(AppState.isUnappliedCoursesReset(lastSeen.addingTimeInterval(1), lastSeen: lastSeen))
    }

    /// The comparison never involves this device's clock: one running behind used to read the
    /// same reset as new on every sync and drop the hidden and manual courses each time.
    @Test func theResetLastSeenIsNotAppliedAgain() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        #expect(!AppState.isUnappliedCoursesReset(lastSeen, lastSeen: lastSeen))
        #expect(!AppState.isUnappliedCoursesReset(lastSeen.addingTimeInterval(-60), lastSeen: lastSeen))
    }

    /// An account's first sync on this device has no hidden or manual courses from before the
    /// reset to drop; it records the reset so the next one is told apart.
    @Test func theFirstSyncOnlyRecordsTheReset() {
        #expect(!AppState.isUnappliedCoursesReset(Date(timeIntervalSince1970: 1_000), lastSeen: nil))
        #expect(!AppState.isUnappliedCoursesReset(nil, lastSeen: Date(timeIntervalSince1970: 1_000)))
    }
}
