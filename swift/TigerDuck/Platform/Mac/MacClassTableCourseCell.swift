#if os(macOS)
import SwiftUI
import Defaults

/// A course on the Mac class table: its name, teacher and room on the course's colour, with its
/// edit menu.
struct MacClassTableCourseCell: View {
    let viewModel: ClassTableViewModel
    let course: CourseStore.Course
    var roomHint: String? = nil

    @Default(.outlineRequiredCourses) private var outlineRequiredCourses

    private var isViewingCurrentSemester: Bool {
        viewModel.currentSemester == SchoolTerms.current
    }

    static func spokenName(_ course: CourseStore.Course, ignoresAssignments: Bool) -> String {
        guard ignoresAssignments else { return course.displayName }
        return course.displayName + ", " + String(localized: "a11y_class_table_cell_assignments_ignored")
    }

    private static let ignoredMarkSize: CGFloat = 11

    var body: some View {
        let color = TigerDuckTheme.courseColor(for: course.courseNo)
        let ignored = viewModel.editor.ignoresAssignments(of: course.courseNo)
        return VStack(alignment: .leading, spacing: 3) {
            Text(course.displayName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            if !course.instructor.isEmpty {
                Text(course.instructor)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let roomHint {
                Text(roomHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.trailing, ignored ? Self.ignoredMarkSize + 6 : 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.4))
            }
        )
        .overlay {
            let edge = RoundedRectangle(cornerRadius: 8, style: .continuous)
            if outlineRequiredCourses, course.isRequired {
                edge.strokeBorder(color, lineWidth: 1)
            } else {
                edge.stroke(color.opacity(0.6), lineWidth: 0.5)
            }
        }
        .ignoredAssignmentsBadge(show: ignored, iconSize: Self.ignoredMarkSize, padding: 8)
        .contentShape(Rectangle())
        .courseEditMenu(isEditable: viewModel.shownPerson == nil) {
            if isViewingCurrentSemester {
                Button {
                    viewModel.editor.startRename(course)
                } label: {
                    Label(String(localized: "class_table_rename_title"), systemImage: "pencil")
                }
            }
            Button {
                viewModel.editor.startRecolor(course)
            } label: {
                Label(String(localized: "course_color_picker_title"), systemImage: "paintpalette")
            }
            if isViewingCurrentSemester {
                Button {
                    viewModel.editor.setIgnoresAssignments(!ignored, for: course)
                } label: {
                    if ignored {
                        Label(String(localized: "class_table_ignore_assignments_undo"), systemImage: "arrow.uturn.backward")
                    } else {
                        Label(String(localized: "class_table_ignore_assignments"), systemImage: "archivebox")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    viewModel.editor.deleteCourse(course)
                } label: {
                    Label(String(localized: "class_table_delete"), systemImage: "trash")
                }
            }
        }
    }
}
#endif
