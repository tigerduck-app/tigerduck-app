#if os(macOS)
import SwiftUI

/// The grid itself: the glass card, its weekday columns, and the cells.
///
/// A weekday is one VStack, not a Grid row, because consecutive periods of
/// the same course render as a single spanning block and SwiftUI Grid has no
/// row spanning. Each column therefore walks `visiblePeriods` top to bottom
/// and decides per period whether it is a block start, a covered row, or
/// empty — see `ClassTableCellRole`.
///
/// Split out of MacClassTableView.swift, which keeps the state, the data
/// reads, and the page chrome around this card.
extension MacClassTableView {
    // MARK: - Glass grid card

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
            Text(period)
                .font(.subheadline.weight(.semibold))
            if let times {
                Text(times.start)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(times.end)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
    }

    /// One vertical stack of cells for `weekday`. Walks `visiblePeriods` one
    /// row at a time; `ClassTableLayout.cellRole` tells us when a row is the
    /// start of a multi-row block (solo or 衝堂 cluster) so contiguous runs
    /// render as a single tall block — same partitioning the iPhone uses.
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
                cellView(role: role, weekday: weekday)
            }
        }
    }

    @ViewBuilder
    private func cellView(role: ClassTableCellRole<SDCourse>, weekday: Int) -> some View {
        switch role {
        case .empty:
            emptyCell.frame(height: cellHeight)
        case let .solo(course, spanCount):
            courseCell(course)
                .frame(height: blockHeight(spanCount))
                .onTapGesture { selectedSlot = SelectedSlot(course: course, weekday: weekday) }
        case let .conflictStart(a, spanA, offsetA, b, spanB, offsetB, combinedSpan):
            // 衝堂 renders as a horizontal split where each half is a column
            // sized to that course's actual span and positioned at its
            // offset within the cluster. Without offset-aware columns,
            // mismatched spans (e.g. A on periods 1–3 overlapping B only on
            // period 2) would show B as a full-height column and make it
            // clickable in rows where the two courses don't actually meet.
            HStack(spacing: rowSpacing) {
                conflictColumn(course: a, span: spanA, offset: offsetA, combinedSpan: combinedSpan, weekday: weekday)
                conflictColumn(course: b, span: spanB, offset: offsetB, combinedSpan: combinedSpan, weekday: weekday)
            }
            .frame(height: blockHeight(combinedSpan))
        case let .conflictMany(segments, combinedSpan):
            // Same offset-aware column layout as the 2-course case
            // above, just N columns wide. Each segment gets a column
            // sized to its own span and positioned at its offset, so a
            // staircase like A(rows 0-1) / B(rows 1-2) / C(rows 2-3)
            // paints each course only in the rows it actually occupies.
            HStack(spacing: rowSpacing) {
                ForEach(segments, id: \.course.courseNo) { segment in
                    conflictColumn(
                        course: segment.course,
                        span: segment.span,
                        offset: segment.offset,
                        combinedSpan: combinedSpan,
                        weekday: weekday
                    )
                }
            }
            .frame(height: blockHeight(combinedSpan))
        case .skip:
            EmptyView()
        }
    }

    private func blockHeight(_ span: Int) -> CGFloat {
        CGFloat(span) * cellHeight + CGFloat(max(span - 1, 0)) * rowSpacing
    }

    /// One column of a 衝堂 cluster. Empty spacers above/below the course
    /// block reserve the rows the course isn't scheduled in so an overlap
    /// only meeting in part of the cluster doesn't extend to the rest.
    @ViewBuilder
    private func conflictColumn(course: SDCourse, span: Int, offset: Int, combinedSpan: Int, weekday: Int) -> some View {
        let bottom = max(combinedSpan - offset - span, 0)
        VStack(spacing: rowSpacing) {
            if offset > 0 {
                Color.clear.frame(height: blockHeight(offset))
            }
            courseCell(course)
                .frame(height: blockHeight(span))
                .onTapGesture { selectedSlot = SelectedSlot(course: course, weekday: weekday) }
                .accessibilityLabel(Text(course.displayName))
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

    private func courseCell(_ course: SDCourse) -> some View {
        let color = TigerDuckTheme.courseColor(for: course.courseNo)
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
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .contextMenu {
            // Rename writes to a courseNo-keyed store shared across semesters;
            // only expose it from the current semester to avoid leaking aliases
            // into other terms. See `isViewingCurrentSemester`.
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
