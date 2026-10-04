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
        #expect(name == "課表_114-2_B11315000.png")
    }

    @Test("a missing student id is dropped, not left as a trailing underscore")
    func dropsMissingStudentId() {
        #expect(ClassTableExporter.fileName(title: "課表", semesterLabel: "114-2", studentId: nil) == "課表_114-2.png")
        #expect(ClassTableExporter.fileName(title: "課表", semesterLabel: "114-2", studentId: "") == "課表_114-2.png")
    }

    /// The English title is "Class table": a space inside a part has to go
    /// as well, not only the ones between parts.
    @Test("spaces become underscores, runs and ends included")
    func replacesSpaces() {
        #expect(ClassTableExporter.fileName(title: "Class table", semesterLabel: "114-2", studentId: nil) == "Class_table_114-2.png")
        #expect(ClassTableExporter.fileName(title: " Class   table ", semesterLabel: "114-2", studentId: nil) == "Class_table_114-2.png")
    }

    /// Nothing stops a translation carrying a slash, and a path separator
    /// would put the file in a directory that does not exist.
    @Test("path characters are stripped")
    func stripsUnsafeCharacters() {
        let name = ClassTableExporter.fileName(title: "Class table/Timetable", semesterLabel: "114-2", studentId: "B11315000")
        #expect(name == "Class_tableTimetable_114-2_B11315000.png")
    }
}
#endif
