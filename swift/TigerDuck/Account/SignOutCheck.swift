import Defaults
import Foundation

@MainActor
struct SignOutCheck {
    let app: AppEnvironment

    nonisolated static func retriesDepartingUnregister(onboarded: Bool, signedIn: Bool, keptOn: [URL], backend: URL) -> Bool {
        onboarded && keptOn.contains { AuthTokenManager.retriesKeptSession(on: $0, signedIn: signedIn, backend: backend) }
    }

    func deletesUnsyncedData() async -> Bool {
        let unsent = await app.cloudSyncCoordinator.holdsUnsentEdits() || app.pushCoordinator.holdsUnsentCourseUploads
            || !app.localEdits.pendingOverrides.isEmpty
            || !AcademicCalendarStore.shared.unacknowledgedHolidayIDs.isEmpty
        return Self.signOutDeletesUnsyncedData(
            heldSignOutData(),
            cloudSyncEnabled: app.cloudSyncEnabled,
            switchedOn: SyncConflicts.switchedOnCategories(),
            synced: Defaults[.categoriesSyncedOnce],
            pendingChecks: Defaults[.pendingConflictCategories],
            unsent: unsent
        )
    }

    func leavesSyncedData() -> Bool {
        Self.signOutLeavesSyncedData(
            heldSignOutData(),
            cloudSyncEnabled: app.cloudSyncEnabled,
            switchedOn: SyncConflicts.switchedOnCategories(),
            synced: Defaults[.categoriesSyncedOnce],
            pendingChecks: Defaults[.pendingConflictCategories]
        )
    }

    private func heldSignOutData() -> SignOutData {
        let cache = CourseStore.shared
        let marks = AssignmentStore.shared
        let names = cache.loadCourseCustomNames()
        let userAdded = cache.loadUserAddedCourses()
        return SignOutData(
            courses: !userAdded.isEmpty || !cache.loadDeletedCourseNos().isEmpty,
            courseNames: names.values.contains { !$0.isEmpty },
            localOnlyCourseNames: Self.holdsLocalOnlyCourseNames(
                names, courses: userAdded + SemesterCatalog.availableSemesters().flatMap { cache.loadCourses(semester: $0) }
            ),
            courseColors: !CourseColorStore.shared.files.loadPickedCourseColors().isEmpty,
            assignmentMarks: !marks.loadArchivedAssignmentIds().isEmpty
                || !marks.loadLocallyCompletedAssignmentIds().isEmpty,
            ignoredCourses: !marks.loadIgnoredAssignmentCourses().isEmpty,
            holidays: !AcademicCalendarStore.shared.optedInHolidayIDs.isEmpty
        )
    }

    static func holdsLocalOnlyCourseNames(_ names: [String: [String: String]], courses: [SDCourse]) -> Bool {
        let withMoodleId = Set(courses.filter { $0.moodleIdNumber != nil }.map(\.courseNo))
        let held = Set(courses.map(\.courseNo))
        return names.contains { !$0.value.isEmpty && held.contains($0.key) && !withMoodleId.contains($0.key) }
    }

    nonisolated struct SignOutData {
        var courses = false
        var courseNames = false
        var localOnlyCourseNames = false
        var courseColors = false
        var assignmentMarks = false
        var ignoredCourses = false
        var holidays = false

        var categoriesNeeded: [(held: Bool, categories: Set<String>)] {
            [
                (courses, ["courses"]),
                (courseNames, ["course_names"]),
                (courseColors, ["course_colors"]),
                (assignmentMarks, ["assignments"]),
                (ignoredCourses, ["assignments", "courses"]),
            ]
        }
    }

    nonisolated static func signOutDeletesUnsyncedData(
        _ data: SignOutData,
        cloudSyncEnabled: Bool,
        switchedOn: Set<String>,
        synced: Set<String>,
        pendingChecks: Set<String>,
        unsent: Bool
    ) -> Bool {
        let kept = cloudSyncEnabled ? switchedOn.intersection(synced).subtracting(pendingChecks) : []
        return unsent || data.localOnlyCourseNames || (data.holidays && !cloudSyncEnabled)
            || data.categoriesNeeded.contains { $0.held && !$0.categories.isSubset(of: kept) }
    }

    nonisolated static func signOutLeavesSyncedData(
        _ data: SignOutData,
        cloudSyncEnabled: Bool,
        switchedOn: Set<String>,
        synced: Set<String>,
        pendingChecks: Set<String>
    ) -> Bool {
        guard cloudSyncEnabled else { return false }
        let kept = switchedOn.intersection(synced).subtracting(pendingChecks)
        return data.holidays || data.categoriesNeeded.contains { $0.held && $0.categories.isSubset(of: kept) }
    }
}
