#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// An exported class table keeps its file name wherever it is saved or sent,
/// so the name has to say what it is and whose, and survive every place a
/// file can land.
struct ClassTableExportTests {

    @Test("the name carries the title, the term and the student id")
    func namesTitleTermAndStudent() {
        let name = ClassTableExporter.fileName(title: "課表", semesterLabel: "114-2", studentId: "B11315000")
        #expect(name == "課表 114-2 B11315000.png")
    }

    @Test("a missing student id is dropped, not left as a trailing space")
    func dropsMissingStudentId() {
        #expect(ClassTableExporter.fileName(title: "課表", semesterLabel: "114-2", studentId: nil) == "課表 114-2.png")
        #expect(ClassTableExporter.fileName(title: "課表", semesterLabel: "114-2", studentId: "") == "課表 114-2.png")
    }

    /// Nothing stops a translation carrying a slash, and a path separator
    /// would put the file in a directory that does not exist.
    @Test("path characters are stripped, spaces inside a part are kept")
    func stripsUnsafeCharacters() {
        let name = ClassTableExporter.fileName(title: "Class table/Timetable", semesterLabel: "114-2", studentId: "B11315000")
        #expect(name == "Class tableTimetable 114-2 B11315000.png")
        #expect(ClassTableExporter.fileName(title: "Class table", semesterLabel: "114-2", studentId: nil) == "Class table 114-2.png")
    }
}
#endif
