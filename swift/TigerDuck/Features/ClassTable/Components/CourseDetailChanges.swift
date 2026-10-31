import SwiftUI
import TigerDuckCore

/// The coming changes of a course on a current-term day's sheet, a day to a line.
struct CourseDetailChanges: View {
    let course: CourseStore.Course
    /// Nil for a sheet of another term, which lists no changes.
    let date: Date?
    /// The meeting the cards show.
    let shown: CourseTimeSlot?
    let changes: SchoolCalendar.Changes

    @ViewBuilder
    var body: some View {
        let rows = date == nil ? [] : Self.changeRows(
            CourseTimeSlot.upcomingChanges(of: course, from: AppClock.now(), changes: changes), besides: shown
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

    /// At most eight days' changes in a line each. The room, time or cancellation of the meeting
    /// the cards show is left to the cards; its notes stay, as the cards have no place for them.
    static func changeRows(
        _ days: [(day: Date, meetings: [CourseTimeSlot])], besides shown: CourseTimeSlot?
    ) -> [(day: Date, summary: String)] {
        let rows = days.lazy
            .map { day in
                (day: day.day, summary: changeSummary(day.meetings, besides: shown))
            }
            .filter { !$0.summary.isEmpty }
        return Array(rows.prefix(8))
    }

    private static func changeSummary(_ meetings: [CourseTimeSlot], besides shown: CourseTimeSlot?) -> String {
        var parts: [String] = []
        for meeting in meetings {
            if let shown, meeting.periods.contains(where: shown.periods.contains),
               TaipeiTime.calendar.startOfDay(for: meeting.date) == TaipeiTime.calendar.startOfDay(for: shown.date) {
                // The cards show the tapped class; a room its meeting's other classes move to does not.
                parts += meeting.changes
                    .filter { $0.kind == .room && !shown.periods.contains(where: $0.covers) }
                    .compactMap(\.room)
                continue
            }
            if meeting.isCancelled {
                parts.append(String(localized: "course_card_cancelled"))
                continue
            }
            if meeting.hasChangedRoom { parts.append(meeting.room) }
            if meeting.hasChangedTime { parts.append("\(meeting.start.timeString) - \(meeting.end.timeString)") }
        }
        var noteIds = Set<Int>()
        parts += meetings.flatMap(\.notes).filter { noteIds.insert($0.id).inserted }.compactMap { $0.note() }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }
}
