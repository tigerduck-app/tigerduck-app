import Foundation

/// What a launch, a return to the foreground and a sign-in start.
@MainActor
final class SceneActivation {
    private unowned let app: AppEnvironment
    private var refreshTask: Task<Void, Never>?
    private var returnTask: Task<Void, Never>?

    init(app: AppEnvironment) {
        self.app = app
    }

    /// The first scene of a launch.
    func sceneAppeared() {
        refresh()
        startCloudSyncIfEnabled()
        #if os(iOS)
        Task { await LibraryService.signInIfCredentialed() }
        #endif
        app.updateNotifyCoordinator.checkInBackground()
    }

    func becameActive() {
        Task { await CourseChangeStore.shared.refresh() }
        returnTask?.cancel()
        returnTask = Task { [app] in
            #if os(iOS)
            await app.liveActivity.refresh()
            guard !Task.isCancelled else { return }
            #endif
            app.pushSchedule.requestSync()
            await app.pushSchedule.refreshMoodleCredentials()
        }
        refreshOnReturn()
        #if os(iOS)
        Task { await LibraryService.signInIfCredentialed() }
        #endif
        app.pushCoordinator.registerAgainIfGaveUp()
        app.updateNotifyCoordinator.checkInBackground()
    }

    func enteredBackground() {
        app.feed.stopPolling()
    }

    func startCloudSyncIfEnabled() {
        if app.cloudSyncCoordinator.state == .active {
            app.cloudSyncCoordinator.start()
        }
    }

    /// The full refresh of a launch, the end of onboarding and a sign-in: a full sync, and every
    /// school source.
    func refresh(recheckSubmissions: Bool = false) {
        guard app.hasCompletedOnboarding else { return }
        app.feed.startPolling(pollNow: false)
        // The first scene of a launch, and the end of onboarding, bring no scene-active refresh.
        Task { await CourseChangeStore.shared.refresh() }
        refreshTask?.cancel()
        refreshTask = Task { [app] in
            // Behind a captive Wi-Fi login page the link is "satisfied" but egress is blocked, and
            // the pinned NTUST hosts would fail with an ATS error; say "no internet" instead.
            guard await NetworkMonitor.shared.isReachable() else {
                NTUSTSessionManager.shared.loadingState = .error(String(localized: "error_network_unavailable"))
                return
            }
            NTUSTSessionManager.shared.loadingState = .loading
            if recheckSubmissions { MoodleEnrolledCoursesService.dropSharedAnswer() }
            _ = await AssignmentFetch.fetchAssignments(
                authService: app.authService, recheckSubmissions: recheckSubmissions
            )
            await app.fullSync.sync(followUpIfBusy: true)
            async let schoolEvents = CalendarService.fetchAndParseICS()
            async let courses: Void = Self.fetchCurrentTerm(app.authService)
            let fetchedSchoolEvents = await schoolEvents
            await courses
            guard !Task.isCancelled else { return }
            if let fetchedSchoolEvents {
                var calendarCache = AssignmentStore.shared.loadCalendarEvents()
                calendarCache.removeAll { $0.source == .school }
                calendarCache.append(contentsOf: fetchedSchoolEvents)
                AssignmentStore.shared.saveCalendarEvents(calendarCache)
            }
            NTUSTSessionManager.shared.loadingState = .loaded
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refreshOnReturn() {
        if app.hasCompletedOnboarding {
            Task { [app] in await AssignmentFetch.refreshAssignmentsIfDue(authService: app.authService) }
        }
        app.feed.startPolling()
    }

    private static func fetchCurrentTerm(_ authService: AuthService) async {
        guard let studentId = authService.storedStudentId else { return }
        let semester = CourseSelectionService.currentSemesterCode()
        if CourseSelectionService.needsSchoolSession(studentId: studentId, semester: semester) {
            guard await authService.ensureAuthenticated() else { return }
        } else {
            await authService.ensureBackendSignedIn()
        }
        _ = await CourseFetch.fetchCourses(authService: authService, semester: semester)
    }
}
