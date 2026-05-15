import SwiftUI

/// Bottom sheet shown when the user taps a conflict cell. Lets them disambiguate
/// which of the two overlapping courses to inspect.
struct ConflictCoursePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let courseA: SDCourse
    let courseB: SDCourse
    let onPick: (SDCourse) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                row(course: courseA)
                Divider()
                    .padding(.leading, 56)
                row(course: courseB)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.backgroundPrimary)
            .navigationTitle(String(localized: "conflict_course_picker_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
            }
        }
    }

    private func row(course: SDCourse) -> some View {
        Button {
            onPick(course)
        } label: {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(course.color)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.displayName)
                        .font(TigerDuckTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(for: course))
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for course: SDCourse) -> String {
        var parts = [course.courseNo]
        if !course.instructor.isEmpty { parts.append(course.instructor) }
        let classroom = SDCourse.dedup(course.classroom)
        if !classroom.isEmpty { parts.append(classroom) }
        return parts.joined(separator: " · ")
    }
}
