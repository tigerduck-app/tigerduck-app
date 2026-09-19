import Foundation
import Testing
@testable import TigerDuck

/// NTUST issues 0.5-credit courses. Credits used to be an `Int` end to end,
/// so every one of them parsed to zero: absent from the class table's total,
/// absent from the transcript row, and weightless in the GPA.
@MainActor
struct HalfCreditTests {

    /// Minimal shape of the transcript table the parser walks: a `div.box`
    /// whose header names the list, then one header row and one course row
    /// of at least nine cells.
    private static func transcriptHTML(credits: String) -> String {
        """
        <html><body>
        <div class="box">
          <div class="box-header"><h2>歷年學業成績列表</h2></div>
          <table>
            <tr><th>#</th><th>學期</th><th>課號</th><th>課名</th><th>學分</th>
                <th>成績</th><th>備註</th><th>向度</th><th>遠距</th></tr>
            <tr><td>1</td><td>1142</td><td>GE3001301</td><td>藝術與人生</td>
                <td>\(credits)</td><td>A</td><td></td><td>C</td><td>否</td></tr>
          </table>
        </div>
        </body></html>
        """
    }

    @Test("a half credit survives the transcript parser")
    func parsesHalfCredit() throws {
        let report = NTUSTScoreParser.parse(html: Self.transcriptHTML(credits: "0.5"))
        let course = try #require(report.courses.first)
        #expect(course.credits == 0.5)
        #expect(course.creditType == .normal)
    }

    /// The bracketed credit types share the same pattern list, so a half
    /// credit has to survive those too rather than falling through to
    /// `.unknown` with no credit at all.
    @Test("a bracketed half credit keeps both its value and its type")
    func parsesBracketedHalfCredit() throws {
        let report = NTUSTScoreParser.parse(html: Self.transcriptHTML(credits: "[0.5]"))
        let course = try #require(report.courses.first)
        #expect(course.credits == 0.5)
        #expect(course.creditType == .educationProgram)
    }

    @Test("whole credits still parse")
    func parsesWholeCredit() throws {
        let report = NTUSTScoreParser.parse(html: Self.transcriptHTML(credits: "3"))
        let course = try #require(report.courses.first)
        #expect(course.credits == 3)
    }

    @Test("half credits carry their weight in the GPA")
    func gpaWeighsHalfCredits() throws {
        func graded(_ code: String, credits: Double, grade: String) -> CourseGrade {
            CourseGrade(
                index: nil, term: "1142", code: code, name: code, credits: credits,
                creditType: .normal, grade: grade, status: .graded, remark: "",
                geDimension: nil, distanceLearning: false
            )
        }
        // A+ (4.3) over 0.5 credits and C (2.0) over 1.5 → weighted 2.575.
        let gpa = try #require(NTUSTGradePoints.gpa(of: [
            graded("A", credits: 0.5, grade: "A+"),
            graded("B", credits: 1.5, grade: "C"),
        ]))
        #expect(abs(gpa - (4.3 * 0.5 + 2.0 * 1.5) / 2.0) < 1e-9)
    }

    /// Locale-safe: assert the shape, not the glyphs. A whole number carries
    /// no fraction; a half does, and reads differently from zero.
    @Test("credits print without a trailing .0")
    func formatsCredits() {
        let separator = Locale.current.decimalSeparator ?? "."
        #expect(!Double(3).creditsText.contains(separator))
        #expect(Double(0.5).creditsText.contains(separator))
        #expect(Double(0.5).creditsText != Double(0).creditsText)
        #expect(Double(1.5).creditsText != Double(1).creditsText)
    }
}
