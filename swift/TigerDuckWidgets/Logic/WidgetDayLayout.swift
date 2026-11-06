import Foundation
import TigerDuckCore

struct WidgetClassRow: nonisolated Equatable, Identifiable, Sendable {
    enum Phase: nonisolated Equatable, Sendable {
        case past
        case ongoing(progress: Double)
        case upcoming
    }

    let row: WidgetTimelineDerivation.TodayRow
    let phase: Phase
    let start: Int
    let end: Int

    var id: String { row.id }
    var isPast: Bool { phase == .past }

    var progress: Double? {
        if case .ongoing(let progress) = phase { return progress }
        return nil
    }
}

enum WidgetDayLayout {
    static func rows(snapshot: WidgetSnapshot, on day: Date, now: Date) -> [WidgetClassRow] {
        let calendar = TaipeiTime.calendar
        let nowMinute: Int
        if calendar.isDate(day, inSameDayAs: now) {
            nowMinute = WidgetTimelineDerivation.minuteOfDay(now)
        } else {
            nowMinute = day < now ? .max : .min
        }
        return WidgetTimelineDerivation.todayRows(snapshot: snapshot, at: day).compactMap { row in
            guard let start = ClassTimeline.minutes(of: row.startTime),
                  let end = ClassTimeline.minutes(of: row.endTime) else { return nil }
            let phase: WidgetClassRow.Phase
            if end <= nowMinute {
                phase = .past
            } else if start <= nowMinute, !row.isCancelled {
                phase = .ongoing(progress: Double(nowMinute - start) / Double(max(end - start, 1)))
            } else {
                phase = .upcoming
            }
            return WidgetClassRow(row: row, phase: phase, start: start, end: end)
        }
    }

    static func window(_ rows: [WidgetClassRow], limit: Int) -> ArraySlice<WidgetClassRow> {
        guard rows.count > limit else { return rows[...] }
        let firstNotPast = rows.firstIndex { !$0.isPast } ?? rows.count
        let start = min(firstNotPast, rows.count - limit)
        return rows[start..<start + limit]
    }

    static func hours(of rows: [WidgetClassRow]) -> ClosedRange<Int>? {
        guard let first = rows.map(\.start).min(), let last = rows.map(\.end).max() else { return nil }
        return first / 60...max(first / 60 + 1, (last + 59) / 60)
    }

    static func nowLine(rows: [WidgetClassRow], now: Date) -> Int? {
        guard !rows.contains(where: { $0.progress != nil }), let hours = hours(of: rows) else { return nil }
        let minute = WidgetTimelineDerivation.minuteOfDay(now)
        return (hours.lowerBound * 60...hours.upperBound * 60).contains(minute) ? minute : nil
    }

    static let tickMinutes = 5

    /// WidgetKit redraws a widget only at its timeline entries, so progress bars and the now line
    /// need one every few minutes between the class boundaries.
    static func ticks(snapshot: WidgetSnapshot, after now: Date) -> [Date] {
        guard let hours = hours(of: rows(snapshot: snapshot, on: now, now: now)) else { return [] }
        let dayStart = TaipeiTime.calendar.startOfDay(for: now)
        return stride(from: hours.lowerBound * 60, through: hours.upperBound * 60, by: tickMinutes).compactMap {
            TaipeiTime.calendar.date(byAdding: .minute, value: $0, to: dayStart)
        }
        .filter { $0 > now }
    }
}

