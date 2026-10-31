import SwiftUI

/// The sheets and alerts of the user's edits of their own class table, on the iPhone and the Mac:
/// adding a course, renaming one and picking its colour.
struct ClassTableCourseEditDialogs: ViewModifier {
    let viewModel: ClassTableViewModel
    @Bindable var editor: ClassTableEditor

    @Environment(AppEnvironment.self) private var app

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $editor.dialogs.showAddCourse) {
                AddCourseSheet(
                    semester: viewModel.currentSemester,
                    tableCourses: viewModel.courses,
                    onAdd: { editor.addCourse($0) },
                    onRemove: { courseNo in
                        editor.removeUserAddedCourse(courseNo: courseNo)
                    }
                )
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
                // The conflict alert hangs off the sheet's content: on the parent, iOS
                // would dismiss the sheet to present it (one presentation per host
                // view). Here it shows above the search results without leaving search.
                .alert(
                    String(localized: "class_table_conflict_add_failed_title"),
                    isPresented: Binding(
                        get: { editor.dialogs.tripleConflictError != nil },
                        set: { if !$0 { editor.dialogs.tripleConflictError = nil } }
                    ),
                    presenting: editor.dialogs.tripleConflictError
                ) { _ in
                    Button(String(localized: "action_confirm"), role: .cancel) {
                        editor.dialogs.tripleConflictError = nil
                    }
                } message: { err in
                    Text(String(
                        format: String(localized: "class_table_conflict_add_failed_message"),
                        err.newCourseName,
                        AppConstants.Periods.shortWeekdayLabel(err.weekday),
                        err.periodId,
                        err.existingA.displayName,
                        err.existingB.displayName
                    ))
                }
            }
            .alert(String(localized: "class_table_rename_title"), isPresented: $editor.dialogs.showRenameAlert) {
                TextField(String(localized: "class_table_course_name"), text: $editor.dialogs.renameText)
                Button(String(localized: "action_confirm")) {
                    editor.confirmRename()
                }
                if let course = editor.dialogs.courseToRename, course.customName != nil {
                    Button(String(localized: "class_table_rename_revert"), role: .destructive) {
                        editor.revertRename(course)
                    }
                }
                Button(String(localized: "action_cancel"), role: .cancel) {
                    editor.dialogs.courseToRename = nil
                }
            } message: {
                if let course = editor.dialogs.courseToRename {
                    Text(String(format: String(localized: "class_table_rename_default_label"), course.courseName))
                }
            }
            .sheet(item: $editor.dialogs.courseToRecolor) { course in
                CourseColorPickerSheet(
                    course: course,
                    isCurrent: app.authService.session.currentCheck(),
                    onSelect: { editor.setColor(hex: $0, for: course) }
                )
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #else
                .frame(minWidth: 360, minHeight: 480)
                #endif
            }
    }
}
