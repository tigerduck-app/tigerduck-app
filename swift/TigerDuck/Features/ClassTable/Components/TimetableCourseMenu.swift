import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

func spokenCourse(
    _ course: CourseStore.Course, room: String? = nil, changes: [String] = [], hasAssignment: Bool, ignoresAssignments: Bool
) -> String {
    var parts = [course.displayName]
    if let room { parts.append(room) }
    parts += changes
    if hasAssignment { parts.append(String(localized: "a11y_class_table_cell_assignment_indicator")) }
    if ignoresAssignments { parts.append(String(localized: "a11y_class_table_cell_assignments_ignored")) }
    return parts.joined(separator: ", ")
}

extension Shape {
    func innerOutline(_ color: Color) -> some View {
        stroke(color, lineWidth: 2).clipShape(self)
    }
}

struct TimetableCellMetrics {
    let cellHeight: CGFloat
    let rowSpacing: CGFloat
    let courseNameSize: CGFloat
    let badgeIconSize: CGFloat

    var roomHintSize: CGFloat { courseNameSize * 0.85 }

    func height(spanning periods: Int) -> CGFloat {
        CGFloat(periods) * cellHeight + CGFloat(periods - 1) * rowSpacing
    }
}

extension Text {
    func timetableBlockName(
        metrics: TimetableCellMetrics, policy: VisualStylePolicy, lineLimit: Int, isCancelled: Bool = false
    ) -> some View {
        font(.system(size: metrics.courseNameSize, weight: policy.classTableCourseNameWeight))
            .strikethrough(isCancelled)
            .foregroundStyle(policy.classTableCourseTextColor.opacity(isCancelled ? 0.45 : 1))
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
            .padding(2)
    }

    func timetableBlockRoom(metrics: TimetableCellMetrics, policy: VisualStylePolicy) -> some View {
        font(.system(size: metrics.roomHintSize))
            .foregroundStyle(policy.classTableCourseSecondaryTextColor)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

struct TimetableCourseMenu: View {
    let course: CourseStore.Course
    let editor: ClassTableEditor
    var showsColorDot = false

    var body: some View {
        Button {
            editor.startRename(course)
        } label: {
            Label(String(localized: "class_table_rename_title"), systemImage: "pencil")
        }
        Button {
            editor.startRecolor(course)
        } label: {
            if showsColorDot {
                Label {
                    Text(String(localized: "class_table_pick_color"))
                } icon: {
                    Self.colorDot(course.color)
                }
            } else {
                Label(String(localized: "course_color_picker_title"), systemImage: "paintpalette")
            }
        }
        if editor.offersIgnoreAssignments {
            let ignored = editor.ignoresAssignments(of: course.courseNo)
            Button {
                editor.setIgnoresAssignments(!ignored, for: course)
            } label: {
                if ignored {
                    Label(String(localized: "class_table_ignore_assignments_undo"), systemImage: "arrow.uturn.backward")
                } else {
                    Label(String(localized: "class_table_ignore_assignments"), systemImage: "archivebox")
                }
            }
        }
        Button(role: .destructive) {
            editor.deleteCourse(course)
        } label: {
            Label(String(localized: "class_table_delete"), systemImage: "trash")
        }
    }

    /// Drawn into a bitmap and marked `.alwaysOriginal` because UIKit retints
    /// template images, SF Symbols included, to the menu's own tint, so
    /// `Image(systemName: "circle.fill").foregroundStyle(...)` arrives grey.
    /// It rides on the "Pick color" row because UIKit renders an inline menu's
    /// section header from its title alone and drops any image it carries.
    private static func colorDot(_ color: Color) -> Image {
        #if canImport(UIKit)
        let side: CGFloat = 16
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            UIColor(color).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return Image(uiImage: rendered.withRenderingMode(.alwaysOriginal))
        #else
        return Image(systemName: "circle.fill")
        #endif
    }
}
