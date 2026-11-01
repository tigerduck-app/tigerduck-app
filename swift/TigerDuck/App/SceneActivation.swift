import Foundation

@MainActor
final class SceneActivation {
    private unowned let app: AppEnvironment
    private var refreshTask: Task<Void, Never>?
    private var returnTask: Task<Void, Never>?

    init(app: AppEnvironment) {
        self.app = app
    }

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
            await app.authService.session.withSignIn { await app.pushSchedule.refreshMoodleCredentials(for: $0) }
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

    func refresh(recheckSubmissions: Bool = false) {
        guard app.hasCompletedOnboarding else { return }
        app.feed.startPolling(pollNow: false)
        Task { await CourseChangeStore.shared.refresh() }
        refreshTask?.cancel()
        let signIn = app.authService.session.currentSignIn
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
                fetchSchool: {
                    await Self.fetchSchoolData(app.authService, recheckSubmissions, afterBackendPull: $0, for: signIn)
                }
            )
            guard !Task.isCancelled else { return }
            NTUSTSessionManager.shared.loadingState = .loaded
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refreshOnReturn() {
        guard app.hasCompletedOnboarding else {
            app.feed.startPolling()
            return
        }
        let signIn = app.authService.session.currentSignIn
        Task { [app] in
            await RefreshOrder.run(
                pull: { await app.feed.pollOnReturn() },
                pushOutbox: { await app.cloudSyncCoordinator.syncTick() },
                fetchSchool: {
                    await AssignmentFetch.refreshAssignmentsIfDue(authService: app.authService, afterBackendPull: $0, for: signIn)
                }
            )
        }
    }

    private static func fetchSchoolData(
        _ authService: AuthService, _ recheckSubmissions: Bool, afterBackendPull: @escaping PullGate, for signIn: SignIn
    ) async {
        _ = await AssignmentFetch.fetchAssignments(
            authService: authService, recheckSubmissions: recheckSubmissions, afterBackendPull: afterBackendPull, for: signIn
        )
        async let schoolEvents = CalendarService.fetchAndParseICS()
        async let courses: Void = fetchCurrentTerm(authService, afterBackendPull: afterBackendPull, for: signIn)
        let fetchedSchoolEvents = await schoolEvents
        await courses
        guard !Task.isCancelled, let fetchedSchoolEvents else { return }
        var calendarCache = AssignmentStore.shared.loadCalendarEvents()
        calendarCache.removeAll { $0.source == .school }
        calendarCache.append(contentsOf: fetchedSchoolEvents)
        AssignmentStore.shared.saveCalendarEvents(calendarCache, for: signIn)
    }

    private static func fetchCurrentTerm(
        _ authService: AuthService, afterBackendPull: @escaping PullGate, for signIn: SignIn
    ) async {
        guard let studentId = authService.storedStudentId else { return }
        let semester = CourseSelectionService.currentSemesterCode()
        if CourseSelectionService.needsSchoolSession(studentId: studentId, semester: semester) {
            guard await authService.ensureAuthenticated(for: signIn) else { return }
        } else {
            await authService.ensureBackendSignedIn()
        }
        _ = await CourseFetch.fetchCourses(authService: authService, semester: semester, afterBackendPull: afterBackendPull, for: signIn)
    }
}

enum RefreshOrder {
    static func run(
        pull: @escaping @MainActor () async -> Void,
        pushOutbox: @escaping @MainActor () async -> Void,
        fetchSchool: @MainActor (_ afterBackendPull: @escaping PullGate) async -> Void
    ) async {
        let pulled = Task { @MainActor () -> PullOutcome in
            await pull()
            let outcome: PullOutcome = Task.isCancelled ? .cancelled : .completed
            await pushOutbox()
            return outcome
        }
        await withTaskCancellationHandler {
            await fetchSchool { await pulled.value }
            await pulled.value
        } onCancel: {
            pulled.cancel()
        }
    }
}
