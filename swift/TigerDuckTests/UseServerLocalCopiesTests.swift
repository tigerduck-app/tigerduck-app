import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct UseServerLocalCopiesTests {
    private static func makeCache() -> DataCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UseServerLocalCopiesTests-\(UUID().uuidString)", isDirectory: true)
        return DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
    }

    @Test("Use Server keeps the hidden courses and drops what the other answered categories hold here")
    func useServerKeepsTheHiddenCourses() {
        let cache = Self.makeCache()
        cache.saveDeletedCourseNos(["1142:CS1"])
        cache.saveCourseCustomNames(["EE2": ["zh": "Name"]])
        cache.replaceArchivedAssignmentIds(["7"])
        cache.replaceIgnoredAssignmentCourses(["1151:EE2"])

        AppState.dropLocalCopies(
            for: AppState.ReenableConflict(
                categories: ["courses", "course_names", "assignments"], description: "",
                serverIgnoredCourses: [], serverMarkedAssignments: []
            ),
            in: cache
        )

        #expect(cache.loadDeletedCourseNos() == ["1142:CS1"])
        #expect(cache.loadCourseCustomNames().isEmpty)
        #expect(cache.loadArchivedAssignmentIds().isEmpty)
        #expect(cache.loadIgnoredAssignmentCourses().isEmpty)
    }

    @Test("Use Server on the colours drops them here with the record of which were picked")
    func useServerDropsTheColoursAndTheirPicks() {
        let cache = Self.makeCache()
        cache.saveCourseColorMap(["CS1": 0x123456])
        cache.notePickedCourseColor("CS1")

        AppState.dropLocalCopies(
            for: AppState.ReenableConflict(
                categories: ["course_colors"], description: "",
                serverIgnoredCourses: nil, serverMarkedAssignments: []
            ),
            in: cache
        )

        #expect(cache.loadCourseColorMap().isEmpty)
        #expect(cache.loadPickedCourseColors().isEmpty)
    }
}
