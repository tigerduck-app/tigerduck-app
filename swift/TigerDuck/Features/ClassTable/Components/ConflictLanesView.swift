import Defaults
import SwiftUI

struct ConflictLanesView: View {
    let cluster: ConflictCluster
    let diffWithoutColor: Bool

    @Environment(AppEnvironment.self) private var app
    @Default(.outlineRequiredCourses) private var outlineRequiredCourses

    private var policy: VisualStylePolicy { app.preferences.visualStylePolicy }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ConflictLaneGeometry(
                width: proxy.size.width,
                laneCount: cluster.laneCount,
                cellHeight: cluster.metrics.cellHeight,
                rowSpacing: cluster.metrics.rowSpacing
            )
            ZStack(alignment: .topLeading) {
                ForEach(cluster.segments) { segment in
                    laneMember(segment, geometry: geometry)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if diffWithoutColor {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(2)
                    .accessibilityHidden(true)
            }
        }
    }

    private func laneMember(_ segment: ClassTableConflictSegment<CourseStore.Course>, geometry: ConflictLaneGeometry) -> some View {
        let course = segment.course
        let runs = ClassTableLayout.laneRuns(of: segment, among: cluster.segments, laneCount: cluster.laneCount).map(geometry.rect)
        let shape = ConflictLaneShape(runs: runs, cornerRadius: TigerDuckTheme.CornerRadius.sm)
        let label = runs.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
        let hasBadge = cluster.showsBadge(for: course)
        let ignoresAssignments = cluster.showsIgnoredMark(for: course)
        let markColor = policy.classTableCourseSecondaryTextColor.opacity(0.5)
        let periods = cluster.viewModel.grid.activePeriods
        let firstPeriod = periods.firstIndex { $0.id == cluster.periodId }.flatMap { periods[safe: $0 + segment.offset] }

        return Button {
            cluster.viewModel.selectCourse(course, weekday: cluster.weekday, periodId: firstPeriod?.id ?? cluster.periodId)
        } label: {
            shape
                .fill(policy.classTableCourseFill(course.color))
                .overlay {
                    if isOutlined(course) { shape.innerOutline(policy.classTableCourseOutline(course.color)) }
                }
                .overlay(alignment: .topLeading) {
                    Text(course.displayName)
                        .font(.system(size: cluster.metrics.courseNameSize, weight: policy.classTableCourseNameWeight))
                        .foregroundStyle(policy.classTableCourseTextColor)
                        .lineLimit(label.height > cluster.metrics.cellHeight ? 3 : 2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .padding(2)
                        .frame(width: label.width, height: label.height)
                        .assignmentBadge(show: hasBadge, iconSize: cluster.metrics.badgeIconSize, padding: 4, color: markColor)
                        .ignoredAssignmentsBadge(
                            show: ignoresAssignments, iconSize: cluster.metrics.badgeIconSize, padding: 4, color: markColor
                        )
                        .offset(x: label.minX, y: label.minY)
                }
                .contentShape(shape)
                .contentShape(.contextMenuPreview, shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text("\(String(localized: "a11y_class_table_conflict_prefix")): " +
                 String(format: String(localized: "a11y_timetable_cell"),
                        AppConstants.Periods.shortWeekdayLabel(cluster.weekday),
                        firstPeriod?.displayLabel ?? cluster.periodId,
                        spokenCourse(course, hasAssignment: hasBadge, ignoresAssignments: ignoresAssignments)))
        )
        .courseEditMenu(isEditable: cluster.viewModel.shownPerson == nil) {
            TimetableCourseMenu(course: course, editor: cluster.viewModel.editor)
        }
    }

    private func isOutlined(_ course: CourseStore.Course) -> Bool {
        outlineRequiredCourses && course.isRequired
    }
}
