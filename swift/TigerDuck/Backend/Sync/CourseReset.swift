import Foundation

enum CourseReset {
    nonisolated static func decide(
        server: Date?, lastSeen: Date?, takesCourses: Bool
    ) -> (apply: Bool, remember: Date) {
        guard let lastSeen else { return (false, server ?? .distantPast) }
        guard let server else { return (false, lastSeen) }
        return (takesCourses && server > lastSeen, server)
    }

    /// The backend refuses a queued add or hide older than the reset, so each one still queued keeps
    /// its course here for the backend to settle.
    static func apply(
        fetchedAt: Date, courses: CourseStore, on coordinator: CloudSyncCoordinator, for signIn: SignIn,
        mayWrite: () -> Bool
    ) async throws {
        let adding = await coordinator.courseAddKeys(unlandedAt: fetchedAt)
        let deleting = await coordinator.pendingCourseDeleteKeys()
        guard mayWrite() else { throw FullSyncAbandoned() }
        let added = adding.compactMap(CourseTombstone.parts(of:))
        courses.saveUserAddedCourses(courses.loadUserAddedCourses().filter { course in
            added.contains { $0.courseNo == course.courseNo && CourseStore.userAddedCourse(course, belongsTo: $0.semester) }
        }, for: signIn)
        courses.saveDeletedCourseNos(courses.loadDeletedCourseNos().filter(deleting.contains), for: signIn)
    }
}
