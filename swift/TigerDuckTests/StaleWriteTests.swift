import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct StaleWriteTests {
    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        lazy var cache = TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("data", isDirectory: true)
        )

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let course = SDCourse(courseNo: "CS1001301", courseName: "Algorithms", semester: "1151")

    @Test("Courses read for a sign-in that has ended are not saved, and those of the current one are")
    func courses() {
        let folder = Folder()

        #expect(!folder.cache.courses.saveCourses([Self.course], semester: "1151", for: endedTestSignIn))
        #expect(folder.cache.courses.loadCourses(semester: "1151").isEmpty)
        #expect(folder.cache.courses.saveCourses([Self.course], semester: "1151", for: testSignIn))
        #expect(folder.cache.courses.loadCourses(semester: "1151").map(\.courseNo) == ["CS1001301"])
    }

    @Test("Assignments read for a sign-in that has ended are not saved")
    func assignments() {
        let folder = Folder()
        let assignment = SDAssignment(assignmentId: "701", courseNo: "CS1001301", courseName: "Algorithms", title: "HW", dueDate: Date())

        #expect(!folder.cache.assignments.saveAssignments([assignment], for: endedTestSignIn))
        #expect(folder.cache.assignments.loadAssignments().isEmpty)
        #expect(folder.cache.assignments.saveAssignments([assignment], for: testSignIn))
        #expect(folder.cache.assignments.loadAssignments().map(\.assignmentId) == ["701"])
    }

    @Test("Course colours for a sign-in that has ended are not kept")
    func colors() {
        let folder = Folder()
        let colors = CourseColorStore(files: folder.cache.colors)
        let palette: [UInt32] = [0xFF6B6B, 0x4ECDC4]

        #expect(!colors.applyColors([("CS1001301", 0x4ECDC4)], palette: palette, for: endedTestSignIn))
        #expect(colors.map.isEmpty)
        #expect(colors.applyColors([("CS1001301", 0x4ECDC4)], palette: palette, for: testSignIn))
        #expect(colors.map == ["CS1001301": 0x4ECDC4])
    }

    @Test("Moodle copies and course ids read for a sign-in that has ended are not saved")
    func moodle() {
        let folder = Folder()

        folder.cache.moodle.replaceMoodleCourseIdMap(["1151CS1001301": 7], for: endedTestSignIn)
        folder.cache.moodle.saveMoodleData(["forum"], fetchedAt: Date(), name: "forums-7", account: "B11300000",
                                           for: endedTestSignIn)
        #expect(folder.cache.moodle.loadMoodleCourseIdMap().isEmpty)
        #expect(folder.cache.moodle.loadMoodleData([String].self, name: "forums-7", account: "B11300000") == nil)
        folder.cache.moodle.replaceMoodleCourseIdMap(["1151CS1001301": 7], for: testSignIn)
        #expect(folder.cache.moodle.loadMoodleCourseIdMap() == ["1151CS1001301": 7])
    }

    @Test("A class table imported for a sign-in that has ended is not kept")
    func importedTables() throws {
        let folder = Folder()
        let store = ImportedClassTableStore(
            fileURL: folder.root.appendingPathComponent("imported.json"), signedInStudentId: { "B11300000" }
        )
        let code = try #require(ClassTableShareCode.decode(try #require(ClassTableShareCode.encode(
            studentId: "B11300001", sharedAt: Date(), terms: [.init(semester: "1151", courseNos: ["CS1001301"])]
        ))))

        #expect(store.add(code, nickname: "Ming", courses: [:], for: endedTestSignIn) == nil)
        #expect(store.people.isEmpty)
        #expect(store.add(code, nickname: "Ming", courses: [:], for: testSignIn) != nil)
        #expect(store.people.count == 1)
    }

    @Test("Account keys, sync progress, browser sites and synced settings for a sign-in that has ended are not written")
    func accountKeys() async {
        await withExclusiveRealDefaults {
            let saved = (Defaults[.schoolDataSyncedAt], Defaults[.assignmentMarksSyncedOnce], Defaults[.browserZoom])
            defer {
                Defaults[.schoolDataSyncedAt, for: testSignIn] = saved.0
                Defaults[.assignmentMarksSyncedOnce, for: testSignIn] = saved.1
                Defaults[.browserZoom, for: testSignIn] = saved.2
                NotificationSettingsSync.forget()
            }
            Defaults[.schoolDataSyncedAt, for: testSignIn] = nil
            SyncProgress.forget()
            BrowserSites.forget()
            NotificationSettingsSync.forget()
            let local = NotificationSettingsSync.LocalPreferences(from: LiveActivityPreferencesStore())

            SchoolAccountKeys.noteSchoolDataSynced(for: endedTestSignIn)
            SyncProgress.noteMarksSynced(for: endedTestSignIn)
            BrowserSites.change(for: endedTestSignIn) { $0.setZoom(150, for: "moodle2.ntust.edu.tw") }
            NotificationSettingsSync.seedSyncedCopyOnSignIn(from: local, for: endedTestSignIn)

            #expect(Defaults[.schoolDataSyncedAt] == nil)
            #expect(!Defaults[.assignmentMarksSyncedOnce])
            #expect(BrowserSites.stored == BrowserSites())
            #expect(NotificationSettingsSync.lastSyncedPreferences == nil)

            SyncProgress.noteMarksSynced(for: testSignIn)
            #expect(Defaults[.assignmentMarksSyncedOnce])
        }
    }

    @Test("A value held for a sign-in reads as empty once that sign-in ends")
    func boundValue() {
        let signedIn = TestSignIn()
        var held = SignInBound(empty: 0)

        held.set(3, for: signedIn.signIn)
        #expect(held.value == 3)
        signedIn.signOut()
        #expect(held.value == 0)
        held.set(4, for: signedIn.signIn)
        #expect(held.value == 0)
    }
}
