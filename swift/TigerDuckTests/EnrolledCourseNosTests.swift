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

    @Test("The English proficiency test is matched by its name in either language")
    func englishTestMatchesByName() {
        let row = { (name: String) in
            CourseGrade(
                index: 1, term: "1141", code: "CC1011301", name: name, credits: 0, creditType: .normal,
                grade: "通過", status: .passed, remark: "", geDimension: nil, distanceLearning: false
            )
        }
        #expect(AppServiceBridge.isEnglishProficiencyTest(row("校定英文能力檢測")))
        #expect(AppServiceBridge.isEnglishProficiencyTest(row("English Proficiency Test")))
        #expect(!AppServiceBridge.isEnglishProficiencyTest(row("英文閱讀與寫作")))
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

    @Test("An empty answer records nothing and clears nothing: parser drift is not a mass drop")
    func emptyAnswerIsInert() {
        #expect(AppServiceBridge.selectionDrops(
            previous: ["C"], localPortalNos: ["A", "B"], roster: []
        ) == ["C"])
    }
}
