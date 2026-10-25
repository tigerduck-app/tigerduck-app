import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    var isNTUSTLoggedIn: Bool { authService.isNTUSTAuthenticated }

    func ntustProtectedAccessState(isEmpty: Bool) -> NTUSTProtectedAccessState {
        if !authService.hasStoredCredentials { return .loginRequired }
        return isEmpty ? .empty : .content
    }

    var ntustReauthErrorMessage: String? { authService.reauthErrorMessage }

    func clearNTUSTReauthError() {
        authService.clearReauthError()
    }

    func presentNTUSTLogin() {
        guard !isShowingNTUSTLoginSheet else { return }
        isShowingNTUSTLoginSheet = true
    }

    func dismissNTUSTLogin() {
        isShowingNTUSTLoginSheet = false
    }

    func openFromWidget(_ destination: WidgetDestination) {
        pendingWidgetDestination = destination
    }

    func clearPendingWidgetDestination() {
        pendingWidgetDestination = nil
    }

    var isLibraryLoggedIn: Bool {
        _ = _libraryRevision
        return LibraryService.hasAccount
    }

    var libraryUsername: String? {
        _ = _libraryRevision
        return LibraryService.storedUsername
    }

    @MainActor
    func logoutLibrary() {
        LibraryService.clearCredentials()
        _libraryRevision += 1
    }

    @discardableResult
    func logoutNTUST() -> Task<Void, Never> {
        stopRevisionPolling()
        _lastKnownRevision = 0
        syncTask?.cancel()
        syncTask = nil
        AppServiceBridge.cancelAssignmentRound()
        #if os(iOS)
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        boundaryRefreshTask?.cancel()
        boundaryRefreshTask = nil
        #endif

        // The order and what each step clears: docs/decisions/0026-one-sign-out-path.md.
        authService.logout()
        let endingSession = Task { await authTokenManager.endSession() }
        Self.forgetAccountOnDevice()
        didSkipMacLogin = false
        syncConflicts = []
        pendingSyncServerArchived = []
        pendingSyncServerCompleted = []
        reenableConflict = nil
        pushCoordinator.forgetUploads()
        cancelHolidayUploads()
        #if os(iOS)
        cancelNotificationSettingsPushes()
        #endif
        cloudSyncEnabled = false
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        return authService.startSignOutCalls { [self] in
            await cloudSyncCoordinator.settleForSignOut()
            await authTokenManager.unregisterDeparting(accessToken: await endingSession.value) {
                await pushCoordinator.disable()
            }
            #if os(iOS)
            await liveActivityCoordinator.endAll()
            #endif
        }
    }

    /// What the device keeps of the school account outside `AppState`, which a sign-out clears
    /// after the account generation has moved. docs/account-state.md lists each store.
    static func forgetAccountOnDevice(cache: DataCache = .shared) {
        LibraryService.schoolAccountDidSignOut()
        ServerStatusTracker.shared.reset()
        Defaults[.schoolDataSyncedAt] = nil
        Defaults[.classTableSelectedSemester] = nil
        Defaults[.emptyClassroomBuilding] = nil
        MoodleFileDownloads.shared.cancelAll()
        cache.clearUserScopedData()
        TigerDuckTheme.reload()
        ImportedClassTableStore.shared.removeAll()
        BulletinsViewModel.forgetListSession()
        forgetSyncProgress()
        AcademicCalendarStore.shared.forgetHolidayOverrides()
    }

    /// A sign-in hands the device on its backend to the new account, so while signed in only a
    /// session kept on another backend still has an unregister to send.
    nonisolated static func retriesDepartingUnregister(onboarded: Bool, signedIn: Bool, keptOn: [URL], backend: URL) -> Bool {
        onboarded && keptOn.contains { !signedIn || !AuthTokenManager.isSameBackend($0, backend) }
    }

    func signOutDeletesUnsyncedData() async -> Bool {
        let cache = DataCache.shared
        let calendar = AcademicCalendarStore.shared
        let names = cache.loadCourseCustomNames()
        let userAdded = cache.loadUserAddedCourses()
        let held = SignOutData(
            courses: !userAdded.isEmpty || !cache.loadDeletedCourseNos().isEmpty,
            courseNames: names.values.contains { !$0.isEmpty },
            localOnlyCourseNames: Self.holdsLocalOnlyCourseNames(
                names, courses: userAdded + SemesterCatalog.availableSemesters().flatMap { cache.loadCourses(semester: $0) }
            ),
            courseColors: !cache.loadPickedCourseColors().isEmpty,
            assignmentMarks: !cache.loadArchivedAssignmentIds().isEmpty
                || !cache.loadLocallyCompletedAssignmentIds().isEmpty,
            ignoredCourses: !cache.loadIgnoredAssignmentCourses().isEmpty,
            holidays: !calendar.optedInHolidayIDs.isEmpty
        )
        let unsent = await cloudSyncCoordinator.holdsUnsentEdits() || pushCoordinator.holdsUnsentCourseUploads
            || !pendingOverrides.isEmpty
            || !calendar.unacknowledgedHolidayIDs.isEmpty
        return Self.signOutDeletesUnsyncedData(
            held,
            cloudSyncEnabled: cloudSyncEnabled,
            switchedOn: Self.switchedOnCategories(),
            synced: Defaults[.categoriesSyncedOnce],
            pendingChecks: Defaults[.pendingConflictCategories],
            unsent: unsent
        )
    }

    /// A course name syncs under its course's Moodle ID, so a name on a course without one,
    /// a hand-added course among them, stays on this device.
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
        let needs: [(held: Bool, categories: Set<String>)] = [
            (data.courses, ["courses"]),
            (data.courseNames, ["course_names"]),
            (data.courseColors, ["course_colors"]),
            (data.assignmentMarks, ["assignments"]),
            (data.ignoredCourses, ["assignments", "courses"]),
        ]
        return unsent || data.localOnlyCourseNames || (data.holidays && !cloudSyncEnabled)
            || needs.contains { $0.held && !$0.categories.isSubset(of: kept) }
    }

    static func forgetSyncProgress() {
        Defaults[.pendingConflictCategories] = []
        Defaults[.assignmentMarksSyncedOnce] = false
        Defaults[.lastSeenCoursesResetAt] = nil
        Defaults[.categoriesSyncedOnce] = []
        Defaults[.courseRowIdsSeen] = [:]
    }

    func notifyLibraryStateChanged() {
        _libraryRevision += 1
    }
}
