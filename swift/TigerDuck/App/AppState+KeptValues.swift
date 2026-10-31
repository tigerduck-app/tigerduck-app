import Foundation

extension AppState {

    func adoptKeptValue(_ kept: KeptValue) {
        guard Self.adopt(kept, into: .shared, skipping: pendingOverrides, applyColors: TigerDuckTheme.applyColors)
        else { return }
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
    }

    /// Writes a value the backend kept into `cache` and the colours, and reports whether that
    /// changed anything. A mark or an ignore setting in `pending` was just edited here, and that
    /// edit, on its way into the outbox, outranks the value kept.
    static func adopt(
        _ kept: KeptValue,
        into cache: DataCache,
        skipping pending: Set<String> = [],
        applyColors: ([(courseNo: String, hex: UInt32)]) -> Bool
    ) -> Bool {
        switch kept {
        case .courseColor(let semester, let moodleId, let hex):
            guard let courseNo = courseNo(ofMoodleId: moodleId, semester: semester, in: cache) else { return false }
            return applyColors([(courseNo, hex)])

        case .courseName(let semester, let moodleId, let locale, let name):
            guard let courseNo = courseNo(ofMoodleId: moodleId, semester: semester, in: cache) else { return false }
            let before = cache.loadCourseCustomNames()
            var names = before
            var course = names[courseNo] ?? [:]
            course[locale] = name.isEmpty ? nil : name
            names[courseNo] = course.isEmpty ? nil : course
            guard names != before else { return false }
            cache.saveCourseCustomNames(names)
            return true

        case .courseIgnore(let semester, let courseNo, let ignore):
            let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
            let before = cache.loadIgnoredAssignmentCourses()
            let after = ignore ? before.union([key]) : before.subtracting([key])
            guard !pending.contains(key), after != before else { return false }
            cache.replaceIgnoredAssignmentCourses(after)
            return true

        case .mark(let id, let status):
            let archived = cache.loadArchivedAssignmentIds()
            let completed = cache.loadLocallyCompletedAssignmentIds()
            let isArchived = status == "ignored" || status == "archived"
            let newArchived = isArchived ? archived.union([id]) : archived.subtracting([id])
            let newCompleted = status == "locally_completed" ? completed.union([id]) : completed.subtracting([id])
            guard !pending.contains(id), newArchived != archived || newCompleted != completed else { return false }
            cache.replaceArchivedAssignmentIds(newArchived)
            cache.replaceLocallyCompletedAssignmentIds(newCompleted)
            return true
        }
    }

    /// An edit names the term it was made in, which a colour pick spreading to other terms' courses
    /// does not match, so the other terms are searched after it.
    private static func courseNo(ofMoodleId moodleId: String, semester: String, in cache: DataCache) -> String? {
        if let course = (cache.loadCourses(semester: semester) + cache.loadUserAddedCourses())
            .first(where: { $0.moodleIdNumber == moodleId }) {
            return course.courseNo
        }
        return SemesterCatalog.availableSemesters().lazy
            .compactMap { cache.loadCourses(semester: $0).first { $0.moodleIdNumber == moodleId }?.courseNo }
            .first
    }
}
