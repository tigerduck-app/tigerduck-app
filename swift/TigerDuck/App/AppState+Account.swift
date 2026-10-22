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

        let departingStudentId = authService.storedStudentId
        authService.logout()
        if let departingStudentId, LibraryService.clearCredentials(ifSchoolAccount: departingStudentId) {
            _libraryRevision += 1
        }
        #if os(iOS)
        if let departingStudentId { MailAccountManager.shared.logout(ifSchoolAccount: departingStudentId) }
        #endif
        let endingSession = Task { await authTokenManager.endSession() }
        ServerStatusTracker.shared.reset()
        Defaults[.schoolDataSyncedAt] = nil
        Defaults[.classTableSelectedSemester] = nil
        Defaults[.emptyClassroomBuilding] = nil
        didSkipMacLogin = false
        MoodleFileDownloads.shared.cancelAll()
        DataCache.shared.clearUserScopedData()
        TigerDuckTheme.reload()
        ImportedClassTableStore.shared.removeAll()
        BulletinsViewModel.forgetListSession()
        syncConflicts = []
        pendingSyncServerArchived = []
        pendingSyncServerCompleted = []
        reenableConflict = nil
        Self.forgetSyncProgress()
        pushCoordinator.forgetUploads()
        cancelHolidayUploads()
        AcademicCalendarStore.shared.forgetHolidayOverrides()
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

    nonisolated static func retriesDepartingUnregister(onboarded: Bool, signedIn: Bool, sessionKept: Bool) -> Bool {
        onboarded && !signedIn && sessionKept
    }

    func signOutDeletesUnsyncedData() async -> Bool {
        let cache = DataCache.shared
        let calendar = AcademicCalendarStore.shared
        let held = SignOutData(
            courses: !cache.loadUserAddedCourses().isEmpty || !cache.loadDeletedCourseNos().isEmpty,
            courseNames: cache.loadCourseCustomNames().values.contains { !$0.isEmpty },
            courseColors: !cache.loadPickedCourseColors().isEmpty,
            assignmentMarks: !cache.loadArchivedAssignmentIds().isEmpty
                || !cache.loadLocallyCompletedAssignmentIds().isEmpty,
            ignoredCourses: !cache.loadIgnoredAssignmentCourses().isEmpty,
            holidays: !calendar.optedInHolidayIDs.isEmpty
        )
        let unsent = await cloudSyncCoordinator.holdsUnsentEdits() || !pendingOverrides.isEmpty
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

    nonisolated struct SignOutData {
        var courses = false
        var courseNames = false
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
        return unsent || (data.holidays && !cloudSyncEnabled)
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
