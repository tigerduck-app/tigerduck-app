import Defaults
import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

/// Each test signs in on a series of its own: while the app's school sign-in is the demo, the
/// app's sessions refuse every request in the process.
@Suite("Store-review demo account")
@MainActor
struct DemoAccountTests {
    private static let studentId = "B11308964"
    private static let schoolPassword = "its-my-duty"
    private static let libraryPassword = "its-my-duty"

    private final class Calls {
        var syncTurnedOff = 0
        var library: [String] = []
        var schoolSignIns = 0
    }

    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoAccountTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = TestCache(folders: CacheFolders(root: root))
        lazy var classmates = ImportedClassTableStore(
            fileURL: root.appendingPathComponent("imported.json"), signedInStudentId: { DemoAccountTests.studentId }
        )
        let suiteName = "DemoAccountTests-\(UUID().uuidString)"
        lazy var demoSignedIn = AccountKey<Bool>("demoSignedIn", default: false, suite: UserDefaults(suiteName: suiteName)!)

        deinit {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
    }

    private static func demoSignIn() -> SignIn {
        let signIns = SignInSeries()
        signIns.startDemo()
        return signIns.currentSignIn
    }

    private static func account(_ folder: Folder, statuses: ServerStatusTracker = ServerStatusTracker(),
                                calls: Calls = Calls()) -> DemoAccount {
        let cache = folder.cache
        let stores = DemoStores(
            courses: cache.courses, colors: CourseColorStore(files: cache.colors), rounds: AssignmentRounds(),
            classmates: folder.classmates, statuses: statuses, demoSignedIn: folder.demoSignedIn,
            moodle: { MoodleCacheContext(account: $0, cache: cache.moodle, assignments: cache.assignments, signIn: $1) },
            keepBulletins: { BulletinFeed.keep($0, files: cache.bulletins, for: $1) },
            turnOffSync: { _ in calls.syncTurnedOff += 1 },
            libraryIsKept: { false },
            signInLibrary: { username, _ in calls.library.append(username) }
        )
        return DemoAccount(fixture: .bundled, stores: stores, language: { .en })
    }

    @Test("the bundled demo.json decodes with the Android file's credentials and sections")
    func bundledFileDecodes() throws {
        let url = try #require(Bundle.main.url(forResource: "demo", withExtension: "json"))
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(raw.keys) == [
            "studentId", "school-password", "library-password", "mail", "libraryQr", "courses", "classmates",
            "assignments", "bulletins", "calendar", "moodle", "emptyClassroom",
        ])

