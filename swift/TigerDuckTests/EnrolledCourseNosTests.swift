import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct EnrolledCourseNosTests {
    private static func transcript(rows: [(term: String, code: String, name: String, grade: String, remark: String)]) -> ScoreReport {
        let cells = rows.enumerated().map { index, row -> String in
            "<tr><td>\(index + 1)</td><td>\(row.term)</td><td>\(row.code)</td><td>\(row.name)</td><td>2</td>"
                + "<td>\(row.grade)</td><td>\(row.remark)</td><td></td><td>否</td></tr>"
        }
        return NTUSTScoreParser.parse(html: """
        <html><body><div class="box">
          <div class="box-header"><h2>歷年學業成績列表</h2></div>
          <table>
            <tr><th>#</th><th>學期</th><th>課號</th><th>課名</th><th>學分</th>
                <th>成績</th><th>備註</th><th>向度</th><th>遠距</th></tr>
            \(cells.joined(separator: "\n"))
          </table>
        </div></body></html>
        """)
    }

    @Test("A past term built from the transcript takes only its graded and passed classes, NTU and NTNU ones too")
    func pastTermTakesTheTranscriptsClasses() throws {
        let report = Self.transcript(rows: [
            ("1141", "CS1001301", "程式設計", "A", ""),
            ("1141", "PE1001301", "體育", "通過", ""),
            ("1141", "GE1001301", "通識", "", "抵免"),
            ("1141", "CC1011301", "校定英文能力檢測", "通過", ""),
            ("1141", "MA1001301", "微積分", "二次退選", ""),
            ("1141", "3N1004701", "聯盟課程", "B+", ""),
            ("1141", "3T5287701", "聯盟課程", "A-", ""),
            ("1142", "EE1001301", "電路學", "A", ""),
        ])

        let term = try #require(AppServiceBridge.termCourseNos(
            selection: nil,
            transcript: AppServiceBridge.classRows(of: report, term: "1141").map(\.code),
            cached: []
        ))

        #expect(term.courseNos == ["CS1001301", "PE1001301", "3N1004701", "3T5287701"])
    }

    @Test("A transcript only adds: a term it lists late or in part keeps its cached courses and records no drops")
    func transcriptNeverShrinksATerm() throws {
        let term = try #require(AppServiceBridge.termCourseNos(
            selection: nil, transcript: ["CS1001301", "PE1001301"], cached: ["EE2005301", "CS1001301"]
        ))

        #expect(term.courseNos == ["CS1001301", "PE1001301", "EE2005301"])
        #expect(term.roster == nil)
    }

    @Test("A class the transcript adds joins its term only with class times; course selection's and cached ones stay")
    func transcriptClassesNeedClassTimes() {
        let courses = [
            SDCourse(courseNo: "CS1001301", courseName: "Timed", schedule: [2: ["3", "4"]], semester: "1141"),
            SDCourse(courseNo: "GE1001301", courseName: "No periods", semester: "1141"),
            SDCourse(courseNo: "MA1001301", courseName: "Empty day", schedule: [3: []], semester: "1141"),
            SDCourse(courseNo: "EE2005301", courseName: "Cached", semester: "1141"),
        ]

        let fromTranscript = AppServiceBridge.drawnCourses(courses, fromSelection: false, cached: ["EE2005301"])
        let fromSelection = AppServiceBridge.drawnCourses(courses, fromSelection: true, cached: [])

        #expect(fromTranscript.map(\.courseNo) == ["CS1001301", "EE2005301"])
        #expect(fromSelection.map(\.courseNo) == ["CS1001301", "GE1001301", "MA1001301", "EE2005301"])
    }

    @Test("The English proficiency test is matched by its course number, or by its exact name")
    func englishTestMatchesByNumberOrExactName() {
        let row = { (code: String, name: String) in
            CourseGrade(
                index: 1, term: "1141", code: code, name: name, credits: 0, creditType: .normal,
                grade: "通過", status: .passed, remark: "", geDimension: nil, distanceLearning: false
            )
        }
        #expect(AppServiceBridge.isEnglishProficiencyTest(row("CC1011301", "校定英文能力檢測")))
        #expect(AppServiceBridge.isEnglishProficiencyTest(row("CC1011301", "English Proficiency Test")))
        #expect(AppServiceBridge.isEnglishProficiencyTest(row("CC1019301", " 校定英文能力檢測 ")))
        #expect(!AppServiceBridge.isEnglishProficiencyTest(row("FL2001301", "English Proficiency Test Preparation")))
        #expect(!AppServiceBridge.isEnglishProficiencyTest(row("FL2002301", "校定英文能力檢測輔導")))
    }

    @Test("A past term whose transcript cannot be fetched, or lists nothing for it, keeps its cached courses")
    func noTranscriptKeepsTheCache() {
        #expect(AppServiceBridge.termCourseNos(selection: nil, transcript: nil, cached: ["CS1"]) == nil)
        #expect(AppServiceBridge.termCourseNos(selection: nil, transcript: [], cached: ["CS1"]) == nil)
    }

    @Test("Course selection answered: it owns the latest term and is its roster, so a stale transcript adds nothing")
    func selectionIsAuthoritative() throws {
        let term = try #require(AppServiceBridge.termCourseNos(
            selection: ["CS1", "CS2", "CS1"], transcript: ["CS1", "DROPPED"], cached: ["CS1", "OLD"]
        ))
        #expect(term.courseNos == ["CS1", "CS2"])
        #expect(term.roster == ["CS1", "CS2"])
    }

    @Test("Course selection unreachable or empty: the latest term falls back to the transcript")
    func latestTermFallsBackToTheTranscript() {
        let unreachable = AppServiceBridge.termCourseNos(selection: nil, transcript: ["CS3", "", "CS3", "PE9"], cached: [])
        #expect(unreachable?.courseNos == ["CS3", "PE9"])
        #expect(AppServiceBridge.termCourseNos(selection: [], transcript: ["PE9"], cached: [])?.courseNos == ["PE9"])
    }
}

