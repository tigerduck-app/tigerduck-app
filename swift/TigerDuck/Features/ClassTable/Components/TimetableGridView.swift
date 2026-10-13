import Defaults
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A course as a cell's VoiceOver label names it. The room hint and the assignment marks
/// are hidden from VoiceOver, so the label carries them.
func spokenCourse(_ course: SDCourse, room: String? = nil, hasAssignment: Bool, ignoresAssignments: Bool) -> String {
    var parts = [course.displayName]
    if let room { parts.append(room) }
    if hasAssignment { parts.append(String(localized: "a11y_class_table_cell_assignment_indicator")) }
    if ignoresAssignments { parts.append(String(localized: "a11y_class_table_cell_assignments_ignored")) }
    return parts.joined(separator: ", ")
}

/// "Ignore assignments", or its undo, offered for the term assignments are fetched for.
@ViewBuilder
private func ignoreAssignmentsButton(_ course: SDCourse, viewModel: ClassTableViewModel) -> some View {
    if viewModel.offersIgnoreAssignments {
        let ignored = viewModel.ignoresAssignments(of: course.courseNo)
        Button {
            viewModel.setIgnoresAssignments(!ignored, for: course)
        } label: {
            if ignored {
                Label(String(localized: "class_table_ignore_assignments_undo"), systemImage: "arrow.uturn.backward")
            } else {
                Label(String(localized: "class_table_ignore_assignments"), systemImage: "archivebox")
            }
        }
    }
}

private extension Shape {
    /// A 1 pt line inside the edge, as `strokeBorder` draws one on an insettable shape: half of a
    /// 2 pt stroke, clipped to the shape, so it stays off the course beside it in a conflict.
    func innerOutline(_ color: Color) -> some View {
        stroke(color, lineWidth: 2).clipShape(self)
    }
}

/// Where the grid's period rows start, by period id, in the scroll view that holds the grid.
nonisolated struct TimetableRowTops: Equatable, Sendable {
    var switchCount: Int
    var tops: [String: CGFloat]

    /// How far a switch moved the first row at or below `visibleTop`, the bottom of the bars over
    /// the scroll view, among the rows both class tables have. Scrolling that far puts the rows back
    /// where they were on screen.
    static func shift(from before: Self, to after: Self, visibleTop: CGFloat) -> CGFloat {
        let moves = before.tops.compactMap { id, top in after.tops[id].map { (from: top, to: $0) } }
        let row = moves.filter { $0.from >= visibleTop }.min { $0.from < $1.from }
            ?? moves.max { $0.from < $1.from }
        return row.map { $0.to - $0.from } ?? 0
    }
}

struct TimetableGridView: View {
    let viewModel: ClassTableViewModel
    /// Off for an exported image: the badge marks work still due, which is
    /// a reminder for whoever is looking at the screen today, not part of
    /// the timetable someone is being shown.
    var showsAssignmentBadges = true
    /// Overrides the environment's Differentiate Without Color, which marks
    /// a schedule-conflict cluster with a warning triangle; nil follows the
    /// environment. For an export, whose renderer cannot set that value itself.
    var differentiateWithoutColor: Bool? = nil
    /// The class table bumps this when it switches to another class table, so that `onSwitch`
    /// hears the layout of that switch and not every scrolled frame.
    var switchCount = 0
    /// The row tops before and after a switch, for the class table to scroll by however far a
    /// row moved.
    var onSwitch: ((_ before: TimetableRowTops, _ after: TimetableRowTops) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @Default(.outlineRequiredCourses) private var outlineRequiredCourses

    private let rowSpacing: CGFloat = 3
    private let colSpacing: CGFloat = 3
    private let headerHeight: CGFloat = 30

    /// The period column stacks three lines (start, period number, end), which
    /// fit a 52pt row comfortably at the default text size. A fixed row height
    /// stops fitting them past a certain Dynamic Type size, so the row and the
    /// column grow with the text instead: unchanged up to roughly 1.3x, taller
    /// beyond, which is what someone who asked for bigger text wants anyway.
    @ScaledMetric(relativeTo: .caption2) private var scaledCellHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .caption2) private var scaledPeriodWidth: CGFloat = 28
    @ScaledMetric(relativeTo: .caption2) private var scaledPeriodNumberWidth: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var periodTimeSize: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var periodLabelSize: CGFloat = 12

