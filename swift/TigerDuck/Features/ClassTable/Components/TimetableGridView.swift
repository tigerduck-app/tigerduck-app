import SwiftUI

struct TimetableGridView: View {
    let viewModel: ClassTableViewModel

    private let cellHeight: CGFloat = 52
    private let rowSpacing: CGFloat = 3
    private let colSpacing: CGFloat = 3
    private let headerHeight: CGFloat = 30
    private let periodWidth: CGFloat = 12

    private static let allWeekdayLabels = AppConstants.Periods.weekdays + AppConstants.Periods.weekendDays

    private var weekdayLabels: [String] {
        viewModel.activeWeekdays.map { day in
            Self.allWeekdayLabels[safe: day - 1] ?? ""
        }
    }

    var body: some View {
        VStack(spacing: rowSpacing) {
            // Header row
            HStack(spacing: colSpacing) {
                Text("")
                    .frame(width: periodWidth, height: headerHeight)
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(TigerDuckTheme.Typography.caption.bold())
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: headerHeight)
                }
            }

            // Grid rows
            ForEach(Array(viewModel.activePeriods.enumerated()), id: \.element.id) { periodIndex, period in
                HStack(spacing: colSpacing) {
                    // Period label
                    Text(period.displayLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: periodWidth, height: cellHeight)

                    // Day cells
                    ForEach(viewModel.activeWeekdays, id: \.self) { weekday in
                        cellView(weekday: weekday, periodIndex: periodIndex, periodId: period.id)
                            .frame(maxWidth: .infinity)
                            .frame(height: cellHeight)
                    }
                }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.xs)
    }

    @ViewBuilder
    private func cellView(weekday: Int, periodIndex: Int, periodId: String) -> some View {
        switch viewModel.cellRole(weekday: weekday, periodIndex: periodIndex) {
        case .empty:
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                .fill(Color.cardSurface.opacity(0.15))

        case .solo(let course, let spanCount):
            let hasBadge = viewModel.hasAssignment(for: course.courseNo)
            let totalHeight = CGFloat(spanCount) * cellHeight + CGFloat(spanCount - 1) * rowSpacing

            Color.clear
                .overlay(alignment: .top) {
                    Button {
                        viewModel.selectCourse(course, weekday: weekday, periodId: periodId)
                    } label: {
                        RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                            .fill(course.color.opacity(0.4))
                            .overlay {
                                Text(course.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(spanCount > 1 ? 3 : 2)
                                    .multilineTextAlignment(.center)
                                    .padding(2)
                            }
                            .assignmentBadge(show: hasBadge, iconSize: 8, padding: 4)
                            .frame(height: totalHeight)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            viewModel.startRename(course)
                        } label: {
                            Label(String(localized: "class_table_rename_title"), systemImage: "pencil")
                        }
                        Button {
                            viewModel.startRecolor(course)
                        } label: {
                            Label(String(localized: "course_color_picker_title"), systemImage: "paintpalette")
                        }
                        Button(role: .destructive) {
                            viewModel.deleteCourse(course)
                        } label: {
                            Label(String(localized: "class_table_delete"), systemImage: "trash")
                        }
                    }
                }
                .zIndex(1)

        case .conflictStart(let cA, let sA, let oA, let cB, let sB, let oB, let combinedSpan):
            let clusterHeight = CGFloat(combinedSpan) * cellHeight + CGFloat(combinedSpan - 1) * rowSpacing
            Color.clear
                .overlay(alignment: .top) {
                    ConflictClusterView(
                        viewModel: viewModel,
                        courseA: cA, spanA: sA, offsetA: oA,
                        courseB: cB, spanB: sB, offsetB: oB,
                        combinedSpan: combinedSpan,
                        cellHeight: cellHeight,
                        rowSpacing: rowSpacing,
                        weekday: weekday,
                        periodId: periodId
                    )
                    .frame(height: clusterHeight)
                }
                .zIndex(1)

        case .skip:
            Color.clear
        }
    }
}

/// Renders two interlocking L-shapes for a conflict cluster. Geometry follows
/// the Android `ConflictCourseCell` — each course occupies its own absolute
/// box inside the cluster, clipped to a Γ or mirror-L so the two regions tile
/// without overlap. Course-name text sits in each shape's "bar" rectangle so
/// neither name is hidden behind the other course's color.
private struct ConflictClusterView: View {
    let viewModel: ClassTableViewModel
    let courseA: SDCourse
    let spanA: Int
    let offsetA: Int
    let courseB: SDCourse
    let spanB: Int
    let offsetB: Int
    let combinedSpan: Int
    let cellHeight: CGFloat
    let rowSpacing: CGFloat
    let weekday: Int
    let periodId: String

