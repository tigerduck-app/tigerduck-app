import Foundation
import TigerDuckCore

/// The store-review account. Its credentials, from `demo.json`, start a demo sign-in
/// (`SignIn.isDemo`), for which every request fails before it leaves the device
/// (`DemoRequestRefusal`) and the file's student goes into the stores the fetches fill.
struct DemoAccount {
    let fixture: DemoFixture?
    var stores = DemoStores()
    var language: () -> DemoLanguage = { .shown }
    var now: () -> Date = { Date() }

    static let app = DemoAccount(fixture: .bundled)

    func matches(studentId: String, password: String) -> Bool {
        fixture?.matches(studentId: studentId, password: password) ?? false
    }

    /// Once the sign-in kept the credentials: the file's data, its classmates' class tables and,
    /// when the file signs the library in and no library account is kept, the library.
    func enter(for signIn: SignIn) {
        guard let fixture, signIn.isDemo else { return }
        SchoolAccountKeys.noteDemoSignedIn(for: signIn)
        NTUSTSessionManager.shared.markLoginSuccess(for: signIn)
        stores.turnOffSync(signIn)
        write(fixture, for: signIn)
        importClassmates(of: fixture, for: signIn)
        if fixture.libraryQr?.fakeLoggedIn == true, !stores.libraryIsKept() {
            stores.signInLibrary(fixture.normalizedStudentId, fixture.libraryPassword)
        }
    }

    /// At launch, before any request: the demo sign-in again, with the data written over in the
    /// language the app now shows.
    static func resumeAtLaunch(in session: AccountSession) {
        URLProtocol.registerClass(DemoRequestRefusal.self)
        guard SchoolAccountKeys.demoIsSignedIn, let fixture = app.fixture else { return }
        app.write(fixture, for: session.startDemoSignIn())
    }

    func write(_ fixture: DemoFixture, for signIn: SignIn) {
        let language = language()
        let semester = CourseSelectionService.currentSemesterCode()
        let moodle = fixture.moodle?.courses(in: language) ?? DemoMoodleCourses(ownMemberId: 0, courses: [])
        writeCourses(fixture.courses ?? [], on: moodle, semester: semester, in: language, for: signIn)
        let assignments = (fixture.assignments ?? []).compactMap { $0.assignment(in: language) }
        let context = stores.moodle(fixture.normalizedStudentId, signIn)
        _ = AssignmentAnswers.persistRound(
            assignments, records: moodle.records(listed: assignments), closed: [:], answered: [:],
            account: context.account, fetchedAt: now(), assignments: context.assignments, moodle: context.cache,
            rounds: stores.rounds, for: signIn
        )
        let school = (fixture.calendar ?? []).enumerated().compactMap { $1.event(index: $0) }
        let kept = context.assignments.loadCalendarEvents().filter { $0.source == .moodle }
        _ = context.assignments.saveCalendarEvents(kept + school, for: signIn)
        stores.keepBulletins((fixture.bulletins ?? []).enumerated().map { $1.detail(index: $0) }, signIn)
        for server in ServerKind.allCases { stores.statuses.set(.ok, for: server) }
    }

    private func writeCourses(
        _ courses: [DemoFixture.Course], on moodle: DemoMoodleCourses, semester: String, in language: DemoLanguage,
        for signIn: SignIn
    ) {
        let onMoodle = Set(moodle.courses.map(\.courseNo))
        let saved = courses.map { $0.course(in: language, semester: semester, onMoodle: onMoodle.contains($0.courseNo)) }
        guard stores.courses.saveCourses(saved, semester: semester, for: signIn) else { return }
        for course in courses {
            guard let hex = course.pickedHex else { continue }
            stores.colors.pick(hex, courseNo: course.courseNo, palette: TigerDuckTheme.coursePaletteHexes, for: signIn)
        }
        let context = stores.moodle(fixture?.normalizedStudentId ?? "", signIn)
        let ids = moodle.courses.map { (SDCourse.normalizedMoodleId(semester + $0.courseNo), $0.moodleId) }
        let kept = context.cache.loadMoodleCourseIdMap()
        context.cache.replaceMoodleCourseIdMap(kept.merging(ids, uniquingKeysWith: { _, demo in demo }), for: signIn)
    }

    /// Only at sign-in, so a classmate the reviewer removed stays removed.
    private func importClassmates(of fixture: DemoFixture, for signIn: SignIn) {
        let language = language()
        let semester = CourseSelectionService.currentSemesterCode()
        let sharedAt = TaipeiTime.calendar.dateInterval(of: .minute, for: now())?.start
        for classmate in fixture.classmates ?? [] {
            let courses = (classmate.courses ?? []).filter { CourseSelectionService.isCourseNo(Substring($0.courseNo)) }
            let code = ClassTableShareCode(
                format: .tigerDuck, studentId: classmate.studentId, sharedAt: sharedAt,
                terms: [ClassTableShareCode.Term(semester: semester, courseNos: courses.map(\.courseNo))]
            )
            let tables = [semester: courses.map { $0.course(in: language, semester: semester, onMoodle: false) }]
            stores.classmates.add(
                code, nickname: classmate.nickname.text(in: language), courses: tables, importedAt: now(), for: signIn
            )
        }
    }
}

/// Where the demo account's data goes: the app's stores, or a test's.
struct DemoStores {
    var courses: CourseStore = .shared
    var colors: CourseColorStore = .shared
    var rounds: AssignmentRounds = .shared
    var classmates: ImportedClassTableStore = .shared
    var statuses: ServerStatusTracker = .shared
    var moodle: (_ account: String, _ signIn: SignIn) -> MoodleCacheContext = {
        MoodleCacheContext(account: $0, cache: .shared, signIn: $1)
    }
    var keepBulletins: (_ bulletins: [BulletinAPI.BulletinDetail], _ signIn: SignIn) -> Void = {
        BulletinFeed.keep($0, for: $1)
    }
    var turnOffSync: (SignIn) -> Void = { CloudSyncPreference.turnOffForDemo($0) }
    var libraryIsKept: () -> Bool = { LibraryService.storedUsername != nil }
    var signInLibrary: (_ username: String, _ password: String) -> Void = {
        LibraryService.saveCredentials(username: $0, password: $1)
    }
}
