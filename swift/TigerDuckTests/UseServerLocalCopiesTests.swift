import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct UseServerLocalCopiesTests {
    private static func makeCache() -> TestCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UseServerLocalCopiesTests-\(UUID().uuidString)", isDirectory: true)
        return TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
    }

    @Test("Use Server keeps the hidden courses and drops what the other answered categories hold here")
    func useServerKeepsTheHiddenCourses() {
        let cache = Self.makeCache()
        cache.courses.saveDeletedCourseNos(["1142:CS1"], for: testSignIn)
        cache.courses.saveCourseCustomNames(["EE2": ["zh": "Name"]], for: testSignIn)
        cache.assignments.replaceArchivedAssignmentIds(["7"], for: testSignIn)
        cache.assignments.replaceIgnoredAssignmentCourses(["1151:EE2"], for: testSignIn)

        SyncConflicts.dropLocalCopies(
            for: SyncConflicts.ReenableConflict(
                categories: [.courses, .courseNames, .assignments], description: "",
                serverIgnoredCourses: [], serverMarkedAssignments: []
            ),
            courses: cache.courses, assignments: cache.assignments, colors: CourseColorStore(files: cache.colors), signIn: testSignIn
        )

        #expect(cache.courses.loadDeletedCourseNos() == ["1142:CS1"])
        #expect(cache.courses.loadCourseCustomNames().isEmpty)
        #expect(cache.assignments.loadArchivedAssignmentIds().isEmpty)
        #expect(cache.assignments.loadIgnoredAssignmentCourses().isEmpty)
    }

    @Test("Use Server on the colours drops them here with the record of which were picked")
    func useServerDropsTheColoursAndTheirPicks() {
        let cache = Self.makeCache()
        cache.colors.saveCourseColorMap(["CS1": 0x123456])
        cache.colors.notePickedCourseColor("CS1")

        SyncConflicts.dropLocalCopies(
            for: SyncConflicts.ReenableConflict(
                categories: [.courseColors], description: "",
                serverIgnoredCourses: nil, serverMarkedAssignments: []
            ),
            courses: cache.courses, assignments: cache.assignments, colors: CourseColorStore(files: cache.colors), signIn: testSignIn
        )

        #expect(cache.colors.loadCourseColorMap().isEmpty)
        #expect(cache.colors.loadPickedCourseColors().isEmpty)
    }
}
