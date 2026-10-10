// "Use Local" for courses (`AppState.keepLocalCourses`) against `FakeCourseServer`, which keeps
// the course rules of tigerduck-backend's server/routes/sync/courses.py and uploads.py.
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct KeepLocalCoursesTests {
    private static func roster(_ courseNos: String...) -> [SDCourse] {
        courseNos.map { SDCourse(courseNo: $0, courseName: $0) }
    }

    /// `deletedOnServer`: the delete reached the server (course sync off, cloud sync on) or did
    /// not (cloud sync off).
    @Test("a course deleted here stays deleted after Use Local and the next roster upload",
          arguments: [false, true])
    func deletedCourseStaysDeleted(deletedOnServer: Bool) async throws {
        let server = FakeCourseServer(
            rows: deletedOnServer ? ["client:1151:CS1"] : ["client:1151:CS1", "client:1151:CS2"],
            tombstones: deletedOnServer ? ["client:1151:CS2": false] : [:]
        )
        let roster = Self.roster("CS1", "CS2")

        try await AppState.keepLocalCourses([("1151", roster)], hiding: ["1151:CS2"], on: server)
        #expect(server.rows == ["client:1151:CS1"])

        // A refresh uploads the whole roster, the hidden course included.
        try await server.uploadCourses(AppState.courseUploadRequest(roster, semester: "1151", forceKeys: []))
        #expect(server.rows == ["client:1151:CS1"])
    }

    /// `termCached`: another course of the term is in this language's cache, so the term is reset.
    @Test("a course hidden here but missing from the cache stays deleted",
          arguments: [false, true], [false, true])
    func uncachedHiddenCourseStaysDeleted(deletedOnServer: Bool, termCached: Bool) async throws {
        let cached = termCached ? Self.roster("CS1") : []
        let cachedKeys = Set(cached.map { "client:1151:\($0.courseNo)" })
        let server = FakeCourseServer(
            rows: deletedOnServer ? cachedKeys : cachedKeys.union(["client:1151:CS2"]),
            tombstones: deletedOnServer ? ["client:1151:CS2": false] : [:]
        )

        try await AppState.keepLocalCourses([("1151", cached)], hiding: ["1151:CS2"], on: server)

        // A refresh in the language that caches the course uploads it again.
        try await server.uploadCourses(AppState.courseUploadRequest(
            cached + Self.roster("CS2"), semester: "1151", forceKeys: []
        ))
        #expect(server.rows == cachedKeys)
    }

    @Test("a retry after a failed delete finishes it")
    func retryAfterFailedDelete() async throws {
        let server = FakeCourseServer(rows: ["client:1151:CS1", "client:1151:CS2"])
        let roster = Self.roster("CS1", "CS2")
        server.failingDeletes = 1

        await #expect(throws: URLError.self) {
            try await AppState.keepLocalCourses([("1151", roster)], hiding: ["1151:CS2"], on: server)
        }
        try await AppState.keepLocalCourses([("1151", roster)], hiding: ["1151:CS2"], on: server)

        try await server.uploadCourses(AppState.courseUploadRequest(roster, semester: "1151", forceKeys: []))
        #expect(server.rows == ["client:1151:CS1"])
    }

    @Test("Use Local resets only the terms it re-uploads, never every term at once")
    func resetsTermByTerm() async throws {
        let server = FakeCourseServer(rows: ["client:1151:CS1", "client:1142:CS9"])

        try await AppState.keepLocalCourses(
            [("1151", Self.roster("CS1")), ("1142", [])], hiding: [], on: server
        )

        #expect(server.fullResets == 0)
        #expect(server.rows == ["client:1151:CS1", "client:1142:CS9"])
    }
}

/// One device's view of the backend: rows and tombstones by course key, every tombstone written
/// by this device. A tombstone's value is its `deleted_by_reset`.
@MainActor
private final class FakeCourseServer: CourseSyncBackend {
    private(set) var rows: Set<String>
    private(set) var tombstones: [String: Bool]
    private(set) var fullResets = 0
    /// How many of the next `deleteCourse` calls fail before reaching the server.
    var failingDeletes = 0

    init(rows: Set<String>, tombstones: [String: Bool] = [:]) {
        self.rows = rows
        self.tombstones = tombstones
    }

    func deleteAllCourses(semester: String?) async throws {
        guard let semester else {
            fullResets += 1
            rows = []
            tombstones = [:]
            return
        }
        let prefix = "client:\(semester):"
        let removed = rows.filter { $0.hasPrefix(prefix) }
        rows.subtract(removed)
        for key in tombstones.keys where key.hasPrefix(prefix) { tombstones[key] = true }
        for key in removed { tombstones[key] = true }
    }

    func uploadCourses(_ request: PushAPI.CourseUploadRequest) async throws {
        for key in request.forceKeys { tombstones[key] = nil }
        let keys = request.courses.map { "client:\($0.semester):\($0.courseNo)" }
        for key in keys where tombstones[key] == true { tombstones[key] = nil }
        rows.formUnion(keys.filter { tombstones[$0] == nil })
    }

    func deleteCourse(courseKey: String) async throws {
        if failingDeletes > 0 {
            failingDeletes -= 1
            throw URLError(.networkConnectionLost)
        }
        guard rows.remove(courseKey) != nil else { return }
        tombstones[courseKey] = tombstones[courseKey] ?? false
    }
}
