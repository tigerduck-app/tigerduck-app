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
    ) -> [(day: Date, summary: String)] {
        let rows = days.lazy
            .map { day in
                (day: day.day, summary: changeSummary(day.meetings, besides: meetingOnCards))
            }
            .filter { !$0.summary.isEmpty }
        return Array(rows.prefix(shownDays))
    }

    private static func changeSummary(_ meetings: [CourseTimeSlot], besides meetingOnCards: CourseTimeSlot?) -> String {
        var parts: [String] = []
        for meeting in meetings {
            if let onCards = meetingOnCards, meeting.overlaps(onCards) {
                parts += roomsOutsideTheCards(meeting, onCards)
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
