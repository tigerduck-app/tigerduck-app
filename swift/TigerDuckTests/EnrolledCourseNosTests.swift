import Foundation
import os
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

    @Test("A fetch saves no course dropped on the server unless a live answer or a final transcript lists it")
    func savedCoursesSkipServerDrops() {
        let courses = ["CS1001301", "MA1010003"].map { SDCourse(courseNo: $0, courseName: $0, semester: "1151") }
        let saved = { (pastTerm: Bool, live: Bool, dropped: Set<String>) in
            AppServiceBridge.savedCourses(courses, pastTerm: pastTerm, live: live, dropped: dropped)?.map(\.courseNo)
        }

        #expect(saved(false, false, ["MA1010003"]) == ["CS1001301"])
        #expect(saved(false, false, ["CS1001301", "MA1010003"]) == [])
        #expect(saved(false, true, ["MA1010003"]) == ["CS1001301", "MA1010003"])
        #expect(saved(true, false, ["MA1010003"]) == ["CS1001301", "MA1010003"])
    }

    @Test("A fetch that drew nothing keeps the cache, unless a past term's final transcript lists no class")
    func emptyDrawKeepsTheCache() {
        #expect(AppServiceBridge.savedCourses([], pastTerm: false, live: false, dropped: []) == nil)
        #expect(AppServiceBridge.savedCourses([], pastTerm: true, live: false, dropped: [])?.isEmpty == true)
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
            handAdded: ["GE1010001", "EE2005301"], droppedMerges: [], hidden: [], adding: []
        )
        #expect(unlisted.drop == ["EE2005301"])
    }

    private static var rowsAfterARoster: [[String: Any]] {
        [
            ["course_no": "CS1001301", "source": "ntust_portal", "enrollment_status": "enrolled"],
            ["course_no": "PE1001301", "source": "ntust_portal"],
            ["course_no": "GE1010001", "source": "ntust_portal", "enrollment_status": "dropped"],
            ["course_no": "EE2005301", "source": "ntust_portal", "enrollment_status": "dropped"],
            ["course_no": "MA1010003", "source": "ntust_portal", "enrollment_status": "dropped"],
            ["course_no": "PH1010004", "source": "ntust_portal", "enrollment_status": "dropped"],
        ]
    }

    private static var addedAndMerged: [SDCourse] {
        [
            SDCourse(courseNo: "GE1010001", courseName: "Added here", semester: "1151"),
            SDCourse(courseNo: "EE2005301", courseName: "Merged", moodleIdNumber: "1151EE2005301", semester: "1151"),
        ]
    }

    @Test("A row a roster dropped is not merged and takes its merged copy along; a hand-add here stays")
    @MainActor
    func serverDropLeavesLikeASelectionDrop() {
        let listed = Set(AppState.keptRows(
            Self.rowsAfterARoster, semester: "1151", dropped: [], userAdded: Self.addedAndMerged
        ).compactMap { $0["course_no"] as? String })
        let unlisted = AppState.unlistedCourses(
            in: "1151", listed: listed, tombstoned: [], fetched: ["CS1001301"],
            handAdded: ["GE1010001", "EE2005301"], droppedMerges: [], hidden: [], adding: []
        )

        #expect(listed == ["CS1001301", "PE1001301", "GE1010001"])
        #expect(unlisted.drop == ["EE2005301"])
    }

    @MainActor
    private static func makeCache(fetched: [String], userAdded: [SDCourse]) -> TestCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionDropsTests-\(UUID().uuidString)", isDirectory: true)
        let cache = TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        cache.courses.saveCourses(fetched.map { SDCourse(courseNo: $0, courseName: $0, semester: "1151") }, semester: "1151")
        cache.courses.saveUserAddedCourses(userAdded)
        return cache
    }

    @Test("A course a roster dropped leaves the courses fetched here, with no hide, unless course selection listed it live since",
          arguments: [nil, -3600, 3600] as [TimeInterval?])
    @MainActor
    func serverDropLeavesFetchedCourses(answeredSinceDrop offset: TimeInterval?) {
        let droppedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = Self.rowsAfterARoster.map { row in
            row.merging(["updated_at": TigerDuckDateFormatters.withFractional.string(from: droppedAt)]) { kept, _ in kept }
        }
        let cache = Self.makeCache(fetched: ["CS1001301", "MA1010003"], userAdded: Self.addedAndMerged)
        var forgotten = 0

        let term = AppState.readTerm(
            "1151", rows: rows, tombstones: [], selectionDropped: [], userAdded: Self.addedAndMerged, hidden: [],
            adding: [], liveAnswer: offset.map { (courseNos: ["CS1001301", "MA1010003"], at: droppedAt + $0) },
            courses: cache.courses, forgetAnswer: { forgotten += 1 }
        )

        let keptLive = offset == 3600
        #expect(term.left == (keptLive ? [] : ["MA1010003"]))
        #expect(cache.courses.loadCourses(semester: "1151").map(\.courseNo) == (keptLive ? ["CS1001301", "MA1010003"] : ["CS1001301"]))
        #expect(term.serverNos.contains("MA1010003") == keptLive)
        #expect(forgotten == (offset == -3600 ? 1 : 0))
        #expect(term.unlisted.hide.isEmpty)
        #expect(term.unlisted.drop == ["EE2005301"])
        #expect(cache.courses.loadDeletedCourseNos().isEmpty)
        let alsoDropped: Set<String> = ["GE1010001", "EE2005301", "PH1010004"]
        #expect(cache.courses.loadServerDroppedNos(semester: "1151") == alsoDropped.union(keptLive ? [] : ["MA1010003"]))
    }

    @Test("A course dropped on the server leaves the term's cached courses in every language")
    @MainActor
    func serverDropLeavesEveryLanguage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDropTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        let cache = TestCache(cacheDir: cacheDir, persistentDir: root.appendingPathComponent("persistent", isDirectory: true))
        cache.courses.saveCourses(["CS1001301", "MA1010003"].map { SDCourse(courseNo: $0, courseName: $0, semester: "1151") }, semester: "1151")
        let files = FileManager.default
        let current = try #require(try files.contentsOfDirectory(atPath: cacheDir.path).first { $0.hasPrefix("courses_1151_") })
        let other = cacheDir.appendingPathComponent("courses_1151_other.json")
        try files.copyItem(at: cacheDir.appendingPathComponent(current), to: other)

        cache.courses.removeCourses(["MA1010003"], semester: "1151")
        let currentLeft = cache.courses.loadCourses(semester: "1151").map(\.courseNo)
        try files.removeItem(at: cacheDir.appendingPathComponent(current))
        try files.moveItem(at: other, to: cacheDir.appendingPathComponent(current))

        #expect(currentLeft == ["CS1001301"])
        #expect(cache.courses.loadCourses(semester: "1151").map(\.courseNo) == ["CS1001301"])
    }

    @Test("A course selection answer older than a drop is forgotten even when this language's cache lacks the course")
    @MainActor
    func staleAnswerForgottenWithoutLocalCopy() {
        let droppedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let rows: [[String: Any]] = [[
            "course_no": "MA1010003", "source": "ntust_portal", "enrollment_status": "dropped",
            "updated_at": TigerDuckDateFormatters.withFractional.string(from: droppedAt),
        ]]
        var forgotten = 0

        let term = AppState.readTerm(
            "1151", rows: rows, tombstones: [], selectionDropped: [], userAdded: [], hidden: [], adding: [],
            liveAnswer: (courseNos: ["CS1001301", "MA1010003"], at: droppedAt - 3600),
            courses: Self.makeCache(fetched: ["CS1001301"], userAdded: []).courses, forgetAnswer: { forgotten += 1 }
        )

        #expect(term.left.isEmpty)
        #expect(forgotten == 1)
    }

    @Test("A term whose every server row a roster dropped is not empty on the server, so its courses do not go up again")
    @MainActor
    func termOfDroppedRowsIsNotEmpty() {
        let read = { (rows: [[String: Any]]) in
            AppState.readTerm(
                "1151", rows: rows, tombstones: [], selectionDropped: ["EE2005301"], userAdded: [], hidden: [], adding: [],
                liveAnswer: nil, courses: Self.makeCache(fetched: ["CS1001301"], userAdded: []).courses, forgetAnswer: {}
            )
        }
        let dropped: [[String: Any]] = [["course_no": "MA1010003", "enrollment_status": "dropped"]]

        #expect(!read(dropped).serverHoldsNothing)
        #expect(read([]).serverHoldsNothing)
        #expect(read([["course_no": "EE2005301", "enrollment_status": "enrolled"]]).serverHoldsNothing)
    }

    @Test("A merged copy leaves when every row of its term was dropped on the server; a hand-add here stays")
    @MainActor
    func serverDropEmptyingATermTakesMergedCopies() {
        let rows = Self.rowsAfterARoster.filter { $0["course_no"] as? String != "GE1010001" }
            .map { $0.merging(["enrollment_status": "dropped"]) { _, dropped in dropped } }
        let droppedOnServer = AppState.droppedOnServer(rows)
        let kept = AppState.keptRows(rows, semester: "1151", dropped: [], userAdded: Self.addedAndMerged)
        let unlisted = AppState.unlistedCourses(
            in: "1151", listed: [], tombstoned: [], fetched: [], handAdded: ["GE1010001", "EE2005301"],
            droppedMerges: AppState.droppedMerges(Self.addedAndMerged, semester: "1151", dropped: droppedOnServer),
            hidden: [], adding: []
        )

        #expect(kept.isEmpty)
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
            [Self.looked("CS1001301"), Self.looked("GE1001301", times: false)], unreadable: [],
            cached: ["CS1001301", "GE1001301", "EC9999301"].map { Self.course($0) },
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
            unreadable: [], cached: [Self.course("CS1001301")], others: [], userAdded: []
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
            [Self.looked("CS1001301")], unreadable: [], cached: [Self.course("CS1001301")],
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
            handAdded: Set(userAdded.map(\.courseNo)), droppedMerges: [], hidden: [], adding: []
        )

        #expect(listed == ["CS1001301", "GE1010001", "PE1001301"])
        #expect(unlisted.drop == ["EC9999301"])
    }

    @Test("Junk merged from the server leaves even when the drops leave the term no server row; a hand-add stays")
    func droppedMergeLeavesATermWithNoRowLeft() {
        let userAdded = [Self.course("GE1010001"), Self.course("EC9999301", moodleId: "1141EC9999301")]
        let dropped: Set<String> = ["GE1010001", "EC9999301"]
        let rows: [[String: Any]] = [["course_no": "EC9999301", "source": "ntust_portal"]]

        let listed = Set(AppState.keptRows(rows, semester: "1141", dropped: dropped, userAdded: userAdded)
            .compactMap { $0["course_no"] as? String })
        let unlisted = AppState.unlistedCourses(
            in: "1141", listed: listed, tombstoned: [], fetched: [], handAdded: Set(userAdded.map(\.courseNo)),
            droppedMerges: AppState.droppedMerges(userAdded, semester: "1141", dropped: dropped),
            hidden: [], adding: []
        )

        #expect(listed.isEmpty)
        #expect(unlisted.drop == ["EC9999301"])
    }

    private static func report(_ rows: [(term: String, code: String, status: GradeStatus)]) -> ScoreReport {
        ScoreReport(student: "", currentTerm: "", rankings: [], courses: rows.map {
            CourseGrade(
                index: nil, term: $0.term, code: $0.code, name: $0.code, credits: 2, creditType: .normal,
                grade: "", status: $0.status, remark: "", geDimension: nil, distanceLearning: false
            )
        }, creditSummary: .empty)
    }

    @Test("The newest term the transcript lists only adds: a just-ended term listed in part, or one still running")
    func newestListedTermOnlyAdds() {
        let rebuilds = AppServiceBridge.rebuildsFromTranscript
        let justEnded = Self.report([("1141", "CS1001301", .graded), ("1142", "MA1001301", .pending)])
        #expect(!rebuilds(justEnded, "1142", false))
        #expect(rebuilds(justEnded, "1141", false))

        let running = Self.report([("1141", "CS1001301", .graded), ("1142", "MA1001301", .unknown), ("1151", "GE1001301", .exempted)])
        #expect(!rebuilds(running, "1142", false))
        #expect(!rebuilds(running, "1141", true))
        #expect(!rebuilds(nil, "1141", false))
        #expect(rebuilds(Self.report([("991", "CS1001301", .graded), ("1001", "MA1001301", .graded)]), "991", false))
    }

    @Test("A summer term follows its year's second term: a running one only adds, an ended one is rebuilt")
    func summerTermFollowsTheSecondTerm() {
        let rebuilds = AppServiceBridge.rebuildsFromTranscript
        let running = Self.report([("1141", "CS1001301", .graded), ("1142", "MA1001301", .graded), ("114H", "PE1001301", .unknown)])
        #expect(!rebuilds(running, "114H", false))
        #expect(rebuilds(running, "1142", false))

        let ended = Self.report([("114H", "PE1001301", .graded), ("1151", "GE1001301", .graded)])
        #expect(rebuilds(ended, "114H", false))

        let padded = Self.report([("98 2", "CS1001301", .graded), ("99 1", "MA1001301", .graded)])
        #expect(rebuilds(padded, "98 2", false))
        #expect(!rebuilds(padded, "99 1", false))
    }

    @Test("A row the course query cannot read keeps its cached copy; rows the rule leaves out and courses off the transcript are dropped")
    func unreadableRowKeepsItsCachedCopy() {
        let report = Self.report([
            ("1141", "CS1001301", .graded), ("1141", "NTU-CSIE-101", .graded), ("1141", "MA1001301", .withdrew),
        ])
        let unreadable = AppServiceBridge.unreadableClassRows(of: report, term: "1141").map(\.code)
        let rebuilt = AppServiceBridge.rebuiltPastTerm(
            [Self.looked("CS1001301")], unreadable: unreadable,
            cached: ["CS1001301", "NTU-CSIE-101", "MA1001301", "EC9999301"].map { Self.course($0) },
            others: report.courses.map(\.code), userAdded: []
        )

        #expect(unreadable == ["NTU-CSIE-101"])
        #expect(rebuilt.courses.map(\.courseNo) == ["CS1001301", "NTU-CSIE-101"])
        #expect(AppServiceBridge.selectionDrops(previous: [], localPortalNos: rebuilt.dropping, roster: rebuilt.roster)
            == ["MA1001301", "EC9999301"])
    }

    @Test("An ended term whose transcript leaves no class to draw is saved empty and drops what it held")
    func emptyRebuildDropsWhatItHeld() {
        let report = Self.report([
            ("1141", "TH9001301", .graded), ("1141", "MA1001301", .withdrew), ("1142", "CS1001301", .graded),
        ])
        #expect(AppServiceBridge.rebuildsFromTranscript(report, term: "1141", servedBySelection: false))

        let rebuilt = AppServiceBridge.rebuiltPastTerm(
            [Self.looked("TH9001301", times: false)], unreadable: [], cached: [Self.course("EE2005301")],
            others: ["TH9001301", "MA1001301"], userAdded: []
        )

        #expect(rebuilt.courses.isEmpty)
        #expect(rebuilt.roster.isEmpty)
        #expect(AppServiceBridge.selectionDrops(
            previous: [], localPortalNos: rebuilt.dropping, roster: rebuilt.roster, isFinal: true
        ) == ["EE2005301", "TH9001301", "MA1001301"])
        #expect(AppServiceBridge.selectionDrops(previous: [], localPortalNos: ["EE2005301"], roster: []).isEmpty)
    }

    @Test("A term the transcript lists only through exempted rows is not rebuilt")
    func exemptedOnlyTermIsNotRebuilt() {
        let report = Self.report([("1141", "GE1001301", .exempted), ("1142", "CS1001301", .graded)])
        #expect(!AppServiceBridge.rebuildsFromTranscript(report, term: "1141", servedBySelection: false))
    }

    @Test("A hand-added course filled in from its server row keeps having no Moodle ID")
    func filledHandAddKeepsNoMoodleId() {
        let added = SDCourse(courseNo: "GE1010001", courseName: "Added here", semester: "1141")
        let row: [String: Any] = [
            "course_no": "GE1010001", "moodle_id": "1141GE1010001", "schedule_json": ["2": ["3", "4"]],
        ]

        let filled = AppState.scheduled(added, fromServerRow: row)

        #expect(filled.schedule == [2: ["3", "4"]])
        #expect(filled.moodleIdNumber == nil)
    }
}

@MainActor
struct WarmTermsTests {
    @Test("Shared answers that outlive a sign-out reach no term; the terms save under the sign-in they were fetched in")
    func answersFromAnotherAccountReachNoTerm() async {
        let account = AccountSession()
        let calls = OSAllocatedUnfairLock(initialState: [String: AccountSession.Ticket]())
        let fetch: @Sendable (String, AccountSession.Ticket, [MoodleEnrolledCourse]?, ScoreReport?) async -> Void = {
            semester, ticket, _, _ in calls.withLock { $0[semester] = ticket }
        }

        await AppServiceBridge.warmTerms(["1141", "1142"], account: account, shared: {
            account.moveOn()
            return (nil, nil)
        }, fetch: fetch)
        #expect(calls.withLock { $0 }.isEmpty)

        await AppServiceBridge.warmTerms(["1141", "1142"], account: account, shared: { (nil, nil) }, fetch: fetch)
        #expect(calls.withLock { $0 } == ["1141": account.ticket, "1142": account.ticket])
    }
}
