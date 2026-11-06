import SwiftUI
import TigerDuckCore

struct CourseDetailChanges: View {
    let course: CourseStore.Course
    let meetingOnCards: CourseTimeSlot?
    let changes: SchoolCalendar.Changes

    static let shownDays = 8

    @ViewBuilder
    var body: some View {
        let rows = Self.changeRows(
            CourseTimeSlot.upcomingChanges(of: course, from: AppClock.now(), changes: changes), besides: meetingOnCards
        )
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                Divider()
                Text(String(localized: "course_detail_changes"))
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: TigerDuckTheme.Spacing.lg, verticalSpacing: 6) {
                    ForEach(rows, id: \.day) { row in
                        GridRow {
                            Text(Date.dayWeekdayFormatter.string(from: row.day))
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize()
                            Text(row.summary)
                                .accessibilityLabel(row.spoken)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.subheadline.monospacedDigit())
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }

    static func changeRows(
        _ days: [(day: Date, meetings: [CourseTimeSlot])], besides meetingOnCards: CourseTimeSlot?
    ) -> [(day: Date, summary: String, spoken: String)] {
        let rows = days.lazy
            .map { day in
                let summary = changeSummary(day.meetings, besides: meetingOnCards)
                return (day: day.day, summary: summary.text, spoken: summary.spoken)
            }
            .filter { !$0.summary.isEmpty }
        return Array(rows.prefix(shownDays))
    }

    private static func changeSummary(
        _ meetings: [CourseTimeSlot], besides meetingOnCards: CourseTimeSlot?
    ) -> (text: String, spoken: String) {
        var parts: [(text: String, spoken: String)] = []
        for meeting in meetings {
            if let onCards = meetingOnCards, meeting.overlaps(onCards) {
                parts += roomsOutsideTheCards(meeting, onCards).map { (text: $0, spoken: $0) }
                continue
            }
            if meeting.isCancelled {
                let cancelled = String(localized: "course_card_cancelled")
                parts.append((text: cancelled, spoken: cancelled))
                continue
            }
            if meeting.hasChangedRoom { parts.append((text: meeting.room, spoken: meeting.room)) }
            if meeting.hasChangedTime {
                let start = meeting.start.timeString, end = meeting.end.timeString
                parts.append((text: TimeRange.text(start, end), spoken: TimeRange.spoken(start, end)))
            }
        }
        var noteIds = Set<Int>()
        parts += meetings.flatMap(\.notes).filter { noteIds.insert($0.id).inserted }
            .compactMap { $0.note() }.map { (text: $0, spoken: $0) }
        var seen = Set<String>()
        let shown = parts.filter { seen.insert($0.text).inserted }
        return (shown.map { $0.text }.joined(separator: " · "), shown.map { $0.spoken }.joined(separator: " · "))
    }

    private static func roomsOutsideTheCards(_ meeting: CourseTimeSlot, _ onCards: CourseTimeSlot) -> [String] {
        meeting.changes
            .filter { $0.kind == .room && !onCards.periods.contains(where: $0.covers) }
            .compactMap(\.room)
    }
}

private extension CourseTimeSlot {
    func overlaps(_ other: CourseTimeSlot) -> Bool {
        periods.contains(where: other.periods.contains)
            && TaipeiTime.calendar.startOfDay(for: date) == TaipeiTime.calendar.startOfDay(for: other.date)
    }
}
