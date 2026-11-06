import Foundation
#if os(iOS)
import SwiftUI
import UIKit
#endif
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct MoodleMemberCoursesTests {
    private nonisolated static let courseId = 20119
    private nonisolated static let ownId = 42

    nonisolated static func moodle(_ id: Int, _ idnumber: String, _ fullname: String) -> MoodleEnrolledCourse {
        MoodleEnrolledCourse(id: id, fullname: fullname, shortname: "", idnumber: idnumber, startDate: nil, endDate: nil)
    }

    nonisolated static func member(_ id: Int, _ fullName: String) -> MoodleMember {
        MoodleMember(
            id: id, fullName: fullName, idNumber: nil, email: nil, groups: [], roles: [], pictureURL: nil,
            description: "", interests: [], fields: []
        )
    }

    private nonisolated static let me = member(ownId, "B11399001 @ Tiger Duck")
    private nonisolated static let classmate = member(43, "B11399002 @ Duck Tiger")
    /// The page's own course, which every member shares.
    private nonisolated static let thisCourse = moodle(courseId, "1141CS1001301", "CS1001301 Data Structures")
    private nonisolated static let algorithms = moodle(30001, "1141CS2001301", "CS2001301 Algorithms")

    private static func classCourse(_ courseNo: String, _ name: String, by instructor: String, in semester: String) -> CourseStore.Course {
        CourseStore.Course(courseNo: courseNo, courseName: name, instructor: instructor, semester: semester)
    }

    private static func table(_ terms: [String: [CourseStore.Course]] = [:]) -> (String) -> [CourseStore.Course] {
        { terms[$0] ?? [] }
    }

    private final class Site: @unchecked Sendable {
        private let lock = NSLock()
        private var _functions: Set<String> = [
            MoodleCourseMembersService.membersFunction, MoodleEnrolledCoursesService.usersCoursesFunction,
        ]
        private var _shared: [MoodleEnrolledCourse] = []
        private var _calls: [Int] = []

        func set(functions: Set<String>? = nil, shared: [MoodleEnrolledCourse]? = nil) {
            lock.withLock {
                if let functions { _functions = functions }
                if let shared { _shared = shared }
            }
        }

        var calls: [Int] { lock.withLock { _calls } }

        func api(before: @escaping @Sendable () async throws -> Void = {}) -> MoodleCourseAPI {
            MoodleCourseAPI(
                functions: { self.lock.withLock { self._functions } },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                members: { _ in
                    MoodleMemberList(
                        ownId: MoodleMemberCoursesTests.ownId,
                        members: [MoodleMemberCoursesTests.me, MoodleMemberCoursesTests.classmate]
                    )
                },
                sharedCourses: { userId in
                    self.lock.withLock { self._calls.append(userId) }
                    try await before()
                    return self.lock.withLock { self._shared }
                }
            )
        }
    }

    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleMemberCoursesTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func store(
        _ folder: Folder,
        site: Site,
        account: String = "B11399001",
        signedIn: TestSignIn = TestSignIn(),
        before: @escaping @Sendable () async throws -> Void = {}
    ) -> MoodleCourseStore {
        MoodleCourseStore(
            courseId: courseId,
            termCourseIds: [courseId],
            context: MoodleCacheContext(account: account, cache: folder.cache.moodle, signIn: signedIn.signIn),
            api: site.api(before: before)
        )
    }

    @Test("courses in common list by term, newest first, under the class table's name, and leave out the page's course")
    func byTerm() {
        let calculus = Self.classCourse("MA1001301", "微積分（一）", by: "Lin", in: "1131")
        calculus.customName = "Calculus"
        let classTable = Self.table([
            "1141": [
                Self.classCourse("CS2001301", "Algorithms", by: "Wang", in: "1141"),
                Self.classCourse("CS3001302", "Operating Systems", by: "", in: "1141"),
            ],
            "1132": [Self.classCourse("CS1002301", "Introduction to Computers", by: "Chen", in: "1132")],
            "1131": [calculus],
        ])
        let shared = [
            Self.thisCourse,
            Self.moodle(10001, "1131MA1001301", "MA1001301 微積分（一）"),
            Self.moodle(30002, "1141GE3105701", "GE3105701 Ethics"),
            Self.moodle(20001, "1132CS1002301", "CS1002301 計算機概論"),
            Self.moodle(30003, "1141CS3001301", "CS3001301 CS3001302 作業系統"),
            Self.moodle(20500, "113hPE1001301", "PE1001301 Swimming"),
            Self.moodle(30001, "1141CS2001301", "CS2001301 演算法"),
        ]

        let terms = MoodleCommonTerm.terms(of: shared, besides: Self.courseId, classTable: classTable)

        #expect(terms == [
            MoodleCommonTerm(term: "1141", courses: [
                MoodleCommonCourse(id: 30001, name: "Algorithms", details: ["CS2001301", "Wang"], colorKey: "CS2001301"),
                MoodleCommonCourse(id: 30002, name: "Ethics", details: ["GE3105701"], colorKey: "GE3105701"),
                MoodleCommonCourse(id: 30003, name: "Operating Systems", details: ["CS3001302"], colorKey: "CS3001302"),
            ]),
            MoodleCommonTerm(term: "113H", courses: [
                MoodleCommonCourse(id: 20500, name: "Swimming", details: ["PE1001301"], colorKey: "PE1001301"),
            ]),
            MoodleCommonTerm(term: "1132", courses: [
                MoodleCommonCourse(
                    id: 20001, name: "Introduction to Computers", details: ["CS1002301", "Chen"], colorKey: "CS1002301"
                ),
            ]),
            MoodleCommonTerm(term: "1131", courses: [
                MoodleCommonCourse(id: 10001, name: "Calculus", details: ["MA1001301", "Lin"], colorKey: "MA1001301"),
            ]),
        ])
    }

    @Test("a member who shares only the page's course, or whom Moodle lists in nothing, has no courses in common")
    func nothingInCommon() {
        #expect(MoodleCommonTerm.terms(of: [Self.thisCourse], besides: Self.courseId, classTable: Self.table()).isEmpty)
        #expect(MoodleCommonTerm.terms(of: [], besides: Self.courseId, classTable: Self.table()).isEmpty)
    }

    @Test("a course whose Moodle id names no term lists after every term, under Moodle's name and without a course number")
    func courseWithoutTerm() {
        let shared = [
            Self.moodle(900, "", "TA Training"),
            Self.moodle(901, "2025ORIENT", "Orientation 2025"),
            Self.moodle(902, "DEPTCS", "CS Department News"),
            Self.algorithms,
        ]

        let terms = MoodleCommonTerm.terms(of: shared, besides: Self.courseId, classTable: Self.table())

        #expect(terms.map(\.term) == ["1141", nil])
        #expect(terms.last?.courses == [
            MoodleCommonCourse(id: 902, name: "CS Department News", details: [], colorKey: "902"),
            MoodleCommonCourse(id: 901, name: "Orientation 2025", details: [], colorKey: "901"),
            MoodleCommonCourse(id: 900, name: "TA Training", details: [], colorKey: "900"),
        ])
    }

    @Test("the account's own page asks Moodle for nothing and lists no courses in common")
    func yourself() async {
        let folder = Folder()
        let site = Site()
        site.set(shared: [Self.thisCourse, Self.algorithms])
        let store = Self.store(folder, site: site)
        await store.refreshMembers()

        await store.memberCourses.refresh(with: Self.me)

        #expect(site.calls.isEmpty)
        #expect(store.memberCourses.terms(with: Self.me, classTable: Self.table()).isEmpty)
    }

    @Test("a member's courses in common come from Moodle, show from the account's cache the next time and go at its sign-out")
    func keptForTheAccount() async {
        let folder = Folder()
        let site = Site()
        site.set(shared: [Self.thisCourse, Self.algorithms])
        let store = Self.store(folder, site: site)
        await store.refreshMembers()

        await store.memberCourses.refresh(with: Self.classmate)

        let expected = [MoodleCommonTerm(term: "1141", courses: [
            MoodleCommonCourse(id: 30001, name: "Algorithms", details: ["CS2001301"], colorKey: "CS2001301"),
        ])]
        #expect(site.calls == [43])
        #expect(store.memberCourses.terms(with: Self.classmate, classTable: Self.table()) == expected)
        let reopened = Self.store(folder, site: Site())
        #expect(reopened.memberCourses.terms(with: Self.classmate, classTable: Self.table()) == expected)
        let otherAccount = Self.store(folder, site: Site(), account: "B11399002")
        #expect(otherAccount.memberCourses.terms(with: Self.classmate, classTable: Self.table()).isEmpty)

        // The Moodle store alone: the whole school sign-out also resets the process's shared browser data.
        MoodleFiles.forgetAccount(in: AccountStorage(folders: folder.cache.folders))
        #expect(Self.store(folder, site: Site()).memberCourses.terms(with: Self.classmate, classTable: Self.table()).isEmpty)
    }

    @Test("courses in common that land after a sign-out are neither shown nor kept")
    func signOutWhileFetching() async throws {
        let folder = Folder()
        let signedIn = TestSignIn()
        let answer = ManualSleeper()
        let site = Site()
        site.set(shared: [Self.algorithms])
        let store = Self.store(folder, site: site, signedIn: signedIn) { await answer.sleep(for: .zero) }
        await store.refreshMembers()

        let refresh = Task { await store.memberCourses.refresh(with: Self.classmate) }
        try await answer.waitUntilArmed()
        signedIn.signOut()
        await answer.fire()
        await refresh.value

        #expect(store.memberCourses.terms(with: Self.classmate, classTable: Self.table()).isEmpty)
        let kept = folder.cache.moodle.loadMoodleData([MoodleEnrolledCourse].self, name: "members/43/courses", account: "B11399001")
        #expect(kept == nil)
    }

    @Test("a site that does not allow the call is asked nothing, and the member page lists no courses in common")
    func gatedByFunctions() async {
        let folder = Folder()
        let site = Site()
        site.set(functions: [MoodleCourseMembersService.membersFunction], shared: [Self.algorithms])
        let store = Self.store(folder, site: site)
        await store.refreshMembers()

        await store.memberCourses.refresh(with: Self.classmate)

        #expect(site.calls.isEmpty)
        #expect(store.memberCourses.feed(of: Self.classmate).status == .ok)
        #expect(store.memberCourses.terms(with: Self.classmate, classTable: Self.table()).isEmpty)
    }
}

