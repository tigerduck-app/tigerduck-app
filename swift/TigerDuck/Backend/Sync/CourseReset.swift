import Foundation

enum CourseReset {
    nonisolated static func decide(
        server: Date?, lastSeen: Date?, takesCourses: Bool
    ) -> (apply: Bool, remember: Date) {
        guard let lastSeen else { return (false, server ?? .distantPast) }
        guard let server else { return (false, lastSeen) }
        return (takesCourses && server > lastSeen, server)
    }

    static func apply(
        at resetAt: Date, courses: CourseStore, on coordinator: CloudSyncCoordinator, for signIn: SignIn,
        mayWrite: () -> Bool
    ) async throws -> Set<String> {
        let dropped = await coordinator.dropCourseEdits(madeBeforeReset: resetAt)
        let adding = await coordinator.courseAddKeys(
            unlandedAt: resetAt.addingTimeInterval(-CloudSyncCoordinator.clockSkewMargin), takenIn: coordinator.clock.era
        )
        let deleting = await coordinator.pendingCourseDeleteKeys()
        guard mayWrite() else { throw FullSyncAbandoned() }
        let added = adding.compactMap(CourseTombstone.parts(of:))
        courses.saveUserAddedCourses(courses.loadUserAddedCourses().filter { course in
            added.contains { $0.courseNo == course.courseNo && CourseStore.userAddedCourse(course, belongsTo: $0.semester) }
        }, for: signIn)
        courses.saveDeletedCourseNos(courses.loadDeletedCourseNos().filter(deleting.contains), for: signIn)
        return dropped
    }
}
