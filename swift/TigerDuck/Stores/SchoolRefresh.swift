import Foundation

/// The school fetches a screen starts, and NTUST's loading state while they run. Each fetch saves
/// what it got in its store, which the screens observe.
enum SchoolRefresh {
    /// Shows the loading state; false, with the offline error shown instead, without a network.
    static func begin() async -> Bool {
        guard await NetworkMonitor.shared.isReachable() else {
            showOffline()
            return false
        }
        NTUSTSessionManager.shared.loadingState = .loading
        return true
    }

    static func showOffline() {
        NTUSTSessionManager.shared.loadingState = .error(String(localized: "error_network_unavailable"))
    }

    static func end() {
        NTUSTSessionManager.shared.loadingState = .loaded
    }

    /// The next fetch asks Moodle for the enrolled courses again instead of sharing the last answer.
    static func dropMoodleCourses() {
        MoodleEnrolledCoursesService.dropSharedAnswer()
    }

    /// The assignments, with each submission's status asked again.
    @discardableResult
    static func assignments(authService: AuthService) async -> [SDAssignment] {
        await AssignmentFetch.fetchAssignments(authService: authService, recheckSubmissions: true)
    }

    /// The assignments as the calendar's Moodle rows.
    static func moodleEvents(authService: AuthService) async -> [SDCalendarEvent] {
        await assignments(authService: authService).map(AssignmentRecords.moodleCalendarEvent)
    }

    /// The school calendar's events; nil when the fetch fails.
    static func schoolEvents() async -> [SDCalendarEvent]? {
        await CalendarService.fetchAndParseICS()
    }

    static func courses(_ semester: String, authService: AuthService, force: Bool = false) async {
        _ = await CourseFetch.fetchCourses(authService: authService, semester: semester, forceRefresh: force)
    }

    /// Fetches every term on offer whose courses are not stored yet.
    static func allTerms(authService: AuthService) async {
        await CourseFetch.warmAllSemesterCaches(authService: authService)
    }

    static func userAddedCourses(_ semester: String, authService: AuthService) async {
        _ = await CourseDetails.refreshUserAddedCourses(semester: semester, authService: authService)
    }

    static func coursesMissingClassroom(_ semester: String, authService: AuthService) async {
        _ = await CourseDetails.refreshCoursesMissingClassroom(semester: semester, authService: authService)
    }

    static func courseChanges() async {
        _ = await CourseChangeStore.shared.refresh()
    }

    /// Course names come in the new language from the next fetch on.
    static func languageChanged() {
        CourseFetch.handleLanguageChange()
    }

    /// An imported term's courses looked up again; nil when the lookup fails.
    static func importedTerm(semester: String, courseNos: [String], current: [SDCourse]) async -> [SDCourse]? {
        await CourseDetails.refreshImportedCourses(semester: semester, courseNos: courseNos, current: current)
    }

    static func importedCourses(semester: String, courseNos: [String]) async throws -> [SDCourse] {
        try await CourseDetails.importedCourses(semester: semester, courseNos: courseNos)
    }
}
