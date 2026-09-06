import SwiftUI

/// Week-at-a-glance grid for the Schedule widget. Mirrors the in-app
/// `TimetableGridView` design: consecutive periods of the same course collapse
/// into a single tall block with a soft tinted fill + matching stroke, empty
/// slots show a neutral surface, and the period/weekday rails use the same
/// secondary-text treatment. Dimensions are scaled down for the widget canvas
/// and derived from `GeometryReader` so a course spanning N periods knows the
/// exact height to overlay.
struct WeekGridView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette

    private let rowSpacing: CGFloat = 2
    private let colSpacing: CGFloat = 2
    private let headerHeight: CGFloat = 18
    private let periodWidth: CGFloat = 12
    private let cornerRadius: CGFloat = 4

    /// User-chosen multiplier for course-name font, read from the App
    /// Group at struct init. Multiplied into the cell-height-driven
    /// `fontScale` so the user override stacks on top of the widget's
    /// own size adaptation (small iPhone widget vs. iPad systemExtraLarge).
    /// Only the course-name labels in `courseBlock` / `conflictHalf`
    /// consume this; period/weekday rails stay un-scaled.
    private let userCourseNameScale: CGFloat = CGFloat(CourseCardFontScale.renderScale(CourseCardFontScaleStore().read()))

    /// Dynamic-Type-anchored baselines for the course-name labels in
    /// `courseBlock` (solo) and `conflictHalf` (衝堂). Anchoring to
    /// `.caption2` lets the user's system Display & Text Size preference
    /// grow/shrink these labels alongside the surrounding rails, the same
    /// way the Next Class / Today widgets stack Dynamic Type with the
    /// per-app `userCourseNameScale`. Without these, the Week widget
    /// would replace Dynamic Type with the per-app scale instead of
    /// stacking on top of it.
    @ScaledMetric(relativeTo: .caption2) private var soloCourseNameBase: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var conflictCourseNameBase: CGFloat = 8

    var body: some View {
        Group {
            if !snapshot.isLoggedIn {
                Text(String(localized: "widget_sign_in"))
                    .font(.callout)
                    .foregroundStyle(palette.onSurfaceVariant)
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var grid: some View {
        let weekdays = snapshot.activeWeekdays
        let periods = snapshot.activePeriodIds
        let todayWeekday = WidgetTimelineDerivation.weekdayFor(now)

        GeometryReader { geom in
            let totalRowSpacing = CGFloat(max(0, periods.count - 1)) * rowSpacing
            let available = max(0, geom.size.height - headerHeight - rowSpacing - totalRowSpacing)
            // Floor at a small but nonzero minimum so the edit-mode drag
            // preview can't shrink every cell to height 0 and render the
            // widget as a blank rectangle. The grid is willing to overflow
            // its container rather than disappear — at the family sizes
            // this branch never triggers because `available` is plenty.
            let minCellHeight: CGFloat = 6
            let computed = periods.isEmpty ? 0 : available / CGFloat(periods.count)
            let cellHeight = periods.isEmpty ? 0 : max(minCellHeight, computed)
            // Scale text with cell height so systemExtraLarge (iPad, ~38pt
            // cells) doesn't render the same 9pt text as systemLarge (iPhone,
            // ~17pt cells). Clamped so the small-widget case stays compact.
            let fontScale = min(1.6, max(1.0, cellHeight / 17.0))

            VStack(spacing: rowSpacing) {
                headerRow(weekdays: weekdays, todayWeekday: todayWeekday, fontScale: fontScale)
                ForEach(Array(periods.enumerated()), id: \.offset) { periodIndex, periodId in
                    HStack(spacing: colSpacing) {
                        Text(periodId)
                            .font(.system(size: 8 * fontScale))
                            .foregroundStyle(palette.onSurfaceVariant)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: periodWidth, height: cellHeight)

                        ForEach(weekdays, id: \.self) { weekday in
                            cellView(
                                weekday: weekday,
                                periodIndex: periodIndex,
                                periods: periods,
                                cellHeight: cellHeight,
                                fontScale: fontScale
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: cellHeight)
                        }
                    }
                }
            }
        }
    }

    private func headerRow(weekdays: [Int], todayWeekday: Int, fontScale: CGFloat) -> some View {
        HStack(spacing: colSpacing) {
            Color.clear.frame(width: periodWidth, height: headerHeight)
            ForEach(weekdays, id: \.self) { weekday in
                VStack(spacing: 1) {
                    Text(String(localized: String.LocalizationValue(weekdayKey(weekday))))
                        .font(.system(size: 7 * fontScale, weight: .bold))
                        .foregroundStyle(palette.onSurfaceVariant)
                    Rectangle()
                        .fill(weekday == todayWeekday ? palette.highlight : Color.clear)
                        .frame(height: 1.5)
                }
                .frame(maxWidth: .infinity)
                .frame(height: headerHeight)
            }
        }
    }

    @ViewBuilder
    private func cellView(
        weekday: Int,
        periodIndex: Int,
        periods: [String],
        cellHeight: CGFloat,
        fontScale: CGFloat
    ) -> some View {
        let role = ClassTableLayout.cellRole(
            courses: snapshot.courses,
            periodIds: periods,
            weekday: weekday,
            periodIndex: periodIndex,
            keyOf: { $0.courseNo },
            scheduleOf: { $0.schedule }
        )
        switch role {
        case .empty:
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(palette.emptyCell)

        case let .solo(course, spanCount):
            courseBlock(course, spanCount: spanCount, cellHeight: cellHeight, fontScale: fontScale)

        case let .conflictStart(courseA, spanA, offsetA, courseB, spanB, offsetB, combinedSpan):
            // Two-course 衝堂: each half is a column sized to that course's
            // own span and positioned at its offset within the cluster, so
            // an overlap meeting in only part of the cluster (e.g. A on
            // periods 1–3 overlapping B only on period 2) doesn't extend
            // either course into the rows where they don't actually meet.
            let totalHeight = CGFloat(combinedSpan) * cellHeight + CGFloat(combinedSpan - 1) * rowSpacing
            Color.clear
                .overlay(alignment: .top) {
                    HStack(spacing: 1) {
                        conflictColumn(courseA, span: spanA, offset: offsetA, combinedSpan: combinedSpan, cellHeight: cellHeight, fontScale: fontScale)
                        conflictColumn(courseB, span: spanB, offset: offsetB, combinedSpan: combinedSpan, cellHeight: cellHeight, fontScale: fontScale)
                    }
                    .frame(height: totalHeight)
                }
                .zIndex(1)

        case let .conflictMany(segments, combinedSpan):
            // Same offset-aware column layout as the 2-course path, just
            // N columns wide. Each segment is placed by its own
            // span/offset so a chain like A(rows 0-1)/B(rows 1-2)/C(rows
            // 2-3) paints each course only where it actually meets.
            let totalHeight = CGFloat(combinedSpan) * cellHeight + CGFloat(combinedSpan - 1) * rowSpacing
            Color.clear
                .overlay(alignment: .top) {
                    HStack(spacing: 1) {
                        ForEach(segments, id: \.course.courseNo) { segment in
                            conflictColumn(
                                segment.course,
                                span: segment.span,
                                offset: segment.offset,
                                combinedSpan: combinedSpan,
                                cellHeight: cellHeight,
                                fontScale: fontScale
                            )
                        }
                    }
                    .frame(height: totalHeight)
                }
                .zIndex(1)

        case .skip:
            Color.clear
        }
    }

    @ViewBuilder
    private func courseBlock(
        _ course: SnapshotCourse, spanCount: Int, cellHeight: CGFloat, fontScale: CGFloat
    ) -> some View {
        let totalHeight = CGFloat(spanCount) * cellHeight + CGFloat(spanCount - 1) * rowSpacing
        let courseColor = Color(widgetHex: course.colorHex)
        Color.clear
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(courseColor.opacity(0.25))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(courseColor.opacity(0.4), lineWidth: 0.5)
                    }
                    .overlay {
                        VStack(spacing: 1) {
                            Text(course.displayName)
                                .font(.system(size: soloCourseNameBase * fontScale * userCourseNameScale, weight: .medium))
                                .foregroundStyle(palette.onSurface)
                                .lineLimit(spanCount > 1 ? 3 : 2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.7)
                            if !course.classroom.isEmpty && spanCount > 1 {
                                Text(course.classroom)
                                    .font(.system(size: 7 * fontScale))
                                    .foregroundStyle(palette.onSurfaceVariant)
                                    .lineLimit(1)
                            }
                        }
                        .padding(2)
                    }
                    .frame(height: totalHeight)
            }
            .zIndex(1)
    }

    /// One column of a 衝堂 cluster, sized to the course's own span and
    /// positioned at its offset within the cluster via empty spacers.
    @ViewBuilder
    private func conflictColumn(
        _ course: SnapshotCourse,
        span: Int,
        offset: Int,
        combinedSpan: Int,
        cellHeight: CGFloat,
        fontScale: CGFloat
    ) -> some View {
        let topRows = offset
        let bottomRows = max(combinedSpan - offset - span, 0)
        let topHeight = topRows > 0
            ? CGFloat(topRows) * cellHeight + CGFloat(topRows - 1) * rowSpacing
            : 0
        let bottomHeight = bottomRows > 0
            ? CGFloat(bottomRows) * cellHeight + CGFloat(bottomRows - 1) * rowSpacing
            : 0
        let courseHeight = CGFloat(span) * cellHeight + CGFloat(max(span - 1, 0)) * rowSpacing
        VStack(spacing: rowSpacing) {
            if topRows > 0 {
                Color.clear.frame(height: topHeight)
            }
            conflictHalf(course, fontScale: fontScale)
                .frame(height: courseHeight)
            if bottomRows > 0 {
                Color.clear.frame(height: bottomHeight)
            }
        }
    }

    @ViewBuilder
    private func conflictHalf(_ course: SnapshotCourse, fontScale: CGFloat) -> some View {
        let courseColor = Color(widgetHex: course.colorHex)
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(courseColor.opacity(0.25))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(courseColor.opacity(0.4), lineWidth: 0.5)
            }
            .overlay {
                Text(course.displayName)
                    .font(.system(size: conflictCourseNameBase * fontScale * userCourseNameScale, weight: .medium))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.55)
                    .padding(1)
            }
    }

    private func weekdayKey(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "weekday_mon_short"
        case 2: return "weekday_tue_short"
        case 3: return "weekday_wed_short"
        case 4: return "weekday_thu_short"
        case 5: return "weekday_fri_short"
        case 6: return "weekday_sat_short"
        default: return "weekday_sun_short"
        }
    }
}