        let fixture = try #require(DemoFixture.load(from: .main))
        #expect(fixture.studentId == Self.studentId)
        #expect(fixture.schoolPassword == Self.schoolPassword)
        #expect(fixture.libraryPassword == Self.libraryPassword)
        #expect(fixture.courses?.count == 5)
        #expect(fixture.classmates?.count == 1)
        #expect(fixture.assignments?.count == 3)
        #expect(fixture.bulletins?.count == 2)
        #expect(fixture.calendar?.count == 3)
        #expect(fixture.moodle?.courses?.count == 3)
        #expect(fixture.emptyClassroom?.rooms?.isEmpty == false)
        #expect(fixture.libraryQr?.content.isEmpty == false)
        #if os(iOS)
        let mail = try #require(MailDemoFixture.load(from: .main, in: .en))
        #expect(mail.studentId == Self.studentId)
        #expect(mail.password == Self.schoolPassword)
        #expect(mail.folders.values.map(\.count).reduce(0, +) == 6)
        #endif
    }

    @Test("the demo credentials match, the ID as the sign-in writes it, and other credentials do not")
    func demoCredentialsMatch() throws {
        let fixture = try #require(DemoFixture.bundled)

        #expect(fixture.matches(studentId: " \(Self.studentId.lowercased()) ", password: Self.schoolPassword))
        #expect(!fixture.matches(studentId: Self.studentId, password: Self.schoolPassword + "x"))
        #expect(!fixture.matches(studentId: "B11000000", password: Self.schoolPassword))
        #expect(fixture.matchesLibrary(username: Self.studentId.lowercased(), password: Self.libraryPassword))
        #expect(!fixture.matchesLibrary(username: Self.studentId, password: "password"))
        #expect(DemoFixture.isDemoLibrary(Self.studentId, Self.libraryPassword))
        #expect(!DemoFixture.isDemoLibrary(Self.studentId, nil))
    }

    @Test("signing in with the demo credentials starts a demo sign-in and never asks the school")
    func demoCredentialsStartTheDemo() async {
        let folder = Folder()
        let calls = Calls()
        let auth = AuthService(
            session: AccountSession(signIns: SignInSeries()), keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(),
            schoolSignIn: { _, _, _ in
                calls.schoolSignIns += 1
                return true
            },
            demo: Self.account(folder, calls: calls)
        )
        #if os(iOS)
        auth.accountNotifications = DeliveredNotificationsStub()
        #endif

        await withExclusiveRealDefaults { () async -> Void in
            let saved = (Defaults[.ssoLoginTimestamp], Defaults[.ntustCredentialsPresent])
            defer {
                Defaults[.ssoLoginTimestamp, for: testSignIn] = saved.0
                Defaults[.ntustCredentialsPresent, for: testSignIn] = saved.1
            }
            await SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) { () async -> Void in
                #expect(await auth.login(studentId: Self.studentId.lowercased(), password: Self.schoolPassword))
                #expect(auth.storedStudentId == Self.studentId)
                #expect(Defaults[auth.deps.demo.stores.demoSignedIn])
            }
        }

        #expect(auth.session.signIns.currentSignIn.isDemo)
        #expect(calls.schoolSignIns == 0)
        #expect(calls.syncTurnedOff == 1)
    }

    @Test("other credentials sign in at the school, and not as the demo")
    func otherCredentialsSignInAtTheSchool() async {
        let calls = Calls()
        let auth = AuthService(
            session: AccountSession(signIns: SignInSeries()), keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(),
            schoolSignIn: { _, _, _ in
                calls.schoolSignIns += 1
                return false
            },
            demo: Self.account(Folder(), calls: calls)
        )

        await SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
            _ = await auth.login(studentId: Self.studentId, password: Self.libraryPassword + "x")
        }

        #expect(calls.schoolSignIns == 1)
        #expect(!auth.session.signIns.currentSignIn.isDemo)
    }

    @Test("the file's student lands in the stores the fetches fill")
    func fixtureLandsInTheStores() async throws {
        let folder = Folder()
        let statuses = ServerStatusTracker()
        let calls = Calls()
        let signIn = Self.demoSignIn()
        let semester = CourseSelectionService.currentSemesterCode()

        await withExclusiveRealDefaults {
            let saved = Defaults[.ssoLoginTimestamp]
            defer { Defaults[.ssoLoginTimestamp, for: testSignIn] = saved }
            Self.account(folder, statuses: statuses, calls: calls).enter(for: signIn)
        }

        let cache = folder.cache
        let courses = cache.courses.loadCourses(semester: semester)
        #expect(courses.count == 5)
        #expect(courses.first { $0.courseNo == "CS3005301" }?.moodleIdNumber == semester + "CS3005301")
        #expect(CourseColorStore(files: cache.colors).hex(for: "CS3005301", palette: TigerDuckTheme.coursePaletteHexes) == 0xE57373)
        #expect(cache.moodle.lookupMoodleCourseId(idnumber: semester + "CS3005301") == 90501)

        let assignments = cache.assignments.loadAssignments(semester: semester)
        #expect(Set(assignments.map(\.assignmentId)) == ["900001", "900002", "900003"])
        #expect(assignments.first { $0.assignmentId == "900003" }?.isCompleted == true)
        let context = MoodleCacheContext(account: Self.studentId, cache: cache.moodle, assignments: cache.assignments, signIn: signIn)
        #expect(MoodleCourseAssignments.records(in: context).map(\.cmId).sorted() == [950001, 950002, 950003])

        let events = cache.assignments.loadCalendarEvents()
        #expect(Set(events.map(\.source)) == [.moodle, .semester, .holiday, .exam])
        #expect(events.filter { $0.source != .moodle }.count == 3)

        let bulletins = cache.bulletins.loadBulletinSummaries()
        #expect(bulletins.count == 2)
        #expect(bulletins.allSatisfy { cache.bulletins.loadBulletinDetail(id: $0.id)?.bodyMd?.isEmpty == false })

        #expect(folder.classmates.people.map(\.nickname) == ["Duckling"])
        #expect(ServerKind.allCases.allSatisfy { statuses.status(for: $0) == .ok })
        #expect(calls.library == [Self.studentId])
        #expect(calls.syncTurnedOff == 1)
    }

    @Test("signing out ends the demo, and the sign-out's clearing takes the file's data with it")
    func signingOutLeavesTheDemo() async throws {
        let folder = Folder()
        let session = AccountSession(signIns: SignInSeries())
        let signIn = session.startDemoSignIn()
        let semester = CourseSelectionService.currentSemesterCode()
        let demo = Self.account(folder)
        demo.write(try #require(demo.fixture), for: signIn)
        #expect(!folder.cache.courses.loadCourses(semester: semester).isEmpty)

        session.endSignIn()
        await withExclusiveRealDefaults { folder.cache.forgetAccount() }

        #expect(!session.signIns.currentSignIn.isDemo)
        #expect(folder.cache.courses.loadCourses(semester: semester).isEmpty)
        #expect(folder.cache.assignments.loadAssignments(semester: semester).isEmpty)
        #expect(folder.cache.bulletins.loadBulletinSummaries().isEmpty)
        #expect(folder.cache.moodle.loadMoodleCourseIdMap().isEmpty)
    }

    @Test("a launch behind the lock screen resumes the demo sign-in, and a classmate removed stays removed")
    func aLockedLaunchResumesTheDemo() async throws {
        let folder = Folder()
        let calls = Calls()
        let demo = Self.account(folder, calls: calls)
        let auth = AuthService(
            session: AccountSession(signIns: SignInSeries()), keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(), demo: demo
        )
        #if os(iOS)
        auth.accountNotifications = DeliveredNotificationsStub()
        #endif
        let launch = AccountSession(signIns: SignInSeries())

        await withExclusiveRealDefaults { () async -> Void in
            let saved = (Defaults[.ssoLoginTimestamp], Defaults[.ntustCredentialsPresent])
            defer {
                Defaults[.ssoLoginTimestamp, for: testSignIn] = saved.0
                Defaults[.ntustCredentialsPresent, for: testSignIn] = saved.1
            }
            await SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) { () async -> Void in
                #expect(await auth.login(studentId: Self.studentId, password: Self.schoolPassword))
            }
        }
        let classmate = try #require(folder.classmates.people.first)
        folder.classmates.delete(classmate.id, for: auth.session.signIns.currentSignIn)
        SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) { demo.resume(in: launch) }

        #expect(launch.signIns.currentSignIn.isDemo)
        #expect(folder.cache.courses.loadCourses(semester: CourseSelectionService.currentSemesterCode()).count == 5)
        #expect(folder.classmates.people.isEmpty)
        #expect(calls.syncTurnedOff == 2)
    }

    @Test("the demo timetable is there in either course language, each in its own")
    func theTimetableIsThereInEitherLanguage() throws {
        let folder = Folder()
        let demo = Self.account(folder)
        let semester = CourseSelectionService.currentSemesterCode()
        demo.write(try #require(demo.fixture), for: Self.demoSignIn())

        let files = CourseFiles(folders: folder.cache.folders)
        let shown = ["zh-Hant", "en"].map {
            files.loadCourses(semester: semester, language: LanguageManager.resolvedCourseApiLanguage(appLanguage: $0))
        }

        #expect(shown.map(\.count) == [5, 5])
        #expect(shown[0].first { $0.courseNo == "CS3005301" }?.courseName == "資料結構")
        #expect(shown[1].first { $0.courseNo == "CS3005301" }?.courseName == "Data Structures")
    }

    @Test("signing out of the demo signs out the library it signed in, and the next launch is no demo")
    func signingOutOfTheDemoSignsOutItsLibrary() async {
        let folder = Folder()
        let auth = AuthService(
            session: AccountSession(signIns: SignInSeries()), keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(), endSchoolSession: { _ in }, demo: Self.account(folder)
        )
        #if os(iOS)
        auth.accountNotifications = DeliveredNotificationsStub()
        #endif
        auth.beginSignOutBackgroundTask = { {} }

        let library = await withExclusiveRealDefaults { () async -> String? in
            let saved = (Defaults[.ssoLoginTimestamp], Defaults[.ntustCredentialsPresent])
            defer {
                Defaults[.ssoLoginTimestamp, for: testSignIn] = saved.0
                Defaults[.ntustCredentialsPresent, for: testSignIn] = saved.1
            }
            return await SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) { () async -> String? in
                #expect(await auth.login(studentId: Self.studentId, password: Self.schoolPassword))
                LibraryService.saveCredentials(username: Self.studentId, password: Self.libraryPassword)
                await SignOutPlan.school(auth: auth).run(in: AccountStorage(folders: folder.cache.folders))?.value
                return LibraryService.storedUsername
            }
        }

        let launch = AccountSession(signIns: SignInSeries())
        auth.deps.demo.resume(in: launch)

        #expect(library == nil)
        #expect(!auth.session.signIns.currentSignIn.isDemo)
        #expect(!launch.signIns.currentSignIn.isDemo)
    }

    @Test("push registration does not start for the demo account")
    func pushDoesNotStart() async {
        let signIns = SignInSeries()
        signIns.startDemo()
        let push = PushCoordinator(signIns: signIns)

        push.enable()

        #expect(await push.currentSnapshot().isStarted == false)
    }

    @Test("TigerSync stays off for the demo account")
    func tigerSyncStaysOff() {
        let suiteName = "DemoAccountTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let key = AccountKey<Bool>("cloudSyncEnabled", default: true, suite: suite)
        let preference = CloudSyncPreference(key: key)
        let signIn = Self.demoSignIn()

        CloudSyncPreference.turnOffForDemo(signIn, key: key)
        #expect(!preference.isEnabled)
        preference.setEnabled(true, for: signIn)
        #expect(!preference.isEnabled)
        preference.setEnabled(true, for: testSignIn)
        #expect(preference.isEnabled)
    }

    @Test("a course page reads the file's Moodle, which needs no network")
    func moodleAnswersFromTheFile() async throws {
        let moodle = try #require(DemoFixture.bundled?.moodle?.courses(in: .en))
        let api = MoodleCourseAPI.demo(moodle)
        let course = try #require(moodle.course(90501))

        let forums = try await api.forums([90501])
        #expect(forums.map(\.type) == ["news", "general"])
        #expect(try await api.discussions(course.newsForumId, 0).count == 4)
        let thread = try #require(try await api.discussions(forums[1].id, 0).first)
        #expect(try await !api.posts(thread.id).isEmpty)
        #expect(try await api.materials(90501).sections.count == 3)
        #expect(try await api.members(90501).members.count == 7)
        #expect(try await api.gradeItems(90501).count == 5)
        #expect(try await api.summary(90501).names.isEmpty == false)

        let graded = try #require(try await api.submission(900003).id)
        #expect(try await api.submission(900003).comments == nil)
        #expect(try await api.comments(950003, graded).count == 2)
        #expect(try await !api.groups(90502).isEmpty)
        let file = MoodleFile(name: "notes.pdf", size: 1, url: "https://moodle.invalid/notes.pdf", mimeType: nil, modified: nil)
        await #expect(throws: URLError.self) { _ = try await api.download(file, { _ in }) }
    }

    @Test("the empty-classroom page gets the file's week, and weekends have no rooms")
    func emptyClassroomsFromTheFile() async throws {
        let classrooms = try #require(DemoFixture.bundled?.emptyClassroom)
        let monday = try #require(DemoTime.date("2026-09-14"))
        let saturday = try #require(DemoTime.date("2026-09-19"))
        let usage = classrooms.usage(on: monday, in: .en)

        #expect(usage.rooms.count == 23)
        #expect(usage.rooms.allSatisfy { $0.slots.count == ClassroomUsageParser.periodCount })
        #expect(usage.rooms.contains { $0.slots.contains(.booked) })
        #expect(classrooms.usage(on: saturday, in: .en).rooms.isEmpty)

        let calls = Calls()
        let service = ClassroomUsageService(
            session: URLSession(configuration: .ephemeral), queryURL: ClassroomUsageService.queryURL,
            signIn: { _, _ in
                calls.schoolSignIns += 1
                return false
            }
        )
        let credentials = ClassroomUsageService.Credentials(
            studentId: Self.studentId, password: Self.schoolPassword, signIn: Self.demoSignIn()
        )
        let kept = try await service.usage(on: monday, isToday: false, force: true, credentials: credentials)
        #expect(!kept.usage.rooms.isEmpty)
        #expect(calls.schoolSignIns == 0)
    }

    @Test("the demo library signs in and shows the file's QR code without asking the library")
    func libraryFromTheFile() async throws {
        let keychain = MemoryKeychain.locked()
        let qr = try #require(DemoFixture.bundled?.libraryQr?.content)

        let shown = try await withExclusiveRealDefaults {
            try await SecureStore.$sharedForTesting.withValue(keychain) { () async throws -> String in
                try await LibraryService.login(username: Self.studentId, password: Self.libraryPassword, request: { _, _ in
                    Issue.record("the demo library sign-in reached the library")
                    throw URLError(.notConnectedToInternet)
                })
                return try await LibraryService.generateQRCode()
            }
        }

        #expect(shown == qr)
    }
}
