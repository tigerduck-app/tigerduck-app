import Foundation

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

    static func dropMoodleCourses() {
        MoodleEnrolledCoursesService.dropSharedAnswer()
    }

    @discardableResult
    static func assignments(authService: AuthService, for signIn: SignIn) async -> [SDAssignment] {
        await AssignmentFetch.fetchAssignments(authService: authService, recheckSubmissions: true, for: signIn)
    }

    static func moodleEvents(authService: AuthService, for signIn: SignIn) async -> [SDCalendarEvent] {
        await assignments(authService: authService, for: signIn).map(AssignmentRecords.moodleCalendarEvent)
    }

    /// The school calendar's events; nil when the fetch fails.
    static func schoolEvents() async -> [SDCalendarEvent]? {
        await CalendarService.fetchAndParseICS()
    }

    static func courses(_ semester: String, authService: AuthService, force: Bool = false, for signIn: SignIn) async {
        _ = await CourseFetch.fetchCourses(authService: authService, semester: semester, forceRefresh: force, for: signIn)
    }

    static func missingTerms(authService: AuthService, for signIn: SignIn) async {
        await CourseFetch.warmAllSemesterCaches(authService: authService, for: signIn)
    }

    static func userAddedCourses(_ semester: String, for signIn: SignIn) async {
        _ = await CourseDetails.refreshUserAddedCourses(semester: semester, for: signIn)
    }

    static func coursesMissingClassroom(_ semester: String, for signIn: SignIn) async {
        _ = await CourseDetails.refreshCoursesMissingClassroom(semester: semester, for: signIn)
    }

    /// The club activity feed and, once its `max-age` has passed, the club directory; nothing while
    /// the account subscribes to no club.
    static func clubActivities(
        subscriptions: ClubSubscriptions = .shared, activities: ClubActivities = .shared, directory: ClubDirectory = .shared
    ) async {
        guard subscriptions.hasSubscriptions else { return }
        async let feed: Void = activities.refresh()
        await directory.refresh()
        await feed
    }

    static func courseChanges() async {
        _ = await CourseChangeStore.shared.refresh()
    }

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