    var body: some View {
        GeometryReader { proxy in
            // Step matches the surrounding grid exactly (cell + rowSpacing),
            // so each course's L sits where the corresponding solo block
            // would have been. Dividing the cluster height by combinedSpan
            // averages the spacing into every row and makes the seam drift
            // farther as the cluster grows.
            let step = cellHeight + rowSpacing
            let aTop = CGFloat(offsetA) * step
            let aHeight = CGFloat(spanA) * cellHeight + CGFloat(spanA - 1) * rowSpacing
            let bTop = CGFloat(offsetB) * step
            let bHeight = CGFloat(spanB) * cellHeight + CGFloat(spanB - 1) * rowSpacing

            let overlapStart = max(offsetA, offsetB)
            let overlapEnd = min(offsetA + spanA, offsetB + spanB)

            // Each course's overlap region in box-local pixels. Computing
            // fractions against those (rather than against `span` row
            // counts) keeps the L seam on the actual row+spacing boundary.
            let overlapTopA = CGFloat(max(0, overlapStart - offsetA)) * step
            let overlapBottomA = max(0, CGFloat(overlapEnd - offsetA) * step - rowSpacing)
            let overlapTopB = CGFloat(max(0, overlapStart - offsetB)) * step
            let overlapBottomB = max(0, CGFloat(overlapEnd - offsetB) * step - rowSpacing)

            let soloAboveA = aHeight > 0 ? overlapTopA / aHeight : 0
            let soloBelowA = aHeight > 0 ? (aHeight - overlapBottomA) / aHeight : 0
            let soloAboveB = bHeight > 0 ? overlapTopB / bHeight : 0
            let soloBelowB = bHeight > 0 ? (bHeight - overlapBottomB) / bHeight : 0

            // When BOTH courses share an outer top/bottom edge of the cluster,
            // both shapes have a convex corner there. Rounding both produces a
            // wedge-shaped gap, so keep those corners sharp instead.
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
            // One tap anywhere in the cluster opens the picker; the picker
            // resolves which course to inspect. Per-shape hit-testing would
            // bypass the picker entirely, but the Android version still goes
            // through the sheet so the user can see both options.
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.presentConflictPicker(
                    courseA: courseA, courseB: courseB,
                    weekday: weekday, periodId: periodId
                )
            }
            .contextMenu {
                conflictContextMenu()
            }
        }
    }

    @ViewBuilder
    private func conflictContextMenu() -> some View {
        Section(courseA.displayName) {
            Button {
                viewModel.startRename(courseA)
            } label: {
                Label(String(localized: "class_table_rename_title"), systemImage: "pencil")
            }
            Button {
                viewModel.startRecolor(courseA)
            } label: {
                Label(String(localized: "class_table_pick_color"), systemImage: "paintpalette")
            }
            Button(role: .destructive) {
                viewModel.deleteCourse(courseA)
            } label: {
                Label(String(localized: "class_table_delete"), systemImage: "trash")
            }
        }
        Section(courseB.displayName) {
            Button {
                viewModel.startRename(courseB)
            } label: {
                Label(String(localized: "class_table_rename_title"), systemImage: "pencil")
            }
            Button {
                viewModel.startRecolor(courseB)
            } label: {
                Label(String(localized: "class_table_pick_color"), systemImage: "paintpalette")
            }
            Button(role: .destructive) {
                viewModel.deleteCourse(courseB)
            } label: {
                Label(String(localized: "class_table_delete"), systemImage: "trash")
            }
        }
    }

    private func courseRegion(
        course: SDCourse,
        shape: ConflictLShape,
        labelAlignment: Alignment,
        barFraction: CGFloat
    ) -> some View {
        let hasBadge = viewModel.hasAssignment(for: course.courseNo)
        return GeometryReader { boxProxy in
            ZStack(alignment: labelAlignment) {
                course.color.opacity(0.4)
                // Course name sits in the "bar" rectangle of the L —
                // 72% width, `barFraction` height (matches Android's 28%
                // tail width). Aligning top-right (Γ) / bottom-left (L)
                // keeps the text inside the visible color region.
                Text(course.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(2)
                    .frame(
                        width: boxProxy.size.width * (1 - 0.28),
                        height: boxProxy.size.height * barFraction
                    )

                if hasBadge {
                    Image(systemName: "book.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.textPrimary.opacity(0.7))
                        .padding(3)
                }
            }
        }
        .clipShape(shape)
        .contentShape(shape)
    }
}
