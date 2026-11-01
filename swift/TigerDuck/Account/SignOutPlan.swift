import Foundation

protocol AccountScoped {
    static func forgetAccount(in storage: AccountStorage)
}

struct AccountStorage {
    var folders: CacheFolders = .app
    #if os(iOS)
    var mailPreferences: any MailPreferences = MailSettingsStore.shared
    var mailCredentials = MailCredentialStore()
    #endif
}

struct SignOutPlan {
    let session: AccountSession
    let stores: [any AccountScoped.Type]
    var stopWork: () -> Void = {}
    var endSession: () -> () -> Task<Void, Never>? = { { nil } }
    var clearRest: () -> Void = {}

    @discardableResult
    func run(in storage: AccountStorage = AccountStorage()) -> Task<Void, Never>? {
        session.stopWork()
        stopWork()
        session.moveOn()
        let startCalls = endSession()
        for store in stores {
            store.forgetAccount(in: storage)
        }
        clearRest()
        return startCalls()
    }
}

extension SignOutPlan {
    static let schoolStores: [any AccountScoped.Type] = {
        var stores: [any AccountScoped.Type] = [
            SchoolAccountKeys.self, CourseFiles.self, CourseColorFiles.self, AssignmentFiles.self,
            CalendarEventFiles.self, BulletinFiles.self, ScoreReportFiles.self, MoodleFiles.self,
            ImportedClassTableStore.self, BulletinsViewModel.self, AcademicCalendarStore.self,
        ]
        #if os(iOS)
        stores.append(BrowserData.self)
        #endif
        return stores
    }()

    static let libraryStores: [any AccountScoped.Type] = [LibraryService.self]

    #if os(iOS)
    static let mailStores: [any AccountScoped.Type] = [MailCredentialStore.self, MailSettingsStore.self]
    #endif

    static func school(_ app: AppEnvironment) -> SignOutPlan {
        let auth = app.authService
        let tokens = app.authTokenManager
        return SignOutPlan(
            session: auth.session,
            stores: schoolStores,
            stopWork: {
                app.feed.stopPolling()
                app.feed.lastKnownRevision = 0
                app.activation.cancelRefresh()
                AssignmentFetch.cancelAssignmentRound()
                MoodleFileDownloads.shared.cancelAll()
                app.holidays.cancelUploads()
                #if os(iOS)
                app.liveActivity.cancelRefreshes()
                #endif
            },
            endSession: {
                auth.logout()
                let backend = tokens.beginSignOut()
                let ending = Task { await tokens.endSession(on: backend) }
                return {
                    auth.startSignOutCalls {
                        await app.cloudSyncCoordinator.settleForSignOut()
                        await tokens.unregisterDeparting(as: await ending.value) { await app.pushCoordinator.disable() }
                        #if os(iOS)
                        await app.liveActivity.coordinator.endAll()
                        #endif
                    }
                }
            },
            clearRest: {
                LibraryService.schoolAccountDidSignOut()
                ServerStatusTracker.shared.reset()
                TigerDuckTheme.reload()
                CourseStore.shared.noteChange()
                AssignmentStore.shared.noteChange()
                ImportedClassTableStore.shared.removeAll()
                app.didSkipMacLogin = false
                app.conflicts.syncConflicts = []
                app.syncTarget.signedOut()
                app.conflicts.reenableConflict = nil
                app.pushCoordinator.forgetUploads()
                #if os(iOS)
                app.notificationSettings.cancelPushes()
                #endif
                app.cloudSyncEnabled = false
            }
        )
    }
}
