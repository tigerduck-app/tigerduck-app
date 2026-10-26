import Foundation

/// Moodle numbers a weekly course's sections from its start date, so those need no dates. Any
/// other format leaves the week to the section names, the only place a teacher writes it.
nonisolated enum MoodleCurrentWeek {
    static let weeklyFormat = "weeks"

    static func sectionId(
        in sections: [MoodleMaterialSection],
        format: String?,
        startDate: Date?,
        now: Date,
        calendar: Calendar
    ) -> Int? {
        let today = calendar.startOfDay(for: now)
        guard format == weeklyFormat, let startDate else {
            return sectionId(byNames: sections, today: today, calendar: calendar)
        }
        guard let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate), to: today).day,
              days >= 0 else { return nil }
        return sections.first { $0.number == days / 7 + 1 }?.id
    }

    private struct DatedSection {
        let id: Int
        let start: Date
        let end: Date
    }

    /// A name often gives only its week's first day, so a section lasts at least a week. Dates
    /// that do not rise are likelier other numbers, such as "Quiz 1/2", than a schedule.
    private static func sectionId(byNames sections: [MoodleMaterialSection], today: Date, calendar: Calendar) -> Int? {
        let dated = sections.compactMap { section -> DatedSection? in
            let days = monthDays(in: section.name).compactMap { date($0, near: today, calendar: calendar) }
            guard let first = days.first, let last = days.last,
                  let week = calendar.date(byAdding: .day, value: 7, to: first),
                  let after = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
            return DatedSection(id: section.id, start: first, end: max(week, after))
        }
        guard zip(dated, dated.dropFirst()).allSatisfy({ $0.start <= $1.start }),
              let index = dated.lastIndex(where: { $0.start <= today }) else { return nil }
        let next = dated.indices.contains(index + 1) ? dated[index + 1].start : .distantFuture
        return today < min(dated[index].end, next) ? dated[index].id : nil
    }

    private static let monthDay = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})(?:[/／]|\s*月\s*)(\d{1,2})(?!\d)"#)

    private static func monthDays(in name: String) -> [(month: Int, day: Int)] {
        monthDay.matches(in: name, range: NSRange(name.startIndex..., in: name)).compactMap { match in
            guard let month = Range(match.range(at: 1), in: name).flatMap({ Int(name[$0]) }),
                  let day = Range(match.range(at: 2), in: name).flatMap({ Int(name[$0]) }) else { return nil }
            return (month, day)
        }
    }

    /// The date with that month and day nearest today, which puts a December section of a term
    /// across New Year in the year before its January ones.
    private static func date(_ monthDay: (month: Int, day: Int), near today: Date, calendar: Calendar) -> Date? {
        let year = calendar.component(.year, from: today)
        return (year - 1...year + 1)
            .compactMap { calendar.date(from: DateComponents(year: $0, month: monthDay.month, day: monthDay.day)) }
            .filter {
                calendar.component(.month, from: $0) == monthDay.month && calendar.component(.day, from: $0) == monthDay.day
            }
            .min { abs($0.timeIntervalSince(today)) < abs($1.timeIntervalSince(today)) }
    }
}