    private var policy: VisualStylePolicy { appState.visualStylePolicy }
    private var drawsPeriodTiles: Bool { policy.classTableGridStyle == .periodTiles }

    private var cellHeight: CGFloat { max(52, scaledCellHeight) }
    private var periodWidth: CGFloat {
        drawsPeriodTiles ? max(20, scaledPeriodNumberWidth) : max(36, scaledPeriodWidth)
    }
    @ScaledMetric(relativeTo: .caption2) private var badgeIconSize: CGFloat = 8

    @ScaledMetric(relativeTo: .caption2) private var courseNameBaseSize: CGFloat = 8

    /// The Settings → Font size multiplier times the Dynamic-Type-scaled base, so
    /// the cell follows both the system setting and the per-app override. Read
    /// through `AppState`, not the store, so SwiftUI tracks the `@Observable`
    /// dependency and redraws as the slider moves instead of after a relaunch.
    ///
    /// Normalized at the read site so the timetable, the Settings readout and the
    /// App-Group value the widgets read agree: the Slider snaps to its `step:`, but
    /// another writer (debug menu, migration, tests) can store an unstepped value.
    private var courseNameSize: CGFloat {
        courseNameBaseSize * CGFloat(CourseCardFontScale.renderScale(appState.courseCardFontScale))
    }

    /// The room hint rides a notch under the course name so the name keeps
    /// the visual weight — the room is a reminder, not a second title.
    private var roomHintSize: CGFloat { courseNameSize * 0.85 }

    private static let allWeekdayLabels = AppConstants.Periods.weekdays + AppConstants.Periods.weekendDays

    private var weekdayLabels: [String] {
        viewModel.activeWeekdays.map { day in
            Self.allWeekdayLabels[safe: day - 1] ?? ""
        }
    }

