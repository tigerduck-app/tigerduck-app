import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseRefreshUploadTests {
    private static let courses = ["CS1", "CS2", "CS3"].map { SDCourse(courseNo: $0, courseName: $0) }

    private struct Upload: Equatable {
        let courses: [String]
        let asRoster: Bool
        var resend = false
    }

    private static func uploads(
        _ courseNos: [String], roster: [String]?, hidden: Set<String> = [], resendingRoster: Bool = false
    ) -> [Upload] {
        var uploads: [Upload] = []
        AppServiceBridge.uploadVisibleCourses(
            courseNos.map { SDCourse(courseNo: $0, courseName: $0) }, semester: "1151", hidden: hidden,
            roster: roster, resendingRoster: resendingRoster
        ) { courses, _, asRoster, resend in
            uploads.append(Upload(courses: courses.map(\.courseNo), asRoster: asRoster, resend: resend))
        }
        return uploads
    }

    @Test("A course refresh uploads its term but the courses hidden here, in that term or in every term")
    func hiddenCoursesStayOutOfTheUpload() {
        var uploads: [(courses: [String], semester: String)] = []

        AppServiceBridge.uploadVisibleCourses(
            Self.courses, semester: "1151", hidden: ["1151:CS2", "CS3", "1142:CS1"]
        ) { courses, semester, _, _ in uploads.append((courses.map(\.courseNo), semester)) }

        #expect(uploads.map(\.courses) == [["CS1"]])
        #expect(uploads.map(\.semester) == ["1151"])
    }

    @Test("A course refresh whose courses are all hidden here uploads nothing")
    func aTermHiddenWholeUploadsNothing() {
        var uploads = 0

        AppServiceBridge.uploadVisibleCourses(
            Self.courses, semester: "1151", hidden: ["1151:CS1", "1151:CS2", "1151:CS3"], roster: ["CS1", "CS2", "CS3"]
        ) { _, _, _, _ in uploads += 1 }

        #expect(uploads == 0)
    }

    @Test("Course selection's answer goes up as its term's roster only when this fetch got it from the school",
          arguments: [true, false])
    func selectionAnswerIsARosterWhenLive(live: Bool) throws {
        let term = try #require(AppServiceBridge.termCourseNos(
            selection: ["CS1", "CS2"], transcript: ["CS3"], cached: ["CS4"]
        ))
        let roster = AppServiceBridge.uploadedRoster(selection: term.roster, live: live, pastTerm: nil)

        #expect(Self.uploads(term.courseNos, roster: roster) == [Upload(courses: ["CS1", "CS2"], asRoster: live)])
    }

    @Test("A running term's transcript and the cache, or what an empty or failed answer falls back to, are no roster",
          arguments: [nil, [String]()])
    func fallbackIsNoRoster(selection: [String]?) throws {
        let term = try #require(AppServiceBridge.termCourseNos(
            selection: selection, transcript: ["CS1"], cached: ["CS2"]
        ))

        #expect(Self.uploads(term.courseNos, roster: term.roster) == [Upload(courses: ["CS1", "CS2"], asRoster: false)])
    }

    @Test("A past term rebuilt from the final transcript goes up as its roster, once every class's lookup answered")
    func rebuiltPastTermIsARoster() {
        let course = { (courseNo: String) in
            SDCourse(courseNo: courseNo, courseName: courseNo, schedule: [2: ["3", "4"]], semester: "1141")
        }
        let answered = AppServiceBridge.rebuiltPastTerm(
            [.init(course: course("CS1"), answered: true)], unreadable: [], cached: [], others: [], userAdded: []
        )
        let waiting = AppServiceBridge.rebuiltPastTerm(
            [.init(course: course("CS1"), answered: true), .init(course: course("CS2"), answered: false)],
            unreadable: [], cached: [], others: [], userAdded: []
        )

        let roster = { (pastTerm: [String]) in
            AppServiceBridge.uploadedRoster(selection: nil, live: false, pastTerm: pastTerm)
        }

        #expect(Self.uploads(answered.courses.map(\.courseNo), roster: roster(answered.roster)).map(\.asRoster) == [true])
        #expect(Self.uploads(waiting.courses.map(\.courseNo), roster: roster(waiting.roster)).map(\.asRoster) == [false])
    }

    @Test("A roster may leave out a course hidden here, but not one whose lookup failed")
    func rosterListsEveryShownCourse() {
        let roster = ["CS1", "CS2", "CS3"]

        #expect(Self.uploads(["CS1", "CS2"], roster: roster, hidden: ["1151:CS3"]).map(\.asRoster) == [true])
        #expect(Self.uploads(["CS1", "CS2"], roster: roster).map(\.asRoster) == [false])
    }

    @Test("A requested roster goes past the unchanged check; a fetch course selection did not answer forces nothing")
    func requestedRosterResendsOnlyARoster() {
        #expect(Self.uploads(["CS1"], roster: ["CS1"], resendingRoster: true)
            == [Upload(courses: ["CS1"], asRoster: true, resend: true)])
        #expect(Self.uploads(["CS1"], roster: nil, resendingRoster: true)
            == [Upload(courses: ["CS1"], asRoster: false, resend: false)])
    }

    @Test("A roster request goes to the school once, then again only after an hour or a new sign-in")
    func rosterRequestRetriesAfterAnHour() {
        var log = RosterRequestLog()
        let now = Date()
        let snapshot: [String: Any] = ["roster_requests": ["1151", "1151"]]

        #expect(log.termsToAsk(in: [:], generation: 1, now: now).isEmpty)
        #expect(log.termsToAsk(in: snapshot, generation: 1, now: now) == ["1151"])
        #expect(log.termsToAsk(in: snapshot, generation: 1, now: now + 3599).isEmpty)
        #expect(log.termsToAsk(in: snapshot, generation: 2, now: now + 3599) == ["1151"])
        #expect(log.termsToAsk(in: snapshot, generation: 2, now: now + 3599 + 3600) == ["1151"])
    }
}
