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
                ConflictPickerSheet(
                    title: String(localized: "conflict_course_picker_title"),
                    rows: target.courses.map(ConflictPickerSheet.Row.init(course:)),
                    onPick: { id in
                        if let course = target.courses.first(where: { $0.courseNo == id }) { viewModel.pickFromConflict(course) }
                    }
                )
                .presentationDetents([.medium])
            }
            .sheet(item: $viewModel.selection.clubPicker) { target in
                ConflictPickerSheet(
                    title: String(localized: "class_table_club_picker_title"),
                    rows: target.clubs.map(ConflictPickerSheet.Row.init(club:)),
                    onPick: { id in
                        if let club = target.clubs.first(where: { String($0.id) == id }) { viewModel.pickFromClubPicker(club) }
                    }
                )
                .presentationDetents([.medium])
            }
            .sheet(item: $viewModel.selection.club) { club in
                ClubActivityDetailSheet(club: club, policy: app.preferences.visualStylePolicy)
            }
            .sheet(isPresented: $editor.dialogs.showsClubSubscriptions, onDismiss: {
                Task { await SchoolRefresh.clubActivities() }
            }) {
                ClubSubscribeSheet(signIn: app.authService.session.currentSignIn)
                    .presentationDetents([.large])
            }
            .clubColorSheet($editor.dialogs.clubToRecolor, signIn: app.authService.session.currentSignIn)
    }
}
