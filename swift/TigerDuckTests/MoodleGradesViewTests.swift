import Foundation
import SwiftUI
import Testing
@testable import TigerDuck

/// What the grades screen writes for an item: the most it could be only beside a grade that is a
/// number, the value VoiceOver reads, the kind's icon and the activity a long press opens.
@MainActor
struct MoodleGradeItemDisplayTests {
    private static func item(grade: String?, max: Double? = 100, module: String? = "assign", cmid: Int? = 9101) -> MoodleGradeItem {
        MoodleGradeItem(
            id: 1, name: "Lab 1", type: module == nil ? "manual" : "mod", module: module, cmid: cmid,
            grade: grade, maxGrade: max, isHidden: false, feedback: ""
        )
    }

    @Test("the most is written beside a number, never beside a letter, a percentage or a scale's word")
    func maxBesideNumbersOnly() {
        #expect(Self.item(grade: "92.00").maxText == "100")
        #expect(Self.item(grade: "0").maxText == "100")
        #expect(Self.item(grade: "7,5", max: 10).maxText == "10")
        #expect(Self.item(grade: "9.5", max: 12.5).maxText == "12.5")
        #expect(Self.item(grade: "1200", max: 1500).maxText == "1500")
        #expect(Self.item(grade: "A-").maxText == nil)
        #expect(Self.item(grade: "92.00 %").maxText == nil)
        #expect(Self.item(grade: "Satisfactory", max: 3).maxText == nil)
        #expect(Self.item(grade: "92.00", max: nil).maxText == nil)
    }

    @Test("VoiceOver reads the grade with the most it could be")
    func spokenGrade() {
        #expect(Self.item(grade: "92.00").spokenGrade == "92.00 / 100")
        #expect(Self.item(grade: "A-").spokenGrade == "A-")
    }

    @Test("an assignment, a quiz and any other item each have their icon")
    func symbols() {
        #expect(Self.item(grade: "1", module: "assign").symbol == "doc.text")
        #expect(Self.item(grade: "1", module: "quiz").symbol == "checklist")
        #expect(Self.item(grade: "1", module: "workshop").symbol == "number")
        #expect(Self.item(grade: "1", module: nil, cmid: nil).symbol == "number")
    }

    @Test("a long press opens the item's activity, and an item no activity gives has none")
    func activityPage() {
        #expect(Self.item(grade: "1").activityPage == MoodlePage(path: "/mod/assign/view.php?id=9101"))
        #expect(Self.item(grade: "1", module: nil, cmid: nil).activityPage == nil)
        #expect(Self.item(grade: "1", cmid: nil).activityPage == nil)
        #expect(Self.item(grade: "1", module: "../login").activityPage == nil)
        #expect(MoodlePage.gradeReport(courseId: 20119).path == "/grade/report/user/index.php?id=20119")
    }
}

#if os(iOS)
import UIKit

/// The grade row laid out in a hosting controller: the name stops at two lines however long it
/// runs, and only feedback opened under the row makes it taller.
@MainActor
struct MoodleGradeRowTests {
    private static let longName = String(repeating: "期末專題書面報告與口頭簡報（含同儕互評）", count: 6)

    private static func item(name: String, feedback: String = "") -> MoodleGradeItem {
        MoodleGradeItem(
            id: 1, name: name, type: "mod", module: "assign", cmid: 9101, grade: "100.00",
            maxGrade: 100, isHidden: false, feedback: feedback
        )
    }

    private func height(_ item: MoodleGradeItem, expanded: Bool = false) -> CGFloat {
        let host = UIHostingController(
            rootView: MoodleGradeRow(item: item, accent: .blue, isExpanded: .constant(expanded))
        )
        return host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)).height
    }

    @Test("the name stops at two lines, so a longer one does not grow the row")
    func nameStopsAtTwoLines() {
        let short = height(Self.item(name: "Lab 1"))
        let long = height(Self.item(name: Self.longName))
        let longer = height(Self.item(name: Self.longName + Self.longName))

        #expect(long > short)
        #expect(abs(longer - long) < 0.5, "row grew from \(long)pt to \(longer)pt")
    }

    @Test("feedback shows under the row only while it is open")
    func feedbackOpensInPlace() {
        let item = Self.item(name: "Lab 1", feedback: "Clear structure, **good** tests.")

        #expect(height(item, expanded: true) > height(item) + 10)
    }
}
#endif
