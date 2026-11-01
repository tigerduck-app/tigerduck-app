#if os(macOS)
import SwiftUI

struct MacCourseDetailOverlay: View {
    let viewModel: ClassTableViewModel
    @Binding var moodlePath: [MoodleCourseRoute]

    var body: some View {
        if let course = viewModel.selection.course {
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.selection.course = nil }

                CourseDetailSheet(
                    course: course,
                    assignments: viewModel.assignmentsFor(courseNo: course.courseNo),
                    timeRange: viewModel.selection.timeRange,
                    weekday: viewModel.selection.weekday,
                    periods: viewModel.selection.coursePeriods,
                    moodlePath: $moodlePath,
                    showsMoodle: viewModel.shownPerson == nil
                )
                .frame(maxWidth: 560, maxHeight: 620)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                .onTapGesture { }

                // Restore ESC dismissal: custom overlays don't inherit a sheet's automatic
                // cancel handling.
                Button("") {
                    if moodlePath.isEmpty {
                        viewModel.selection.course = nil
                    } else {
                        moodlePath.removeLast()
                    }
                }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
#endif
