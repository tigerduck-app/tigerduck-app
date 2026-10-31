import Defaults
import SwiftUI

/// Two courses meeting at once, drawn as two interlocking L shapes; a tap opens the picker
/// between them.
struct ConflictPairView: View {
    let cluster: ConflictCluster
    let diffWithoutColor: Bool

    @Environment(AppEnvironment.self) private var app
    @Default(.outlineRequiredCourses) private var outlineRequiredCourses

    private var policy: VisualStylePolicy { app.preferences.visualStylePolicy }

    private var courseA: CourseStore.Course { cluster.segments[0].course }
    private var spanA: Int { cluster.segments[0].span }
    private var offsetA: Int { cluster.segments[0].offset }
    private var courseB: CourseStore.Course { cluster.segments[1].course }
    private var spanB: Int { cluster.segments[1].span }
    private var offsetB: Int { cluster.segments[1].offset }

    var body: some View {
        GeometryReader { proxy in
            let step = cluster.metrics.cellHeight + cluster.metrics.rowSpacing
            let aTop = CGFloat(offsetA) * step
            let aHeight = CGFloat(spanA) * cluster.metrics.cellHeight + CGFloat(spanA - 1) * cluster.metrics.rowSpacing
            let bTop = CGFloat(offsetB) * step
            let bHeight = CGFloat(spanB) * cluster.metrics.cellHeight + CGFloat(spanB - 1) * cluster.metrics.rowSpacing

            let overlapStart = max(offsetA, offsetB)
            let overlapEnd = min(offsetA + spanA, offsetB + spanB)

            let overlapTopA = CGFloat(max(0, overlapStart - offsetA)) * step
            let overlapBottomA = max(0, CGFloat(overlapEnd - offsetA) * step - cluster.metrics.rowSpacing)
            let overlapTopB = CGFloat(max(0, overlapStart - offsetB)) * step
            let overlapBottomB = max(0, CGFloat(overlapEnd - offsetB) * step - cluster.metrics.rowSpacing)

            let soloAboveA = aHeight > 0 ? overlapTopA / aHeight : 0
            let soloBelowA = aHeight > 0 ? (aHeight - overlapBottomA) / aHeight : 0
            let soloAboveB = bHeight > 0 ? overlapTopB / bHeight : 0
            let soloBelowB = bHeight > 0 ? (bHeight - overlapBottomB) / bHeight : 0

            let sharpTop = soloAboveA == 0 && soloAboveB == 0
            let sharpBottom = soloBelowA == 0 && soloBelowB == 0

            let aBarFraction = max(0.1, soloAboveA + 0.5 * (1 - soloAboveA - soloBelowA))
            let bBarFraction = max(0.1, soloBelowB + 0.5 * (1 - soloAboveB - soloBelowB))

            let shapeA = ConflictLShape(
                orientation: .topBarRightTail,
                soloAboveFraction: soloAboveA,
                soloBelowFraction: soloBelowA,
                sharpTopOuter: sharpTop,
                sharpBottomOuter: sharpBottom
            )
            let shapeB = ConflictLShape(
                orientation: .leftTailBottomBar,
                soloAboveFraction: soloAboveB,
                soloBelowFraction: soloBelowB,
                sharpTopOuter: sharpTop,
                sharpBottomOuter: sharpBottom
            )

            // `scrollSafeTapAction` wraps the cluster in a real `Button` so the first tap
            // wins iOS 18 scroll arbitration; see View+ScrollSafeGesture. Any tap opens
            // the picker, not per-shape hit-testing, so the user sees both, as on Android.
            ZStack(alignment: .topLeading) {
                courseRegion(
                    course: courseA,
                    shape: shapeA,
                    labelAlignment: .topTrailing,
                    barFraction: aBarFraction
                )
                .frame(width: proxy.size.width, height: aHeight)
                .offset(y: aTop)

                courseRegion(
                    course: courseB,
                    shape: shapeB,
                    labelAlignment: .bottomLeading,
                    barFraction: bBarFraction
                )
                .frame(width: proxy.size.width, height: bHeight)
                .offset(y: bTop)
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
            .scrollSafeTapAction {
                cluster.viewModel.presentConflictPicker(
                    courseA: courseA, courseB: courseB,
                    weekday: cluster.weekday, periodId: cluster.periodId
                )
            }
            .accessibilityLabel(
                Text("\(String(localized: "a11y_class_table_conflict_prefix")): " +
                     String(format: String(localized: "a11y_timetable_cell"),
                            AppConstants.Periods.shortWeekdayLabel(cluster.weekday),
                            cluster.periodLabel,
                            [courseA, courseB].map {
                                spokenCourse($0, hasAssignment: cluster.showsBadge(for: $0),
                                             ignoresAssignments: cluster.showsIgnoredMark(for: $0))
                            }
                            .joined(separator: ", ")))
            )
            .courseEditMenu(isEditable: cluster.viewModel.shownPerson == nil) {
                ForEach(cluster.segments) { segment in
                    Section(segment.course.displayName) {
                        TimetableCourseMenu(course: segment.course, editor: cluster.viewModel.editor, showsColorDot: true)
                    }
                }
            }
        }
    }

    private func courseRegion(
        course: CourseStore.Course,
        shape: ConflictLShape,
        labelAlignment: Alignment,
        barFraction: CGFloat
    ) -> some View {
        let hasBadge = cluster.showsBadge(for: course)
        let ignoresAssignments = cluster.showsIgnoredMark(for: course)
        return GeometryReader { boxProxy in
            ZStack(alignment: labelAlignment) {
                policy.classTableCourseFill(course.color)
                Text(course.displayName)
                    .font(.system(size: cluster.metrics.courseNameSize, weight: policy.classTableCourseNameWeight))
                    .foregroundStyle(policy.classTableCourseTextColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .padding(2)
                    .frame(
                        width: boxProxy.size.width * (1 - 0.28),
                        height: boxProxy.size.height * barFraction
                    )

                if hasBadge {
                    Image(systemName: "book.fill")
                        .font(.system(size: cluster.metrics.badgeIconSize))
                        .foregroundStyle(policy.classTableCourseTextColor.opacity(0.7))
                        .padding(3)
                } else if ignoresAssignments {
                    IgnoredAssignmentsIcon(size: cluster.metrics.badgeIconSize)
                        .foregroundStyle(policy.classTableCourseTextColor.opacity(0.7))
                        .padding(3)
                }
            }
        }
        .overlay {
            if isOutlined(course) { shape.innerOutline(policy.classTableCourseOutline(course.color)) }
        }
        .clipShape(shape)
        .contentShape(shape)
    }

    private func isOutlined(_ course: CourseStore.Course) -> Bool {
        outlineRequiredCourses && course.isRequired
    }
}
