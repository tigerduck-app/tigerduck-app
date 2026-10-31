import Defaults
import Foundation
import os
import Testing
@testable import TigerDuck

/// docs/account-state.md lists what these fill; `tools/check_account_state.py` covers a store
/// added later.
@MainActor
@Suite(.serialized)
struct AccountSwitchTests {
    private static let first = "B11000001"
    private static let second = "B11000002"
    private static let semester = "1141"

    enum Account: CaseIterable {
        case school, library
        #if os(iOS)
        case mail
        #endif
    }

    /// Real `Defaults` keys the sign-outs clear, put back after each test.
    private struct SavedDefaults {
        private var restores: [() -> Void] = []

        init() {
            keep(.ntustCredentialsPresent)
            keep(.schoolDataSyncedAt)
            keep(.classTableSelectedSemester)
            keep(.emptyClassroomBuilding)
            keep(.categoriesSyncedOnce)
            keep(.courseRowIdsSeen)
            keep(.pendingConflictCategories)
            keep(.assignmentMarksSyncedOnce)
            keep(.lastSeenCoursesResetAt)
            keep(.holidayNotifyOverrides)
            keep(.holidayOverridesAwaitingUpload)
            keep(.bulletinsSyncedAt)
            keep(.ntustStoredPasswordRefusals)
            keep(.ntustStoredPasswordRefusedAt)
            keep(.libraryStoredPasswordRefusals)
            keep(.libraryStoredPasswordRefusedAt)
            #if os(iOS)
            keep(.browserZoom)
            keep(.browserDesktopSites)
            keep(.browserDataState)
            #endif
        }

        private mutating func keep<Value: Defaults.Serializable>(_ key: Defaults.Key<Value>) {
            let value = Defaults[key]
            restores.append { Defaults[key] = value }
        }

        func restore() {
            restores.forEach { $0() }
        }
    }

    /// Each account's stores, filled in folders of the test's own.
    @MainActor
    private struct Device {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache: DataCache
        let keychain = MemoryKeychain.locked()
        #if os(iOS)
        let mailPrefs = InMemoryMailPreferences()
        let mailSecrets = InMemoryMailSecretStorage()
        let mailCache = SchoolMailTestDoubles.temporaryCache()
        #endif

        init() {
            cache = DataCache(
                cacheDir: root.appendingPathComponent("cache", isDirectory: true),
                persistentDir: root.appendingPathComponent("data", isDirectory: true)
            )
        }

        var storage: AccountStorage {
            #if os(iOS)
            AccountStorage(
                cache: cache, mailPreferences: mailPrefs, mailCredentials: MailCredentialStore(storage: mailSecrets)
            )
            #else
            AccountStorage(cache: cache)
            #endif
        }

        #if os(iOS)
        func mailAccount() -> MailAccountManager {
            MailAccountManager(
                prefs: mailPrefs, credentials: MailCredentialStore(storage: mailSecrets), cache: mailCache,
                isDemoLogin: { _, _ in false }, makeClient: { _ in FakeMailClient() }
            )
        }
        #endif