struct MoodleUsersCoursesServiceTests {
    private static let site = URL(string: "https://moodle-stub.invalid")!

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    private static func endpoint(token: String) -> URL {
        URL(string: "https://moodle-stub.invalid/webservice/rest/server.php?moodlewsrestformat=json"
            + "&wsfunction=\(MoodleEnrolledCoursesService.usersCoursesFunction)&wstoken=\(token)")!
    }

    static let answer = #"""
    [
      {"id": 30001, "shortname": "Algorithms", "fullname": "CS2001301 Algorithms", "displayname": "CS2001301 Algorithms",
       "idnumber": "1141CS2001301", "visible": 1, "format": "topics", "startdate": 1788192000, "enddate": 1799596800},
      {"id": 900, "shortname": "TA", "fullname": "TA Training", "idnumber": "", "startdate": 0, "enddate": 0}
    ]
    """#

    @Test("a member's courses ask Moodle by their user id, without counting each course's participants")
    func request() async throws {
        let token = UUID().uuidString
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(Self.answer.utf8)), for: Self.endpoint(token: token))

        let courses = try await MoodleEnrolledCoursesService.courses(
            of: 43, token: token, session: Self.session(), siteURL: Self.site
        )

        let request = try #require(SettingsAPIStub.requests(for: Self.endpoint(token: token)).first)
        let body = SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == "wstoken=\(token)&userid=43&returnusercount=0")
        #expect(courses.map(\.id) == [30001, 900])
        #expect(courses.map(\.idnumber) == ["1141CS2001301", ""])
        #expect(courses.map(\.semester) == ["1141", ""])
    }
}

#if os(iOS)
@MainActor
@Suite(.serialized)
struct MoodleMemberCommonCoursesScreenTests {
    private static let member = MoodleMember(
        id: 43, fullName: "B11399002 @ Duck Tiger", idNumber: "B11399002", email: nil, groups: [], roles: [],
        pictureURL: nil, description: "", interests: [], fields: []
    )

    private static let longName = "Special Topics in Human-Computer Interaction and Ubiquitous Computing Systems"

    private static let terms = [
        MoodleCommonTerm(term: "1141", courses: [
            MoodleCommonCourse(id: 1, name: "Algorithms", details: ["CS2001301", "Wang"], colorKey: "CS2001301"),
            MoodleCommonCourse(id: 2, name: longName, details: ["CS5145701", "Professor Long Surname"], colorKey: "CS5145701"),
        ]),
        MoodleCommonTerm(term: "113H", courses: [
            MoodleCommonCourse(id: 3, name: "Swimming", details: ["PE1001301"], colorKey: "PE1001301"),
        ]),
        MoodleCommonTerm(term: "1132", courses: [
            MoodleCommonCourse(id: 4, name: "Introduction to Computers", details: ["CS1002301", "Chen"], colorKey: "CS1002301"),
        ]),
        MoodleCommonTerm(term: nil, courses: [
            MoodleCommonCourse(id: 900, name: "TA Training", details: [], colorKey: "900"),
        ]),
    ]

    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The member page's scroll view and margins around the profile.
    private static func page(_ terms: [MoodleCommonTerm]) -> some View {
        ScrollView {
            MoodleMemberProfile(
                member: member, picture: nil, policy: VisualStylePolicy(preset: .default),
                writeTo: { _ in }, openPicture: {}, commonCourses: terms
            )
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.xxl)
        }
        .background(Color.backgroundPrimary)
    }

    @Test("the member page lists the courses in common by term under headings, each row read whole and kept in the page",
          arguments: ClubScreensTests.looks)
    func section(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let window = try ClubScreensTests.show(Self.page(Self.terms), look: look, height: look.textSize == .large ? 812 : 2600)
            defer { window.isHidden = true }
            let title = String(localized: "course_member_common_courses")
            try await waitUntil { accessibilityElement(labeled: "Algorithms, CS2001301, Wang", in: window) != nil }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "member-common-courses-\(look.testDescription)-\(Self.language)")

            let headings = ["114-1", "113-H", "113-2", String(localized: "course_member_common_courses_other")]
            #expect(accessibilityElement(labeled: title, in: window)?.accessibilityTraits.contains(.header) == true)
            var seen = Set<String>()
            #expect(exposedAccessibilityLabels(in: window).filter { headings.contains($0) && seen.insert($0).inserted } == headings)
            for heading in headings {
                #expect(accessibilityElement(labeled: heading, in: window)?.accessibilityTraits.contains(.header) == true, "\(heading)")
            }
            for label in [
                "Algorithms, CS2001301, Wang", "\(Self.longName), CS5145701, Professor Long Surname", "Swimming, PE1001301",
                "Introduction to Computers, CS1002301, Chen", "TA Training",
            ] {
                let row = try #require(accessibilityElement(labeled: label, in: window), "\(label)")
                #expect(!row.accessibilityTraits.contains(.button), "\(label)")
                #expect(row.accessibilityFrame.minX >= 0 && row.accessibilityFrame.maxX <= window.bounds.maxX + 0.5, "\(label)")
            }
        }
    }

    @Test("a member page with no courses in common has no such heading")
    func noSection() async throws {
        try await withAccessibilityAutomation {
            let window = try ClubScreensTests.show(Self.page([]), look: ClubScreensTests.looks[0])
            defer { window.isHidden = true }
            try await waitUntil { accessibilityElement(labeled: "Duck Tiger", in: window) != nil }

            #expect(accessibilityElement(labeled: String(localized: "course_member_common_courses"), in: window) == nil)
        }
    }
}
#endif