    var body: some View {
        let periods = viewModel.activePeriods
        let firstRowTop = headerHeight + rowSpacing
        let rowPitch = cellHeight + rowSpacing
        let switchCount = switchCount
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
            ForEach(Array(periods.enumerated()), id: \.element.id) { periodIndex, period in
                HStack(spacing: colSpacing) {
                    // Start, period number, end: one timestamp would not say which end of
                    // the period it marks, and the last row has no next row to infer from.
                    // Each line shrinks rather than truncating, since "08:…" says nothing.
                    VStack(spacing: 0) {
                        if !drawsPeriodTiles {
                            Text(period.startTime)
                                .font(.system(size: periodTimeSize))
                                .foregroundStyle(Color.textSecondary)
                        }
                        Text(period.displayLabel)
                            .font(.system(size: periodLabelSize, weight: .bold))
                            .foregroundStyle(Color.textPrimary)
                        if !drawsPeriodTiles {
                            Text(period.endTime)
                                .font(.system(size: periodTimeSize))
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: periodWidth, height: cellHeight)

                    // Day cells
                    ForEach(viewModel.activeWeekdays, id: \.self) { weekday in
                        let role = viewModel.cellRole(weekday: weekday, periodIndex: periodIndex)
                        let key = contentKey(of: role, weekday: weekday, periodId: period.id)
                        cellView(role, key: key, weekday: weekday, periodId: period.id)
                            .frame(maxWidth: .infinity)
                            .frame(height: cellHeight)
                            // Animates the cell's fade when its courses change; the fade sets its own timing.
                            .animation(.linear(duration: 0.25), value: key)
                    }
                }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.xs)
        // Behind the whole grid, not each row: a course block reaches down over the rows below
        // its first, and a later row's band would cover it.
        .background(alignment: .top) {
            if drawsPeriodTiles {
                VStack(spacing: 0) {
                    ForEach(periods.indices, id: \.self) { index in
                        (index.isMultiple(of: 2) ? Color.rowBand : Color.rowBandAlternate)
                            .frame(height: rowPitch)
                    }
                }
                // Each band reaches halfway into the gaps around its row, so the bands meet.
                .padding(.top, firstRowTop - rowSpacing / 2)
            }
        }
        // Every row is one cell high, so the grid's top places them all.
        .onGeometryChange(for: TimetableRowTops.self) { proxy in
            let gridTop = proxy.frame(in: .scrollView).minY
            return TimetableRowTops(switchCount: switchCount, tops: Dictionary(
                uniqueKeysWithValues: periods.enumerated().map { index, period in
                    (period.id, gridTop + firstRowTop + CGFloat(index) * rowPitch)
                }
            ))
        } action: { before, after in
            if before.switchCount != after.switchCount { onSwitch?(before, after) }
        }
    }

    /// A cell whose courses change, as when the class table switches between people, fades the
    /// old courses out and then the new ones in, 0.25 s in all. A course both have stays as it is,
    /// and so does the grid around it.
    private static let courseFade = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.1)),
        removal: .opacity.animation(.easeIn(duration: 0.1))
    )

    /// What a cell's courses show, as the identity of its block: a change in name, room or rows
    /// makes a new block, which `courseFade` swaps in. Colour follows the course number.
    private func contentKey(of role: ClassTableViewModel.CellRole, weekday: Int, periodId: String) -> String {
        func shown(_ course: SDCourse) -> String { "\(course.courseNo)|\(course.displayName)" }
        switch role {
        case .empty:
            return "empty"
        case .skip:
            return "skip"
        case .solo(let course, let spanCount):
            let room = appState.showClassroomInClassTable
                ? CourseRoomHint.room(for: course, weekday: weekday, periodId: periodId) ?? ""
                : ""
            return "solo \(spanCount) \(shown(course))|\(room)"
        case let .conflictStart(courseA, spanA, offsetA, courseB, spanB, offsetB, combinedSpan):
            return "pair \(combinedSpan) \(spanA) \(offsetA) \(shown(courseA)) \(spanB) \(offsetB) \(shown(courseB))"
        case let .conflictMany(segments, combinedSpan, laneCount):
            let lanes = segments.map { "\($0.span) \($0.offset) \($0.lane) \(shown($0.course))" }
            return "lanes \(combinedSpan) \(laneCount) " + lanes.joined(separator: " ")
        }
    }

    @ViewBuilder
    private func cellView(_ role: ClassTableViewModel.CellRole, key: String, weekday: Int, periodId: String) -> some View {
        switch role {
        case .empty:
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                .fill(drawsPeriodTiles ? Color.clear : Color.cardSurface.opacity(0.15))
                .transition(.identity)

        case .solo(let course, let spanCount):
            let hasBadge = showsAssignmentBadges && viewModel.hasAssignment(for: course.courseNo)
            let ignoresAssignments = showsAssignmentBadges && viewModel.ignoresAssignments(of: course.courseNo)
            let totalHeight = CGFloat(spanCount) * cellHeight + CGFloat(spanCount - 1) * rowSpacing
            // A conflict cell never reaches this branch, so the hint is absent
            // there by construction; a split cell has no free corner.
            let roomHint = appState.showClassroomInClassTable
                ? CourseRoomHint.room(for: course, weekday: weekday, periodId: periodId)
                : nil
            let markColor = policy.classTableCourseSecondaryTextColor.opacity(0.5)

            Color.clear
                .overlay(alignment: .top) {
                    // `scrollSafeTapAction` wraps the cell in a real `Button` so
                    // the first tap wins iOS 18 arbitration against the grid's
                    // scroll view. See View+ScrollSafeGesture.
                    courseFace(course, spanCount: spanCount, leavesRoomHintLine: roomHint != nil)
                        .overlay(alignment: .bottomLeading) {
                            if let room = roomHint {
                                Text(room)
                                    .font(.system(size: roomHintSize))
                                    .foregroundStyle(policy.classTableCourseSecondaryTextColor)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .padding(.leading, 3)
                                    .padding(.bottom, 2)
                                    // Stay clear of the assignment badge,
                                    // which sits in the opposite corner.
                                    .padding(.trailing, hasBadge || ignoresAssignments ? badgeIconSize + 6 : 3)
                                    .accessibilityHidden(true)
                            }
                        }
                        .assignmentBadge(show: hasBadge, iconSize: badgeIconSize, padding: 4, color: markColor)
                        .ignoredAssignmentsBadge(
                            show: ignoresAssignments, iconSize: badgeIconSize, padding: 4, color: markColor
                        )
                        .frame(height: totalHeight)
                        .scrollSafeTapAction {
                            viewModel.selectCourse(course, weekday: weekday, periodId: periodId)
                        }
                        .accessibilityLabel(
                            Text(String(
                                format: String(localized: "a11y_timetable_cell"),
                                AppConstants.Periods.shortWeekdayLabel(weekday),
                                viewModel.activePeriods.first { $0.id == periodId }?.displayLabel ?? periodId,
                                // The visible hint is `accessibilityHidden`;
                                // it rides the cell's own label instead so it
                                // is announced once, in place.
                                spokenCourse(
                                    course, room: roomHint,
                                    hasAssignment: hasBadge, ignoresAssignments: ignoresAssignments
                                )
                            ))
                        )
                        .courseEditMenu(isEditable: viewModel.shownPerson == nil) {
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
                            ignoreAssignmentsButton(course, viewModel: viewModel)
                            Button(role: .destructive) {
                                viewModel.deleteCourse(course)
                            } label: {
                                Label(String(localized: "class_table_delete"), systemImage: "trash")
                            }
                        }
                }
                .id(key)
                .transition(Self.courseFade)
                .zIndex(1)

        case let .conflictStart(courseA, spanA, offsetA, courseB, spanB, offsetB, combinedSpan):
            conflictCluster(
                segments: [
                    ClassTableConflictSegment(course: courseA, span: spanA, offset: offsetA, lane: 0),
                    ClassTableConflictSegment(course: courseB, span: spanB, offset: offsetB, lane: 1),
                ],
                combinedSpan: combinedSpan,
                laneCount: 2,
                weekday: weekday,
                periodId: periodId
            )
            .id(key)
            .transition(Self.courseFade)
            .zIndex(1)

        case let .conflictMany(segments, combinedSpan, laneCount):
            conflictCluster(
                segments: segments,
                combinedSpan: combinedSpan,
                laneCount: laneCount,
                weekday: weekday,
                periodId: periodId
            )
            .id(key)
            .transition(Self.courseFade)
            .zIndex(1)

        case .skip:
            Color.clear
                .transition(.identity)
        }
    }

    /// A course's run: one block, or with period tiles one tile per period, each naming the
    /// course. Either way the run's bottom corners hold the room hint and the assignment marks.
    @ViewBuilder
    private func courseFace(_ course: SDCourse, spanCount: Int, leavesRoomHintLine: Bool) -> some View {
        if drawsPeriodTiles {
            VStack(spacing: rowSpacing) {
                ForEach(0..<spanCount, id: \.self) { index in
                    courseTile(
                        course,
                        cornerRadius: TigerDuckTheme.CornerRadius.xs,
                        lineLimit: 3,
                        leavesRoomHintLine: leavesRoomHintLine && index == spanCount - 1
                    )
                    .frame(height: cellHeight)
                }
            }
        } else {
            courseTile(
                course,
                cornerRadius: TigerDuckTheme.CornerRadius.sm,
                lineLimit: spanCount > 1 ? 3 : 2,
                leavesRoomHintLine: leavesRoomHintLine
            )
        }
    }

    private func courseTile(
        _ course: SDCourse, cornerRadius: CGFloat, lineLimit: Int, leavesRoomHintLine: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(policy.classTableCourseFill(course.color))
            .overlay {
                if outlineRequiredCourses, course.isRequired {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(course.color, lineWidth: 1)
                }
            }
            .overlay {
                Text(course.displayName)
                    .font(.system(size: courseNameSize, weight: .medium))
                    .foregroundStyle(policy.classTableCourseTextColor)
                    .lineLimit(lineLimit)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .padding(2)
                    // Leave the hint its line, or the centred name keeps the
                    // whole cell and a two-line name in a one-period cell
                    // prints straight through the room.
                    .padding(.bottom, leavesRoomHintLine ? roomHintSize + 2 : 0)
            }
    }

    private func conflictCluster(
        segments: [ClassTableConflictSegment<SDCourse>],
        combinedSpan: Int,
        laneCount: Int,
        weekday: Int,
        periodId: String
    ) -> some View {
        let clusterHeight = CGFloat(combinedSpan) * cellHeight + CGFloat(combinedSpan - 1) * rowSpacing
        return Color.clear
            .overlay(alignment: .top) {
                ConflictClusterView(
                    viewModel: viewModel,
                    showsAssignmentBadges: showsAssignmentBadges,
                    differentiateWithoutColorOverride: differentiateWithoutColor,
                    segments: segments,
                    combinedSpan: combinedSpan,
                    laneCount: laneCount,
                    cellHeight: cellHeight,
                    rowSpacing: rowSpacing,
                    weekday: weekday,
                    periodId: periodId
                )
                .frame(height: clusterHeight)
            }
    }
}

