import SwiftUI

struct ClassTableEditDialogs: ViewModifier {
    @Bindable var viewModel: ClassTableViewModel
    @Bindable var editor: ClassTableEditor

    @Environment(AppEnvironment.self) private var app

    func body(content: Content) -> some View {
        content
            .modifier(ClassTableCourseEditDialogs(viewModel: viewModel, editor: editor))
            .sheet(item: $viewModel.selection.course) { course in
                CourseDetailSheet(
                    course: course,
                    assignments: viewModel.assignmentsFor(courseNo: course.courseNo),
                    timeRange: viewModel.selection.timeRange,
                    weekday: viewModel.selection.weekday,
                    periods: viewModel.selection.coursePeriods,
                    date: viewModel.selection.date,
                    slot: viewModel.selection.currentClassSlot,
                    showsMoodle: viewModel.shownPerson == nil
                )
                .linkRouting()
            }
            .alert(
                String(
                    format: String(localized: "class_table_reset_title_with_semester"),
                    viewModel.displayLabel(for: viewModel.currentSemester)
                ),
                isPresented: $editor.dialogs.showResetConfirm
            ) {
                Button(String(localized: "action_confirm"), role: .destructive) {
                    editor.resetCourses(authService: app.authService)
                }
                Button(String(localized: "action_cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "class_table_reset_message"))
            }
            .alert(
                String(
                    format: String(localized: "class_table_reset_title_with_semester"),
                    viewModel.displayLabel(for: viewModel.currentSemester)
                ),
                isPresented: $editor.dialogs.showResetFailedAlert
            ) {
                Button(String(localized: "action_confirm"), role: .cancel) {}
            } message: {
                Text(String(localized: "error_network_unavailable"))
            }
            .sheet(item: $viewModel.selection.conflictPickerTarget) { target in
                ConflictCoursePickerSheet(
                    courses: target.courses,
                    onPick: { viewModel.pickFromConflict($0) }
                )
                .presentationDetents([.medium])
            }
    }
}
