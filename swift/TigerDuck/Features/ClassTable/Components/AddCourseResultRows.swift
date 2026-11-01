import SwiftUI

/// The Add Course sheet's results, a course to a row, each with a button that adds the course or
/// removes one added in this sheet.
struct AddCourseResultRows: View {
    let shown: [AddCourseResults.Shown]
    let tableCourses: [CourseStore.Course]
    @Binding var addedHere: Set<String>
    let add: (AddCourseResults.Course) -> Void
    let remove: ((String) -> Void)?

    var body: some View {
        let existingCourseNos = Set(tableCourses.map(\.courseNo))
        ForEach(shown, id: \.course.courseNo) { item in
            let group = item.course
            let mark: AddCourseRowMark = addedHere.contains(group.courseNo) ? .addedHere
                : existingCourseNos.contains(group.courseNo) ? .inTable : .notAdded
            Button {
                switch mark {
                case .addedHere:
                    addedHere.remove(group.courseNo)
                    remove?(group.courseNo)
                case .notAdded:
                    add(group)
                case .inTable:
                    break
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.displayName)
                            .font(TigerDuckTheme.Typography.headline)
                            .foregroundStyle(Color.textPrimary)
                        Text(String(format: String(localized: "add_course_result_meta"), group.courseNo, group.instructor, group.credits.creditsText))
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                        if !group.classroom.isEmpty {
                            Text(group.classroom)
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        if !group.nodeDisplay.isEmpty {
                            Text(group.nodeDisplay)
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        if mark == .notAdded, !item.conflicts.isEmpty {
                            Label(
                                String(
                                    format: String(localized: "course_search_conflicts_with"),
                                    ListFormatter.localizedString(byJoining: item.conflicts)
                                ),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(TigerDuckTheme.Tint.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: mark.symbol)
                        .foregroundStyle(mark == .inTable ? AnyShapeStyle(Color.textSecondary) : AnyShapeStyle(.tint))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .disabled(mark == .inTable)
            .accessibilityValue(mark.accessibilityValue)
            .accessibilityHint(mark.accessibilityHint)
        }
    }
}
