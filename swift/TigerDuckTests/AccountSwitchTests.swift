import Defaults
import Foundation
import os
import Testing
@testable import TigerDuck

/// docs/account-state.md lists what these fill; `tools/check_account_state.py` covers a store
/// added later.
@MainActor
struct AccountSwitchTests {
    private static let first = "B11000001"
    private static let second = "B11000002"
    private static let semester = "1141"

    private static func fill(_ cache: DataCache) throws {
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
        cache.saveCalendarEvents([SDCalendarEvent(eventId: "moodle-1", title: "Quiz", date: Date(), source: .moodle)])
        cache.saveBulletinSummaries([])
        cache.saveMoodleCourseIdMap(["1141CS1001": 7])
        cache.saveMoodleData(["forum"], fetchedAt: Date(), name: "forums-7", account: first)
        try FileManager.default.createDirectory(at: cache.moodleFilesDir, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: cache.moodleFilesDir.appendingPathComponent("slides.pdf"))
    }

    private static func files(under root: URL) -> [String] {
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return (walk?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent)
    }

    @Test("signing in as a second student after a first leaves nothing of the first")
    func aSecondAccountFindsNothingOfTheFirst() async throws {
        try await withExclusiveRealDefaults {
            let saved = (
                Defaults[.ntustCredentialsPresent], Defaults[.schoolDataSyncedAt], Defaults[.classTableSelectedSemester],
                Defaults[.emptyClassroomBuilding], Defaults[.categoriesSyncedOnce], Defaults[.courseRowIdsSeen],
                Defaults[.holidayNotifyOverrides], SSOLoginService.storedPasswordRefusals
            )
            defer {
                Defaults[.ntustCredentialsPresent] = saved.0
                Defaults[.schoolDataSyncedAt] = saved.1
                Defaults[.classTableSelectedSemester] = saved.2
                Defaults[.emptyClassroomBuilding] = saved.3
                Defaults[.categoriesSyncedOnce] = saved.4
                Defaults[.courseRowIdsSeen] = saved.5
                Defaults[.holidayNotifyOverrides] = saved.6
                SSOLoginService.storedPasswordRefusals = saved.7
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = DataCache(
                cacheDir: root.appendingPathComponent("cache", isDirectory: true),
                persistentDir: root.appendingPathComponent("data", isDirectory: true)
            )
            let moodleToken = OSAllocatedUnfairLock<String?>(initialState: nil)
            let signedIn = OSAllocatedUnfairLock<[String]>(initialState: [])
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
                    signedIn.withLock { $0.append(studentId) }
                    return true
                },
                endSchoolSession: { _ in }
            )
            #if os(iOS)
            auth.accountNotifications = DeliveredNotificationsStub([("reminder-1", "assignments")])
            #endif
            auth.beginSignOutBackgroundTask = { {} }
            auth.signOutStoredAccount = {
                auth.logout()
                AppState.forgetAccountOnDevice(cache: cache)
                await auth.startSignOutCalls {}.value
            }
            let keychain = MemoryKeychain.locked()

            try await SecureStore.$sharedForTesting.withValue(keychain) {
                #expect(await auth.login(studentId: Self.first, password: "first-password"))
                let firstGeneration = auth.loginGeneration
                try Self.fill(cache)
                Defaults[.schoolDataSyncedAt] = Date()
                Defaults[.classTableSelectedSemester] = Self.semester
                Defaults[.emptyClassroomBuilding] = "TR"
                Defaults[.categoriesSyncedOnce] = ["courses"]
                Defaults[.courseRowIdsSeen] = [Self.semester: 3]
                Defaults[.holidayNotifyOverrides] = [12]
                SSOLoginService.storedPasswordRefusals = (1, Date())
                #expect(!Self.files(under: root).isEmpty)

                #expect(await auth.login(studentId: Self.second, password: "second-password"))

                #expect(signedIn.withLock { $0 } == [Self.first, Self.second])
                #expect(auth.loginGeneration != firstGeneration)
                #expect(auth.storedStudentId == Self.second)
                #expect(auth.storedPassword == "second-password")
                #expect(moodleToken.withLock { $0 } == "token-\(Self.second)")
                #expect(Self.files(under: root).isEmpty)
                #expect(cache.loadDeletedCourseNos().isEmpty)
                #expect(cache.loadMoodleCourseIdMap().isEmpty)
                #expect(Defaults[.schoolDataSyncedAt] == nil)
                #expect(Defaults[.classTableSelectedSemester] == nil)
                #expect(Defaults[.emptyClassroomBuilding] == nil)
                #expect(Defaults[.categoriesSyncedOnce].isEmpty)
                #expect(Defaults[.courseRowIdsSeen].isEmpty)
                #expect(Defaults[.holidayNotifyOverrides].isEmpty)
                #expect(SSOLoginService.storedPasswordRefusals.count == 0)
                #if os(iOS)
                #expect((auth.accountNotifications as? DeliveredNotificationsStub)?.delivered.isEmpty == true)
                #endif
            }
        }
    }
}
