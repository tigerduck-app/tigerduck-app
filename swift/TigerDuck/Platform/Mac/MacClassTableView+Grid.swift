#if os(macOS)
import SwiftUI

extension MacClassTableView {

    var glassGridCard: some View {
        VStack(spacing: rowSpacing) {
            headerRow
            HStack(alignment: .top, spacing: rowSpacing) {
                periodLabelColumn
                ForEach(weekdays, id: \.self) { weekday in
                    weekdayColumn(weekday)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }

    private var headerRow: some View {
        HStack(spacing: rowSpacing) {
            Color.clear.frame(width: periodLabelWidth, height: 22)
            ForEach(weekdays, id: \.self) { weekday in
                Text(weekdayLabel(weekday))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func weekdayLabel(_ weekday: Int) -> String {
        switch weekday {
        case 1...5: return AppConstants.Periods.weekdays[safe: weekday - 1] ?? "?"
        case 6: return AppConstants.Periods.weekendDays[safe: 0] ?? "?"
        case 7: return AppConstants.Periods.weekendDays[safe: 1] ?? "?"
        default: return "?"
        }
    }

    private var periodLabelColumn: some View {
        VStack(spacing: rowSpacing) {
            ForEach(visiblePeriods, id: \.self) { period in
                periodLabel(period)
                    .frame(height: cellHeight)
            }
        }
        .frame(width: periodLabelWidth)
    }

    private func periodLabel(_ period: String) -> some View {
        let times = AppConstants.PeriodTimes.mapping[period]
        return VStack(alignment: .trailing, spacing: 2) {
            if let times {
                Text(times.start)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(period)
                .font(.subheadline.weight(.semibold))
            if let times {
                Text(times.end)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private func weekdayColumn(_ weekday: Int) -> some View {
        let periods = visiblePeriods
        VStack(spacing: rowSpacing) {
            ForEach(periods.indices, id: \.self) { index in
                let role = ClassTableLayout.cellRole(
                    courses: courses,
                    periodIds: periods,
                    weekday: weekday,
                    periodIndex: index,
                    keyOf: { $0.courseNo },
                    scheduleOf: { $0.schedule }
                )
                cellView(role: role, weekday: weekday, periods: periods, index: index)
            }
        }
    }

    @ViewBuilder
    private func cellView(role: ClassTableCellRole<SDCourse>, weekday: Int, periods: [String], index: Int) -> some View {
        let periodId = periods[index]
        switch role {
        case .empty:
            emptyCell.frame(height: cellHeight)
        case let .solo(course, spanCount):
            courseCell(course, roomHint: roomHint(course, weekday: weekday, periodId: periodId))
                .frame(height: blockHeight(spanCount))
                .onTapGesture { selectedSlot = SelectedSlot(course: course, weekday: weekday, periodId: periodId) }
        case let .conflictStart(a, spanA, offsetA, b, spanB, offsetB, combinedSpan):
            HStack(spacing: rowSpacing) {
                conflictColumn(
                    course: a, span: spanA, offset: offsetA, combinedSpan: combinedSpan,
                    weekday: weekday, periodId: periods[index + offsetA]
                )
                conflictColumn(
                    course: b, span: spanB, offset: offsetB, combinedSpan: combinedSpan,
                    weekday: weekday, periodId: periods[index + offsetB]
                )
            }
            .frame(height: blockHeight(combinedSpan))
        case let .conflictMany(segments, combinedSpan, laneCount):
            HStack(spacing: rowSpacing) {
                ForEach(0..<laneCount, id: \.self) { lane in
                    ZStack(alignment: .top) {
                        ForEach(segments.filter { $0.lane == lane }) { segment in
                            conflictColumn(
                                course: segment.course,
                                span: segment.span,
                                offset: segment.offset,
                                combinedSpan: combinedSpan,
                                weekday: weekday,
                                periodId: periods[index + segment.offset]
                            )
                        }
                    }
                }
            }
            .frame(height: blockHeight(combinedSpan))
        case .skip:
            EmptyView()
        }
    }

    private func roomHint(_ course: SDCourse, weekday: Int, periodId: String) -> String? {
        guard appState.showClassroomInClassTable else { return nil }
        return CourseRoomHint.room(for: course, weekday: weekday, periodId: periodId)
    }

    private func blockHeight(_ span: Int) -> CGFloat {
        CGFloat(span) * cellHeight + CGFloat(max(span - 1, 0)) * rowSpacing
    }

    @ViewBuilder
    private func conflictColumn(
        course: SDCourse, span: Int, offset: Int, combinedSpan: Int, weekday: Int, periodId: String
    ) -> some View {
        let bottom = max(combinedSpan - offset - span, 0)
        VStack(spacing: rowSpacing) {
            if offset > 0 {
                Color.clear.frame(height: blockHeight(offset))
            }
            courseCell(course)
                .frame(height: blockHeight(span))
                .onTapGesture { selectedSlot = SelectedSlot(course: course, weekday: weekday, periodId: periodId) }
                .accessibilityLabel(Text(spokenName(course)))
            if bottom > 0 {
                Color.clear.frame(height: blockHeight(bottom))
            }
        }
    }

    private var emptyCell: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.04), lineWidth: 0.5)
            )
    }

    private static let ignoredMarkSize: CGFloat = 11

    private func ignoresAssignments(_ course: SDCourse) -> Bool {
        ignoredAssignmentCourses.contains(CourseTombstone.key(semester: selectedSemester, courseNo: course.courseNo))
    }

    private func spokenName(_ course: SDCourse) -> String {
        guard ignoresAssignments(course) else { return course.displayName }
        return course.displayName + ", " + String(localized: "a11y_class_table_cell_assignments_ignored")
    }

    private func courseCell(_ course: SDCourse, roomHint: String? = nil) -> some View {
        let color = TigerDuckTheme.courseColor(for: course.courseNo)
        let ignored = ignoresAssignments(course)
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
        .courseEditMenu(isEditable: shownPerson == nil) {
            if isViewingCurrentSemester {
                Button {
                    startRename(course)
                } label: {
                    Label(String(localized: "class_table_rename_title"), systemImage: "pencil")
                }
            }
            Button {
                courseToRecolor = course
            } label: {
                Label(String(localized: "course_color_picker_title"), systemImage: "paintpalette")
            }
            if isViewingCurrentSemester {
                Button {
                    setIgnoresAssignments(!ignored, for: course)
                } label: {
                    if ignored {
                        Label(String(localized: "class_table_ignore_assignments_undo"), systemImage: "arrow.uturn.backward")
                    } else {
                        Label(String(localized: "class_table_ignore_assignments"), systemImage: "archivebox")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    deleteCourse(course)
                } label: {
                    Label(String(localized: "class_table_delete"), systemImage: "trash")
                }
            }
        }
    }
}
#endif
