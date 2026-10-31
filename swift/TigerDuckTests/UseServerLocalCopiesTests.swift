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
        cache.courses.saveDeletedCourseNos(["1142:CS1"])
        cache.courses.saveCourseCustomNames(["EE2": ["zh": "Name"]])
        cache.assignments.replaceArchivedAssignmentIds(["7"])
        cache.assignments.replaceIgnoredAssignmentCourses(["1151:EE2"])

        AppState.dropLocalCopies(
            for: AppState.ReenableConflict(
                categories: ["courses", "course_names", "assignments"], description: "",
                serverIgnoredCourses: [], serverMarkedAssignments: []
            ),
            courses: cache.courses, assignments: cache.assignments, colors: cache.colors
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

        AppState.dropLocalCopies(
            for: AppState.ReenableConflict(
                categories: ["course_colors"], description: "",
                serverIgnoredCourses: nil, serverMarkedAssignments: []
            ),
            courses: cache.courses, assignments: cache.assignments, colors: cache.colors
        )

        #expect(cache.colors.loadCourseColorMap().isEmpty)
        #expect(cache.colors.loadPickedCourseColors().isEmpty)
    }
}
