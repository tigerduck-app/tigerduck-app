import SwiftUI

/// Maps the codebase weekday convention (1=Mon, 2=Tue, ..., 7=Sun) to a
/// localized short weekday name. DateFormatter's symbol arrays use a
/// 1=Sunday convention, so we remap before indexing. The fallback to the
/// raw int keeps VoiceOver labels usable even if symbol lookup fails.
private func weekdayDisplayName(_ weekday: Int) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    let symbols = formatter.shortStandaloneWeekdaySymbols ?? formatter.shortWeekdaySymbols ?? []
    // Codebase: 1=Mon...6=Sat,7=Sun → DateFormatter index: 2=Mon...7=Sat,1=Sun
    let dfIndex: Int
    switch weekday {
    case 1...6: dfIndex = weekday + 1 // Mon..Sat → 2..7
    case 7: dfIndex = 1               // Sun → 1
    default: dfIndex = 0
    }
    guard dfIndex >= 1, dfIndex <= symbols.count else { return "\(weekday)" }
    return symbols[dfIndex - 1]
}

struct TimetableGridView: View {
    let viewModel: ClassTableViewModel

    // Course-name cells render a dynamic `.caption` font; scale the row
    // height with it so larger text gets more room instead of clipping.
    @ScaledMetric(relativeTo: .caption) private var cellHeight: CGFloat = 52
    private let rowSpacing: CGFloat = 3
    private let colSpacing: CGFloat = 3
    private let headerHeight: CGFloat = 30
    private let periodWidth: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var badgeIconSize: CGFloat = 8

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
                        .font(.caption2)
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
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(spanCount > 1 ? 3 : 2)
                                    .minimumScaleFactor(0.7)
                                    .multilineTextAlignment(.center)
                                    .padding(2)
                            }
                            .assignmentBadge(show: hasBadge, iconSize: badgeIconSize, padding: 4)
                            .frame(height: totalHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        Text(String(
                            format: String(localized: "a11y_timetable_cell"),
                            weekdayDisplayName(weekday),
                            viewModel.activePeriods.first { $0.id == periodId }?.displayLabel ?? periodId,
                            course.displayName
                        ))
                    )
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

        case .conflictStart(let segments, let combinedSpan):
            let clusterHeight = CGFloat(combinedSpan) * cellHeight + CGFloat(combinedSpan - 1) * rowSpacing
            Color.clear
                .overlay(alignment: .top) {
                    ConflictClusterView(
                        viewModel: viewModel,
                        segments: segments,
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

/// Renders a conflict cluster. For two courses we draw the interlocking
/// L-shapes (Γ + mirror-L) that follow the Android `ConflictCourseCell`
/// geometry; for three or more we fall back to a column layout so every
/// course keeps a visible region — the L-shape geometry only resolves
/// cleanly for two interlocking blocks, and an N>=3 chain would otherwise
/// bury a course's tail under a `.skip` with nothing drawn on top.
private struct ConflictClusterView: View {
    let viewModel: ClassTableViewModel
    let segments: [ClassTableViewModel.ConflictSegment]
    let combinedSpan: Int
    let cellHeight: CGFloat
    let rowSpacing: CGFloat
    let weekday: Int
    let periodId: String

    @ScaledMetric(relativeTo: .caption2) private var badgeIconSize: CGFloat = 8

    private var courseA: SDCourse { segments[0].course }
    private var spanA: Int { segments[0].span }
    private var offsetA: Int { segments[0].offset }
    private var courseB: SDCourse { segments[1].course }
    private var spanB: Int { segments[1].span }
    private var offsetB: Int { segments[1].offset }

    @ViewBuilder
    var body: some View {
        if segments.count == 2 {
            lShapeLayout
        } else {
            // 3+ chain (e.g. A on periods 1-2, B on 2-3, C on 3-4):
            // the Γ / mirror-L geometry only resolves for two
            // interlocking blocks, so fall back to the N-column layout
            // the Mac and widget renderers use. Without this branch
            // `cellRole` emits one cluster with N segments but only the
            // first two drew, leaving C's tail covered by `.skip` with
            // nothing on top.
            //
            // TODO: design a proper 衝堂 visual for transitive 3-course
            // clusters. Today (e.g. PE115B022 @ 6-7, CS3005302 @ 6-8,
            // FE1792702 @ 8-9) renders as three vertical bars side-by-
            // side, which loses the interlocking-L look the 2-course
            // case has.
            columnLayout
        }
    }

    private var lShapeLayout: some View {
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
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                Text("\(String(localized: "a11y_class_table_conflict_prefix")): " +
                     String(format: String(localized: "a11y_timetable_cell"),
                            weekdayDisplayName(weekday),
                            viewModel.activePeriods.first { $0.id == periodId }?.displayLabel ?? periodId,
                            "\(courseA.displayName), \(courseB.displayName)"))
            )
            .contextMenu {
                conflictContextMenu()
            }
        }
    }

    /// N-column layout for 3+ overlapping courses. Each segment owns a
    /// column sized to its own `span` and offset by `offset` rows so a
    /// staircase like A(0-1) / B(1-2) / C(2-3) paints each course only
    /// in the rows it actually meets. Per-column tap selects that course
    /// directly — unlike the L-shape, there's no seam ambiguity that
    /// requires routing through the picker.
    private var columnLayout: some View {
        // `rowSpacing` doubles as the horizontal seam between columns,
        // matching the Mac renderer's `HStack(spacing: rowSpacing)`.
        HStack(spacing: rowSpacing) {
            ForEach(segments, id: \.course.courseNo) { segment in
                conflictColumn(segment: segment)
            }
        }
    }

    private func conflictColumn(segment: ClassTableViewModel.ConflictSegment) -> some View {
        let course = segment.course
        let span = segment.span
        let offset = segment.offset
        let bottomRows = max(combinedSpan - offset - span, 0)
        let hasBadge = viewModel.hasAssignment(for: course.courseNo)

        return VStack(spacing: rowSpacing) {
            if offset > 0 {
                Color.clear.frame(height: blockHeight(offset))
            }
            Button {
                viewModel.selectCourse(course, weekday: weekday, periodId: periodId)
            } label: {
                RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                    .fill(course.color.opacity(0.4))
                    .overlay {
                        Text(course.displayName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(span > 1 ? 3 : 2)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center)
                            .padding(2)
                    }
                    .assignmentBadge(show: hasBadge, iconSize: badgeIconSize, padding: 4)
                    .frame(height: blockHeight(span))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text("\(String(localized: "a11y_class_table_conflict_prefix")): " +
                     String(format: String(localized: "a11y_timetable_cell"),
                            weekdayDisplayName(weekday),
                            viewModel.activePeriods.first { $0.id == periodId }?.displayLabel ?? periodId,
                            course.displayName))
            )
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
            if bottomRows > 0 {
                Color.clear.frame(height: blockHeight(bottomRows))
            }
        }
    }

    private func blockHeight(_ span: Int) -> CGFloat {
        CGFloat(span) * cellHeight + CGFloat(max(span - 1, 0)) * rowSpacing
    }

    @ViewBuilder
    private func conflictContextMenu() -> some View {
        ForEach(segments, id: \.course.courseNo) { segment in
            Section(segment.course.displayName) {
                Button {
                    viewModel.startRename(segment.course)
                } label: {
                    Label(String(localized: "class_table_rename_title"), systemImage: "pencil")
                }
                Button {
                    viewModel.startRecolor(segment.course)
                } label: {
                    Label(String(localized: "class_table_pick_color"), systemImage: "paintpalette")
                }
                Button(role: .destructive) {
                    viewModel.deleteCourse(segment.course)
                } label: {
                    Label(String(localized: "class_table_delete"), systemImage: "trash")
                }
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
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
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
                        .font(.system(size: badgeIconSize))
                        .foregroundStyle(Color.textPrimary.opacity(0.7))
                        .padding(3)
                }
            }
        }
        .clipShape(shape)
        .contentShape(shape)
    }
}
