import Foundation

/// What a launch, a return to the foreground and a sign-in start. Each runs one ordered refresh
/// (`RefreshOrder`): school data is applied after the backend pull, and uploaded after that.
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
            await RefreshOrder.run(
                pull: { await app.fullSync.sync(followUpIfBusy: true) },
                pushOutbox: { await app.cloudSyncCoordinator.syncTick() },
                fetchSchool: { await Self.fetchSchoolData(app.authService, recheckSubmissions, applyAfter: $0) }
            )
            guard !Task.isCancelled else { return }
            NTUSTSessionManager.shared.loadingState = .loaded
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// A return reads the revision, and the change feed or a full sync when it moved.
    private func refreshOnReturn() {
        guard app.hasCompletedOnboarding else {
            app.feed.startPolling()
            return
        }
        Task { [app] in
            await RefreshOrder.run(
                pull: { await app.feed.pollOnReturn() },
                pushOutbox: { await app.cloudSyncCoordinator.syncTick() },
                fetchSchool: { await AssignmentFetch.refreshAssignmentsIfDue(authService: app.authService, applyAfter: $0) }
            )
        }
    }

    private static func fetchSchoolData(
        _ authService: AuthService, _ recheckSubmissions: Bool, applyAfter: @escaping PullGate
    ) async {
        _ = await AssignmentFetch.fetchAssignments(
            authService: authService, recheckSubmissions: recheckSubmissions, applyAfter: applyAfter
        )
        async let schoolEvents = CalendarService.fetchAndParseICS()
        async let courses: Void = fetchCurrentTerm(authService, applyAfter: applyAfter)
        let fetchedSchoolEvents = await schoolEvents
        await courses
        guard !Task.isCancelled, let fetchedSchoolEvents else { return }
        var calendarCache = AssignmentStore.shared.loadCalendarEvents()
        calendarCache.removeAll { $0.source == .school }
        calendarCache.append(contentsOf: fetchedSchoolEvents)
        AssignmentStore.shared.saveCalendarEvents(calendarCache)
    }

    private static func fetchCurrentTerm(
        _ authService: AuthService, applyAfter: @escaping PullGate
    ) async {
        guard let studentId = authService.storedStudentId else { return }
        let semester = CourseSelectionService.currentSemesterCode()
        if CourseSelectionService.needsSchoolSession(studentId: studentId, semester: semester) {
            guard await authService.ensureAuthenticated() else { return }
        } else {
            await authService.ensureBackendSignedIn()
        }
        _ = await CourseFetch.fetchCourses(authService: authService, semester: semester, applyAfter: applyAfter)
    }
}

/// One refresh in order: the pull and the school fetch start together, the fetch applies its
/// result once the pull and the outbox send after it are done, and its uploads go after that
/// (`SyncTarget` holds them until this sign-in's first pull). A cancelled pull applies nothing.
enum RefreshOrder {
    static func run(
        pull: @escaping @MainActor () async -> Void,
        pushOutbox: @escaping @MainActor () async -> Void,
        fetchSchool: @MainActor (_ applyAfter: @escaping PullGate) async -> Void
    ) async {
        let pulled = Task { @MainActor () -> Bool in
            await pull()
            let completed = !Task.isCancelled
            await pushOutbox()
            return completed
        }
        await withTaskCancellationHandler {
            await fetchSchool { await pulled.value }
            await pulled.value
        } onCancel: {
            pulled.cancel()
        }
    }
}