/// Renders a conflict cluster. For two courses we draw the interlocking
/// L-shapes (Γ + mirror-L) that follow the Android `ConflictCourseCell`
/// geometry; for three or more, lanes, with a course across the whole
/// width in the rows where it meets no other: the L-shape geometry only
/// resolves for two interlocking blocks.
private struct ConflictClusterView: View {
    let viewModel: ClassTableViewModel
    let showsAssignmentBadges: Bool
    let differentiateWithoutColorOverride: Bool?
    let segments: [ClassTableConflictSegment<SDCourse>]
    let combinedSpan: Int
    let laneCount: Int
    let cellHeight: CGFloat
    let rowSpacing: CGFloat
    let weekday: Int
    let periodId: String

    @Environment(\.accessibilityDifferentiateWithoutColor) private var environmentDiffWithoutColor
    private var diffWithoutColor: Bool { differentiateWithoutColorOverride ?? environmentDiffWithoutColor }
    @Environment(AppState.self) private var appState
    @Default(.outlineRequiredCourses) private var outlineRequiredCourses
    @ScaledMetric(relativeTo: .caption2) private var badgeIconSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var courseNameBaseSize: CGFloat = 8

    private var policy: VisualStylePolicy { appState.visualStylePolicy }

    /// Same convention as `TimetableGridView.courseNameSize` — see there
    /// for the rationale, including why we read through `AppState`
    /// rather than `CourseCardFontScaleStore` directly, and why we
    /// normalize at the read site.
    private var courseNameSize: CGFloat {
        courseNameBaseSize * CGFloat(CourseCardFontScale.renderScale(appState.courseCardFontScale))
    }

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
            laneLayout
        }
    }

    private var lShapeLayout: some View {
        GeometryReader { proxy in
            // Step by the grid's own cell + rowSpacing so each L sits where its solo
            // block would. Dividing the cluster height by combinedSpan would spread
            // the spacing into every row and drift the seam as the cluster grows.
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
                viewModel.presentConflictPicker(
                    courseA: courseA, courseB: courseB,
                    weekday: weekday, periodId: periodId
                )
            }
            .accessibilityLabel(
                Text("\(String(localized: "a11y_class_table_conflict_prefix")): " +
                     String(format: String(localized: "a11y_timetable_cell"),
                            AppConstants.Periods.shortWeekdayLabel(weekday),
                            viewModel.activePeriods.first { $0.id == periodId }?.displayLabel ?? periodId,
                            [courseA, courseB].map {
                                spokenCourse($0, hasAssignment: showsBadge(for: $0),
                                             ignoresAssignments: showsIgnoredMark(for: $0))
                            }
                            .joined(separator: ", ")))
            )
            .courseEditMenu(isEditable: viewModel.shownPerson == nil) {
                conflictContextMenu()
            }
        }
    }

    /// Lanes for 3+ overlapping courses: courses that never meet share one, so a chain like
    /// A(0-1) / B(1-2) / C(2-3) is two lanes wide, and each course takes the whole width in
    /// the rows where it is alone. Each course is a button of its own, so a tap selects it
    /// directly: unlike the L shapes, no seam leaves in doubt which course was meant.
    private var laneLayout: some View {
        GeometryReader { proxy in
            let geometry = ConflictLaneGeometry(
                width: proxy.size.width,
                laneCount: laneCount,
                cellHeight: cellHeight,
                rowSpacing: rowSpacing
            )
            ZStack(alignment: .topLeading) {
                ForEach(segments, id: \.course.courseNo) { segment in
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

    private func laneMember(_ segment: ClassTableConflictSegment<SDCourse>, geometry: ConflictLaneGeometry) -> some View {
        let course = segment.course
        let runs = ClassTableLayout.laneRuns(of: segment, among: segments, laneCount: laneCount).map(geometry.rect)
        let shape = ConflictLaneShape(runs: runs, cornerRadius: TigerDuckTheme.CornerRadius.sm)
        // The name goes in the largest run, which is a full-width one where there is one.
        let label = runs.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
        let hasBadge = showsBadge(for: course)
        let ignoresAssignments = showsIgnoredMark(for: course)
        let markColor = policy.classTableCourseSecondaryTextColor.opacity(0.5)
        // A course can start below the cluster's first period; VoiceOver names its own.
        let periods = viewModel.activePeriods
        let firstPeriod = periods.firstIndex { $0.id == periodId }.flatMap { periods[safe: $0 + segment.offset] }

        return Button {
            viewModel.selectCourse(course, weekday: weekday, periodId: firstPeriod?.id ?? periodId)
        } label: {
            shape
                .fill(policy.classTableCourseFill(course.color))
                .overlay {
                    if isOutlined(course) { shape.innerOutline(course.color) }
                }
                .overlay(alignment: .topLeading) {
                    Text(course.displayName)
                        .font(.system(size: courseNameSize, weight: .medium))
                        .foregroundStyle(policy.classTableCourseTextColor)
                        .lineLimit(label.height > cellHeight ? 3 : 2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .padding(2)
                        .frame(width: label.width, height: label.height)
                        .assignmentBadge(show: hasBadge, iconSize: badgeIconSize, padding: 4, color: markColor)
                        .ignoredAssignmentsBadge(
                            show: ignoresAssignments, iconSize: badgeIconSize, padding: 4, color: markColor
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
                        AppConstants.Periods.shortWeekdayLabel(weekday),
                        firstPeriod?.displayLabel ?? periodId,
                        spokenCourse(course, hasAssignment: hasBadge, ignoresAssignments: ignoresAssignments)))
        )
        .courseEditMenu(isEditable: viewModel.shownPerson == nil) {
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
            ignoreAssignmentsButton(course, viewModel: viewModel)
            Button(role: .destructive) {
                viewModel.deleteCourse(course)
            } label: {
                Label(String(localized: "class_table_delete"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func conflictContextMenu() -> some View {
        ForEach(segments, id: \.course.courseNo) { segment in
            // One menu section per course. Names may not tell them apart, since two
            // sections of one course clashing is the usual reason to open this menu, so
            // the "Pick color" row carries its cell's fill colour; `colorDot` says why there.
            Section(segment.course.displayName) {
                Button {
                    viewModel.startRename(segment.course)
                } label: {
                    Label(String(localized: "class_table_rename_title"), systemImage: "pencil")
                }
                Button {
                    viewModel.startRecolor(segment.course)
                } label: {
                    Label {
                        Text(String(localized: "class_table_pick_color"))
                    } icon: {
                        Self.colorDot(segment.course.color)
                    }
                }
                ignoreAssignmentsButton(segment.course, viewModel: viewModel)
                Button(role: .destructive) {
                    viewModel.deleteCourse(segment.course)
                } label: {
                    Label(String(localized: "class_table_delete"), systemImage: "trash")
                }
            }
        }
    }

    /// A filled dot in the course's own colour, for use as a menu icon.
    ///
    /// Drawn into a bitmap and marked `.alwaysOriginal` because UIKit retints
    /// template images, SF Symbols included, to the menu's own tint, so
    /// `Image(systemName: "circle.fill").foregroundStyle(...)` arrives grey.
    ///
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

    private func showsBadge(for course: SDCourse) -> Bool {
        showsAssignmentBadges && viewModel.hasAssignment(for: course.courseNo)
    }

    private func showsIgnoredMark(for course: SDCourse) -> Bool {
        showsAssignmentBadges && viewModel.ignoresAssignments(of: course.courseNo)
    }

    private func isOutlined(_ course: SDCourse) -> Bool {
        outlineRequiredCourses && course.isRequired
    }

    private func courseRegion(
        course: SDCourse,
        shape: ConflictLShape,
        labelAlignment: Alignment,
        barFraction: CGFloat
    ) -> some View {
        let hasBadge = showsBadge(for: course)
        let ignoresAssignments = showsIgnoredMark(for: course)
        return GeometryReader { boxProxy in
            ZStack(alignment: labelAlignment) {
                policy.classTableCourseFill(course.color)
                // The name sits in the L's bar: 72% wide, leaving Android's 28% tail, and
                // `barFraction` tall. Aligning top-right (Γ) or bottom-left (L) keeps the
                // text inside the visible color region.
                Text(course.displayName)
                    .font(.system(size: courseNameSize, weight: .medium))
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
                        .font(.system(size: badgeIconSize))
                        .foregroundStyle(policy.classTableCourseTextColor.opacity(0.7))
                        .padding(3)
                } else if ignoresAssignments {
                    IgnoredAssignmentsIcon(size: badgeIconSize)
                        .foregroundStyle(policy.classTableCourseTextColor.opacity(0.7))
                        .padding(3)
                }
            }
        }
        .overlay {
            if isOutlined(course) { shape.innerOutline(course.color) }
        }
        .clipShape(shape)
        .contentShape(shape)
    }
}
