import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseDeleteHideTests {
    private static let term = "1151"
    private static let enrolled = SDCourse(courseNo: "CS1001301", courseName: "Algorithms", semester: term)
    private static let handAdded = SDCourse(courseNo: "GE1010001", courseName: "Art", semester: term)

    private static func makeCache() -> TestCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDeleteHideTests-\(UUID().uuidString)", isDirectory: true)
        let cache = TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        cache.courses.saveCourses([enrolled], semester: term)
        cache.courses.saveUserAddedCourses([handAdded])
        return cache
    }

    private static func afterSelectionLists(
        _ courseNos: [String], in cache: TestCache
    ) -> (shown: [String], uploaded: [String]) {
        let roster = courseNos.map { SDCourse(courseNo: $0, courseName: $0, semester: term) }
        cache.courses.saveCourses(roster, semester: term)
        var uploaded: [String] = []
        AppServiceBridge.uploadVisibleCourses(roster, semester: term, hidden: Set(cache.courses.loadDeletedCourseNos())) {
            courses, _, _, _ in uploaded = courses.map(\.courseNo)
        }
        let shown = CanonicalCourseProvider(courses: cache.courses).currentCourses(semester: term).map(\.courseNo)
        return (shown.sorted(), uploaded.sorted())
    }

    @Test("A deleted hand-added course shows again and goes up with the roster once course selection lists it")
    func aHandAddedCourseComesBackWithTheRoster() {
        let cache = Self.makeCache()

        cache.courses.apply(.delete(courseNo: Self.handAdded.courseNo, semester: Self.term))
        #expect(CanonicalCourseProvider(courses: cache.courses).currentCourses(semester: Self.term).map(\.courseNo) == ["CS1001301"])

        let after = Self.afterSelectionLists(["CS1001301", "GE1010001"], in: cache)
        #expect(after.shown == ["CS1001301", "GE1010001"])
        #expect(after.uploaded == ["CS1001301", "GE1010001"])
    }

    @Test("A deleted enrolled course stays hidden and off the roster upload when course selection lists it again")
    func anEnrolledCourseStaysHidden() {
        let cache = Self.makeCache()

        cache.courses.apply(.delete(courseNo: Self.enrolled.courseNo, semester: Self.term))

        let after = Self.afterSelectionLists(["CS1001301", "GE1010001"], in: cache)
        #expect(after.shown == ["GE1010001"])
        #expect(after.uploaded == ["GE1010001"])
    }

    @Test("A course merged from another device's row stays hidden after a delete, its term's roster not cached here")
    func aMergedCourseStaysHidden() {
        let cache = Self.makeCache()
        let merged = SDCourse(
            courseNo: "MA1010003", courseName: "Calculus", moodleIdNumber: "1151MA1010003", semester: Self.term
        )
        cache.courses.saveUserAddedCourses([Self.handAdded, merged])

        cache.courses.apply(.delete(courseNo: merged.courseNo, semester: Self.term))

        #expect(cache.courses.loadDeletedCourseNos() == ["1151:MA1010003"])
        let after = Self.afterSelectionLists(["CS1001301", "MA1010003"], in: cache)
        #expect(after.shown == ["CS1001301", "GE1010001"])
        #expect(after.uploaded == ["CS1001301"])
    }

    @Test("A hand-added course the school has listed since counts as enrolled when it is deleted")
    func aHandAddedCourseTheRosterListsIsHidden() {
        let cache = Self.makeCache()
        cache.courses.saveCourses([Self.enrolled, Self.handAdded], semester: Self.term)

        cache.courses.apply(.delete(courseNo: Self.handAdded.courseNo, semester: Self.term))

        #expect(cache.courses.loadDeletedCourseNos() == ["1151:GE1010001"])
        #expect(cache.courses.loadUserAddedCourses().isEmpty)
    }
}
