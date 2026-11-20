import Defaults
import Foundation
import TigerDuckCore

/// The account App Store review signs in with: `demo.json`'s made-up student, whom no server knows.
struct DemoAccount: AccountScoped {
    let fixture: DemoFixture?
    var stores = DemoStores()
    var language: () -> DemoLanguage = { .shown }
    var now: () -> Date = { Date() }

    static let app = DemoAccount(fixture: .bundled)

    func matches(studentId: String, password: String) -> Bool {
        fixture?.matches(studentId: studentId, password: password) ?? false
    }

    @discardableResult
    func startSignIn(in session: AccountSession) -> SignIn {
        let signIn = session.startDemoSignIn()
        Defaults[stores.demoSignedIn, for: signIn] = true
        stores.turnOffSync(signIn)
        return signIn
    }

    func enter(for signIn: SignIn) {
        guard let fixture, signIn.isDemo else { return }
        NTUSTSessionManager.shared.markLoginSuccess(for: signIn)
        write(fixture, for: signIn)
        importClassmates(of: fixture, for: signIn)
        if fixture.libraryQr?.fakeLoggedIn == true, !stores.libraryIsKept() {
            stores.signInLibrary(fixture.normalizedStudentId, fixture.libraryPassword)
        }
    }

    static func resumeAtLaunch(in session: AccountSession) {
        URLProtocol.registerClass(DemoRequestRefusal.self)
        app.resume(in: session)
    }

    func resume(in session: AccountSession) {
        guard let fixture else { return }
        let current = session.signIns.currentSignIn
        guard let kept = storedAccountIsDemoIfReadable() else {
            if Defaults[stores.demoSignedIn], !current.isDemo { startSignIn(in: session) }
            return
        }
        if kept, !current.isDemo {
            write(fixture, for: startSignIn(in: session))
        } else if !kept {
            if Defaults[stores.demoSignedIn] { Defaults.reset(stores.demoSignedIn) }
            if current.isDemo { session.endSignIn() }
        }
    }

    private func storedAccountIsDemoIfReadable() -> Bool? {
        do {
            guard let studentId = try KeychainManager.loadStringIfReadable(key: AppConstants.KeychainKeys.studentId),
                  let password = try KeychainManager.loadStringIfReadable(key: AppConstants.KeychainKeys.password)
            else { return false }
            return matches(studentId: studentId, password: password)
        } catch {
            return nil
        }
    }

    static func forgetAccount(in storage: AccountStorage) {
        Defaults.reset(.demoSignedIn)
    }

    func leave() {
        Defaults.reset(stores.demoSignedIn)
        if LibraryService.keepsDemoLibrary { LibraryService.signOutLibraryOnly() }
        #if os(iOS)
        if MailAccountManager.shared.isDemo { MailAccountManager.shared.logout() }
        #endif
    }

    func write(_ fixture: DemoFixture, for signIn: SignIn) {
        let language = language()
        let semester = CourseSelectionService.currentSemesterCode()
        let moodle = fixture.moodle?.courses(in: language) ?? DemoMoodleCourses(ownMemberId: 0, courses: [], files: [:])
        writeCourses(fixture.courses ?? [], on: moodle, semester: semester, for: signIn)
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
        _ courses: [DemoFixture.Course], on moodle: DemoMoodleCourses, semester: String, for signIn: SignIn
    ) {
        let onMoodle = Set(moodle.courses.map(\.courseNo))
        for language in DemoLanguage.allCases {
            let saved = courses.map { $0.course(in: language, semester: semester, onMoodle: onMoodle.contains($0.courseNo)) }
            guard stores.courses.saveCourses(saved, semester: semester, language: language.rawValue, for: signIn) else {
                return
            }
        }
        for course in courses {
            guard let hex = course.pickedHex else { continue }
            stores.colors.pick(hex, courseNo: course.courseNo, palette: TigerDuckTheme.coursePaletteHexes, for: signIn)
        }
        let context = stores.moodle(fixture?.normalizedStudentId ?? "", signIn)
        let ids = moodle.courses.map { (SDCourse.normalizedMoodleId(semester + $0.courseNo), $0.moodleId) }
        context.cache.replaceMoodleCourseIdMap(
            context.cache.loadMoodleCourseIdMap().merging(ids, uniquingKeysWith: { _, demo in demo }),
            enrolled: context.cache.loadEnrolledMoodleCourseIds().union(moodle.courses.map(\.moodleId)), for: signIn
        )
    }

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

struct DemoStores {
    var courses: CourseStore = .shared
    var colors: CourseColorStore = .shared
    var rounds: AssignmentRounds = .shared
    var classmates: ImportedClassTableStore = .shared
    var statuses: ServerStatusTracker = .shared
    var demoSignedIn: AccountKey<Bool> = .demoSignedIn
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