        var files: [String] {
            let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            return (walk?.allObjects as? [URL] ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map(\.lastPathComponent)
        }

        /// The school account's stores, the imported class tables among them without loading the store.
        func fillSchool() throws {
            cache.saveCourses([], semester: semester)
            cache.saveUserAddedCourses([])
            cache.saveDeletedCourseNos(["CS1001"])
            cache.saveSelectionDroppedNos([semester: ["CS1002"]])
            cache.recordSelectionRoster(semester: semester, roster: ["CS1003"])
            cache.saveCourseCustomNames([semester: ["CS1001": "Mine"]])
            cache.saveCourseColorMap(["CS1001": 0xFF0000])
            cache.savePickedCourseColors(["CS1001"])
            cache.saveAssignments([])
            cache.addArchivedAssignmentId("1")
            cache.addLocallyCompletedAssignmentId("2")
            cache.setAssignmentsIgnored(true, semester: semester, courseNo: "CS1001")
            cache.saveCalendarEvents([
                SDCalendarEvent(eventId: "moodle-1", title: "Quiz", date: Date(), source: .moodle),
            ])
            cache.saveBulletinSummaries([])
            cache.saveMoodleCourseIdMap(["1141CS1001": 7])
            cache.saveMoodleData(["forum"], fetchedAt: Date(), name: "forums-7", account: first)
            try FileManager.default.createDirectory(at: cache.moodleFilesDir, withIntermediateDirectories: true)
            try Data("pdf".utf8).write(to: cache.moodleFilesDir.appendingPathComponent("slides.pdf"))
            try Data("{}".utf8).write(to: cache.persistentDir.appendingPathComponent("imported_class_tables.json"))
            Defaults[.schoolDataSyncedAt] = Date()
            Defaults[.classTableSelectedSemester] = semester
            Defaults[.emptyClassroomBuilding] = "TR"
            Defaults[.categoriesSyncedOnce] = ["courses"]
            Defaults[.courseRowIdsSeen] = [semester: 3]
            Defaults[.pendingConflictCategories] = ["courses"]
            Defaults[.assignmentMarksSyncedOnce] = true
            Defaults[.lastSeenCoursesResetAt] = Date()
            Defaults[.holidayNotifyOverrides] = [12]
            Defaults[.holidayOverridesAwaitingUpload] = [12]
            Defaults[.bulletinsSyncedAt] = Date()
            SSOLoginService.storedPasswordRefusals = (1, Date())
            #if os(iOS)
            Defaults[.browserZoom] = ["moodle2.ntust.edu.tw": 120]
            Defaults[.browserDesktopSites] = ["moodle2.ntust.edu.tw"]
            #endif
        }

        func schoolIsEmpty() -> Bool {
            var empty = files.isEmpty && cache.loadDeletedCourseNos().isEmpty && cache.loadMoodleCourseIdMap().isEmpty
                && Defaults[.schoolDataSyncedAt] == nil && Defaults[.classTableSelectedSemester] == nil
                && Defaults[.emptyClassroomBuilding] == nil && Defaults[.categoriesSyncedOnce].isEmpty
                && Defaults[.courseRowIdsSeen].isEmpty && Defaults[.pendingConflictCategories].isEmpty
                && !Defaults[.assignmentMarksSyncedOnce] && Defaults[.lastSeenCoursesResetAt] == nil
                && Defaults[.holidayNotifyOverrides].isEmpty && Defaults[.holidayOverridesAwaitingUpload].isEmpty
                && Defaults[.bulletinsSyncedAt] == nil && SSOLoginService.storedPasswordRefusals.count == 0
            #if os(iOS)
            empty = empty && Defaults[.browserZoom].isEmpty && Defaults[.browserDesktopSites].isEmpty
            #endif
            return empty
        }

        func schoolIsKept() -> Bool {
            files.contains("imported_class_tables.json") && files.contains("slides.pdf")
                && cache.loadDeletedCourseNos() == ["CS1001"] && Defaults[.classTableSelectedSemester] == semester
                && Defaults[.holidayNotifyOverrides] == [12] && Defaults[.bulletinsSyncedAt] != nil
                && SSOLoginService.storedPasswordRefusals.count == 1
        }

        func fillLibrary() {
            KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryUsername, value: "lib-user")
            KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryPassword, value: "lib-password")
            KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryToken, value: "lib-token")
            KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryTokenExpiry, value: "4102444800000")
            LibraryService.storedPasswordRefusals = (2, Date())
        }

        func libraryIsEmpty() -> Bool {
            LibraryService.storedUsername == nil && LibraryService.storedToken == nil
                && LibraryService.storedPasswordIfAvailable() == nil && LibraryService.storedTokenExpiry == nil
                && LibraryService.storedPasswordRefusals.count == 0
        }

        func libraryIsKept() -> Bool {
            LibraryService.storedUsername == "lib-user" && LibraryService.storedToken == "lib-token"
                && LibraryService.storedPasswordRefusals.count == 2
        }

        #if os(iOS)
        func fillMail() throws {
            mailPrefs.studentID = first
            mailPrefs.inboxNextUID = 4
            try mailSecrets.save("mail-password", forKey: MailCredentialStore.passwordKey)
            mailCache.savePage(MailFolderPage(
                folder: "INBOX", uidValidity: 1, messageCount: 0, summaries: [], oldestLoadedSequence: nil
            ))
        }

        func mailIsEmpty() -> Bool {
            mailPrefs.studentID == nil && mailPrefs.inboxNextUID == nil
                && mailSecrets.load(forKey: MailCredentialStore.passwordKey) == nil
                && mailCache.loadPage(folder: "INBOX") == nil
        }

        func mailIsKept() -> Bool {
            mailPrefs.studentID == first && mailPrefs.inboxNextUID == 4
                && mailSecrets.load(forKey: MailCredentialStore.passwordKey) == "mail-password"
                && mailCache.loadPage(folder: "INBOX") != nil
        }
        #endif
    }

    private static func auth(
        schoolSignIns: OSAllocatedUnfairLock<[String]> = .init(initialState: []),
        moodleToken: OSAllocatedUnfairLock<String?> = .init(initialState: nil)
    ) -> AuthService {
        let auth = AuthService(
            keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(),
            moodleTokens: MoodleTokenService(
                storedCredentials: { nil },
                tokens: .init(
                    load: { moodleToken.withLock { $0 } },
                    save: { triple in moodleToken.withLock { $0 = triple.wstoken } },
                    drop: { moodleToken.withLock { $0 = nil } }
                ),
                harvest: { studentId, _ in .init(signature: "", wstoken: "token-\(studentId)", privatetoken: nil) }
            ),
            schoolSignIn: { studentId, _ in
                schoolSignIns.withLock { $0.append(studentId) }
                return true
            },
            endSchoolSession: { _ in }
        )
        #if os(iOS)
        auth.accountNotifications = DeliveredNotificationsStub([("reminder-1", "assignments")])
        #endif
        auth.beginSignOutBackgroundTask = { {} }
        return auth
    }

    /// The school plan without what `AppState` adds, which these tests do not build.
    private static func schoolSignOut(_ auth: AuthService) -> SignOutPlan {
        SignOutPlan(session: auth.session, stores: SignOutPlan.schoolStores, endSession: {
            auth.logout()
            return { auth.startSignOutCalls {} }
        })
    }

    @Test("signing in as a second student after a first leaves nothing of the first")
    func aSecondAccountFindsNothingOfTheFirst() async throws {
        try await withExclusiveRealDefaults {
            let saved = SavedDefaults()
            defer { saved.restore() }
            let device = Device()
            defer { try? FileManager.default.removeItem(at: device.root) }
            let moodleToken = OSAllocatedUnfairLock<String?>(initialState: nil)
            let signedIn = OSAllocatedUnfairLock<[String]>(initialState: [])
            let auth = Self.auth(schoolSignIns: signedIn, moodleToken: moodleToken)
            auth.signOutStoredAccount = { await Self.schoolSignOut(auth).run(in: device.storage)?.value }

            try await SecureStore.$sharedForTesting.withValue(device.keychain) {
                #expect(await auth.login(studentId: Self.first, password: "first-password"))
                let firstSignIn = auth.session.ticket
                try device.fillSchool()
                #expect(device.schoolIsKept())
                #if os(iOS)
                let browserEpoch = BrowserData.shared.epoch
                #endif

                #expect(await auth.login(studentId: Self.second, password: "second-password"))

                #expect(signedIn.withLock { $0 } == [Self.first, Self.second])
                #expect(!auth.session.isCurrent(firstSignIn))
                #expect(auth.storedStudentId == Self.second)
                #expect(auth.storedPassword == "second-password")
                #expect(moodleToken.withLock { $0 } == "token-\(Self.second)")
                #expect(device.schoolIsEmpty())
                #if os(iOS)
                #expect((auth.accountNotifications as? DeliveredNotificationsStub)?.delivered.isEmpty == true)
                // Dropped at the sign-out and again at the sign-in.
                #expect(BrowserData.shared.epoch >= browserEpoch + 2)
                #endif
            }
        }
    }

    @Test("a sign-in right after a sign-out waits for the calls of the sign-out's last step")
    func aSignInWaitsForTheSignOutsCalls() async throws {
        try await withExclusiveRealDefaults {
            let saved = SavedDefaults()
            defer { saved.restore() }
            let device = Device()
            defer { try? FileManager.default.removeItem(at: device.root) }
            let signedIn = OSAllocatedUnfairLock<[String]>(initialState: [])
            let auth = Self.auth(schoolSignIns: signedIn)
            let (unregistered, unregister) = AsyncStream<Void>.makeStream()
            let callsBegan = OSAllocatedUnfairLock(initialState: false)

            try await SecureStore.$sharedForTesting.withValue(device.keychain) {
                #expect(await auth.login(studentId: Self.first, password: "first-password"))
                SignOutPlan(session: auth.session, stores: SignOutPlan.schoolStores, endSession: {
                    auth.logout()
                    return {
                        auth.startSignOutCalls {
                            callsBegan.withLock { $0 = true }
                            for await _ in unregistered {}
                        }
                    }
                }).run(in: device.storage)

                let signingIn = Task { @MainActor in
                    await SecureStore.$sharedForTesting.withValue(device.keychain) {
                        await auth.login(studentId: Self.second, password: "second-password")
                    }
                }
                try await waitUntil { auth.isLoggingIn && callsBegan.withLock { $0 } }
                try await Task.sleep(for: .milliseconds(100))
                #expect(signedIn.withLock { $0 } == [Self.first])

                unregister.finish()
                #expect(await signingIn.value)
                #expect(signedIn.withLock { $0 } == [Self.first, Self.second])
            }
        }
    }

    @Test("a sign-out empties every store of its account, ones this process never loaded too, and keeps the others'",
          arguments: Account.allCases)
    func aSignOutKeepsTheOtherAccounts(account: Account) async throws {
        try await withExclusiveRealDefaults {
            let saved = SavedDefaults()
            defer { saved.restore() }
            let device = Device()
            defer { try? FileManager.default.removeItem(at: device.root) }
            let auth = Self.auth()

            try await SecureStore.$sharedForTesting.withValue(device.keychain) {
                #expect(await auth.login(studentId: Self.first, password: "first-password"))
                try device.fillSchool()
                device.fillLibrary()
                #if os(iOS)
                try device.fillMail()
                let mail = device.mailAccount()
                #endif

                switch account {
                case .school:
                    await Self.schoolSignOut(auth).run(in: device.storage)?.value
                case .library:
                    LibraryService.clearCredentials()
                #if os(iOS)
                case .mail:
                    mail.logout()
                    await mail.pendingCacheClear?.value
                #endif
                }

                #expect((auth.storedStudentId == nil) == (account == .school))
                #expect(account == .school ? device.schoolIsEmpty() : device.schoolIsKept())
                #expect(account == .library ? device.libraryIsEmpty() : device.libraryIsKept())
                #if os(iOS)
                #expect(account == .mail ? device.mailIsEmpty() : device.mailIsKept())
                #endif
            }
        }
    }
}
