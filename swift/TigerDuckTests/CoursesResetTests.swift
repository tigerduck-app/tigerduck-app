import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CoursesResetTests {

    @Test func parsesTheBackendsTimestampWithMicroseconds() throws {
        let parsed = try #require(FullSyncRunner.backendDate("2026-10-10T16:42:49.666640+00:00"))
        let whole = try #require(FullSyncRunner.backendDate("2026-10-10T16:42:49+00:00"))
        #expect(parsed.timeIntervalSince(whole) > 0.66)
        #expect(parsed.timeIntervalSince(whole) < 0.67)
    }

    @Test func readsNoDateFromAMissingOrMalformedValue() {
        #expect(FullSyncRunner.backendDate(nil) == nil)
        #expect(FullSyncRunner.backendDate(NSNull()) == nil)
        #expect(FullSyncRunner.backendDate("yesterday") == nil)
    }

    @Test func aLaterResetThanTheLastSeenIsAppliedAndKept() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        let reset = CourseReset.decide(server: lastSeen.addingTimeInterval(1), lastSeen: lastSeen, takesCourses: true)
        #expect(reset.apply)
        #expect(reset.remember == lastSeen.addingTimeInterval(1))
    }

    @Test func theResetLastSeenIsNotAppliedAgain() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        #expect(!CourseReset.decide(server: lastSeen, lastSeen: lastSeen, takesCourses: true).apply)
        #expect(!CourseReset.decide(server: lastSeen.addingTimeInterval(-60), lastSeen: lastSeen, takesCourses: true).apply)
    }

    @Test func theFirstSyncOnlyKeepsTheReset() {
        let reset = Date(timeIntervalSince1970: 1_000)
        let first = CourseReset.decide(server: reset, lastSeen: nil, takesCourses: true)
        #expect(!first.apply)
        #expect(first.remember == reset)
    }

    @Test func theFirstResetAfterASyncWithoutOneIsApplied() {
        let first = CourseReset.decide(server: nil, lastSeen: nil, takesCourses: true)
        #expect(!first.apply)

        let reset = Date(timeIntervalSince1970: 1_000)
        let second = CourseReset.decide(server: reset, lastSeen: first.remember, takesCourses: true)
        #expect(second.apply)
        #expect(!CourseReset.decide(server: reset, lastSeen: second.remember, takesCourses: true).apply)
    }

    @Test("A sync that does not take courses keeps them through a new reset, and records the reset")
    func aSyncNotTakingCoursesRecordsTheResetWithoutApplyingIt() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        let reset = lastSeen.addingTimeInterval(1)

        let skipped = CourseReset.decide(server: reset, lastSeen: lastSeen, takesCourses: false)
        #expect(!skipped.apply)
        #expect(skipped.remember == reset)

        #expect(!CourseReset.decide(server: reset, lastSeen: skipped.remember, takesCourses: true).apply)
    }

    @Test func aSyncWithoutAResetKeepsTheLastSeen() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        let reset = CourseReset.decide(server: nil, lastSeen: lastSeen, takesCourses: true)
        #expect(!reset.apply)
        #expect(reset.remember == lastSeen)
    }
}
