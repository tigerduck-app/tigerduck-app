import Foundation

/// A course reset made on another device: whether a full sync applies it, and its apply.
enum CourseReset {
    /// Whether the server's reset is newer than the last one seen, and the time to remember.
    nonisolated static func decide(
        server: Date?, lastSeen: Date?, takesCourses: Bool
    ) -> (apply: Bool, remember: Date) {
        guard let lastSeen else { return (false, server ?? .distantPast) }
        guard let server else { return (false, lastSeen) }
        return (takesCourses && server > lastSeen, server)
    }

    /// Drops the course edits queued before a reset made elsewhere and wipes the hand-added and
    /// hidden courses, but keeps those whose add or delete made after it still goes out, as the
    /// add uploads its course from them. Returns the keys of the dropped deletes, or nil, with the
    /// caches untouched, when `mayWrite` says no after the hops, as behind the lock screen, where
    /// the protected course files read as empty.
    static func apply(
        at resetAt: Date, courses: CourseStore, on coordinator: CloudSyncCoordinator, mayWrite: () -> Bool
    ) async -> Set<String>? {
        let dropped = await coordinator.dropCourseEdits(madeBeforeReset: resetAt)
        let adding = await coordinator.courseAddKeys(unlandedAt: resetAt.addingTimeInterval(-CloudSyncCoordinator.clockSkewMargin))
        let deleting = await coordinator.pendingCourseDeleteKeys()
        guard mayWrite() else { return nil }
        let added = adding.compactMap(CourseTombstone.parts(of:))
        courses.saveUserAddedCourses(courses.loadUserAddedCourses().filter { course in
            added.contains { $0.courseNo == course.courseNo && CourseStore.userAddedCourse(course, belongsTo: $0.semester) }
        })
        courses.saveDeletedCourseNos(courses.loadDeletedCourseNos().filter(deleting.contains))
        return dropped
    }
}
