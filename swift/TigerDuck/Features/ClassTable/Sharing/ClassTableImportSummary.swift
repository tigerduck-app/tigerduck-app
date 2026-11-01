import Foundation
import TigerDuckCore

enum ClassTableImportSummary {
    struct Row: Equatable {
        let title: String
        let value: String
    }

    static func rows(for code: ClassTableShareCode) -> [Row] {
        var rows: [Row] = []
        if let studentId = code.studentId {
            rows.append(Row(title: String(localized: "sign_in_student_id"), value: studentId))
        }
        rows.append(Row(
            title: String(localized: "class_table_semester_picker_label"),
            value: ListFormatter.localizedString(byJoining: code.terms.map { semesterLabel($0.semester) })
        ))
        rows.append(Row(
            title: String(localized: "class_table_import_course_count"),
            value: code.terms.reduce(0) { $0 + $1.courseNos.count }.formatted()
        ))
        if let sharedAt = code.sharedAt {
            rows.append(Row(
                title: String(localized: "class_table_import_shared_at"),
                value: sharedAt.formatted(date: .numeric, time: .shortened)
            ))
        }
        return rows
    }

    nonisolated static func semesterLabel(_ semester: String) -> String {
        AcademicTerm.label(of: semester)
    }
}