struct SelectionDropsTests {
    @Test("A course the answer no longer names is recorded as dropped")
    func dropIsWitnessed() {
        #expect(AppServiceBridge.selectionDrops(
            previous: [], localPortalNos: ["A", "B", "C"], roster: ["A", "B"]
        ) == ["C"])
    }

    @Test("A course this device never held is not a drop — that is how a manual course from another device survives")
    func unknownCourseIsNotADrop() {
        #expect(AppServiceBridge.selectionDrops(
            previous: [], localPortalNos: ["A"], roster: ["A"]
        ).isEmpty)
    }

    @Test("A course the answer names again is cleared, so a re-add comes straight back")
    func readdClears() {
        #expect(AppServiceBridge.selectionDrops(
            previous: ["C", "D"], localPortalNos: ["A"], roster: ["A", "C"]
        ) == ["D"])
    }

    @Test("A dropped course added by hand here or on another device keeps its server row; one merged from the server does not")
    @MainActor
    func onlyCoursesAddedByHandOutliveADrop() {
        let rows: [[String: Any]] = [
            ["course_no": "CS1001301", "source": "ntust_portal"],
            ["course_no": "GE1010001", "source": "ntust_portal"],
            ["course_no": "EE2005301", "source": "ntust_portal"],
            ["course_no": "PE1001301", "source": "user_added"],
        ]
        let userAdded = [
            SDCourse(courseNo: "GE1010001", courseName: "Added here", semester: "1151"),
            SDCourse(courseNo: "EE2005301", courseName: "Merged", moodleIdNumber: "1151EE2005301", semester: "1151"),
        ]

        let kept = AppState.keptRows(
            rows, semester: "1151", dropped: ["GE1010001", "EE2005301", "PE1001301"], userAdded: userAdded
        )
        let listed = Set(kept.compactMap { $0["course_no"] as? String })

        #expect(listed == ["CS1001301", "GE1010001", "PE1001301"])
        let unlisted = AppState.unlistedCourses(
            in: "1151", listed: listed, tombstoned: [], fetched: ["CS1001301"],
            handAdded: ["GE1010001", "EE2005301"], hidden: [], adding: []
        )
        #expect(unlisted.drop == ["EE2005301"])
    }

    @Test("An empty answer records nothing and clears nothing: parser drift is not a mass drop")
    func emptyAnswerIsInert() {
        #expect(AppServiceBridge.selectionDrops(
            previous: ["C"], localPortalNos: ["A", "B"], roster: []
        ) == ["C"])
    }
}

