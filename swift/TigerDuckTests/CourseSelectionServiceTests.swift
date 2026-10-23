import Foundation
import Testing
@testable import TigerDuck

struct CourseSelectionServiceTests {
    @Test("the list's course numbers are read, courses taken at NTU and NTNU too")
    func courseNosInTheList() {
        let html = """
        <table>
        <tr><th>課程代碼</th><th>課程名稱</th></tr>
        <tr>
            <td>CS1010001</td><td>程式設計</td>
        </tr>
        <tr><td>3CS1010002</td><td>離散數學</td></tr>
        <tr><td>3N1010003</td><td>機器學習</td></tr>
        <tr><td>3T1010004</td><td>教育心理學</td></tr>
        <tr><td>A1010005</td><td>不是課號</td></tr>
        <tr><td>12</td><td>總學分</td></tr>
        </table>
        """
        #expect(CourseSelectionService.courseNos(inListPage: html) == ["CS1010001", "3CS1010002", "3N1010003", "3T1010004"])
    }

    @Test("a course number is a head of 3 and two letters, two letters, or 3 and one letter, then 6 or 7 letters or digits",
          arguments: [
              ("CS1010001", true), ("CS101001", true), ("3CS1010002", true), ("3N1010003", true), ("3T101004", true),
              ("3NG115701", true), ("N1010003", false), ("CS10100", false), ("3N10100030", false), ("cs1010001", false),
              ("CS1010-01", false),
          ])
    func shape(text: String, isCourseNo: Bool) {
        #expect(CourseSelectionService.isCourseNo(text[...]) == isCourseNo)
    }
}
