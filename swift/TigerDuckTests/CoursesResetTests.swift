import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CoursesResetTests {

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

    @Test func theResetLastSeenIsNotAppliedAgain() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        #expect(!AppState.coursesReset(server: lastSeen, lastSeen: lastSeen, takesCourses: true).apply)
        #expect(!AppState.coursesReset(server: lastSeen.addingTimeInterval(-60), lastSeen: lastSeen, takesCourses: true).apply)
    }

    @Test func theFirstSyncOnlyKeepsTheReset() {
        let reset = Date(timeIntervalSince1970: 1_000)
        let first = AppState.coursesReset(server: reset, lastSeen: nil, takesCourses: true)
        #expect(!first.apply)
        #expect(first.remember == reset)
    }

    @Test func theFirstResetAfterASyncWithoutOneIsApplied() {
        let first = AppState.coursesReset(server: nil, lastSeen: nil, takesCourses: true)
        #expect(!first.apply)

        let reset = Date(timeIntervalSince1970: 1_000)
        let second = AppState.coursesReset(server: reset, lastSeen: first.remember, takesCourses: true)
        #expect(second.apply)
        #expect(!AppState.coursesReset(server: reset, lastSeen: second.remember, takesCourses: true).apply)
    }

    @Test("A sync that does not take courses keeps them through a new reset, and records the reset")
    func aSyncNotTakingCoursesRecordsTheResetWithoutApplyingIt() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        let reset = lastSeen.addingTimeInterval(1)

        let skipped = AppState.coursesReset(server: reset, lastSeen: lastSeen, takesCourses: false)
        #expect(!skipped.apply)
        #expect(skipped.remember == reset)

        #expect(!AppState.coursesReset(server: reset, lastSeen: skipped.remember, takesCourses: true).apply)
    }

    @Test func aSyncWithoutAResetKeepsTheLastSeen() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        let reset = AppState.coursesReset(server: nil, lastSeen: lastSeen, takesCourses: true)
        #expect(!reset.apply)
        #expect(reset.remember == lastSeen)
    }
}