@MainActor
struct PastTermRebuildTests {
    private static func course(_ courseNo: String, times: Bool = true, moodleId: String? = nil) -> SDCourse {
        SDCourse(
            courseNo: courseNo, courseName: courseNo, schedule: times ? [2: ["3", "4"]] : [:],
            moodleIdNumber: moodleId, semester: "1141"
        )
    }

    private static func looked(_ courseNo: String, times: Bool = true, answered: Bool = true) -> AppServiceBridge.LookedUpCourse {
        AppServiceBridge.LookedUpCourse(course: course(courseNo, times: times), answered: answered)
    }

    @Test("A past term keeps only the transcript's classes with class times; cached junk, Moodle sites and other rows are dropped")
    func junkLeavesAPastTerm() {
        let rebuilt = AppServiceBridge.rebuiltPastTerm(
            [Self.looked("CS1001301"), Self.looked("GE1001301", times: false)],
            cached: ["CS1001301", "GE1001301", "EC9999301"],
            others: ["PE9999301", "CC1011301", "CS1001301", "GE1001301"],
            userAdded: []
        )

        #expect(rebuilt.courses.map(\.courseNo) == ["CS1001301"])
        #expect(rebuilt.roster == ["CS1001301"])
        #expect(AppServiceBridge.selectionDrops(previous: [], localPortalNos: rebuilt.dropping, roster: rebuilt.roster)
            == ["GE1001301", "EC9999301", "PE9999301", "CC1011301"])
    }

    @Test("A class whose lookup failed keeps its cached copy and is never dropped; one with no copy waits for a later fetch")
    func failedLookupKeepsTheCachedCourse() {
        let rebuilt = AppServiceBridge.rebuiltPastTerm(
            [Self.looked("CS1001301", times: false, answered: false), Self.looked("MA1001301", times: false, answered: false)],
            cached: ["CS1001301"], others: [], userAdded: []
        )

        #expect(rebuilt.courses.map(\.courseNo) == ["CS1001301"])
        #expect(AppServiceBridge.selectionDrops(previous: [], localPortalNos: ["CS1001301", "MA1001301"], roster: rebuilt.roster)
            .isEmpty)
    }

    @Test("A failed transcript fetch, or one that lists nothing for the term, leaves a past term untouched")
    func noTranscriptTouchesNothing() {
        #expect(AppServiceBridge.termCourseNos(selection: nil, transcript: nil, cached: []) == nil)
        #expect(AppServiceBridge.termCourseNos(selection: nil, transcript: [], cached: []) == nil)
    }

    @Test("A course added by hand stays through a rebuild and the reconcile; junk merged from the server does not come back")
    func handAddedStaysAndJunkStaysGone() {
        let userAdded = [
            Self.course("GE1010001"),
            Self.course("PE1001301", moodleId: "1141PE1001301"),
            Self.course("EC9999301", moodleId: "1141EC9999301"),
        ]
        let rebuilt = AppServiceBridge.rebuiltPastTerm(
            [Self.looked("CS1001301")], cached: ["CS1001301"],
            others: ["GE1010001", "EC9999301"], userAdded: userAdded
        )
        #expect(!rebuilt.dropping.contains("GE1010001"))

        let dropped = AppServiceBridge.selectionDrops(previous: [], localPortalNos: rebuilt.dropping, roster: rebuilt.roster)
        let rows: [[String: Any]] = [
            ["course_no": "CS1001301", "source": "ntust_portal"],
            ["course_no": "GE1010001", "source": "ntust_portal"],
            ["course_no": "PE1001301", "source": "user_added"],
            ["course_no": "EC9999301", "source": "ntust_portal"],
        ]
        let listed = Set(AppState.keptRows(rows, semester: "1141", dropped: dropped, userAdded: userAdded)
            .compactMap { $0["course_no"] as? String })
        let unlisted = AppState.unlistedCourses(
            in: "1141", listed: listed, tombstoned: [], fetched: Set(rebuilt.courses.map(\.courseNo)),
            handAdded: Set(userAdded.map(\.courseNo)), hidden: [], adding: []
        )

        #expect(listed == ["CS1001301", "GE1010001", "PE1001301"])
        #expect(unlisted.drop == ["EC9999301"])
    }
}
