import Foundation
import Testing
@testable import TigerDuck

/// `AppState.dropLocalCopies(for:in:)`: what Use Server in the re-enable dialog drops on this
/// device before the full sync that takes the server's data, against a cache of its own.
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

    /// Cleared here, the hidden courses of a term the server lists none in, which the check did not
    /// compare, came back with the sync after the answer and were uploaded.
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

    /// Left behind, the picks would make the sign-out ask about colours that are the server's now
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/563).
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
