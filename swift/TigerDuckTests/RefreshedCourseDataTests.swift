import Foundation
import Testing
@testable import TigerDuck

/// What one course becomes in a term refresh. The refreshed list replaces the term's cache and
/// is uploaded, and the backend's upsert overwrites times and rooms with what it carries, so a
/// row that loses them here loses them on every synced device.
@MainActor
struct RefreshedCourseDataTests {
    private static let display = AppServiceBridge.CourseDisplayPreferences(
        language: "zh",
        courseAbbrEnabled: false,
        classroomAbbrEnabled: false,
        classroomMandarinDisplay: "original"
    )

    private static let cached = CourseData(
        courseNo: "CS1001301",
        courseName: "程式設計",
        instructor: "王大明",
        credits: 3,
        classroom: "TR-313",
        enrolledCount: 52,
        maxCount: 60,
        schedule: [1: ["3", "4"], 4: ["6"]],
        moodleIdNumber: "1151CS1001301",
        classroomMap: ["1-3": "TR-313", "1-4": "TR-313", "4-6": "TR-409"],
        dimension: "",
        allYear: "H",
        requireOption: "R"
    )

    private static let moodle = MoodleEnrolledCourse(
        id: 7,
        fullname: "【1151】CS1001301 程式設計",
        shortname: "cs1001301",
        idnumber: "1151CS1001301",
        startDate: nil,
        endDate: nil
    )

    private static func refreshed(
        cached: CourseData?,
        moodle: MoodleEnrolledCourse?,
        lookup: () async throws -> [CourseSearchResult]
    ) async -> CourseData? {
        await AppServiceBridge.refreshedCourseData(
            courseNo: "CS1001301",
            semester: "1151",
            cached: cached,
            moodle: moodle,
            grade: nil,
            display: display,
            lookup: lookup
        )
    }

    @Test("A failed lookup keeps the cached times and rooms instead of Moodle's bare row")
    func failedLookupKeepsTheCachedRow() async {
        let row = await Self.refreshed(cached: Self.cached, moodle: Self.moodle) {
            throw URLError(.timedOut)
        }
        #expect(row?.schedule == Self.cached.schedule)
        #expect(row?.classroomMap == Self.cached.classroomMap)
        #expect(row?.classroom == "TR-313")
        #expect(row?.courseName == "程式設計")
    }

    @Test("A failed lookup keeps a cached course that neither Moodle nor the transcript lists")
    func failedLookupKeepsACourseOnlyTheCacheKnows() async {
        let row = await Self.refreshed(cached: Self.cached, moodle: nil) {
            throw URLError(.badServerResponse)
        }
        #expect(row?.courseNo == "CS1001301")
        #expect(row?.schedule == Self.cached.schedule)
    }

    @Test("A failed lookup of a course not cached yet falls back to Moodle")
    func failedLookupWithoutACachedRowFallsBack() async {
        let row = await Self.refreshed(cached: nil, moodle: Self.moodle) {
            throw URLError(.timedOut)
        }
        #expect(row?.courseName == Self.moodle.fullname)
        #expect(row?.schedule.isEmpty == true)
    }

    @Test("An answer with no rows, as for a term NTUST no longer indexes, keeps the cached row")
    func emptyAnswerKeepsTheCachedRow() async {
        let row = await Self.refreshed(cached: Self.cached, moodle: Self.moodle) { [] }
        #expect(row?.schedule == Self.cached.schedule)
        #expect(row?.classroomMap == Self.cached.classroomMap)
        #expect(row?.courseName == "程式設計")
    }

    @Test("An answer with no rows for a course not cached yet falls back to Moodle")
    func emptyAnswerWithoutACachedRowFallsBack() async {
        let row = await Self.refreshed(cached: nil, moodle: Self.moodle) { [] }
        #expect(row?.courseName == Self.moodle.fullname)
        #expect(row?.schedule.isEmpty == true)
    }
}
